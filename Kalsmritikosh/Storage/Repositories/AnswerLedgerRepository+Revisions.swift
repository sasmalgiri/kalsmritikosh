//
//  AnswerLedgerRepository+Revisions.swift
//  Kalsmritikosh
//
//  AEE-M2 — evolves the ONE answer-ledger authority with the progressive REVISION chain.
//  Every lifecycle transition for one answer is written in a SINGLE savepoint
//  (revision + claims + claim_evidence + lifecycle event + the answers projection), so a
//  user-visible verifiedFinal/corrected always has a durable audit record before it is shown.
//  Prior revisions are NEVER updated or deleted; a materially different answer is a NEW
//  revision, and a correction records what it replaced and why. Deterministic replay reaches
//  the exact EvidenceBlocks / SourceVersions with no model call.
//

import Foundation

// MARK: - Value types

/// One immutable revision in an answer's chain.
public struct StoredAnswerRevision: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let answerID: UUID
    public let revisionNumber: Int
    public let body: String
    public let answerState: AnswerState
    public let confidence: Double
    public let source: String?
    public let contentHash: String
    public let correctionOfRevisionID: UUID?
    public let correctionReason: String?
    public let correctionReasonKind: CorrectionReasonKind?
    public let createdAt: Date
    public var isCorrection: Bool { correctionOfRevisionID != nil }
}

/// One append-only progressive-answer lifecycle event.
public struct AnswerLifecycleEvent: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let answerID: UUID
    public let sequence: Int
    public let revisionID: UUID?
    public let state: ProgressiveAnswerState
    public let detail: String?
    public let createdAt: Date
}

/// The full revision + event history of one answer (for the audit view and replay).
public struct AnswerHistory: Sendable, Hashable {
    public let answerID: UUID
    public let isTerminal: Bool
    public let revisions: [StoredAnswerRevision]   // ordered by revision_number
    public let events: [AnswerLifecycleEvent]      // ordered by sequence
    public var latestState: ProgressiveAnswerState? { events.last?.state }
    public var latestRevision: StoredAnswerRevision? { revisions.last }
}

/// A deterministic replay leaf — the exact evidence a claim rests on, down to blocks + versions.
public struct ReplayEvidenceLeaf: Sendable, Hashable {
    public let objectID: UUID?
    public let eventID: UUID?
    public let blockIDs: [String]
    public let sourceVersionIDs: [String]
    public let role: String
}
public struct ReplayClaim: Sendable, Hashable {
    public let claimID: UUID
    public let text: String
    public let evidence: [ReplayEvidenceLeaf]
}
public struct ReplayRevision: Sendable, Hashable {
    public let revision: StoredAnswerRevision
    public let claims: [ReplayClaim]
}
/// The deterministic replay of an answer: revisions → claims → evidence → blocks → versions.
public struct AnswerReplay: Sendable, Hashable {
    public let answerID: UUID
    public let revisions: [ReplayRevision]
}

// MARK: - Revision writer

extension AnswerLedgerRepository {

    /// The inputs describing a correction (which prior revision it replaces + why).
    public struct CorrectionInput: Sendable, Hashable {
        public let priorRevisionID: UUID
        public let reasonKind: CorrectionReasonKind
        public let detail: String?
        public init(priorRevisionID: UUID, reasonKind: CorrectionReasonKind, detail: String? = nil) {
            self.priorRevisionID = priorRevisionID; self.reasonKind = reasonKind; self.detail = detail
        }
    }

    /// Create the answers header for a new progressive answer (non-terminal). No revision yet.
    @discardableResult
    public func beginAnswer(
        question: String,
        mission: QueryMission?,
        corpusSnapshotID: UUID? = nil,
        originScopeID: UUID? = nil,
        at when: Date = Date()
    ) async throws -> UUID {
        let answerID = UUID()
        try await database.exec("""
        INSERT INTO answers
            (id, question, answer_state, corpus_snapshot_id, body, confidence, source, created_at,
             request_id, mission_lane, mission_objective, mission_deliverable, is_terminal, updated_at,
             origin_scope_id)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?);
        """, [
            .uuid(answerID), .text(question), .text(AnswerState.unknown.rawValue),
            corpusSnapshotID.map { .uuid($0) } ?? .null, .text(""), .real(0), .null,
            .real(when.timeIntervalSince1970),
            mission.map { .uuid($0.requestID) } ?? .null,
            mission.map { .text($0.primaryLane.rawValue) } ?? .null,
            mission.map { .text($0.objective.rawValue) } ?? .null,
            mission.map { .text($0.deliverable.rawValue) } ?? .null,
            .real(when.timeIntervalSince1970),
            originScopeID.map { .uuid($0) } ?? .null
        ])
        return answerID
    }

