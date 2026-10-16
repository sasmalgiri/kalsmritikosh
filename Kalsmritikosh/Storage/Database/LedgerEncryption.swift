//
//  LedgerEncryption.swift
//  Kalsmritikosh
//
//  W2-7 (owner decision 2026-10-15, SHIP_DECISIONS change log) — the ledger
//  database is encrypted at rest with SQLCipher (AES-256, the library's default
//  page format). The key is 32 random bytes made on this Mac and kept in the
//  Keychain for this device only. The same bytes, written as 64 hex characters,
//  are the person's recovery key: it opens the ledger on another Mac (a restored
//  backup) or after the Keychain item is lost. There is no other copy and no
//  fallback — without the key the ledger cannot be read, which is the point.
//
//  An existing plaintext ledger is converted once (`LedgerEncryptionMigrator`):
//  exported into a new encrypted file, verified (quick_check, schema version and
//  per-table row counts), then swapped in. The plaintext file is removed only
//  after the encrypted copy verifies; an interrupted swap is finished or undone
//  on the next launch, never left half-done.
//

import Foundation
import Security
import SQLCipher
import os

public struct LedgerKey: Sendable, Equatable {
    public let raw: Data

    public init?(raw: Data) {
        guard raw.count == 32 else { return nil }
        self.raw = raw
    }

    private init(checked raw: Data) { self.raw = raw }

    /// 32 bytes from the system CSPRNG (SystemRandomNumberGenerator is arc4random_buf on Apple platforms).
    public static func random() -> LedgerKey {
        var g = SystemRandomNumberGenerator()
        return LedgerKey(checked: Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &g) }))
    }

    var hex: String { raw.map { String(format: "%02X", $0) }.joined() }

    /// `PRAGMA key = "x'…'";` — a raw 256-bit key (no passphrase derivation).
    var pragmaValue: String { "\"x'\(hex)'\"" }

    /// 64 hex characters in 16 groups of 4, for the person to write down.
    public var recoveryText: String {
        stride(from: 0, to: hex.count, by: 4).map { i -> String in
            let a = hex.index(hex.startIndex, offsetBy: i)
            return String(hex[a..<hex.index(a, offsetBy: 4)])
        }.joined(separator: "-")
    }

    /// Accepts the recovery text with or without dashes/spaces, any letter case.
    public init?(recoveryText: String) {
        let hex = recoveryText.uppercased().filter { "0123456789ABCDEF".contains($0) }
        guard hex.count == 64, recoveryText.uppercased().allSatisfy({ "0123456789ABCDEF- \n\t".contains($0) }) else { return nil }
        var bytes = [UInt8]()
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            guard let b = UInt8(hex[i..<j], radix: 16) else { return nil }
            bytes.append(b); i = j
        }
        self.init(raw: Data(bytes))
    }
}

/// The Keychain item holding the ledger key (this Mac only, available after first unlock).
public enum LedgerKeychain {
    /// The unit-test host IS this app (same bundle id, same Keychain), so tests use their own
    /// item: a test storing a key must never be able to replace the key of the person's ledger.
    static var service: String {
        let base = "ecosanskritiinnovation.Kalsmritikosh.ledger-key"
        return ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil ? base : base + ".tests"
    }
    static let account = "ledger"

    /// The person's own ledger key, READ ONLY, even from the test host — for the owner-archive
    /// harnesses that copy the live ledger. Nothing may ever store under this service from tests.
    static func loadPersonKey() -> LedgerKey? {
        load(service: "ecosanskritiinnovation.Kalsmritikosh.ledger-key")
    }

    public static func load() -> LedgerKey? { load(service: service) }

    private static func load(service: String) -> LedgerKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return LedgerKey(raw: data)
    }

    public static func store(_ key: LedgerKey) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = key.raw
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let rc = SecItemAdd(add as CFDictionary, nil)
        guard rc == errSecSuccess else {
            KalsmritikoshLog.storage.error("Ledger key could not be saved to the Keychain (OSStatus \(rc, privacy: .public))")
            throw LedgerEncryptionError.keychain(rc)
        }
    }
}

