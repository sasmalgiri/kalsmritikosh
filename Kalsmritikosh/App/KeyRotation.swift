//
//  KeyRotation.swift
//  Kalsmritikosh
//
//  ALCOA ALC-21 (DATA-31, owner 2026-11-24) — secure. "Rotate keys": a new ledger key, the ledger re-keyed (the existing
//  rekeyedCopy path: SQLCipher export into a copy under the new key, integrity-checked), every sealed vault copy re-sealed
//  under the key derived from the new ledger key, a new audit-chain key id (derived from the new key — the retired chain
//  key is kept inside the encrypted ledger so older seals still verify), the recovery key changed with it, and a chained
//  record (key_rotations, sealed as 'keyRotation').
//
//  It runs while the ledger is closed, at the moment the app opens it (LedgerOpener), in phases recorded in a marker
//  beside the ledger (no secret in it), so a crash at any point resumes or finishes on the next open:
//    requested → re-seal the vault beside the originals (.sealed.next) and write the re-keyed copy with its record
//    swap      → the old ledger aside, the re-keyed copy in
//    finish    → the re-sealed copies in, the new key stored as THE key, the old ledger and the rotation key removed.
//  The new key waits in its own Keychain item until the swap is done, so neither key is ever lost part-way.
//  Backups made before a rotation still need the recovery key that was current when they were made.
//

import Foundation
import os