    /// immediateFinding — a cited, explicitly-provisional finding.
    @discardableResult
    public func appendFinding(answerID: UUID, body: String, answerText: String? = nil,
                              citations: [VerifiedAnswer.Citation], answerState: AnswerState,
                              confidence: Double, source: String? = nil, detail: String? = nil,
                              at when: Date = Date()) async throws -> UUID {
        try await writeContentRevision(answerID: answerID, targetState: .immediateFinding, body: body,
            answerText: answerText, citations: citations, answerState: answerState, confidence: confidence,
            source: source, correction: nil, detail: detail, at: when)
    }

    /// groundedWorkingResult — the first answer-shaped result with citations.
    @discardableResult
    public func appendWorkingResult(answerID: UUID, body: String, answerText: String? = nil,
                                    citations: [VerifiedAnswer.Citation], answerState: AnswerState,
                                    confidence: Double, source: String? = nil, detail: String? = nil,
                                    at when: Date = Date()) async throws -> UUID {
        try await writeContentRevision(answerID: answerID, targetState: .groundedWorkingResult, body: body,
            answerText: answerText, citations: citations, answerState: answerState, confidence: confidence,
            source: source, correction: nil, detail: detail, at: when)
    }

    /// corrected — an explicit replacement of a previously-visible revision (preserved).
    @discardableResult
    public func recordCorrection(answerID: UUID, body: String, answerText: String? = nil,
                                 citations: [VerifiedAnswer.Citation], answerState: AnswerState,
                                 confidence: Double, source: String? = nil,
                                 correction: CorrectionInput, at when: Date = Date()) async throws -> UUID {
        try await writeContentRevision(answerID: answerID, targetState: .corrected, body: body,
            answerText: answerText, citations: citations, answerState: answerState, confidence: confidence,
            source: source, correction: correction, detail: nil, at: when)
    }

    /// analysisProgress — a status-only event (no content revision, no uncited claims).
    public func appendProgress(answerID: UUID, detail: String, at when: Date = Date()) async throws {
        try await database.withSavepoint("aee_progress") { db in
            try Self.requireLiveAnswer(db, answerID)
            let last = try Self.lastState(db, answerID)
            try ProgressiveAnswerStateMachine().validate(from: last, to: .analysisProgress)
            let seq = try Self.nextEventSequence(db, answerID)
            try Self.insertEvent(db, answerID: answerID, sequence: seq, revisionID: nil,
                                 state: .analysisProgress, detail: detail, at: when)
            try Self.touch(db, answerID, at: when)
        }
    }

    /// reviewReady — the current content revision satisfies the mission's obligations.
    public func markReviewReady(answerID: UUID, detail: String? = nil, at when: Date = Date()) async throws {
        try await database.withSavepoint("aee_review") { db in
            try Self.requireLiveAnswer(db, answerID)
            guard let rev = try Self.latestRevisionID(db, answerID) else {
                throw ProgressiveAnswerError.noContentRevisionToReview
            }
            let last = try Self.lastState(db, answerID)
            try ProgressiveAnswerStateMachine().validate(from: last, to: .reviewReady)
            let seq = try Self.nextEventSequence(db, answerID)
            try Self.insertEvent(db, answerID: answerID, sequence: seq, revisionID: rev,
                                 state: .reviewReady, detail: detail, at: when)
            try Self.touch(db, answerID, at: when)
        }
    }