public enum LedgerEncryptionError: Error, LocalizedError, Sendable {
    case keychain(OSStatus)
    case cipherUnavailable
    case wrongKey
    case conversionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .keychain(let rc): return "The ledger key could not be saved in the Keychain (error \(rc))."
        case .cipherUnavailable: return "This build cannot encrypt the ledger (the encryption library is missing), so it will not open it."
        case .wrongKey: return "This ledger is encrypted with a different key."
        case .conversionFailed(let m): return "The ledger could not be encrypted: \(m). The original, unencrypted ledger is unchanged."
        }
    }
}

public enum LedgerFileState: Equatable, Sendable {
    case missing, plaintext, encrypted

    /// A plaintext SQLite file starts with "SQLite format 3\0"; an SQLCipher file starts with random salt.
    public static func of(_ url: URL) -> LedgerFileState {
        guard let h = try? FileHandle(forReadingFrom: url) else { return .missing }
        defer { try? h.close() }
        let head = (try? h.read(upToCount: 16)) ?? Data()
        if head.isEmpty { return .missing }
        return head == Data("SQLite format 3\0".utf8) ? .plaintext : .encrypted
    }
}

/// Applying and checking a key on a raw handle — the single place every connection goes through.
enum LedgerCipher {
    /// Key the connection, prove the cipher is really present, and prove the key opens the file.
    /// Throws instead of ever leaving a connection that would read or write plaintext.
    static func apply(_ key: LedgerKey, to handle: OpaquePointer) throws {
        guard sqlite3_exec(handle, "PRAGMA key = \(key.pragmaValue);", nil, nil, nil) == SQLITE_OK else {
            throw LedgerEncryptionError.cipherUnavailable
        }
        // Without SQLCipher, `PRAGMA key` is silently ignored — cipher_version is the proof it is not.
        guard let version = scalarText(handle, "PRAGMA cipher_version;"), !version.isEmpty else {
            throw LedgerEncryptionError.cipherUnavailable
        }
        // The first real read fails with SQLITE_NOTADB when the key is wrong.
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(handle, "SELECT count(*) FROM sqlite_master;", -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW else {
            throw LedgerEncryptionError.wrongKey
        }
    }

    static func scalarText(_ handle: OpaquePointer, _ sql: String) -> String? {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, sqlite3_step(stmt) == SQLITE_ROW,
              let t = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: t)
    }

    static func scalarInt(_ handle: OpaquePointer, _ sql: String) -> Int64? {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(stmt, 0)
    }

    static func quote(_ path: String) -> String { "'" + path.replacingOccurrences(of: "'", with: "''") + "'" }

    /// A PLAINTEXT working copy of a ledger (encrypted with `key`, or plaintext when nil), read
    /// without modifying it. Only for the owner-archive test harnesses, which boot a throwaway
    /// copy of the live ledger; boot then encrypts that copy with the test key.
    static func plaintextCopy(from source: URL, key: LedgerKey?, to destination: URL) throws {
        try? FileManager.default.removeItem(at: destination)
        var src: OpaquePointer?
        guard sqlite3_open_v2(source.path, &src, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK, let db = src else {
            sqlite3_close(src)
            throw LedgerEncryptionError.conversionFailed("the ledger could not be opened")
        }
        defer { sqlite3_close(db) }
        if let key, LedgerFileState.of(source) == .encrypted { try apply(key, to: db) }
        let userVersion = scalarInt(db, "PRAGMA user_version;") ?? 0
        for sql in ["ATTACH DATABASE \(quote(destination.path)) AS plaincopy KEY '';",
                    "SELECT sqlcipher_export('plaincopy');",
                    "PRAGMA plaincopy.user_version = \(userVersion);",
                    "DETACH DATABASE plaincopy;"] {
            var err: UnsafeMutablePointer<CChar>?
            if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
                let m = err.map { String(cString: $0) } ?? "unknown"
                sqlite3_free(err)
                try? FileManager.default.removeItem(at: destination)
                throw LedgerEncryptionError.conversionFailed(m)
            }
        }
    }

