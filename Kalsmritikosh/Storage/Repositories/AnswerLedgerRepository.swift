//
//  AnswerLedgerRepository.swift
//  Kalsmritikosh
//
//  Ledger-AI v28 — persists answers as first-class objects, not
//  throwaway prose. The correct generation flow is:
//
//      Evidence → Claims → Verified answer → User-facing prose
//
//  ...NOT "LLM paragraph → hope it is correct". This repository stores
//  the answer, its atomic claims, and the claim→evidence contract so
//  the "Why this answer?" panel and future audits can reconstruct
//  exactly which files/chunks/events/entities supported each claim, and
//  which corpus snapshot the answer was produced against.
//

import Foundation

/// One persisted answer row (header). Claims + evidence hang off it via
/// the answer_claims / claim_evidence tables.
public struct StoredAnswer: Sendable, Identifiable, Hashable {
    public typealias ID = UUID

    public let id: ID
    public let question: String
    public let answerState: AnswerState
    public let corpusSnapshotID: UUID?
    public let body: String
    public let confidence: Double
    public let source: String?
    public let createdAt: Date

    public nonisolated init(
        id: ID = UUID(),
        question: String,
        answerState: AnswerState,
        corpusSnapshotID: UUID? = nil,
        body: String,
        confidence: Double,
        source: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.question = question
        self.answerState = answerState
        self.corpusSnapshotID = corpusSnapshotID
        self.body = body
        self.confidence = confidence
        self.source = source
        self.createdAt = createdAt
    }
}