    /// verifiedFinal — lock the answer AFTER verification. Projects the final revision into the
    /// answers row so the whole write (event + terminal projection) is durable before display.
    public func lockVerifiedFinal(answerID: UUID, detail: String? = nil, at when: Date = Date()) async throws {
        try await database.withSavepoint("aee_final") { db in
            try Self.requireLiveAnswer(db, answerID)
            let last = try Self.lastState(db, answerID)
            guard last == .reviewReady else { throw ProgressiveAnswerError.notReviewReady }
            guard let rev = try Self.latestRevisionID(db, answerID) else {
                throw ProgressiveAnswerError.noContentRevisionToReview
            }
            let seq = try Self.nextEventSequence(db, answerID)
            try Self.insertEvent(db, answerID: answerID, sequence: seq, revisionID: rev,
                                 state: .verifiedFinal, detail: detail, at: when)
            try Self.projectRevision(db, answerID: answerID, revisionID: rev, terminal: true, at: when)
        }
    }

    /// incomplete — an honest terminal when the mission could not complete. May carry a partial
    /// revision (what was found) or be revision-less (interrupted before any content).
    public func markIncomplete(answerID: UUID, reason: String, at when: Date = Date()) async throws {
        try await database.withSavepoint("aee_incomplete") { db in
            try Self.requireLiveAnswer(db, answerID)
            let last = try Self.lastState(db, answerID)
            try ProgressiveAnswerStateMachine().validate(from: last, to: .incomplete)
            let rev = try Self.latestRevisionID(db, answerID)          // may be nil
            let seq = try Self.nextEventSequence(db, answerID)
            try Self.insertEvent(db, answerID: answerID, sequence: seq, revisionID: rev,
                                 state: .incomplete, detail: reason, at: when)
            if let rev { try Self.projectRevision(db, answerID: answerID, revisionID: rev, terminal: true, at: when) }
            else { try Self.markTerminal(db, answerID, at: when) }
        }
    }

    // MARK: - Content revision core

    private func writeContentRevision(
        answerID: UUID, targetState: ProgressiveAnswerState, body: String, answerText: String?,
        citations: [VerifiedAnswer.Citation], answerState: AnswerState, confidence: Double,
        source: String?, correction: CorrectionInput?, detail: String?, at when: Date
    ) async throws -> UUID {
        // Resolve each citation's supporting block ids OUTSIDE the savepoint (read-only, async).
        let resolved = await resolvedBlockIDs(for: citations)
        let hash = ProgressiveAnswerContentHasher().hash(
            answerText: answerText ?? body, citations: citations, answerState: answerState)

        if let correction, correction.reasonKind.requiresDetail,
           (correction.detail ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ProgressiveAnswerError.correctionReasonDetailRequired
        }

        return try await database.withSavepoint("aee_content") { db -> UUID in
            try Self.requireLiveAnswer(db, answerID)
            let last = try Self.lastState(db, answerID)
            try ProgressiveAnswerStateMachine().validate(from: last, to: targetState)

            // The latest existing revision (all revisions are content revisions).
            let latest = try db.query("""
                SELECT id, content_hash FROM answer_revisions WHERE answer_id = ?
                ORDER BY revision_number DESC LIMIT 1;
                """, [.uuid(answerID)]).first
            let latestID = latest?.uuid(0)
            let latestHash = latest?.string(1)

            if let correction {
                // A correction must reference a prior revision of THIS answer and change content.
                let prior = try db.query("""
                    SELECT content_hash FROM answer_revisions WHERE id = ? AND answer_id = ? LIMIT 1;
                    """, [.uuid(correction.priorRevisionID), .uuid(answerID)]).first
                guard let priorHash = prior?.string(0) else { throw ProgressiveAnswerError.correctionCrossAnswer }
                guard priorHash != hash else { throw ProgressiveAnswerError.contentUnchanged }
            } else {
                // A non-correction repeat with identical content is an idempotent no-op.
                if let latestHash, latestHash == hash, let latestID { return latestID }
            }

            let revisionID = UUID()
            let revisionNumber = try Self.nextRevisionNumber(db, answerID)
            let reasonText: String? = correction.map { $0.detail?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? $0.reasonKind.rawValue }
            try db.exec("""
                INSERT INTO answer_revisions
                    (id, answer_id, revision_number, body, answer_state, confidence, source, content_hash,
                     correction_of_revision_id, correction_reason, correction_reason_kind, created_at)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?);
                """, [
                    .uuid(revisionID), .uuid(answerID), .integer(Int64(revisionNumber)),
                    .text(body), .text(answerState.rawValue), .real(confidence),
                    source.map { .text($0) } ?? .null, .text(hash),
                    correction.map { .uuid($0.priorRevisionID) } ?? .null,
                    reasonText.map { .text($0) } ?? .null,
                    correction.map { .text($0.reasonKind.rawValue) } ?? .null,
                    .real(when.timeIntervalSince1970)
                ])

            // One top-level claim per revision, pinned to the EXACT revision, plus its evidence.
            let claimID = UUID()
            try db.exec("""
                INSERT INTO answer_claims
                    (id, answer_id, claim_text, support_status, confidence, ordinal, created_at, revision_id)
                VALUES (?,?,?,?,?,?,?,?);
                """, [
                    .uuid(claimID), .uuid(answerID), .text(answerText ?? body),
                    .text(answerState.rawValue), .real(confidence), .integer(0),
                    .real(when.timeIntervalSince1970), .uuid(revisionID)
                ])
            for (citation, blocks) in resolved {
                let blocksJSON = blocks.isEmpty ? nil : (try? JSONEncoder().encode(blocks)).flatMap { String(data: $0, encoding: .utf8) }
                try db.exec("""
                    INSERT OR IGNORE INTO claim_evidence
                        (claim_id, object_id, chunk_id, event_id, entity_id, evidence_role, block_ids)
                    VALUES (?,?,?,?,?,?,?);
                    """, [
                        .uuid(claimID), .uuid(citation.objectID),
                        citation.chunkID.map { .uuid($0) } ?? .null,
                        citation.eventID.map { .uuid($0) } ?? .null, .null,
                        .text("supports"), blocksJSON.map { .text($0) } ?? .null
                    ])
            }

            let seq = try Self.nextEventSequence(db, answerID)
            try Self.insertEvent(db, answerID: answerID, sequence: seq, revisionID: revisionID,
                                 state: targetState, detail: detail, at: when)
            try Self.touch(db, answerID, at: when)
            return revisionID
        }
    }