    /// W4-6 — the iPhone/iPad snapshot: copy `source` (encrypted with `key`, or plaintext when nil)
    /// into `destination` encrypted with a PASSPHRASE the person chose, so this Mac's raw key never
    /// leaves it. SQLCipher derives the page key from the passphrase (PBKDF2-HMAC-SHA512).
    /// The copy is reopened with the passphrase and integrity-checked before it is returned.
    static func exportCopy(from source: URL, key: LedgerKey?, to destination: URL, passphrase: String) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: destination)
        var src: OpaquePointer?
        guard sqlite3_open_v2(source.path, &src, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK, let db = src else {
            sqlite3_close(src)
            throw LedgerEncryptionError.conversionFailed("the snapshot copy could not be opened")
        }
        defer { sqlite3_close(db) }
        if let key { try apply(key, to: db) }
        let userVersion = scalarInt(db, "PRAGMA user_version;") ?? 0
        for sql in ["ATTACH DATABASE \(quote(destination.path)) AS passcopy KEY \(quote(passphrase));",
                    "SELECT sqlcipher_export('passcopy');",
                    "PRAGMA passcopy.user_version = \(userVersion);",
                    "DETACH DATABASE passcopy;"] {
            var err: UnsafeMutablePointer<CChar>?
            if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
                let m = err.map { String(cString: $0) } ?? "unknown"
                sqlite3_free(err)
                try? fm.removeItem(at: destination)
                throw LedgerEncryptionError.conversionFailed(m)
            }
        }
        var check: OpaquePointer?
        defer { sqlite3_close(check) }
        guard sqlite3_open_v2(destination.path, &check, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let c = check,
              sqlite3_exec(c, "PRAGMA key = \(quote(passphrase));", nil, nil, nil) == SQLITE_OK,
              scalarText(c, "PRAGMA quick_check;") == "ok", LedgerFileState.of(destination) == .encrypted else {
            try? fm.removeItem(at: destination)
            throw LedgerEncryptionError.conversionFailed("the passphrase-protected copy did not verify")
        }
    }
}

public enum LedgerEncryptionMigrator {
    public struct Report: Sendable, Equatable {
        public let tables: Int
        public let rows: Int64
    }

    static func pendingURL(_ url: URL) -> URL { url.appendingPathExtension("plaintext-pending") }
    static func stagingURL(_ url: URL) -> URL { url.appendingPathExtension("encrypting") }

    /// Finish or undo a swap a previous launch did not complete. Safe to call every launch.
    public static func recoverInterruptedSwap(at url: URL) {
        let fm = FileManager.default
        let pending = pendingURL(url)
        guard fm.fileExists(atPath: pending.path) else {
            try? fm.removeItem(at: stagingURL(url))          // an unfinished export; the plaintext is intact
            return
        }
        if LedgerFileState.of(url) == .encrypted {
            // The encrypted file is in place (it verified before the swap began): finish removing the plaintext.
            removeWithSidecars(pending)
            KalsmritikoshLog.storage.notice("Ledger encryption: finished removing the previous unencrypted file")
        } else {
            // The swap stopped before the encrypted file arrived: put the plaintext back.
            try? fm.removeItem(at: url)
            try? fm.moveItem(at: pending, to: url)
            KalsmritikoshLog.storage.notice("Ledger encryption: restored the unencrypted ledger after an interrupted swap")
        }
    }

    /// Convert a plaintext ledger at `url` to an encrypted one with `key`. No-op unless it is plaintext.
    @discardableResult
    public static func encryptIfPlaintext(at url: URL, key: LedgerKey) throws -> Report? {
        recoverInterruptedSwap(at: url)
        guard LedgerFileState.of(url) == .plaintext else { return nil }
        let fm = FileManager.default
        let staging = stagingURL(url)
        try? fm.removeItem(at: staging)

        var src: OpaquePointer?
        guard sqlite3_open_v2(url.path, &src, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let db = src else {
            sqlite3_close(src)
            throw LedgerEncryptionError.conversionFailed("the ledger could not be opened")
        }
        var closed = false
        defer { if !closed { sqlite3_close(db) } }
        guard let version = LedgerCipher.scalarText(db, "PRAGMA cipher_version;"), !version.isEmpty else {
            throw LedgerEncryptionError.cipherUnavailable
        }
        // (SQLITE_OPEN_CREATE above: ATTACH inherits the connection's flags, and the encrypted
        // target does not exist yet.) Fold the WAL into the main file so the export sees every committed row.
        _ = sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE);", nil, nil, nil)
        let before = try counts(db)
        let userVersion = LedgerCipher.scalarInt(db, "PRAGMA user_version;") ?? 0

        let attach = "ATTACH DATABASE \(LedgerCipher.quote(staging.path)) AS encrypted KEY \(key.pragmaValue);"
        for sql in [attach, "SELECT sqlcipher_export('encrypted');", "PRAGMA encrypted.user_version = \(userVersion);", "DETACH DATABASE encrypted;"] {
            var err: UnsafeMutablePointer<CChar>?
            if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
                let m = err.map { String(cString: $0) } ?? "unknown"
                sqlite3_free(err)
                try? fm.removeItem(at: staging)
                throw LedgerEncryptionError.conversionFailed(m)
            }
        }
        sqlite3_close(db); closed = true