public nonisolated enum KeyRotation {

    struct Marker: Codable, Equatable {
        var requestedBy: String
        var requestedAt: Date
        var phase: String
        var rotationID: String
        var resealed: Int = 0
    }

    /// What a finished rotation did.
    public struct Report: Sendable, Equatable {
        public let rotationID: UUID
        public let oldChainKeyID: String
        public let newChainKeyID: String
        public let vaultResealed: Int
        public var line: String {
            "Keys rotated: a new ledger key, \(vaultResealed) sealed original(s) re-sealed, audit-chain key \(newChainKeyID) (was \(oldChainKeyID)). "
                + "Write down the new recovery key now; backups made before today need the recovery key you had then."
        }
    }

    public enum RotationError: Error, LocalizedError {
        case notEncrypted, noKey, failed(String)
        public var errorDescription: String? {
            switch self {
            case .notEncrypted: return "The ledger is not encrypted, so there is no key to rotate."
            case .noKey: return "This Mac does not hold the ledger's key, so it cannot be rotated."
            case .failed(let why): return "The keys were not rotated: \(why). Nothing was changed."
            }
        }
    }

    /// Where the keys live: this Mac's Keychain (the app), or an in-memory store (tests — the test host shares one
    /// process-wide ledger key with every other test, so a test rotation must never touch it).
    public struct KeyStore: Sendable {
        public var load: @Sendable () -> LedgerKey?
        public var loadNext: @Sendable () -> LedgerKey?
        public var storeNext: @Sendable (LedgerKey) throws -> Void
        public var store: @Sendable (LedgerKey) throws -> Void
        public var clearNext: @Sendable () -> Void
        public static let keychain = KeyStore(load: { LedgerKeychain.load() }, loadNext: { LedgerKeychain.loadNext() },
                                              storeNext: { try LedgerKeychain.storeNext($0) }, store: { try LedgerKeychain.store($0) },
                                              clearNext: { LedgerKeychain.clearNext() })
    }

    static func markerURL(for ledger: URL) -> URL { ledger.appendingPathExtension("rotate-keys") }
    static func stagingURL(for ledger: URL) -> URL { ledger.appendingPathExtension("rekeyed") }
    static func retiredURL(for ledger: URL) -> URL { ledger.appendingPathExtension("rotated-old") }
    static func vaultRoot(for ledger: URL) -> URL { ledger.deletingLastPathComponent().appendingPathComponent("EvidenceVault", isDirectory: true) }

    /// The last rotation this process finished (shown once in Settings).
    private static let lastBox = OSAllocatedUnfairLock<Report?>(initialState: nil)
    public static var lastReport: Report? { lastBox.withLock { $0 } }
    private static let lastFailureBox = OSAllocatedUnfairLock<String?>(initialState: nil)
    /// Why the last requested rotation did not run (nil: none failed in this process).
    public static var lastFailure: String? { lastFailureBox.withLock { $0 } }

    private static func read(_ url: URL) -> Marker? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .secondsSince1970
        do { return try dec.decode(Marker.self, from: data) } catch {
            KalsmritikoshLog.storage.error("Key rotation: marker unreadable: \(String(describing: error), privacy: .private)")
            return nil
        }
    }

    private static func write(_ m: Marker, to url: URL) throws {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .secondsSince1970
        try enc.encode(m).write(to: url, options: .atomic)
    }

    /// Ask for a rotation; it runs when the ledger is next opened (`AppState.rotateKeys` closes and reopens it at once).
    public static func request(ledgerURL: URL, by actor: String, at date: Date = Date(), keys: KeyStore = .keychain) throws {
        guard LedgerFileState.of(ledgerURL) == .encrypted else { throw RotationError.notEncrypted }
        guard keys.load() != nil else { throw RotationError.noKey }
        let m = Marker(requestedBy: actor, requestedAt: date, phase: "requested", rotationID: UUID().uuidString)
        try write(m, to: markerURL(for: ledgerURL))
    }

    public static func isRequested(ledgerURL: URL) -> Bool { FileManager.default.fileExists(atPath: markerURL(for: ledgerURL).path) }

    private static func removeWithSidecars(_ url: URL) {
        let fm = FileManager.default
        for side in ["", "-wal", "-shm"] {
            let u = URL(fileURLWithPath: url.path + side)
            guard fm.fileExists(atPath: u.path) else { continue }
            do { try fm.removeItem(at: u) } catch {
                KalsmritikoshLog.storage.error("Key rotation: \(u.lastPathComponent, privacy: .private) not removed: \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    private static func move(_ from: URL, _ to: URL) throws {
        let fm = FileManager.default
        for side in ["", "-wal", "-shm"] {
            let a = URL(fileURLWithPath: from.path + side), b = URL(fileURLWithPath: to.path + side)
            guard fm.fileExists(atPath: a.path) else { continue }
            if fm.fileExists(atPath: b.path) { try fm.removeItem(at: b) }
            try fm.moveItem(at: a, to: b)
        }
    }

    /// Run, resume or finish a requested rotation of the ledger at `ledgerURL`. Called while the ledger is closed.
    /// Returns the report when a rotation finished now; nil when none was requested. Throws when it could not proceed —
    /// the ledger and the vault are then as they were (or resumable on the next open).
    @discardableResult
    public static func performIfRequested(ledgerURL: URL, vaultRoot root: URL? = nil, now: Date = Date(), keys: KeyStore = .keychain) throws -> Report? {
        let markerURL = markerURL(for: ledgerURL)
        guard var marker = read(markerURL) else { return nil }
        let vault = root ?? vaultRoot(for: ledgerURL)
        let staging = stagingURL(for: ledgerURL), retired = retiredURL(for: ledgerURL)
        guard let oldKey = keys.load() else { throw RotationError.noKey }
        let newKey: LedgerKey
        if let next = keys.loadNext() { newKey = next } else {
            newKey = LedgerKey.random()
            do { try keys.storeNext(newKey) } catch {
                KalsmritikoshLog.storage.error("Key rotation: the new key was not kept: \(error.localizedDescription, privacy: .private)")
                throw RotationError.failed("the new key could not be kept in the Keychain")
            }
        }
        let oldChain = AuditChainSecret.ledgerKey(from: oldKey), newChain = AuditChainSecret.ledgerKey(from: newKey)

        if marker.phase == "requested" {
            EvidenceVault.discardResealed(root: vault)
            removeWithSidecars(staging)
            do {
                marker.resealed = try EvidenceVault.reseal(root: vault, from: oldKey.derivedKey(for: EvidenceVault.sealPurpose),
                                                           to: newKey.derivedKey(for: EvidenceVault.sealPurpose))
                try LedgerCipher.rekeyedCopy(from: ledgerURL, key: oldKey, to: staging, newKey: newKey)
                let tz = TimeZone.current.identifier
                try LedgerCipher.execute(on: staging, key: newKey, [
                    ("INSERT OR IGNORE INTO audit_chain_keys (key_id, secret, retired_at, rotation_id) VALUES (?,?,?,?);",
                     [.text(oldChain.id), .blob(oldChain.secret), .real(now.timeIntervalSince1970), .text(marker.rotationID)]),
                    ("""
                     INSERT INTO key_rotations (id, rotated_at, rotated_by, old_chain_key_id, new_chain_key_id, vault_resealed, recorded_tz)
                     VALUES (?,?,?,?,?,?,?);
                     """, [.text(marker.rotationID), .real(now.timeIntervalSince1970), .text(marker.requestedBy), .text(oldChain.id),
                           .text(newChain.id), .integer(Int64(marker.resealed)), .text(tz)]),
                ])
            } catch {
                // Nothing was swapped: the ledger, the vault and the key are as they were; the request is withdrawn.
                EvidenceVault.discardResealed(root: vault)
                removeWithSidecars(staging)
                keys.clearNext()
                do { try FileManager.default.removeItem(at: markerURL) } catch {
                    KalsmritikoshLog.storage.error("Key rotation: marker not removed after a stop: \(error.localizedDescription, privacy: .private)")
                }
                KalsmritikoshLog.storage.error("Key rotation stopped before the swap: \(String(describing: error), privacy: .private)")
                let failure = RotationError.failed(error.localizedDescription)
                lastFailureBox.withLock { $0 = failure.errorDescription }
                throw failure
            }
            marker.phase = "swap"
            try write(marker, to: markerURL)
        }
        if marker.phase == "swap" {
            if FileManager.default.fileExists(atPath: staging.path) {
                try move(ledgerURL, retired)
                try move(staging, ledgerURL)
            }
            marker.phase = "finish"
            try write(marker, to: markerURL)
        }
        // finish — the ledger is under the new key now; the old one is only needed for the retired copy.
        try EvidenceVault.promoteResealed(root: vault)
        try keys.store(newKey)
        keys.clearNext()
        removeWithSidecars(retired)
        do { try FileManager.default.removeItem(at: markerURL) } catch {
            KalsmritikoshLog.storage.error("Key rotation: marker not removed: \(error.localizedDescription, privacy: .private)")
        }
        let report = Report(rotationID: UUID(uuidString: marker.rotationID) ?? UUID(), oldChainKeyID: oldChain.id, newChainKeyID: newChain.id,
                            vaultResealed: marker.resealed)
        lastBox.withLock { $0 = report }
        KalsmritikoshLog.storage.notice("Key rotation finished: \(marker.resealed, privacy: .public) vault copies re-sealed")
        return report
    }

    /// The chain keys retired by rotations (kept in the encrypted ledger), so seals made before still verify.
    public static func retiredChainKeys(_ db: Database) async throws -> [String: Data] {
        guard !(try await db.query("SELECT 1 FROM sqlite_master WHERE type='table' AND name='audit_chain_keys';", []).isEmpty) else { return [:] }
        var out: [String: Data] = [:]
        for r in try await db.query("SELECT key_id, secret FROM audit_chain_keys;", []) {
            if let id = r.string(0), let s = r.blob(1), s.count == 32 { out[id] = s }
        }
        return out
    }

    /// One recorded rotation.
    public struct Record: Sendable, Equatable {
        public let id: UUID
        public let rotatedAt: Date
        public let rotatedBy: String
        public let oldChainKeyID: String
        public let newChainKeyID: String
        public let vaultResealed: Int
        public let zone: String
    }

    public static func records(_ db: Database) async throws -> [Record] {
        guard !(try await db.query("SELECT 1 FROM sqlite_master WHERE type='table' AND name='key_rotations';", []).isEmpty) else { return [] }
        return try await db.query("""
            SELECT id, rotated_at, rotated_by, old_chain_key_id, new_chain_key_id, vault_resealed, recorded_tz FROM key_rotations ORDER BY rotated_at;
            """, []).compactMap { r in
            guard let id = r.uuid(0), let at = r.date(1), let by = r.string(2), let o = r.string(3), let n = r.string(4), let v = r.int(5),
                  let tz = r.string(6) else { return nil }
            return Record(id: id, rotatedAt: at, rotatedBy: by, oldChainKeyID: o, newChainKeyID: n, vaultResealed: Int(v), zone: tz)
        }
    }

    /// The rotations, sealed in the audit chain ('keyRotation').
    public static func auditChainEvents(_ db: Database) async throws -> [AuditChainEvent] {
        try await records(db).map { r in
            AuditChainEvent(source: .keyRotation, eventID: r.id, occurredAt: r.rotatedAt,
                            canonicalPayload: "by=\(r.rotatedBy);new=\(r.newChainKeyID);old=\(r.oldChainKeyID);resealed=\(r.vaultResealed);tz=\(r.zone)")
        }
    }
}
