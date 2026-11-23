//
//  ContentResultCacheRepository.swift
//  Kalsmritikosh
//
//  Speed PERF-34 torrent (owner 2026-11-23) — not tested yet. "Pieces carry fingerprints": a content-addressed cache of
//  derived results (v205 `content_result_cache`). A result is stored under the SHA-256 of the NORMALISED content it was
//  derived from (a page image's bytes, a block's text), the producer with its version, and a scope:
//
//    • OCR text of a page image (lines, confidence, the box inside the image — independent of any document);
//    • the typed fields a block's text yields (type, raw value, confidence), re-anchored to the new block on reuse;
//    • a verified AI reply — scope = its case + the cleared document set + the permission it was sent under, so it is
//      reused ONLY inside the same case, the same cleared documents and the same consent (never across cases, never after
//      the permission changed). It carries case_id: a case erasure deletes it.
//
//  Vectors stay in `embedding_cache` (EmbeddingCacheRepository, keyed by model + text hash).
//
//  `content_result_origins` records which file / source version each entry came from or was reused by; an erasure of those
//  documents deletes the entries derived from them (CaseEraser.scrubContentCache). A fingerprint here is NEVER a custody
//  digest: custody hashes are of the exact stored bytes (intake); these are of normalised content, for reuse only.
//

import Foundation
import CryptoKit
import os

public nonisolated enum ContentResultKind: String, Sendable, CaseIterable {
    case ocr, typedFields, aiReply
}