        // Verify the encrypted copy on its own before anything is replaced.
        var enc: OpaquePointer?
        guard sqlite3_open_v2(staging.path, &enc, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let e = enc else {
            sqlite3_close(enc); try? fm.removeItem(at: staging)
            throw LedgerEncryptionError.conversionFailed("the encrypted copy could not be opened")
        }
        do {
            try LedgerCipher.apply(key, to: e)
            guard LedgerCipher.scalarText(e, "PRAGMA quick_check;") == "ok" else { throw LedgerEncryptionError.conversionFailed("the encrypted copy failed its integrity check") }
            guard LedgerCipher.scalarInt(e, "PRAGMA user_version;") == userVersion else { throw LedgerEncryptionError.conversionFailed("the schema version did not carry over") }
            let after = try counts(e)
            guard after == before else { throw LedgerEncryptionError.conversionFailed("row counts differ after encryption") }
        } catch {
            sqlite3_close(e); try? fm.removeItem(at: staging)
            throw error
        }
        sqlite3_close(e)
        guard LedgerFileState.of(staging) == .encrypted else {
            try? fm.removeItem(at: staging)
            throw LedgerEncryptionError.conversionFailed("the new file is not encrypted")
        }

        // Swap: plaintext aside → encrypted in → plaintext (and its WAL/SHM) removed.
        let pending = pendingURL(url)
        try? fm.removeItem(at: pending)
        try fm.moveItem(at: url, to: pending)
        for side in ["-wal", "-shm"] {
            let s = URL(fileURLWithPath: url.path + side)
            if fm.fileExists(atPath: s.path) { try? fm.moveItem(at: s, to: URL(fileURLWithPath: pending.path + side)) }
        }
        try fm.moveItem(at: staging, to: url)
        removeWithSidecars(pending)
        let rows = before.values.reduce(0, +)
        KalsmritikoshLog.storage.notice("Ledger encrypted: \(before.count, privacy: .public) tables, \(rows, privacy: .public) rows verified")
        return Report(tables: before.count, rows: rows)
    }

    /// Row count per ordinary table (virtual FTS tables are rebuilt from their content tables).
    static func counts(_ db: OpaquePointer) throws -> [String: Int64] {
        var names: [String] = []
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type='table' AND sql NOT LIKE 'CREATE VIRTUAL%' AND name NOT LIKE 'sqlite_%';", -1, &stmt, nil) == SQLITE_OK else {
            throw LedgerEncryptionError.conversionFailed(String(cString: sqlite3_errmsg(db)))
        }
        while sqlite3_step(stmt) == SQLITE_ROW { if let t = sqlite3_column_text(stmt, 0) { names.append(String(cString: t)) } }
        sqlite3_finalize(stmt)
        var out: [String: Int64] = [:]
        for n in names {
            guard let c = LedgerCipher.scalarInt(db, "SELECT count(*) FROM \"\(n.replacingOccurrences(of: "\"", with: "\"\""))\";") else {
                throw LedgerEncryptionError.conversionFailed("could not count \(n)")
            }
            out[n] = c
        }
        return out
    }

    private static func removeWithSidecars(_ url: URL) {
        let fm = FileManager.default
        for p in [url.path, url.path + "-wal", url.path + "-shm"] where fm.fileExists(atPath: p) {
            try? fm.removeItem(atPath: p)
        }
    }
}
