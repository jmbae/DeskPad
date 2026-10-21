import Foundation
import Observation
import Security

struct SavedConnection: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var host: String
    var port: UInt16
    var username: String
    var lastConnected: Date?

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? host : trimmed
    }
}

enum ConnectionValidationError: LocalizedError {
    case emptyHost
    case invalidHost
    case invalidPort

    var errorDescription: String? {
        switch self {
        case .emptyHost:
            "호스트를 입력하세요."
        case .invalidHost:
            "호스트에는 공백이나 경로를 포함할 수 없습니다."
        case .invalidPort:
            "포트는 1~65535 사이의 숫자여야 합니다."
        }
    }
}

protocol CredentialStorage {
    func password(for id: UUID) throws -> String?
    func set(_ password: String, for id: UUID) throws
    func remove(for id: UUID) throws
}

enum ConnectionStorageError: LocalizedError {
    case unreadableStore
    case rollbackFailed(Error, Error)
    var errorDescription: String? {
        switch self {
        case .unreadableStore: "저장된 연결을 읽지 못해 변경할 수 없습니다. 원본 파일을 복구한 후 다시 실행하세요."
        case let .rollbackFailed(write, rollback): "저장 실패: \(write.localizedDescription). 자격 증명 복원 실패: \(rollback.localizedDescription)"
        }
    }
}

@Observable
@MainActor
final class ConnectionStore {
    private(set) var connections: [SavedConnection] = []
    private(set) var loadError: String?

    private let fileURL: URL
    private let keychain: any CredentialStorage
    private var writable = true
    private let removeLegacyFile: (URL) throws -> Void

