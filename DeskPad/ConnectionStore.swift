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

@Observable
@MainActor
final class ConnectionStore {
    private(set) var connections: [SavedConnection] = []
    private(set) var loadError: String?

    private let fileURL: URL
    private let keychain = CredentialKeychain()

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("deskpad-connections.json")

        do {
            connections = try Self.readConnections(from: self.fileURL)
        } catch {
            loadError = "저장된 연결을 읽지 못했습니다: \(error.localizedDescription)"
        }
    }

    func save(_ connection: SavedConnection, newPassword: String?) throws {
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
                try keychain.restore(previousPassword, for: connection.id)
            }
            throw error
        }
    }

    func delete(_ connection: SavedConnection) throws {
        let previousPassword = try keychain.password(for: connection.id)
        try keychain.remove(for: connection.id)

        let updated = connections.filter { $0.id != connection.id }
        do {
            try Self.writeConnections(updated, to: fileURL)
            connections = updated
            loadError = nil
        } catch {
            try keychain.restore(previousPassword, for: connection.id)
            throw error
        }
    }

    func markConnected(_ connection: SavedConnection) throws {
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

private struct CredentialKeychain {
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

    func restore(_ password: String?, for id: UUID) throws {
        try remove(for: id)
        if let password { try set(password, for: id) }
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
