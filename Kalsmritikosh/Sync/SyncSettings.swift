//
//  SyncSettings.swift
//  Kalsmritikosh
//
//  X-5 — where this Mac syncs and with which keys. The folder is remembered as a
//  security-scoped bookmark; the store key (derived from the passphrase — the passphrase
//  itself is never kept) and this device's signing key live in the Keychain. Under the test
//  host both keys stay in memory, so tests never touch the person's Keychain.
//

import Foundation
import CryptoKit
import Security
import AppKit

nonisolated enum SyncSettings {
    static let folderKey = "kalsmritikosh.sync.folderBookmark"
    static let deviceIDKey = "kalsmritikosh.sync.deviceID"
    static let storeIDKey = "kalsmritikosh.sync.storeID"
    static let storeKeyService = "ecosanskritiinnovation.Kalsmritikosh.sync-store-key"
    static let deviceKeyService = "ecosanskritiinnovation.Kalsmritikosh.sync-device-key"
    static let usesMemoryStore = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    private static let memory = MemoryItems()

    static var deviceID: String {
        let d = UserDefaults.standard
        if let id = d.string(forKey: deviceIDKey) { return id }
        let id = UUID().uuidString
        d.set(id, forKey: deviceIDKey)
        return id
    }

    static var deviceName: String { Host.current().localizedName ?? "This Mac" }

    static var isConfigured: Bool { UserDefaults.standard.data(forKey: folderKey) != nil && storeKey() != nil }

    // MARK: - Folder

    static func remember(folder: URL) throws {
        let bookmark = try folder.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        UserDefaults.standard.set(bookmark, forKey: folderKey)
    }

    /// The remembered folder (access must be started by the caller); nil when none or stale.
    static func folder() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: folderKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil,
                                 bookmarkDataIsStale: &stale) else { return nil }
        if stale { try? remember(folder: url) }
        return url
    }

    /// Stop syncing on this Mac: forget the folder and the store key. Nothing in the folder or
    /// in this Mac's archive is removed.
    static func forget() {
        UserDefaults.standard.removeObject(forKey: folderKey)
        UserDefaults.standard.removeObject(forKey: storeIDKey)
        delete(service: storeKeyService)
    }

    // MARK: - Keys

    static func storeKey() -> SymmetricKey? { load(service: storeKeyService).map { SymmetricKey(data: $0) } }

    static func saveStoreKey(_ key: SymmetricKey, storeID: String) throws {
        try save(key.withUnsafeBytes { Data($0) }, service: storeKeyService)
        UserDefaults.standard.set(storeID, forKey: storeIDKey)
    }

    static func signingKey() throws -> Curve25519.Signing.PrivateKey {
        if let raw = load(service: deviceKeyService), let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) {
            return key
        }
        let key = Curve25519.Signing.PrivateKey()
        try save(key.rawRepresentation, service: deviceKeyService)
        return key
    }

    // MARK: - Keychain

    enum KeychainFailure: Error, LocalizedError {
        case status(OSStatus)
        var errorDescription: String? {
            if case .status(let s) = self { return "The sync key could not be saved in the Keychain (error \(s))." }
            return nil
        }
    }

    private static func load(service: String) -> Data? {
        if usesMemoryStore { return memory.get(service) }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: "sync", kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    private static func save(_ data: Data, service: String) throws {
        if usesMemoryStore { memory.set(service, data); return }
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: "sync"]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let rc = SecItemAdd(add as CFDictionary, nil)
        guard rc == errSecSuccess else { throw KeychainFailure.status(rc) }
    }

    private static func delete(service: String) {
        if usesMemoryStore { memory.set(service, nil); return }
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                       kSecAttrAccount as String: "sync"] as CFDictionary)
    }
}

nonisolated private final class MemoryItems: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    func get(_ k: String) -> Data? { lock.lock(); defer { lock.unlock() }; return items[k] }
    func set(_ k: String, _ v: Data?) { lock.lock(); items[k] = v; lock.unlock() }
}
