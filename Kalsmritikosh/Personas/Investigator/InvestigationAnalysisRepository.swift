//
//  InvestigationAnalysisRepository.swift
//  Kalsmritikosh
//
//  INV-04..07 — the durable authority for the Investigator analytical spine (schema v99): leads/hypotheses
//  + their for/against evidence links, evidence requests, and the 5W1H worksheet. Pure persistence with
//  optimistic revision CAS and one SAVEPOINT per mutation; every row REFERENCES canonical evidence by id and
//  forks no Claim/gap/contradiction authority. Case-scope authorization of cited evidence is enforced ONE
//  level up, in InvestigationAnalysisService — this actor only records what it is given.
//

import Foundation

public actor InvestigationAnalysisRepository {
    private let database: Database

    public init(database: Database) { self.database = database }

    // MARK: - Leads / hypotheses

    /// Capture an idea as a LEAD (INV-04). A lead is typed reasoning, never a fact.
    public func captureLead(caseID: UUID, statement: String, actor: String, at date: Date) async throws -> InvestigationHypothesis {
        try await insertHypothesis(caseID: caseID, kind: .lead, statement: statement, actor: actor, at: date)
    }

    /// Capture a hypothesis directly (INV-07).
    public func captureHypothesis(caseID: UUID, statement: String, actor: String, at date: Date) async throws -> InvestigationHypothesis {
        try await insertHypothesis(caseID: caseID, kind: .hypothesis, statement: statement, actor: actor, at: date)
    }

    private func insertHypothesis(caseID: UUID, kind: HypothesisKind, statement: String, actor: String, at date: Date) async throws -> InvestigationHypothesis {
        let clean = statement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw InvestigationHypothesisError.blankStatement }
        let cleanActor = try validatedActor(actor)
        let id = UUID()
        try await tx("invhyp", id) { db in
            try Self.requireOpenCase(db, caseID)
            try db.exec("""
                INSERT INTO investigation_hypotheses (id, case_id, kind, statement, status, origin_hypothesis_id, revision, actor, created_at, updated_at)
                VALUES (?,?,?,?,?,?,?,?,?,?);
                """, [.uuid(id), .uuid(caseID), .text(kind.rawValue), .text(clean), .text(HypothesisStatus.proposed.rawValue),
                      .null, .integer(1), .text(cleanActor), .date(date), .date(date)])
        }
        return try await requireHypothesis(id)
    }

    /// Promote a lead into a hypothesis (INV-04 human decision). In place: kind lead → hypothesis, status stays proposed.
    public func promoteToHypothesis(hypothesisID: UUID, expectedRevision: Int, actor: String, at date: Date) async throws -> InvestigationHypothesis {
        let cleanActor = try validatedActor(actor)
        try await tx("invhypp", hypothesisID) { db in
            let h = try Self.hypothesisCAS(db, hypothesisID, expectedRevision: expectedRevision)
            guard h.kind == .lead else { throw InvestigationHypothesisError.notALead(hypothesisID) }
            try db.exec("UPDATE investigation_hypotheses SET kind = ?, revision = ?, actor = ?, updated_at = ? WHERE id = ? AND revision = ?;",
                                         [.text(HypothesisKind.hypothesis.rawValue), .integer(Int64(h.revision + 1)), .text(cleanActor), .date(date), .uuid(hypothesisID), .integer(Int64(h.revision))])
        }
        return try await requireHypothesis(hypothesisID)
    }

    /// Set a hypothesis's human-decision status. `requireSupported` is checked by the service before this;
    /// only a PROPOSED hypothesis (kind=hypothesis) may move to confirmed/rejected; a lead may be dismissed.
    /// `decision` (rationale + the profile at decision time) is written in the same savepoint as the
    /// status change, so a confirmed hypothesis never exists without its recorded reasons.
    public func setHypothesisStatus(hypothesisID: UUID, expectedRevision: Int, to status: HypothesisStatus,
                                    actor: String, at date: Date,
                                    decision: (reason: HypothesisConfirmationReason, profile: HypothesisEvidenceProfile)? = nil) async throws -> InvestigationHypothesis {
        let cleanActor = try validatedActor(actor)
        try await tx("invhyps", hypothesisID) { db in
            if let decision {
                let p = decision.profile
                try db.exec("""
                    INSERT INTO investigation_hypothesis_decisions (id, hypothesis_id, decision, rationale, contrary_evidence, alternatives,
                        for_count, against_count, for_lineages, against_lineages, unassessed_count, actor, decided_at)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?);
                    """, [.uuid(UUID()), .uuid(hypothesisID), .text(status.rawValue), .text(decision.reason.rationale),
                          .text(decision.reason.contraryEvidence), .text(decision.reason.alternatives),
                          .integer(Int64(p.forCount)), .integer(Int64(p.againstCount)), .integer(Int64(p.forLineages)),
                          .integer(Int64(p.againstLineages)), .integer(Int64(p.unassessedCount)), .text(cleanActor), .date(date)])
            }
            let h = try Self.hypothesisCAS(db, hypothesisID, expectedRevision: expectedRevision)
            switch status {
            case .confirmed, .rejected:
                guard h.kind == .hypothesis else { throw InvestigationHypothesisError.notAHypothesis(hypothesisID) }
                guard h.status == .proposed else { throw InvestigationHypothesisError.notProposed(hypothesisID) }
            case .dismissed:
                break   // a lead or a proposed hypothesis can be dismissed
            case .proposed:
                break
            }
            try db.exec("UPDATE investigation_hypotheses SET status = ?, revision = ?, actor = ?, updated_at = ? WHERE id = ? AND revision = ?;",
                                         [.text(status.rawValue), .integer(Int64(h.revision + 1)), .text(cleanActor), .date(date), .uuid(hypothesisID), .integer(Int64(h.revision))])
        }
        return try await requireHypothesis(hypothesisID)
    }

    public func fetchHypothesis(_ id: UUID) async throws -> InvestigationHypothesis? {
        (try await database.query("\(Self.hypSelect) WHERE id = ? LIMIT 1;", [.uuid(id)])).first.flatMap(Self.decodeHypothesis)
    }
    public func hypotheses(caseID: UUID) async throws -> [InvestigationHypothesis] {
        (try await database.query("\(Self.hypSelect) WHERE case_id = ? ORDER BY created_at ASC, id ASC;", [.uuid(caseID)])).compactMap(Self.decodeHypothesis)
    }

    // MARK: - Evidence links (for/against)

    public func addEvidence(hypothesisID: UUID, stance: EvidenceStance, sourceVersionID: UUID, knowledgeObjectID: UUID,
                            note: String?, addedBy: String, at date: Date) async throws -> HypothesisEvidenceLink {
        let cleanBy = try validatedActor(addedBy)
        let id = UUID()
        let noteValue = opt(note)
        try await tx("invhe", id) { db in
            try db.exec("""
                INSERT INTO investigation_hypothesis_evidence (id, hypothesis_id, stance, source_version_id, knowledge_object_id, note, added_by, created_at)
                VALUES (?,?,?,?,?,?,?,?);
                """, [.uuid(id), .uuid(hypothesisID), .text(stance.rawValue), .uuid(sourceVersionID), .uuid(knowledgeObjectID),
                      noteValue, .text(cleanBy), .date(date)])
        }
        return HypothesisEvidenceLink(id: id, hypothesisID: hypothesisID, stance: stance, sourceVersionID: sourceVersionID,
                                      knowledgeObjectID: knowledgeObjectID, note: note?.trimmingCharacters(in: .whitespacesAndNewlines),
                                      addedBy: cleanBy, createdAt: date)
    }

    public func evidence(hypothesisID: UUID) async throws -> [HypothesisEvidenceLink] {
        let rows = try await database.query("""
            SELECT id, hypothesis_id, stance, source_version_id, knowledge_object_id, note, added_by, created_at
            FROM investigation_hypothesis_evidence WHERE hypothesis_id = ? ORDER BY created_at ASC, id ASC;
            """, [.uuid(hypothesisID)])
        return rows.compactMap { r in
            guard let id = r.uuid(0), let hyp = r.uuid(1), let stance = r.string(2).flatMap(EvidenceStance.init(rawValue:)),
                  let sv = r.uuid(3), let ko = r.uuid(4), let by = r.string(6), let at = r.date(7) else { return nil }
            return HypothesisEvidenceLink(id: id, hypothesisID: hyp, stance: stance, sourceVersionID: sv,
                                          knowledgeObjectID: ko, note: r.string(5), addedBy: by, createdAt: at)
        }
    }

    /// The counted evidence profile — deterministic counts, never a verdict.
    /// Lineages reuse the HIST-035 independence keys (email thread, file content hash); a citation whose
    /// object has no such key falls back to its source version's content hash, so two imports of the
    /// same bytes are still one lineage. Only a citation with neither stands alone.
    public func profile(hypothesisID: UUID) async throws -> HypothesisEvidenceProfile {
        let rows = try await database.query("""
            SELECT e.stance, e.knowledge_object_id, sv.content_hash, e.source_version_id,
                   (SELECT COUNT(*) FROM investigation_hypothesis_evidence_assessments a WHERE a.link_id = e.id)
            FROM investigation_hypothesis_evidence e
            LEFT JOIN source_versions sv ON sv.id = e.source_version_id
            WHERE e.hypothesis_id = ?;
            """, [.uuid(hypothesisID)])
        let objectIDs = Set(rows.compactMap { $0.uuid(1) })
        let keys = try await LedgerSourceIndependenceKeyProvider(objects: KnowledgeObjectRepository(database: database))
            .keys(for: objectIDs)
        var f = 0, a = 0, unassessed = 0
        var forKeys = Set<String>(), againstKeys = Set<String>()
        for r in rows {
            guard let stance = r.string(0).flatMap(EvidenceStance.init(rawValue:)) else { continue }
            let key = r.uuid(1).flatMap { keys[$0] }
                ?? r.string(2).map { "version-hash:" + $0 }
                ?? "version:" + (r.string(3) ?? UUID().uuidString)
            if (r.int(4) ?? 0) == 0 { unassessed += 1 }
            switch stance {
            case .supporting: f += 1; forKeys.insert(key)
            case .opposing: a += 1; againstKeys.insert(key)
            }
        }
        return HypothesisEvidenceProfile(forCount: f, againstCount: a, forLineages: forKeys.count,
                                         againstLineages: againstKeys.count, unassessedCount: unassessed)
    }

    /// Record (or revise) a reviewer's reliability + diagnostic-relevance assessment of one link.
    public func assess(linkID: UUID, reliability: SourceReliability, relevance: DiagnosticRelevance, note: String?,
                       assessedBy: String, at date: Date) async throws {
        let cleanBy = try validatedActor(assessedBy)
        let noteValue = opt(note)
        try await tx("invhea", linkID) { db in
            guard !(try db.query("SELECT 1 FROM investigation_hypothesis_evidence WHERE id = ? LIMIT 1;", [.uuid(linkID)])).isEmpty else {
                throw InvestigationHypothesisError.evidenceLinkNotFound(linkID)
            }
            try db.exec("""
                INSERT INTO investigation_hypothesis_evidence_assessments (link_id, reliability, diagnostic_relevance, note, assessed_by, assessed_at)
                VALUES (?,?,?,?,?,?)
                ON CONFLICT(link_id) DO UPDATE SET reliability = excluded.reliability, diagnostic_relevance = excluded.diagnostic_relevance,
                    note = excluded.note, assessed_by = excluded.assessed_by, assessed_at = excluded.assessed_at;
                """, [.uuid(linkID), .text(reliability.rawValue), .text(relevance.rawValue), noteValue, .text(cleanBy), .date(date)])
        }
    }

    public func assessments(hypothesisID: UUID) async throws -> [HypothesisEvidenceAssessment] {
        let rows = try await database.query("""
            SELECT a.link_id, a.reliability, a.diagnostic_relevance, a.note, a.assessed_by, a.assessed_at
            FROM investigation_hypothesis_evidence_assessments a
            JOIN investigation_hypothesis_evidence e ON e.id = a.link_id
            WHERE e.hypothesis_id = ? ORDER BY a.assessed_at ASC, a.link_id ASC;
            """, [.uuid(hypothesisID)])
        return rows.compactMap { r in
            guard let link = r.uuid(0), let rel = r.string(1).flatMap(SourceReliability.init(rawValue:)),
                  let dia = r.string(2).flatMap(DiagnosticRelevance.init(rawValue:)), let by = r.string(4), let at = r.date(5) else { return nil }
            return HypothesisEvidenceAssessment(linkID: link, reliability: rel, relevance: dia, note: r.string(3), assessedBy: by, assessedAt: at)
        }
    }

    /// Every hypothesis decision with the evidence profile it was made on (implementation brief §5).
    public func auditChainEvents() async throws -> [AuditChainEvent] {
        try await database.query("""
            SELECT id, hypothesis_id, decision, rationale, contrary_evidence, alternatives, for_count, against_count,
                   for_lineages, against_lineages, unassessed_count, actor, decided_at
            FROM investigation_hypothesis_decisions ORDER BY decided_at ASC, id ASC;
            """, []).compactMap { r in
            guard let id = r.uuid(0), let h = r.uuid(1), let decision = r.string(2), let actor = r.string(11), let at = r.date(12) else { return nil }
            func digest(_ i: Int) -> String { CaseFileHash.sha256(r.string(i) ?? "") }
            let counts = (6...10).map { String(r.int($0) ?? 0) }.joined(separator: ",")
            let payload = "actor=\(actor);alternativesDigest=\(digest(5));at=\(at.timeIntervalSince1970);contraryDigest=\(digest(4));"
                + "counts=\(counts);decision=\(decision);hypothesisID=\(h.uuidString);rationaleDigest=\(digest(3))"
            return AuditChainEvent(source: .hypothesisDecision, eventID: id, occurredAt: at, canonicalPayload: payload)
        }
    }

    public func decisions(hypothesisID: UUID) async throws -> [HypothesisDecision] {
        let rows = try await database.query("""
            SELECT id, hypothesis_id, decision, rationale, contrary_evidence, alternatives, for_count, against_count,
                   for_lineages, against_lineages, unassessed_count, actor, decided_at
            FROM investigation_hypothesis_decisions WHERE hypothesis_id = ? ORDER BY decided_at ASC, id ASC;
            """, [.uuid(hypothesisID)])
        return rows.compactMap { r in
            guard let id = r.uuid(0), let hyp = r.uuid(1), let decision = r.string(2).flatMap(HypothesisStatus.init(rawValue:)),
                  let rationale = r.string(3), let actor = r.string(11), let at = r.date(12) else { return nil }
            let profile = HypothesisEvidenceProfile(forCount: Int(r.int(6) ?? 0), againstCount: Int(r.int(7) ?? 0),
                                                    forLineages: Int(r.int(8) ?? 0), againstLineages: Int(r.int(9) ?? 0),
                                                    unassessedCount: Int(r.int(10) ?? 0))
            return HypothesisDecision(id: id, hypothesisID: hyp, decision: decision, rationale: rationale, contraryEvidence: r.string(4),
                                      alternatives: r.string(5), profile: profile, actor: actor, decidedAt: at)
        }
    }

    // MARK: - Evidence requests

    public func createRequest(caseID: UUID, hypothesisID: UUID?, description: String, actor: String, at date: Date) async throws -> EvidenceRequest {
        let clean = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw InvestigationHypothesisError.blankStatement }
        let cleanActor = try validatedActor(actor)
        let id = UUID()
        try await tx("invreq", id) { db in
            try Self.requireOpenCase(db, caseID)
            try db.exec("""
                INSERT INTO investigation_evidence_requests (id, case_id, hypothesis_id, description, status, revision, actor, created_at, updated_at)
                VALUES (?,?,?,?,?,?,?,?,?);
                """, [.uuid(id), .uuid(caseID), hypothesisID.map { SQLValue.uuid($0) } ?? .null, .text(clean),
                      .text(EvidenceRequestStatus.open.rawValue), .integer(1), .text(cleanActor), .date(date), .date(date)])
        }
        return try await requireRequest(id)
    }

    public func setRequestStatus(requestID: UUID, expectedRevision: Int, to status: EvidenceRequestStatus, actor: String, at date: Date) async throws -> EvidenceRequest {
        let cleanActor = try validatedActor(actor)
        try await tx("invreqs", requestID) { db in
            let r = try Self.requestCAS(db, requestID, expectedRevision: expectedRevision)
            try db.exec("UPDATE investigation_evidence_requests SET status = ?, revision = ?, actor = ?, updated_at = ? WHERE id = ? AND revision = ?;",
                                         [.text(status.rawValue), .integer(Int64(r.revision + 1)), .text(cleanActor), .date(date), .uuid(requestID), .integer(Int64(r.revision))])
        }
        return try await requireRequest(requestID)
    }

    public func requests(caseID: UUID) async throws -> [EvidenceRequest] {
        (try await database.query("\(Self.reqSelect) WHERE case_id = ? ORDER BY created_at ASC, id ASC;", [.uuid(caseID)])).compactMap(Self.decodeRequest)
    }

    // MARK: - 5W1H worksheet

    /// Upsert a 5W1H cell. `answered` requires answer + cited evidence; `unknown` clears them. One cell per
    /// (case, dimension) — a re-set bumps its revision.
    public func setCell(caseID: UUID, dimension: WorksheetDimension, status: WorksheetCellStatus, answerText: String?,
                        sourceVersionID: UUID?, knowledgeObjectID: UUID?, actor: String, at date: Date) async throws -> WorksheetCell {
        let cleanActor = try validatedActor(actor)
        let answer: SQLValue = status == .answered ? .text((answerText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) : .null
        let sv: SQLValue = status == .answered ? (sourceVersionID.map { .uuid($0) } ?? .null) : .null
        let ko: SQLValue = status == .answered ? (knowledgeObjectID.map { .uuid($0) } ?? .null) : .null
        try await tx("invcell", caseID, dimension.rawValue) { db in
            try Self.requireOpenCase(db, caseID)
            let existing = try db.query("SELECT id, revision FROM investigation_worksheet_cells WHERE case_id = ? AND dimension = ? LIMIT 1;",
                                                         [.uuid(caseID), .text(dimension.rawValue)]).first
            if let existing, let cid = existing.uuid(0), let rev = existing.int(1) {
                try db.exec("""
                    UPDATE investigation_worksheet_cells SET status = ?, answer_text = ?, source_version_id = ?, knowledge_object_id = ?, revision = ?, actor = ?, updated_at = ?
                    WHERE id = ?;
                    """, [.text(status.rawValue), answer, sv, ko, .integer(rev + 1), .text(cleanActor), .date(date), .uuid(cid)])
            } else {
                try db.exec("""
                    INSERT INTO investigation_worksheet_cells (id, case_id, dimension, status, answer_text, source_version_id, knowledge_object_id, revision, actor, updated_at)
                    VALUES (?,?,?,?,?,?,?,?,?,?);
                    """, [.uuid(UUID()), .uuid(caseID), .text(dimension.rawValue), .text(status.rawValue), answer, sv, ko, .integer(1), .text(cleanActor), .date(date)])
            }
        }
        return try await requireCell(caseID: caseID, dimension: dimension)
    }

    public func cells(caseID: UUID) async throws -> [WorksheetCell] {
        (try await database.query("\(Self.cellSelect) WHERE case_id = ? ORDER BY dimension ASC;", [.uuid(caseID)])).compactMap(Self.decodeCell)
    }
    public func cell(caseID: UUID, dimension: WorksheetDimension) async throws -> WorksheetCell? {
        (try await database.query("\(Self.cellSelect) WHERE case_id = ? AND dimension = ? LIMIT 1;", [.uuid(caseID), .text(dimension.rawValue)])).first.flatMap(Self.decodeCell)
    }

    // MARK: - Internals

    private static let hypSelect = "SELECT id, case_id, kind, statement, status, origin_hypothesis_id, revision, actor, created_at, updated_at FROM investigation_hypotheses"
    private static let reqSelect = "SELECT id, case_id, hypothesis_id, description, status, revision, actor, created_at, updated_at FROM investigation_evidence_requests"
    private static let cellSelect = "SELECT id, case_id, dimension, status, answer_text, source_version_id, knowledge_object_id, revision, actor, updated_at FROM investigation_worksheet_cells"

    private func requireHypothesis(_ id: UUID) async throws -> InvestigationHypothesis {
        guard let h = try await fetchHypothesis(id) else { throw InvestigationHypothesisError.hypothesisNotFound(id) }
        return h
    }
    /// Read + revision check INSIDE the caller's savepoint, so the CAS and the write are one step.
    private static func hypothesisCAS(_ db: isolated Database, _ id: UUID, expectedRevision: Int) throws -> InvestigationHypothesis {
        guard let h = try db.query("\(hypSelect) WHERE id = ? LIMIT 1;", [.uuid(id)]).first.flatMap(Self.decodeHypothesis) else {
            throw InvestigationHypothesisError.hypothesisNotFound(id)
        }
        guard h.revision == expectedRevision else { throw InvestigationHypothesisError.revisionConflict(expected: expectedRevision, actual: h.revision) }
        return h
    }
    private func requireRequest(_ id: UUID) async throws -> EvidenceRequest {
        guard let r = (try await database.query("\(Self.reqSelect) WHERE id = ? LIMIT 1;", [.uuid(id)])).first.flatMap(Self.decodeRequest) else {
            throw InvestigationHypothesisError.requestNotFound(id)
        }
        return r
    }
    private static func requestCAS(_ db: isolated Database, _ id: UUID, expectedRevision: Int) throws -> EvidenceRequest {
        guard let r = try db.query("\(reqSelect) WHERE id = ? LIMIT 1;", [.uuid(id)]).first.flatMap(Self.decodeRequest) else {
            throw InvestigationHypothesisError.requestNotFound(id)
        }
        guard r.revision == expectedRevision else { throw InvestigationHypothesisError.revisionConflict(expected: expectedRevision, actual: r.revision) }
        return r
    }
    private func requireCell(caseID: UUID, dimension: WorksheetDimension) async throws -> WorksheetCell {
        guard let c = try await cell(caseID: caseID, dimension: dimension) else { throw InvestigationHypothesisError.cellAnswerRequiresEvidence(dimension) }
        return c
    }

    /// Checked inside the write's savepoint: the case cannot close between the check and the write.
    private static func requireOpenCase(_ db: isolated Database, _ caseID: UUID) throws {
        let rows = try db.query("SELECT status FROM investigation_cases WHERE id = ? LIMIT 1;", [.uuid(caseID)])
        guard let status = rows.first?.string(0) else { throw InvestigationHypothesisError.caseNotFound(caseID) }
        if status == InvestigationCaseStatus.closed.rawValue { throw InvestigationHypothesisError.caseClosed(caseID) }
    }

    private nonisolated static func decodeHypothesis(_ r: SQLRow) -> InvestigationHypothesis? {
        guard let id = r.uuid(0), let caseID = r.uuid(1), let kind = r.string(2).flatMap(HypothesisKind.init(rawValue:)),
              let statement = r.string(3), let status = r.string(4).flatMap(HypothesisStatus.init(rawValue:)),
              let rev = r.int(6), let actor = r.string(7), let created = r.date(8), let updated = r.date(9) else { return nil }
        return InvestigationHypothesis(id: id, caseID: caseID, kind: kind, statement: statement, status: status,
                                       originHypothesisID: r.uuid(5), revision: Int(rev), actor: actor, createdAt: created, updatedAt: updated)
    }
    private nonisolated static func decodeRequest(_ r: SQLRow) -> EvidenceRequest? {
        guard let id = r.uuid(0), let caseID = r.uuid(1), let desc = r.string(3),
              let status = r.string(4).flatMap(EvidenceRequestStatus.init(rawValue:)),
              let rev = r.int(5), let actor = r.string(6), let created = r.date(7), let updated = r.date(8) else { return nil }
        return EvidenceRequest(id: id, caseID: caseID, hypothesisID: r.uuid(2), description: desc, status: status,
                               revision: Int(rev), actor: actor, createdAt: created, updatedAt: updated)
    }
    private nonisolated static func decodeCell(_ r: SQLRow) -> WorksheetCell? {
        guard let id = r.uuid(0), let caseID = r.uuid(1), let dim = r.string(2).flatMap(WorksheetDimension.init(rawValue:)),
              let status = r.string(3).flatMap(WorksheetCellStatus.init(rawValue:)),
              let rev = r.int(7), let actor = r.string(8), let updated = r.date(9) else { return nil }
        return WorksheetCell(id: id, caseID: caseID, dimension: dim, status: status, answerText: r.string(4),
                             sourceVersionID: r.uuid(5), knowledgeObjectID: r.uuid(6), revision: Int(rev), actor: actor, updatedAt: updated)
    }

    private nonisolated func validatedActor(_ actor: String) throws -> String {
        let clean = actor.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw InvestigationHypothesisError.blankActor }
        return clean
    }
    private nonisolated func opt(_ s: String?) -> SQLValue {
        guard let s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .null }
        return .text(s)
    }

    /// One ISOLATED savepoint around a mutation body (F28): the body runs synchronously on the
    /// database actor, so no other caller's statements interleave with it.
    private func tx(_ prefix: String, _ id: UUID, _ extra: String = "",
                    _ body: @Sendable (isolated Database) throws -> Void) async throws {
        let sp = "\(prefix)_\(id.uuidString.replacingOccurrences(of: "-", with: ""))\(extra.isEmpty ? "" : "_" + extra.replacingOccurrences(of: "-", with: ""))"
        try await database.withSavepoint(sp, body)
    }
}
