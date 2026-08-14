//
//  AuditChainSecret.swift
//  Kalsmritikosh
//
//  The per-installation HMAC secret that keys the audit hash chain
//  (AuditChainService). Kept in the Keychain — separate from the SQLite
//  ledger — so an actor who edits the database file cannot forge a valid
//  chain without also extracting the Keychain item.
//
//  Same generic-password Keychain idiom the app already uses for BYO cloud
//  keys (Routing/Providers/CloudEndpointRegistry). When the Keychain is
//  unavailable (some headless/test contexts) callers fall back to a
//  deterministic per-run secret — that still detects accidental corruption
//  and non-malicious tampering, which is the only claim the UI makes there.
//

import Foundation
import Security
import CryptoKit

public enum AuditChainSecret {
    private static let service = "ecosanskritiinnovation.Kalsmritikosh.auditChain"
    private static let account = "hmac-secret-v1"

    /// Load the existing secret, or generate + store a fresh 32-byte random one.
    /// Returns nil only when the Keychain is entirely unavailable.
    public static func loadOrGenerate() -> Data? {
        if let existing = load() { return existing }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        let secret = Data(bytes)
        return store(secret) ? secret : nil
    }

    private static func load() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return data
    }

    private static func store(_ secret: Data) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: secret,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        SecItemDelete(query as CFDictionary)
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }
}