public actor AnswerLedgerRepository {
    private let database: Database

    public init(database: Database) {
        self.database = database
    }

    /// Persist a VerifiedAnswer decomposed into the closed-corpus
    /// contract tables. Writes the answer header, one claim per
    /// contradiction-free answer body (support_status = answerState),
    /// and one claim_evidence row per citation. When the brain later
    /// produces true claim-level breakdowns, `persistClaims` can be
    /// used for the granular path.
    @discardableResult
    public func persist(
        question: String,
        answer: VerifiedAnswer,
        corpusSnapshotID: UUID?,
        at when: Date = Date()
    ) async throws -> UUID {
        let answerID = UUID()
        try await database.exec("""
        INSERT INTO answers
            (id, question, answer_state, corpus_snapshot_id, body, confidence, source, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?);
        """, [
            .uuid(answerID),
            .text(question),
            .text(answer.answerState.rawValue),
            corpusSnapshotID.map { .uuid($0) } ?? .null,
            .text(answer.body),
            .real(answer.confidence.value),
            .text(answer.source.rawValue),
            .real(when.timeIntervalSince1970)
        ])

        // One top-level claim representing the whole answer, tagged with
        // the answer's support state, plus its citations as evidence.
        let claimID = UUID()
        try await database.exec("""
        INSERT INTO answer_claims
            (id, answer_id, claim_text, support_status, confidence, ordinal, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?);
        """, [
            .uuid(claimID),
            .uuid(answerID),
            .text(answer.answerText ?? answer.body),
            .text(answer.answerState.rawValue),
            .real(answer.confidence.value),
            .integer(0),
            .real(when.timeIntervalSince1970)
        ])

        for citation in answer.citations {
            // A5.9 / A5.10 — for event citations, resolve the event's supporting
            // EvidenceBlock ids (A5.3) so the row completes the replay chain
            // answer → claim → event → block → locator → source version.
            var blockIDsJSON: String?
            var resolvedBlockIDs: [String] = []
            if let eventID = citation.eventID {
                resolvedBlockIDs = await blockIDs(forEvent: eventID)
            }
            // A5.10 bridge — for a non-event (object/chunk) citation, resolve the
            // snippet to the block(s) it came from WITHIN the cited object's own
            // source, so every citation — not just event ones — completes the
            // answer → block → locator chain.
            if resolvedBlockIDs.isEmpty, !citation.snippet.isEmpty {
                resolvedBlockIDs = await blockIDs(forObject: citation.objectID, snippet: citation.snippet)
            }
            if !resolvedBlockIDs.isEmpty, let data = try? JSONEncoder().encode(resolvedBlockIDs) {
                blockIDsJSON = String(data: data, encoding: .utf8)
            }
            try await database.exec("""
            INSERT OR IGNORE INTO claim_evidence
                (claim_id, object_id, chunk_id, event_id, entity_id, evidence_role, block_ids)
            VALUES (?, ?, ?, ?, ?, ?, ?);
            """, [
                .uuid(claimID),
                .uuid(citation.objectID),
                citation.chunkID.map { .uuid($0) } ?? .null,
                citation.eventID.map { .uuid($0) } ?? .null,
                .null,
                .text("supports"),
                blockIDsJSON.map { .text($0) } ?? .null
            ])
        }

        return answerID
    }

    /// A5.3-linked block ids an event cites, read from `events.attributes_json`
    /// (`sourceBlockIDs`). Empty when the event predates the structural layer or
    /// no block matched. Transparent JSON (AnyCodable is a single-value codec).
    private func blockIDs(forEvent eventID: UUID) async -> [String] {
        let rows = (try? await database.query(
            "SELECT attributes_json FROM events WHERE id = ? LIMIT 1;", [.uuid(eventID)]
        )) ?? []
        guard let json = rows.first?.string(0), let data = json.data(using: .utf8),
              let attrs = try? JSONDecoder().decode([String: AnyCodable].self, from: data),
              case .array(let arr)? = attrs["sourceBlockIDs"]?.value else { return [] }
        return arr.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
    }

    /// A5.10 block→KO bridge — the structural block(s) a snippet came from,
    /// scoped to the cited object's OWN source. Hops object → file → current
    /// source version → FTS-ranked blocks matching the snippet. Empty when the
    /// object has no structural version or nothing matches. Best-effort.
    private func blockIDs(forObject objectID: UUID, snippet: String) async -> [String] {
        // object → logical source (file_id).
        let fileRows = (try? await database.query(
            "SELECT file_id FROM knowledge_objects WHERE id = ? LIMIT 1;", [.uuid(objectID)]
        )) ?? []
        guard let fileID = fileRows.first?.uuid(0) else { return [] }
        // logical source → current source version.
        let versionRows = (try? await database.query("""
        SELECT id FROM source_versions WHERE logical_source_id = ? AND is_current = 1
        ORDER BY created_at DESC LIMIT 1;
        """, [.uuid(fileID)])) ?? []
        guard let versionID = versionRows.first?.uuid(0) else { return [] }
        // snippet → best-matching blocks WITHIN that version (FTS, bm25-ranked).
        let match = EvidenceStore.ftsQuery(snippet)
        guard !match.isEmpty else { return [] }
        let blockRows = (try? await database.query("""
        SELECT eb.id FROM evidence_blocks eb
        JOIN evidence_blocks_fts ON evidence_blocks_fts.rowid = eb.rowid
        WHERE eb.source_version_id = ? AND evidence_blocks_fts MATCH ?
        ORDER BY rank LIMIT 3;
        """, [.uuid(versionID), .text(match)])) ?? []
        return blockRows.compactMap { $0.uuid(0)?.uuidString }
    }

    public func recent(limit: Int = 100) async throws -> [StoredAnswer] {
        let rows = try await database.query("""
        SELECT id, question, answer_state, corpus_snapshot_id, body, confidence, source, created_at
        FROM answers
        ORDER BY created_at DESC
        LIMIT ?;
        """, [.integer(Int64(limit))])
        return rows.compactMap(decodeRow)
    }

    public func count() async throws -> Int {
        let rows = try await database.query("SELECT COUNT(*) FROM answers;", [])
        return Int(rows.first?.int(0) ?? 0)
    }

    /// One evidence link supporting a stored claim — the A5.10 replay leaf
    /// (object / event / blocks + role).
    public struct StoredClaimEvidence: Sendable, Hashable {
        public let objectID: UUID?
        public let eventID: UUID?
        public let blockIDs: [String]
        public let role: String
    }

    /// One stored claim with its evidence links.
    public struct StoredClaim: Sendable, Hashable, Identifiable {
        public let id: UUID
        public let text: String
        public let supportStatus: String
        public let confidence: Double
        public let evidence: [StoredClaimEvidence]
    }

    /// The claims (with evidence) for a stored answer, in order — the audit
    /// drill-down behind "Why this answer?": answer → claim → evidence → blocks.
    public func claims(forAnswer answerID: UUID) async throws -> [StoredClaim] {
        let claimRows = try await database.query("""
        SELECT id, claim_text, support_status, confidence
        FROM answer_claims WHERE answer_id = ? ORDER BY ordinal ASC;
        """, [.uuid(answerID)])

        var out: [StoredClaim] = []
        for row in claimRows {
            guard let claimID = row.uuid(0), let text = row.string(1) else { continue }
            let evidenceRows = try await database.query("""
            SELECT object_id, event_id, evidence_role, block_ids
            FROM claim_evidence WHERE claim_id = ?;
            """, [.uuid(claimID)])
            let evidence: [StoredClaimEvidence] = evidenceRows.map { er in
                let blocks: [String] = {
                    guard let json = er.string(3), let data = json.data(using: .utf8) else { return [] }
                    return (try? JSONDecoder().decode([String].self, from: data)) ?? []
                }()
                return StoredClaimEvidence(
                    objectID: er.uuid(0), eventID: er.uuid(1),
                    blockIDs: blocks, role: er.string(2) ?? "supports"
                )
            }
            out.append(StoredClaim(
                id: claimID, text: text,
                supportStatus: row.string(2) ?? "unknown",
                confidence: row.double(3) ?? 0,
                evidence: evidence
            ))
        }
        return out
    }

    // MARK: - Internals

    private func decodeRow(_ row: SQLRow) -> StoredAnswer? {
        guard
            let id = row.uuid(0),
            let question = row.string(1),
            let stateRaw = row.string(2),
            let body = row.string(4),
            let createdAtRaw = row.double(7)
        else { return nil }
        return StoredAnswer(
            id: id,
            question: question,
            answerState: AnswerState(rawValue: stateRaw) ?? .unknown,
            corpusSnapshotID: row.uuid(3),
            body: body,
            confidence: row.double(5) ?? 0,
            source: row.string(6),
            createdAt: Date(timeIntervalSince1970: createdAtRaw)
        )
    }
}
