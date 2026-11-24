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
import os

public enum AuditChainSecret {
    private static let service = "ecosanskritiinnovation.Kalsmritikosh.auditChain"
    private static let account = "hmac-secret-v1"

    /// ALCOA ALC-06 — the key id stored on seals made with this device-only secret (and on every seal made before key ids:
    /// a NULL key_id reads as this).
    public static let deviceKeyID = "device-v1"
    /// ALCOA ALC-06 — the HKDF purpose of the chain key derived from the ledger key (the key backups and the recovery key
    /// carry), so a restore or a new Mac verifies seals made with it.
    public static let ledgerPurpose = "audit-chain"

    /// The chain key derived from a ledger key, and its id ("ledger:" + a short fingerprint, so a rotated ledger key gets a
    /// new id and older seals keep naming the key that made them).
    public static func ledgerKey(from key: LedgerKey) -> (id: String, secret: Data) {
        let derived = key.derivedKey(for: ledgerPurpose).withUnsafeBytes { Data($0) }
        let fp = SHA256.hash(data: derived + Data("key-id".utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        return ("ledger:" + fp, derived)
    }

    /// Load the existing secret, or generate + store a fresh 32-byte random one.
    /// Returns nil only when the Keychain is entirely unavailable.
    /// ALCOA ALC-06 — an existing secret is NEVER overwritten: a new one is generated only when the Keychain says the item
    /// does not exist, and it is added (never delete-then-add); a race or a locked Keychain returns what is there, or nil.
    public static func loadOrGenerate() -> Data? {
        let (existing, status) = loadWithStatus()
        if let existing { return existing }
        guard status == errSecItemNotFound else {
            KalsmritikoshLog.storage.error("Audit chain secret unreadable now (status \(status, privacy: .public)); not replaced")
            return nil
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        let secret = Data(bytes)
        switch add(secret) {
        case errSecSuccess: return secret
        case errSecDuplicateItem: return load()   // another writer stored one first: use it, never replace it
        default: return nil
        }
    }

    /// The existing device secret, or nil — never generates one (used to keep verifying older seals).
    public static func loadExisting() -> Data? { load() }

    private static func load() -> Data? { loadWithStatus().data }

    private static func loadWithStatus() -> (data: Data?, status: OSStatus) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return (nil, status) }
        return (data, status)
    }

    private static func add(_ secret: Data) -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: secret,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        return SecItemAdd(query as CFDictionary, nil)
    }
}
