import Foundation

final class MemoryCredentials: CredentialStorage {
    var values: [UUID: String] = [:]
    var failWrites = false
    var onSet: (() throws -> Void)?
    var onRemove: (() -> Void)?
    func password(for id: UUID) throws -> String? { values[id] }
    func set(_ password: String, for id: UUID) throws {
        if failWrites { throw Failure.injected }
        values[id] = password
        try onSet?()
    }
    func remove(for id: UUID) throws { values.removeValue(forKey: id); onRemove?() }
}
enum Failure: Error { case injected, expectedFailure }

@main struct StorageTests {
    @MainActor static func main() throws {
        try legacyMigration()
        try failedMigrationPreservesSource()
        try defaultsMigration()
        try bothLegacySourcesMigrate()
        try corruptStoreCannotBeOverwritten()
        try fileFailureRestoresCredentials()
        try failedMetadataMigrationPreservesSource()
        try rollbackFailureIsReported()
        try existingStoreImportsLegacyWithoutReplacingEdits()
        try cleanupFailureRetriesWithoutDuplicates()
        try portValidation()
        print("Storage tests passed (11 scenarios)")
    }

    static func directory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    static func connection(_ id: UUID = UUID()) -> SavedConnection {
        SavedConnection(id: id, name: "Mac", host: "mac.local", port: 5900, username: "me", lastConnected: nil)
    }
    static func legacyData(_ id: UUID) -> Data {
        Data("""
        [{"id":"\(id)","name":"Mac","host":"mac.local","port":5900,"username":"me","password":"secret"}]
        """.utf8)
    }
    static func expectFailure(_ operation: () throws -> Void) throws {
        do { try operation() } catch { return }
        throw Failure.expectedFailure
    }
    @MainActor static func legacyMigration() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let legacy = dir.appendingPathComponent("connections.json")
        let id = UUID()
        try legacyData(id).write(to: legacy)
        let file = dir.appendingPathComponent("deskpad-connections.json")
        let credentials = MemoryCredentials()
        let store = ConnectionStore(fileURL: file, keychain: credentials)
        precondition(store.connections.count == 1, "Legacy connection should migrate")
        let password = try store.password(for: store.connections[0])
        precondition(password == "secret")
        let json = try String(contentsOf: file, encoding: .utf8)
        precondition(!json.contains("secret") && !json.contains("password"))
        precondition(!FileManager.default.fileExists(atPath: legacy.path))
        let reopened = ConnectionStore(fileURL: file, keychain: credentials)
        precondition(reopened.connections == store.connections)
        try store.delete(store.connections[0])
        precondition(store.connections.isEmpty && credentials.values[id] == nil)
    }
    @MainActor static func failedMigrationPreservesSource() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let legacy = dir.appendingPathComponent("connections.json")
        let original = legacyData(UUID())
        try original.write(to: legacy)
        let file = dir.appendingPathComponent("deskpad-connections.json")
        let credentials = MemoryCredentials()
        credentials.failWrites = true
        let failed = ConnectionStore(fileURL: file, keychain: credentials)
        precondition(failed.loadError != nil)
        let retained = try Data(contentsOf: legacy)
        precondition(retained == original && !FileManager.default.fileExists(atPath: file.path))
        try expectFailure { try failed.save(connection(), newPassword: "replacement") }
        credentials.failWrites = false
        let retried = ConnectionStore(fileURL: file, keychain: credentials)
        precondition(retried.connections.count == 1 && retried.loadError == nil)
    }
    @MainActor static func defaultsMigration() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let suite = "DeskPadStorageTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("mac.local", forKey: "lastHost")
        defaults.set("5901", forKey: "lastPort")
        defaults.set("me", forKey: "lastUsername")
        defaults.set("old-password", forKey: "lastPassword")
        let credentials = MemoryCredentials()
        credentials.failWrites = true
        let file = dir.appendingPathComponent("deskpad-connections.json")
        let failed = ConnectionStore(fileURL: file, keychain: credentials, defaults: defaults)
        precondition(failed.loadError != nil && defaults.string(forKey: "lastPassword") == "old-password")
        credentials.failWrites = false
        let store = ConnectionStore(fileURL: file, keychain: credentials, defaults: defaults)
        precondition(store.connections.count == 1 && store.connections[0].port == 5901)
        let password = try store.password(for: store.connections[0])
        precondition(password == "old-password" && defaults.object(forKey: "lastPassword") == nil)
    }
    @MainActor static func bothLegacySourcesMigrate() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try legacyData(UUID()).write(to: dir.appendingPathComponent("connections.json"))
        let suite = "DeskPadStorageTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("second.local", forKey: "lastHost")
        defaults.set("second-secret", forKey: "lastPassword")
        let store = ConnectionStore(fileURL: dir.appendingPathComponent("deskpad-connections.json"), keychain: MemoryCredentials(), defaults: defaults)
        precondition(store.connections.count == 2, "Both legacy sources must migrate")
        precondition(defaults.object(forKey: "lastPassword") == nil)
    }
    @MainActor static func corruptStoreCannotBeOverwritten() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("deskpad-connections.json")
        let corrupt = Data("not JSON".utf8)
        try corrupt.write(to: file)
        let store = ConnectionStore(fileURL: file, keychain: MemoryCredentials())
        precondition(store.loadError != nil)
        try expectFailure { try store.save(connection(), newPassword: "password") }
        try expectFailure { try store.delete(connection()) }
        try expectFailure { try store.markConnected(connection()) }
        let after = try Data(contentsOf: file)
        precondition(after == corrupt)
    }
    @MainActor static func fileFailureRestoresCredentials() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("deskpad-connections.json")
        let credentials = MemoryCredentials()
        let store = ConnectionStore(fileURL: file, keychain: credentials)
        let saved = connection()
        try store.save(saved, newPassword: "original")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        try expectFailure { try store.save(saved, newPassword: "replacement") }
        let password = try store.password(for: saved)
        precondition(password == "original" && store.connections == [saved])
        try expectFailure { try store.delete(saved) }
        let restored = try store.password(for: saved)
        precondition(restored == "original" && store.connections == [saved])
    }
    @MainActor static func failedMetadataMigrationPreservesSource() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let legacy = dir.appendingPathComponent("connections.json")
        let original = legacyData(UUID())
        try original.write(to: legacy)
        let file = dir.appendingPathComponent("deskpad-connections.json")
        let credentials = MemoryCredentials()
        credentials.onSet = { try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false) }
        let store = ConnectionStore(fileURL: file, keychain: credentials)
        precondition(store.loadError != nil)
        let retained = try Data(contentsOf: legacy)
        precondition(retained == original)
        try FileManager.default.removeItem(at: file)
        credentials.onSet = nil
        let retry = ConnectionStore(fileURL: file, keychain: credentials)
        precondition(retry.connections.count == 1 && retry.loadError == nil)
    }
    @MainActor static func rollbackFailureIsReported() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("deskpad-connections.json")
        let credentials = MemoryCredentials()
        let store = ConnectionStore(fileURL: file, keychain: credentials)
        let saved = connection()
        try store.save(saved, newPassword: "original")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        credentials.onRemove = { credentials.failWrites = true }
        do {
            try store.delete(saved)
            throw Failure.expectedFailure
        } catch ConnectionStorageError.rollbackFailed(let write, let rollback) {
            precondition((write as NSError).domain == NSCocoaErrorDomain)
            precondition(rollback is Failure)
            precondition(store.connections == [saved])
        }
    }
    @MainActor static func existingStoreImportsLegacyWithoutReplacingEdits() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("deskpad-connections.json")
        let saved = connection()
        let credentials = MemoryCredentials()
        let store = ConnectionStore(fileURL: file, keychain: credentials)
        try store.save(saved, newPassword: "new-secret")
        try legacyData(saved.id).write(to: dir.appendingPathComponent("connections.json"))
        let reopened = ConnectionStore(fileURL: file, keychain: credentials)
        precondition(reopened.connections == [saved])
        let password = try reopened.password(for: saved)
        precondition(password == "new-secret")
        precondition(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("connections.json").path))
    }
    @MainActor static func cleanupFailureRetriesWithoutDuplicates() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let legacy = dir.appendingPathComponent("connections.json")
        try legacyData(UUID()).write(to: legacy)
        let suite = "DeskPadStorageTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("second.local", forKey: "lastHost")
        defaults.set("defaults-secret", forKey: "lastPassword")
        let file = dir.appendingPathComponent("deskpad-connections.json")
        let credentials = MemoryCredentials()
        let failed = ConnectionStore(fileURL: file, keychain: credentials, defaults: defaults,
            removeLegacyFile: { _ in throw Failure.injected })
        precondition(failed.connections.count == 2 && failed.loadError != nil)
        precondition(FileManager.default.fileExists(atPath: legacy.path))
        precondition(defaults.string(forKey: "lastPassword") == "defaults-secret")
        let retry = ConnectionStore(fileURL: file, keychain: credentials, defaults: defaults)
        precondition(retry.connections == failed.connections && retry.loadError == nil)
        precondition(!FileManager.default.fileExists(atPath: legacy.path))
        precondition(defaults.object(forKey: "lastPassword") == nil)
    }
    @MainActor static func portValidation() throws {
        for value in ["", "0", "65536", "-1", "oops", "5900.5"] {
            try expectFailure { _ = try ConnectionStore.parsePort(value) }
        }
        let low = try ConnectionStore.parsePort("1")
        let high = try ConnectionStore.parsePort("65535")
        precondition(low == 1 && high == 65535)
    }
}