/// Fingerprints of normalised content (never custody digests).
public nonisolated enum ContentFingerprint {
    static func hex<D: Digest>(_ d: D) -> String { d.map { String(format: "%02x", $0) }.joined() }

    /// SHA-256 of bytes as they are (an image has no textual normal form).
    public static func bytes(_ data: Data) -> String { hex(SHA256.hash(data: data)) }

    /// SHA-256 of a file's bytes, read in 1 MiB pieces (nil when unreadable).
    public static func file(_ url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var sha = SHA256()
        while true {
            let chunk: Data
            do { chunk = try h.read(upToCount: 1 << 20) ?? Data() } catch {
                KalsmritikoshLog.storage.error("content fingerprint: read failed: \(String(describing: error), privacy: .private)")
                return nil
            }
            if chunk.isEmpty { break }
            sha.update(data: chunk)
        }
        return hex(sha.finalize())
    }

    /// The normal form of text for reuse: Unicode NFC, CRLF/CR → LF, trailing spaces of lines and outer blank space
    /// trimmed. Case and inner spacing are kept (a typed value's case is part of what was read).
    public static func normalise(_ text: String) -> String {
        let nfc = text.precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let lines = nfc.split(separator: "\n", omittingEmptySubsequences: false).map { line -> Substring in
            var l = line
            while let last = l.last, last == " " || last == "\t" { l = l.dropLast() }
            return l
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// SHA-256 of `normalise(text)`.
    public static func text(_ text: String) -> String { hex(SHA256.hash(data: Data(normalise(text).utf8))) }

    /// A digest over several fields (length-prefixed, so no two field lists collide).
    public static func fields(_ parts: [String]) -> String {
        var sha = SHA256()
        for p in parts { sha.update(data: Data("\(p.utf8.count):".utf8)); sha.update(data: Data(p.utf8)) }
        return hex(sha.finalize())
    }
}

public actor ContentResultCacheRepository {
    private let database: Database
    public init(database: Database) { self.database = database }

    /// Where an entry came from: the file and source version being read when it was derived or reused.
    public struct Origin: Sendable, Hashable {
        public let fileID: String
        public let sourceVersionID: String
        public init(fileID: UUID?, sourceVersionID: UUID?) {
            self.fileID = fileID?.uuidString ?? ""; self.sourceVersionID = sourceVersionID?.uuidString ?? ""
        }
        var isEmpty: Bool { fileID.isEmpty && sourceVersionID.isEmpty }
    }

    /// The payload kept for (digest, kind, producer, scope), or nil.
    public func lookup(digest: String, kind: ContentResultKind, producer: String, scope: String = "",
                       origin: Origin? = nil, now: Date = Date()) async -> String? {
        do {
            guard let payload = try await database.query("""
                SELECT payload FROM content_result_cache WHERE digest = ? AND kind = ? AND producer = ? AND scope = ?;
                """, [.text(digest), .text(kind.rawValue), .text(producer), .text(scope)]).first?.string(0) else { return nil }
            // The document reusing it is an origin too: erasing that document clears the entry as well.
            await noteOrigins([digest], kind: kind, origin: origin, now: now)
            return payload
        } catch {
            KalsmritikoshLog.storage.error("content result cache not read (recomputed): \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// The payloads kept for many digests at once (one query), by digest. Scope '' only (document-independent results).
    public func lookupMany(digests: [String], kind: ContentResultKind, producer: String,
                           origin: Origin? = nil, now: Date = Date()) async -> [String: String] {
        let unique = Array(Set(digests))
        guard !unique.isEmpty else { return [:] }
        var out: [String: String] = [:]
        do {
            for start in stride(from: 0, to: unique.count, by: 400) {
                let part = Array(unique[start..<min(unique.count, start + 400)])
                let json = String(data: try JSONSerialization.data(withJSONObject: part), encoding: .utf8) ?? "[]"
                for row in try await database.query("""
                    SELECT digest, payload FROM content_result_cache
                    WHERE kind = ? AND producer = ? AND scope = '' AND digest IN (SELECT value FROM json_each(?));
                    """, [.text(kind.rawValue), .text(producer), .text(json)]) {
                    if let d = row.string(0), let p = row.string(1) { out[d] = p }
                }
            }
        } catch {
            KalsmritikoshLog.storage.error("content result cache not read (recomputed): \(String(describing: error), privacy: .public)")
            return [:]
        }
        await noteOrigins(Array(out.keys), kind: kind, origin: origin, now: now)
        return out
    }

    /// Keep a result (an upsert: two runs of the same content write the same entry — idempotent).
    public func store(digest: String, kind: ContentResultKind, producer: String, scope: String = "", caseID: UUID? = nil,
                      payload: String, origin: Origin? = nil, now: Date = Date()) async {
        await storeMany([(digest, payload)], kind: kind, producer: producer, scope: scope, caseID: caseID, origin: origin, now: now)
    }

    public func storeMany(_ entries: [(digest: String, payload: String)], kind: ContentResultKind, producer: String,
                          scope: String = "", caseID: UUID? = nil, origin: Origin? = nil, now: Date = Date()) async {
        guard !entries.isEmpty else { return }
        do {
            try await database.withSavepoint("content_cache_\(UUID().uuidString.prefix(8))") { db in
                for e in entries {
                    try db.exec("""
                        INSERT INTO content_result_cache (digest, kind, producer, scope, case_id, payload, created_at, used_at)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(digest, kind, producer, scope) DO UPDATE SET payload = excluded.payload, used_at = excluded.used_at;
                        """, [.text(e.digest), .text(kind.rawValue), .text(producer), .text(scope),
                              caseID.map { .uuid($0) } ?? .null, .text(e.payload), .date(now), .date(now)])
                    if let origin, !origin.isEmpty {
                        try db.exec("""
                            INSERT OR IGNORE INTO content_result_origins (digest, kind, file_id, source_version_id, created_at)
                            VALUES (?, ?, ?, ?, ?);
                            """, [.text(e.digest), .text(kind.rawValue), .text(origin.fileID), .text(origin.sourceVersionID), .date(now)])
                    }
                }
            }
        } catch {
            KalsmritikoshLog.storage.error("content result cache not kept (the next read recomputes): \(String(describing: error), privacy: .public)")
        }
    }

    private func noteOrigins(_ digests: [String], kind: ContentResultKind, origin: Origin?, now: Date) async {
        guard let origin, !origin.isEmpty, !digests.isEmpty else { return }
        do {
            try await database.withSavepoint("content_origin_\(UUID().uuidString.prefix(8))") { db in
                for d in digests {
                    try db.exec("""
                        INSERT OR IGNORE INTO content_result_origins (digest, kind, file_id, source_version_id, created_at)
                        VALUES (?, ?, ?, ?, ?);
                        """, [.text(d), .text(kind.rawValue), .text(origin.fileID), .text(origin.sourceVersionID), .date(now)])
                    try db.exec("UPDATE content_result_cache SET used_at = ? WHERE digest = ? AND kind = ?;",
                                [.date(now), .text(d), .text(kind.rawValue)])
                }
            }
        } catch {
            KalsmritikoshLog.storage.error("content result origin not kept: \(String(describing: error), privacy: .public)")
        }
    }

    public func count(kind: ContentResultKind? = nil) async -> Int {
        do {
            if let kind {
                return Int(try await database.query("SELECT COUNT(*) FROM content_result_cache WHERE kind = ?;", [.text(kind.rawValue)]).first?.int(0) ?? 0)
            }
            return Int(try await database.query("SELECT COUNT(*) FROM content_result_cache;", []).first?.int(0) ?? 0)
        } catch {
            KalsmritikoshLog.storage.error("content result cache not counted: \(String(describing: error), privacy: .public)")
            return 0
        }
    }
}

/// Speed PERF-34 torrent (owner 2026-11-23) — not tested yet. The ledger's content cache (set when the ledger opens; nil =
/// nothing reused, everything computed) and the document being read now (task-local, set by the import for the file it
/// reads, so every entry derived or reused while reading it records that file as an origin).
public nonisolated enum ContentResults {
    private static let store = OSAllocatedUnfairLock<ContentResultCacheRepository?>(initialState: nil)
    public static var current: ContentResultCacheRepository? {
        #if DEBUG
        // As CasePartReplies: in the unit-test host only a test's own task-local store is used (nil = nothing reused), so
        // one test's ledger never serves another's.
        if TestHost.isActive { return TestOverride.store }
        #endif
        return store.withLock { $0 }
    }
    public static func set(_ repo: ContentResultCacheRepository?) { store.withLock { $0 = repo } }

    /// The file being read: filled by the import once intake knows its ids (a box, because the ids are known only after
    /// the task-local is bound). Members of a container bind their own.
    public final class OriginBox: Sendable {
        private let value = OSAllocatedUnfairLock<ContentResultCacheRepository.Origin?>(initialState: nil)
        public init() {}
        public func set(fileID: UUID, sourceVersionID: UUID) {
            value.withLock { $0 = .init(fileID: fileID, sourceVersionID: sourceVersionID) }
        }
        public var origin: ContentResultCacheRepository.Origin? { value.withLock { $0 } }
    }
    @TaskLocal public static var reading: OriginBox?
    public static var origin: ContentResultCacheRepository.Origin? { reading?.origin }

    #if DEBUG
    public enum TestOverride {
        @TaskLocal public static var store: ContentResultCacheRepository?
    }
    #endif
}