    // MARK: - Recovery

    /// Mark every non-terminal v89 answer (one that went through the progressive lifecycle but
    /// never reached verifiedFinal/incomplete) as incomplete(interrupted). Legacy pre-v89
    /// answers (no lifecycle events) are untouched. Preserves the last durable revision.
    @discardableResult
    public func recoverInterruptedAnswers(reason: String = "interrupted", at when: Date = Date()) async throws -> [UUID] {
        let rows = try await database.query("""
            SELECT e.answer_id FROM answer_revision_events e
            GROUP BY e.answer_id
            HAVING SUM(CASE WHEN e.state IN ('verifiedFinal','incomplete') THEN 1 ELSE 0 END) = 0;
            """, [])
        let ids = rows.compactMap { $0.uuid(0) }
        for id in ids { try? await markIncomplete(answerID: id, reason: reason, at: when) }
        return ids
    }

    // MARK: - History + replay

    public func history(answerID: UUID) async throws -> AnswerHistory {
        let header = try await database.query("SELECT is_terminal FROM answers WHERE id = ? LIMIT 1;", [.uuid(answerID)]).first
        guard let header else { throw ProgressiveAnswerError.answerNotFound }
        let isTerminal = (header.int(0) ?? 0) != 0
        let revRows = try await database.query("""
            SELECT id, revision_number, body, answer_state, confidence, source, content_hash,
                   correction_of_revision_id, correction_reason, correction_reason_kind, created_at
            FROM answer_revisions WHERE answer_id = ? ORDER BY revision_number ASC;
            """, [.uuid(answerID)])
        let revisions: [StoredAnswerRevision] = revRows.compactMap { r in
            guard let id = r.uuid(0), let body = r.string(2), let hash = r.string(6) else { return nil }
            return StoredAnswerRevision(
                id: id, answerID: answerID, revisionNumber: Int(r.int(1) ?? 0), body: body,
                answerState: AnswerState(rawValue: r.string(3) ?? "") ?? .unknown,
                confidence: r.double(4) ?? 0, source: r.string(5), contentHash: hash,
                correctionOfRevisionID: r.uuid(7), correctionReason: r.string(8),
                correctionReasonKind: r.string(9).flatMap(CorrectionReasonKind.init(rawValue:)),
                createdAt: Date(timeIntervalSince1970: r.double(10) ?? 0))
        }
        let evRows = try await database.query("""
            SELECT id, sequence, revision_id, state, detail, created_at
            FROM answer_revision_events WHERE answer_id = ? ORDER BY sequence ASC;
            """, [.uuid(answerID)])
        let events: [AnswerLifecycleEvent] = evRows.compactMap { r in
            guard let id = r.uuid(0), let state = r.string(3).flatMap(ProgressiveAnswerState.init(rawValue:)) else { return nil }
            return AnswerLifecycleEvent(
                id: id, answerID: answerID, sequence: Int(r.int(1) ?? 0), revisionID: r.uuid(2),
                state: state, detail: r.string(4), createdAt: Date(timeIntervalSince1970: r.double(5) ?? 0))
        }
        return AnswerHistory(answerID: answerID, isTerminal: isTerminal, revisions: revisions, events: events)
    }

