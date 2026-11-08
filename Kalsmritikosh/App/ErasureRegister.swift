//
//  ErasureRegister.swift
//  Kalsmritikosh
//
//  RECOVERY-06 — erasure versus old copies. The ledger's own erasure records (`case_erasures`, the
//  `ledger_*_erase` markers) live INSIDE the ledger, so restoring a backup made before an erasure
//  replaces them along with everything else and the erased case, person or documents silently come
//  back. This register is the durable record that survives that: a small file BESIDE the ledger
//  (`erasure-register.json`, never part of a backup's manifest, so a restore never replaces it) that
//  names each erased case and person only by a SHA-256 of its identifier — no title, no name, no
//  content — plus the time of each full erase.
//
//  It is applied (AppState.applyErasureRegister) every time the ledger opens: a case or person in the
//  ledger whose identifier hash is on the register is erased again, through the same erasure (legal
//  holds still refuse, and a refusal is reported, never hidden). A restore of a backup made BEFORE a
//  full erase is refused outright (PendingRestore), because everything in it was erased.
//

import Foundation
import CryptoKit
import os

nonisolated enum ErasureRegister {
    static let fileName = "erasure-register.json"

    enum Kind: String, Codable, Sendable { case `case`, person, full }

    struct Entry: Codable, Equatable, Sendable {
        var kind: Kind
        /// SHA-256 of the identifier (`hash(_:)`); nil for a full erase.
        var idHash: String?
        /// Case erasures: whether the documents only that case used were erased too.
        var eraseSources: Bool?
        var erasedAt: Double
    }

    struct Register: Codable, Equatable, Sendable {
        var version = 1
        var entries: [Entry] = []
    }

    enum RegisterError: Error, LocalizedError {
        case unreadable(String)
        var errorDescription: String? {
            switch self { case .unreadable(let why): return "The erasure register could not be read (\(why))." }
        }
    }

    static func url(besideLedgerAt ledgerURL: URL) -> URL {
        ledgerURL.deletingLastPathComponent().appendingPathComponent(fileName)
    }

    /// The register's name for an identifier: never the identifier itself.
    static func hash(_ id: UUID) -> String {
        SHA256.hash(data: Data("kals-erasure-register:\(id.uuidString.lowercased())".utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The register beside the ledger (empty when none was ever written). An unreadable register throws:
    /// it is never treated as "nothing was erased".
    static func load(besideLedgerAt ledgerURL: URL) throws -> Register {
        let u = url(besideLedgerAt: ledgerURL)
        guard FileManager.default.fileExists(atPath: u.path) else { return Register() }
        do { return try JSONDecoder().decode(Register.self, from: Data(contentsOf: u)) } catch {
            KalsmritikoshLog.storage.error("Erasure register unreadable: \(error.localizedDescription, privacy: .public)")
            throw RegisterError.unreadable(error.localizedDescription)
        }
    }

    /// Add an entry (an identifier already on the register is not added twice). Written atomically,
    /// owner-only.
    static func record(_ entry: Entry, besideLedgerAt ledgerURL: URL) throws {
        var r = try load(besideLedgerAt: ledgerURL)
        if entry.kind != .full, r.entries.contains(where: { $0.kind == entry.kind && $0.idHash == entry.idHash }) { return }
        r.entries.append(entry)
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let u = url(besideLedgerAt: ledgerURL)
        try enc.encode(r).write(to: u, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: u.path)
    }

    /// Record and report: a register that cannot be written is named to the person (residue), never
    /// assumed written.
    static func recordReporting(_ entry: Entry, besideLedgerAt ledgerURL: URL) -> String? {
        do { try record(entry, besideLedgerAt: ledgerURL); return nil } catch {
            KalsmritikoshLog.storage.error("Erasure register not written: \(error.localizedDescription, privacy: .public)")
            return "the erasure register (an older backup restored later could bring this back)"
        }
    }

    /// The identifiers in `ids` that are on the register as `kind`.
    static func matches(_ ids: [UUID], kind: Kind, in r: Register) -> [(id: UUID, entry: Entry)] {
        let byHash = Dictionary(r.entries.filter { $0.kind == kind && $0.idHash != nil }.map { ($0.idHash!, $0) }, uniquingKeysWith: { a, _ in a })
        guard !byHash.isEmpty else { return [] }
        return ids.compactMap { id in byHash[hash(id)].map { (id, $0) } }
    }

    /// The latest full erase, if any.
    static func lastFullErase(in r: Register) -> Double? {
        r.entries.filter { $0.kind == .full }.map(\.erasedAt).max()
    }

    /// Why a backup made at `backupCreatedAt` must not be restored (a full erase happened after it), or nil.
    static func refusal(backupCreatedAt: Double, besideLedgerAt ledgerURL: URL) -> String? {
        let r: Register
        do { r = try load(besideLedgerAt: ledgerURL) } catch {
            return "The erasure register beside your ledger could not be read, so it cannot be checked that this backup holds nothing you erased. Your ledger was not changed."
        }
        guard let full = lastFullErase(in: r), full > backupCreatedAt else { return nil }
        let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .short
        return "This backup was made before all data was erased on \(df.string(from: Date(timeIntervalSince1970: full))), so restoring it would bring erased data back. It was not restored; your ledger was not changed."
    }
}
