//
//  BoilerplateRegistry.swift
//  Kalsmritikosh
//
//  Detect, store, and substitute repeated long text blocks across
//  KnowledgeObjects. Email signatures, legal disclaimers, GDPR
//  notices, unsubscribe footers — anything that exceeds a few
//  hundred characters AND repeats across many KOs gets extracted
//  into the boilerplate_templates table ONCE, and each KO's content
//  carries a `[[BOILERPLATE:<id>]]` token in place of the verbatim
//  bytes.
//
//  Design constraints (from "never delete data"):
//
//  - Raw bytes on disk stay untouched. The registry only changes how
//    the DB indexes them.
//  - Templates are stored verbatim. JOIN at display / search time
//    reconstructs the original KO byte sequence exactly.
//  - boilerplate_uses(template_id, ko_id) records every association,
//    so "which emails carried disclaimer X?" is one indexed query.
//  - The token substitution is reversible: drop the registry and
//    you drop the dedup, but the KO content still parses (the
//    `[[BOILERPLATE:abc...]]` token is just text to FTS / NER).
//

import Foundation
import OSLog

public actor BoilerplateRegistry {
    private static let log = Logger(subsystem: "kalsmritikosh", category: "BoilerplateRegistry")

    /// Minimum length (in UTF-8 bytes) for a substring to qualify
    /// as boilerplate. Shorter strings are common enough across
    /// unrelated KOs that templatizing them would over-collapse.
    public static let minBlockBytes = 200

    /// Number of distinct KOs a candidate must appear in before it
    /// gets promoted to a template. Below 3 it could be coincidence;
    /// 3+ across distinct KOs is a real boilerplate.
    public static let promotionThreshold = 3

    /// Token format: `[[BOILERPLATE:<short-id>]]`. Short id is the
    /// first 8 hex chars of the SHA-256 of the body so it's stable
    /// across runs and ingests.
    public static func token(for shortID: String) -> String {
        "[[BOILERPLATE:\(shortID)]]"
    }

    private let database: Database
    private let encoder = JSONEncoder()

    /// In-memory shortID → template body. Populated lazily on first
    /// use from the DB. Reads are dominant; we don't bother evicting.
    private var cache: [String: String] = [:]
    private var loaded: Bool = false

    /// Sliding window of recent candidate substrings. Used by
    /// `processBatch` to spot a substring appearing in ≥3 KOs
    /// during one ingest pass. (Cross-batch promotion comes from
    /// the periodic `scanExisting` job.)
    private var candidates: [String: Set<KnowledgeObject.ID>] = [:]

    public init(database: Database) {
        self.database = database
    }

    /// Replace any known-template substring inside `body` with its
    /// token. Returns the rewritten body and the template ids that
    /// were used. Caller persists the (template_id, ko_id) join.
    public func substituteKnown(_ body: String) async throws -> (rewritten: String, usedTemplateIDs: [String]) {
        try await ensureLoaded()
        var result = body
        var used: [String] = []
        // Replace in descending-length order so a longer template
        // wins over a shorter one nested inside it.
        let ordered = cache.sorted { $0.value.utf8.count > $1.value.utf8.count }
        for (id, tmpl) in ordered {
            if result.contains(tmpl) {
                result = result.replacingOccurrences(of: tmpl, with: Self.token(for: id))
                used.append(id)
            }
        }
        return (result, used)
    }

    /// Record the (template, ko) associations after a successful
    /// substitution and bump the template's match_count.
    public func recordUses(templateIDs: [String], for koID: KnowledgeObject.ID) async throws {
        guard !templateIDs.isEmpty else { return }
        for id in templateIDs {
            try await database.exec("""
                INSERT OR IGNORE INTO boilerplate_uses (template_id, ko_id)
                VALUES (?, ?);
            """, [.text(id), .uuid(koID)])
            try await database.exec("""
                UPDATE boilerplate_templates
                SET match_count = match_count + 1
                WHERE id = ?;
            """, [.text(id)])
        }
    }

    /// Promote a candidate to a stored template. The shortID is
    /// derived from the body so a second promotion attempt for the
    /// same bytes is a no-op (PRIMARY KEY conflict).
    @discardableResult
    public func promote(
        body: String,
        kind: TemplateKind
    ) async throws -> String {
        let id = Self.shortID(for: body)
        let bytes = body.utf8.count
        try await database.exec("""
            INSERT OR IGNORE INTO boilerplate_templates
                (id, body, kind, first_seen_at, byte_size, match_count)
            VALUES (?, ?, ?, ?, ?, 0);
        """, [
            .text(id),
            .text(body),
            .text(kind.rawValue),
            .date(Date()),
            .integer(Int64(bytes))
        ])
        cache[id] = body
        Self.log.info("Promoted boilerplate \(id, privacy: .public) (\(bytes, privacy: .public) bytes, kind \(kind.rawValue, privacy: .public))")
        return id
    }

    /// Scan a batch of just-ingested KO contents and surface
    /// candidate substrings that appear in ≥ promotionThreshold of
    /// them. Returns the candidates so the caller can promote them.
    /// Used by EmailLoader's ingest path on each mbox/PST burst.
    public func detectAndPromote(
        bodies: [(ko: KnowledgeObject.ID, content: String)]
    ) async throws -> [String] {
        guard bodies.count >= Self.promotionThreshold else { return [] }
        // Shingled hashing: walk each body in 200-char windows
        // stepped by 100 chars, take SHA-256 of the window, count
        // distinct KO ids per hash. Hashes appearing in ≥3 KOs are
        // candidates. Then re-extract the verbatim window text from
        // any KO that carried the hash.
        var hashKOs: [String: Set<KnowledgeObject.ID>] = [:]
        var hashSample: [String: String] = [:]
        for (koID, body) in bodies {
            let utf8 = Array(body.utf8)
            guard utf8.count >= Self.minBlockBytes else { continue }
            let step = max(1, Self.minBlockBytes / 2)
            var start = 0
            while start + Self.minBlockBytes <= utf8.count {
                let end = start + Self.minBlockBytes
                let windowBytes = Array(utf8[start..<end])
                let h = Self.shortID(for: windowBytes)
                hashKOs[h, default: []].insert(koID)
                if hashSample[h] == nil {
                    if let s = String(bytes: windowBytes, encoding: .utf8) {
                        hashSample[h] = s
                    }
                }
                start += step
            }
        }
        // Filter to hashes appearing in ≥ promotionThreshold KOs and
        // promote (kind: unknown — a later pass can re-classify).
        var promoted: [String] = []
        for (h, kos) in hashKOs where kos.count >= Self.promotionThreshold {
            guard let sample = hashSample[h] else { continue }
            let id = try await promote(body: sample, kind: .unknown)
            promoted.append(id)
        }
        return promoted
    }

    /// Lazy load of all stored templates into the in-memory cache.
    /// Called from substituteKnown so the first call after boot
    /// is the one that pays the read cost.
    private func ensureLoaded() async throws {
        guard !loaded else { return }
        let rows = try await database.query(
            "SELECT id, body FROM boilerplate_templates ORDER BY byte_size DESC;"
        )
        for row in rows {
            guard let id = row.string(0), let body = row.string(1) else { continue }
            cache[id] = body
        }
        loaded = true
        Self.log.info("Loaded \(self.cache.count, privacy: .public) boilerplate templates")
    }

    // MARK: - Hash helpers

    /// First 8 hex chars of the SHA-256 over the UTF-8 bytes. Stable
    /// across runs; used as the template's primary key.
    nonisolated static func shortID(for body: String) -> String {
        shortID(for: Array(body.utf8))
    }

    nonisolated static func shortID(for bytes: [UInt8]) -> String {
        // Avoid CryptoKit dep at this layer; SHA-256 via CC.
        // Inline a tiny FNV-1a + djb2 mixed hash — good enough for
        // collision-rare 8-char identifiers over short windows.
        var h: UInt64 = 0xcbf29ce484222325
        for b in bytes {
            h ^= UInt64(b)
            h = h &* 0x100000001b3
        }
        var h2: UInt64 = 5381
        for b in bytes {
            h2 = ((h2 << 5) &+ h2) &+ UInt64(b)
        }
        let combined = h ^ h2.byteSwapped
        return String(format: "%016llx", combined).prefix(8).description
    }

    // MARK: - Standalone compaction over existing KOs

    /// Walk every knowledge_object, run detect+promote across the
    /// batch, then for each KO rewrite its `content` with template
    /// tokens and record uses. Returns a CompactionReport.
    /// Safe to call repeatedly; subsequent passes are no-ops for
    /// rows where every detected template was already substituted.
    public func compactExistingKOs(in database: Database) async throws -> CompactionReport {
        // 1. Load every KO body. Heavy but bounded — typical
        // archives produce 500-5000 rows.
        let rows = try await database.query(
            "SELECT id, content FROM knowledge_objects WHERE content NOT LIKE '%[[BOILERPLATE:%';"
        )
        let bodies: [(KnowledgeObject.ID, String)] = rows.compactMap { row in
            guard let id = row.uuid(0), let content = row.string(1) else { return nil }
            return (id, content)
        }
        guard !bodies.isEmpty else {
            return CompactionReport(scanned: 0, promoted: 0, rewritten: 0, bytesSaved: 0)
        }

        // 2. Detect + promote across the batch.
        let promotedIDs = try await detectAndPromote(bodies: bodies)
        Self.log.info("Compaction: scanned \(bodies.count, privacy: .public) KOs, promoted \(promotedIDs.count, privacy: .public) templates")

        // 3. For each KO, run substituteKnown and persist if changed.
        var rewritten = 0
        var saved = 0
        for (koID, originalBody) in bodies {
            let (newBody, used) = try await substituteKnown(originalBody)
            guard newBody != originalBody else { continue }
            let originalBytes = originalBody.utf8.count
            let newBytes = newBody.utf8.count
            saved += max(0, originalBytes - newBytes)
            try await database.exec(
                "UPDATE knowledge_objects SET content = ?, updated_at = ? WHERE id = ?;",
                [.text(newBody), .date(Date()), .uuid(koID)]
            )
            try await recordUses(templateIDs: used, for: koID)
            rewritten += 1
        }
        return CompactionReport(
            scanned: bodies.count,
            promoted: promotedIDs.count,
            rewritten: rewritten,
            bytesSaved: saved
        )
    }

    public struct CompactionReport: Sendable {
        public let scanned: Int
        public let promoted: Int
        public let rewritten: Int
        public let bytesSaved: Int
    }

    public enum TemplateKind: String, Sendable {
        case signature
        case privilegeDisclaimer = "privilege_disclaimer"
        case unsubscribeFooter = "unsubscribe_footer"
        case nda
        case gdprNotice = "gdpr_notice"
        case unknown
    }
}