    /// Deterministic replay: answer → each revision → its claims → evidence → blocks → versions.
    /// No model call.
    public func replay(answerID: UUID) async throws -> AnswerReplay {
        let history = try await history(answerID: answerID)
        var out: [ReplayRevision] = []
        for revision in history.revisions {
            let claimRows = try await database.query("""
                SELECT id, claim_text FROM answer_claims WHERE revision_id = ? ORDER BY ordinal ASC;
                """, [.uuid(revision.id)])
            var claims: [ReplayClaim] = []
            for cr in claimRows {
                guard let claimID = cr.uuid(0), let text = cr.string(1) else { continue }
                let evRows = try await database.query("""
                    SELECT object_id, event_id, evidence_role, block_ids FROM claim_evidence WHERE claim_id = ?;
                    """, [.uuid(claimID)])
                var leaves: [ReplayEvidenceLeaf] = []
                for er in evRows {
                    let blocks: [String] = {
                        guard let json = er.string(3), let data = json.data(using: .utf8) else { return [] }
                        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
                    }()
                    let versions = try await sourceVersionIDs(forBlockIDs: blocks)
                    leaves.append(ReplayEvidenceLeaf(objectID: er.uuid(0), eventID: er.uuid(1),
                        blockIDs: blocks, sourceVersionIDs: versions, role: er.string(2) ?? "supports"))
                }
                claims.append(ReplayClaim(claimID: claimID, text: text, evidence: leaves))
            }
            out.append(ReplayRevision(revision: revision, claims: claims))
        }
        return AnswerReplay(answerID: answerID, revisions: out)
    }

    // MARK: - Internals

    private func resolvedBlockIDs(for citations: [VerifiedAnswer.Citation]) async -> [(VerifiedAnswer.Citation, [String])] {
        var out: [(VerifiedAnswer.Citation, [String])] = []
        for c in citations {
            var blocks: [String] = []
            if let eventID = c.eventID { blocks = await blockIDs(forEvent: eventID) }
            if blocks.isEmpty, !c.snippet.isEmpty { blocks = await blockIDs(forObject: c.objectID, snippet: c.snippet) }
            out.append((c, blocks))
        }
        return out
    }

    private func sourceVersionIDs(forBlockIDs blockIDs: [String]) async throws -> [String] {
        guard !blockIDs.isEmpty else { return [] }
        var versions = Set<String>()
        for bid in blockIDs {
            guard let uuid = UUID(uuidString: bid) else { continue }
            let rows = try await database.query(
                "SELECT source_version_id FROM evidence_blocks WHERE id = ? LIMIT 1;", [.uuid(uuid)])
            if let sv = rows.first?.uuid(0) { versions.insert(sv.uuidString) }
        }
        return versions.sorted()
    }

    // Synchronous helpers used INSIDE a savepoint (isolated Database).

