//
//  AppState+LedgerEncryption.swift
//  Kalsmritikosh
//
//  W2-7 — opening the encrypted ledger at boot, unlocking it with a recovery key,
//  and showing the recovery key (behind the Mac's own authentication).
//

import Foundation
import LocalAuthentication
import SQLCipher
import os

/// The outcome of opening the ledger file at boot.
enum LedgerOpenOutcome: Sendable {
    case opened(Database)
    case needsRecoveryKey(String)
}

nonisolated enum LedgerOpener {
    /// Open (or create) the ledger at `url` encrypted. A missing ledger is created encrypted with
    /// this Mac's key (made on first use); a plaintext ledger is converted once; an encrypted one
    /// opens with the Keychain key or, when given, a recovery key — which is then kept.
    static func open(at url: URL, recoveryKey: LedgerKey?) throws -> LedgerOpenOutcome {
        LedgerEncryptionMigrator.recoverInterruptedSwap(at: url)
        let state = LedgerFileState.of(url)
        let stored = LedgerKeychain.load()

        switch state {
        case .missing, .plaintext:
            let key: LedgerKey
            if let k = recoveryKey ?? stored { key = k } else { key = LedgerKey.random() }
            if stored != key { try LedgerKeychain.store(key) }
            if state == .plaintext { try LedgerEncryptionMigrator.encryptIfPlaintext(at: url, key: key) }
            return .opened(try Database(url: url, key: key))

        case .encrypted:
            guard let key = recoveryKey ?? stored else {
                return .needsRecoveryKey("This ledger is encrypted, and this Mac does not hold its key. Enter the recovery key that was shown when the ledger was set up.")
            }
            do {
                let db = try Database(url: url, key: key)
                if stored != key { try LedgerKeychain.store(key) }
                return .opened(db)
            } catch LedgerEncryptionError.wrongKey {
                return .needsRecoveryKey(recoveryKey == nil
                    ? "This ledger is encrypted with a different key from the one on this Mac (for example, it was restored from another Mac). Enter that ledger's recovery key."
                    : "That recovery key does not open this ledger. Check it and try again.")
            }
        }
    }
}

extension AppState {
    /// Try a recovery key the person typed. Returns a message when it is not even well formed;
    /// otherwise boot is retried and the phase shows the result (ready, or asking again).
    @discardableResult
    func unlockLedger(recoveryText: String) async -> String? {
        guard let key = LedgerKey(recoveryText: recoveryText) else {
            return "A recovery key is 64 letters and digits (0–9, A–F), usually written in groups of four."
        }
        let args = pendingBoot
        pendingBoot = nil
        bootRecoveryKey = key
        await boot(databaseURL: args?.databaseURL, suppressAutoReingest: args?.suppressAutoReingest ?? false)
        return nil
    }

    /// The SQLCipher version actually linked, or nil when encryption is not available.
    nonisolated static var cipherVersion: String? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(":memory:", &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let h = db else { sqlite3_close(db); return nil }
        defer { sqlite3_close(h) }
        return LedgerCipher.scalarText(h, "PRAGMA cipher_version;").flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The recovery key, released only after the Mac's own authentication (Touch ID or password).
    func revealRecoveryKey() async -> Result<String, Error> {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // A Mac with no password set cannot authenticate; the key is still only shown on request.
            return LedgerKeychain.load().map { .success($0.recoveryText) } ?? .failure(LedgerEncryptionError.keychain(errSecItemNotFound))
        }
        do {
            try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "show the recovery key for your encrypted ledger")
        } catch {
            return .failure(error)
        }
        guard let key = LedgerKeychain.load() else { return .failure(LedgerEncryptionError.keychain(errSecItemNotFound)) }
        return .success(key.recoveryText)
    }
}