    init(fileURL: URL? = nil, keychain: (any CredentialStorage)? = nil, defaults: UserDefaults = .standard,
         removeLegacyFile: @escaping (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }) {
        self.fileURL = fileURL ?? FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        )[0].appendingPathComponent("deskpad-connections.json")
        self.keychain = keychain ?? CredentialKeychain()
        self.removeLegacyFile = removeLegacyFile
        do {
            if FileManager.default.fileExists(atPath: self.fileURL.path) {
                connections = try Self.readConnections(from: self.fileURL)
            }
            try migrateLegacy(defaults: defaults)
        } catch {
            writable = false
            loadError = "저장된 연결을 읽지 못했습니다: \(error.localizedDescription)"
        }
    }

    private func migrateLegacy(defaults: UserDefaults) throws {
        let legacyURL = fileURL.deletingLastPathComponent().appendingPathComponent("connections.json")
        var passwords: [UUID: String] = [:]
        let legacyExists = FileManager.default.fileExists(atPath: legacyURL.path)
        var migrated: [SavedConnection] = []
        if legacyExists {
            let data = try Data(contentsOf: legacyURL)
            migrated = try JSONDecoder().decode([SavedConnection].self, from: data)
            let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
            for row in rows {
                if let rawID = row["id"] as? String, let id = UUID(uuidString: rawID), let password = row["password"] as? String {
                    passwords[id] = password
                }
            }
        }
        let hasDefaults = defaults.string(forKey: "lastHost")?.isEmpty == false
        if let host = defaults.string(forKey: "lastHost"), !host.isEmpty {
            let port = try Self.parsePort(defaults.string(forKey: "lastPort") ?? "5900")
            try Self.validate(host: host, port: port)
            // Persist only an identifier so interrupted retries reuse the same Keychain account.
            let tokenKey = "deskpadLegacyConnectionID"
            let id = defaults.string(forKey: tokenKey).flatMap(UUID.init(uuidString:)) ?? UUID()
            defaults.set(id.uuidString, forKey: tokenKey)
            let connection = SavedConnection(id: id, name: "", host: host, port: port,
                username: defaults.string(forKey: "lastUsername") ?? "", lastConnected: nil)
            migrated.append(connection)
            passwords[connection.id] = defaults.string(forKey: "lastPassword") ?? ""
        }
        guard legacyExists || hasDefaults else { return }
        // Keep every legacy source intact until credentials and merged metadata are durable.
        // Existing records and credentials take precedence over stale legacy snapshots.
        var merged = connections
        for connection in migrated {
            try Self.validate(host: connection.host, port: connection.port)
            if let password = passwords[connection.id], try keychain.password(for: connection.id) == nil {
                try keychain.set(password, for: connection.id)
            }
            if !merged.contains(where: { $0.id == connection.id }) { merged.append(connection) }
        }
        try Self.writeConnections(merged, to: fileURL)
        connections = merged
        // A cleanup error remains visible, and the next launch repeats this idempotent merge.
        if legacyExists { try removeLegacyFile(legacyURL) }
        if hasDefaults {
            // Remove the secret first; an interrupted cleanup must not orphan a password without its host.
            for key in ["lastPassword", "lastUsername", "lastPort", "lastHost", "deskpadLegacyConnectionID"] {
                defaults.removeObject(forKey: key)
            }
        }
    }

    private func requireWritable() throws {
        guard writable else { throw ConnectionStorageError.unreadableStore }
    }

    private func restore(_ password: String?, for id: UUID, after error: Error) throws -> Never {
        do {
            if let password { try keychain.set(password, for: id) }
            else { try keychain.remove(for: id) }
        } catch let rollback {
            throw ConnectionStorageError.rollbackFailed(error, rollback)
        }
        throw error
    }

    func save(_ connection: SavedConnection, newPassword: String?) throws {
        try requireWritable()
        try Self.validate(host: connection.host, port: connection.port)
        let previousPassword = try keychain.password(for: connection.id)
        let password = newPassword?.isEmpty == false ? newPassword : nil

        if let password {
            try keychain.set(password, for: connection.id)
        }

        var updated = connections
        if let index = updated.firstIndex(where: { $0.id == connection.id }) {
            updated[index] = connection
        } else {
            updated.append(connection)
        }

        do {
            try Self.writeConnections(updated, to: fileURL)
            connections = updated.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            loadError = nil
        } catch {
            if password != nil {
                try restore(previousPassword, for: connection.id, after: error)
            }
            throw error
        }
    }

    func delete(_ connection: SavedConnection) throws {
        try requireWritable()
        let previousPassword = try keychain.password(for: connection.id)
        try keychain.remove(for: connection.id)

        let updated = connections.filter { $0.id != connection.id }
        do {
            try Self.writeConnections(updated, to: fileURL)
            connections = updated
            loadError = nil
        } catch {
            try restore(previousPassword, for: connection.id, after: error)
        }
    }

    func markConnected(_ connection: SavedConnection) throws {
        try requireWritable()
        var updated = connections
        guard let index = updated.firstIndex(where: { $0.id == connection.id }) else { return }
        updated[index].lastConnected = .now
        try Self.writeConnections(updated, to: fileURL)
        connections = updated
    }

    func hasPassword(for connection: SavedConnection) throws -> Bool {
        try keychain.password(for: connection.id) != nil
    }

    func password(for connection: SavedConnection) throws -> String? {
        try keychain.password(for: connection.id)
    }

    static func validate(host: String, port: UInt16) throws {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { throw ConnectionValidationError.emptyHost }
        guard !host.contains(where: \.isWhitespace), !host.contains("/") else {
            throw ConnectionValidationError.invalidHost
        }
        guard port > 0 else { throw ConnectionValidationError.invalidPort }
    }

    static func parsePort(_ value: String) throws -> UInt16 {
        guard let port = UInt16(value), port > 0 else {
            throw ConnectionValidationError.invalidPort
        }
        return port
    }

    private static func readConnections(from url: URL) throws -> [SavedConnection] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([SavedConnection].self, from: data)
    }

    private static func writeConnections(_ connections: [SavedConnection], to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(connections)
        try data.write(to: url, options: .atomic)
    }
}

struct CredentialKeychain: CredentialStorage {
    private let service = "com.africastart.DeskPad.credentials"

    func password(for id: UUID) throws -> String? {
        var query = baseQuery(for: id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let password = String(data: data, encoding: .utf8) else {
            throw keychainError(status)
        }
        return password
    }

    func set(_ password: String, for id: UUID) throws {
        let data = Data(password.utf8)
        let query = baseQuery(for: id)
        let attributes = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw keychainError(updateStatus) }

        var insertion = query
        insertion[kSecValueData as String] = data
        insertion[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(insertion as CFDictionary, nil)
        guard status == errSecSuccess else { throw keychainError(status) }
    }

    func remove(for id: UUID) throws {
        let status = SecItemDelete(baseQuery(for: id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw keychainError(status)
        }
    }

    private func baseQuery(for id: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString
        ]
    }

    private func keychainError(_ status: OSStatus) -> NSError {
        NSError(
            domain: NSOSStatusErrorDomain,
            code: Int(status),
            userInfo: [NSLocalizedDescriptionKey: "Keychain 오류 (\(status))"]
        )
    }
}