    fileprivate static func requireLiveAnswer(_ db: isolated Database, _ answerID: UUID) throws {
        guard let row = try db.query("SELECT is_terminal FROM answers WHERE id = ? LIMIT 1;", [.uuid(answerID)]).first
        else { throw ProgressiveAnswerError.answerNotFound }
        if (row.int(0) ?? 0) != 0 { throw ProgressiveAnswerError.answerAlreadyTerminal }
    }

    fileprivate static func lastState(_ db: isolated Database, _ answerID: UUID) throws -> ProgressiveAnswerState? {
        try db.query("SELECT state FROM answer_revision_events WHERE answer_id = ? ORDER BY sequence DESC LIMIT 1;",
                     [.uuid(answerID)]).first?.string(0).flatMap(ProgressiveAnswerState.init(rawValue:))
    }

    fileprivate static func latestRevisionID(_ db: isolated Database, _ answerID: UUID) throws -> UUID? {
        try db.query("SELECT id FROM answer_revisions WHERE answer_id = ? ORDER BY revision_number DESC LIMIT 1;",
                     [.uuid(answerID)]).first?.uuid(0)
    }

    fileprivate static func nextRevisionNumber(_ db: isolated Database, _ answerID: UUID) throws -> Int {
        Int(try db.query("SELECT COALESCE(MAX(revision_number),0)+1 FROM answer_revisions WHERE answer_id = ?;",
                         [.uuid(answerID)]).first?.int(0) ?? 1)
    }

    fileprivate static func nextEventSequence(_ db: isolated Database, _ answerID: UUID) throws -> Int {
        Int(try db.query("SELECT COALESCE(MAX(sequence),0)+1 FROM answer_revision_events WHERE answer_id = ?;",
                         [.uuid(answerID)]).first?.int(0) ?? 1)
    }

    fileprivate static func insertEvent(_ db: isolated Database, answerID: UUID, sequence: Int,
                                        revisionID: UUID?, state: ProgressiveAnswerState,
                                        detail: String?, at when: Date) throws {
        try db.exec("""
            INSERT INTO answer_revision_events (id, answer_id, sequence, revision_id, state, detail, created_at)
            VALUES (?,?,?,?,?,?,?);
            """, [.uuid(UUID()), .uuid(answerID), .integer(Int64(sequence)),
                  revisionID.map { .uuid($0) } ?? .null, .text(state.rawValue),
                  detail.map { .text($0) } ?? .null, .real(when.timeIntervalSince1970)])
    }

    fileprivate static func touch(_ db: isolated Database, _ answerID: UUID, at when: Date) throws {
        try db.exec("UPDATE answers SET updated_at = ? WHERE id = ?;",
                    [.real(when.timeIntervalSince1970), .uuid(answerID)])
    }

    fileprivate static func markTerminal(_ db: isolated Database, _ answerID: UUID, at when: Date) throws {
        try db.exec("UPDATE answers SET is_terminal = 1, updated_at = ? WHERE id = ?;",
                    [.real(when.timeIntervalSince1970), .uuid(answerID)])
    }

    /// Project a revision's body/state/confidence/source into the answers row (legacy readers
    /// see the current/terminal content), optionally marking the answer terminal.
    fileprivate static func projectRevision(_ db: isolated Database, answerID: UUID, revisionID: UUID,
                                            terminal: Bool, at when: Date) throws {
        guard let r = try db.query("""
            SELECT body, answer_state, confidence, source FROM answer_revisions WHERE id = ? LIMIT 1;
            """, [.uuid(revisionID)]).first else { throw ProgressiveAnswerError.revisionNotFound }
        try db.exec("""
            UPDATE answers SET body = ?, answer_state = ?, confidence = ?, source = ?,
                is_terminal = ?, updated_at = ? WHERE id = ?;
            """, [.text(r.string(0) ?? ""), .text(r.string(1) ?? AnswerState.unknown.rawValue),
                  .real(r.double(2) ?? 0), r.string(3).map { .text($0) } ?? .null,
                  .integer(terminal ? 1 : 0), .real(when.timeIntervalSince1970), .uuid(answerID)])
    }
}

private extension String {
    nonisolated var nilIfEmpty: String? { isEmpty ? nil : self }
}
