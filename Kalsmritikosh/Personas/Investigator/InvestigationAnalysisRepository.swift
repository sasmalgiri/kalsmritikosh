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
        try await requireOpenCase(caseID)
        let id = UUID()
        try await tx("invhyp", id) {
            try await self.database.exec("""
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
        try await tx("invhypp", hypothesisID) {
            let h = try await self.requireHypothesisCAS(hypothesisID, expectedRevision: expectedRevision)
            guard h.kind == .lead else { throw InvestigationHypothesisError.notALead(hypothesisID) }
            try await self.database.exec("UPDATE investigation_hypotheses SET kind = ?, revision = ?, actor = ?, updated_at = ? WHERE id = ? AND revision = ?;",
                                         [.text(HypothesisKind.hypothesis.rawValue), .integer(Int64(h.revision + 1)), .text(cleanActor), .date(date), .uuid(hypothesisID), .integer(Int64(h.revision))])
        }
        return try await requireHypothesis(hypothesisID)
    }

    /// Set a hypothesis's human-decision status. `requireSupported` is checked by the service before this;
    /// only a PROPOSED hypothesis (kind=hypothesis) may move to confirmed/rejected; a lead may be dismissed.
    public func setHypothesisStatus(hypothesisID: UUID, expectedRevision: Int, to status: HypothesisStatus,
                                    actor: String, at date: Date) async throws -> InvestigationHypothesis {
        let cleanActor = try validatedActor(actor)
        try await tx("invhyps", hypothesisID) {
            let h = try await self.requireHypothesisCAS(hypothesisID, expectedRevision: expectedRevision)
            switch status {
            case .confirmed, .rejected:
                guard h.kind == .hypothesis else { throw InvestigationHypothesisError.notAHypothesis(hypothesisID) }
                guard h.status == .proposed else { throw InvestigationHypothesisError.notProposed(hypothesisID) }
            case .dismissed:
                break   // a lead or a proposed hypothesis can be dismissed
            case .proposed:
                break
            }
            try await self.database.exec("UPDATE investigation_hypotheses SET status = ?, revision = ?, actor = ?, updated_at = ? WHERE id = ? AND revision = ?;",
                                         [.text(status.rawValue), .integer(Int64(h.revision + 1)), .text(cleanActor), .date(date), .uuid(hypothesisID), .integer(Int64(h.revision))])
        }
        return try await requireHypothesis(hypothesisID)
    }

    public func fetchHypothesis(_ id: UUID) async throws -> InvestigationHypothesis? {
        (try await database.query("\(hypSelect) WHERE id = ? LIMIT 1;", [.uuid(id)])).first.flatMap(decodeHypothesis)
    }
    public func hypotheses(caseID: UUID) async throws -> [InvestigationHypothesis] {
        (try await database.query("\(hypSelect) WHERE case_id = ? ORDER BY created_at ASC, id ASC;", [.uuid(caseID)])).compactMap(decodeHypothesis)
    }

    // MARK: - Evidence links (for/against)

    public func addEvidence(hypothesisID: UUID, stance: EvidenceStance, sourceVersionID: UUID, knowledgeObjectID: UUID,
                            note: String?, addedBy: String, at date: Date) async throws -> HypothesisEvidenceLink {
        let cleanBy = try validatedActor(addedBy)
        let id = UUID()
        try await tx("invhe", id) {
            try await self.database.exec("""
                INSERT INTO investigation_hypothesis_evidence (id, hypothesis_id, stance, source_version_id, knowledge_object_id, note, added_by, created_at)
                VALUES (?,?,?,?,?,?,?,?);
                """, [.uuid(id), .uuid(hypothesisID), .text(stance.rawValue), .uuid(sourceVersionID), .uuid(knowledgeObjectID),
                      self.opt(note), .text(cleanBy), .date(date)])
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
    public func profile(hypothesisID: UUID) async throws -> HypothesisEvidenceProfile {
        let rows = try await database.query("""
            SELECT stance, COUNT(*) FROM investigation_hypothesis_evidence WHERE hypothesis_id = ? GROUP BY stance;
            """, [.uuid(hypothesisID)])
        var f = 0, a = 0
        for r in rows {
            let n = Int(r.int(1) ?? 0)
            if r.string(0) == EvidenceStance.supporting.rawValue { f = n } else if r.string(0) == EvidenceStance.opposing.rawValue { a = n }
        }
        return HypothesisEvidenceProfile(forCount: f, againstCount: a)
    }

    // MARK: - Evidence requests

    public func createRequest(caseID: UUID, hypothesisID: UUID?, description: String, actor: String, at date: Date) async throws -> EvidenceRequest {
        let clean = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw InvestigationHypothesisError.blankStatement }
        let cleanActor = try validatedActor(actor)
        try await requireOpenCase(caseID)
        let id = UUID()
        try await tx("invreq", id) {
            try await self.database.exec("""
                INSERT INTO investigation_evidence_requests (id, case_id, hypothesis_id, description, status, revision, actor, created_at, updated_at)
                VALUES (?,?,?,?,?,?,?,?,?);
                """, [.uuid(id), .uuid(caseID), hypothesisID.map { SQLValue.uuid($0) } ?? .null, .text(clean),
                      .text(EvidenceRequestStatus.open.rawValue), .integer(1), .text(cleanActor), .date(date), .date(date)])
        }
        return try await requireRequest(id)
    }

    public func setRequestStatus(requestID: UUID, expectedRevision: Int, to status: EvidenceRequestStatus, actor: String, at date: Date) async throws -> EvidenceRequest {
        let cleanActor = try validatedActor(actor)
        try await tx("invreqs", requestID) {
            let r = try await self.requireRequestCAS(requestID, expectedRevision: expectedRevision)
            try await self.database.exec("UPDATE investigation_evidence_requests SET status = ?, revision = ?, actor = ?, updated_at = ? WHERE id = ? AND revision = ?;",
                                         [.text(status.rawValue), .integer(Int64(r.revision + 1)), .text(cleanActor), .date(date), .uuid(requestID), .integer(Int64(r.revision))])
        }
        return try await requireRequest(requestID)
    }

    public func requests(caseID: UUID) async throws -> [EvidenceRequest] {
        (try await database.query("\(reqSelect) WHERE case_id = ? ORDER BY created_at ASC, id ASC;", [.uuid(caseID)])).compactMap(decodeRequest)
    }

    // MARK: - 5W1H worksheet

    /// Upsert a 5W1H cell. `answered` requires answer + cited evidence; `unknown` clears them. One cell per
    /// (case, dimension) — a re-set bumps its revision.
    public func setCell(caseID: UUID, dimension: WorksheetDimension, status: WorksheetCellStatus, answerText: String?,
                        sourceVersionID: UUID?, knowledgeObjectID: UUID?, actor: String, at date: Date) async throws -> WorksheetCell {
        let cleanActor = try validatedActor(actor)
        try await requireOpenCase(caseID)
        let answer: SQLValue = status == .answered ? .text((answerText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) : .null
        let sv: SQLValue = status == .answered ? (sourceVersionID.map { .uuid($0) } ?? .null) : .null
        let ko: SQLValue = status == .answered ? (knowledgeObjectID.map { .uuid($0) } ?? .null) : .null
        try await tx("invcell", caseID, dimension.rawValue) {
            let existing = try await self.database.query("SELECT id, revision FROM investigation_worksheet_cells WHERE case_id = ? AND dimension = ? LIMIT 1;",
                                                         [.uuid(caseID), .text(dimension.rawValue)]).first
            if let existing, let cid = existing.uuid(0), let rev = existing.int(1) {
                try await self.database.exec("""
                    UPDATE investigation_worksheet_cells SET status = ?, answer_text = ?, source_version_id = ?, knowledge_object_id = ?, revision = ?, actor = ?, updated_at = ?
                    WHERE id = ?;
                    """, [.text(status.rawValue), answer, sv, ko, .integer(rev + 1), .text(cleanActor), .date(date), .uuid(cid)])
            } else {
                try await self.database.exec("""
                    INSERT INTO investigation_worksheet_cells (id, case_id, dimension, status, answer_text, source_version_id, knowledge_object_id, revision, actor, updated_at)
                    VALUES (?,?,?,?,?,?,?,?,?,?);
                    """, [.uuid(UUID()), .uuid(caseID), .text(dimension.rawValue), .text(status.rawValue), answer, sv, ko, .integer(1), .text(cleanActor), .date(date)])
            }
        }
        return try await requireCell(caseID: caseID, dimension: dimension)
    }

    public func cells(caseID: UUID) async throws -> [WorksheetCell] {
        (try await database.query("\(cellSelect) WHERE case_id = ? ORDER BY dimension ASC;", [.uuid(caseID)])).compactMap(decodeCell)
    }
    public func cell(caseID: UUID, dimension: WorksheetDimension) async throws -> WorksheetCell? {
        (try await database.query("\(cellSelect) WHERE case_id = ? AND dimension = ? LIMIT 1;", [.uuid(caseID), .text(dimension.rawValue)])).first.flatMap(decodeCell)
    }

    // MARK: - Internals

    private let hypSelect = "SELECT id, case_id, kind, statement, status, origin_hypothesis_id, revision, actor, created_at, updated_at FROM investigation_hypotheses"
    private let reqSelect = "SELECT id, case_id, hypothesis_id, description, status, revision, actor, created_at, updated_at FROM investigation_evidence_requests"
    private let cellSelect = "SELECT id, case_id, dimension, status, answer_text, source_version_id, knowledge_object_id, revision, actor, updated_at FROM investigation_worksheet_cells"

    private func requireHypothesis(_ id: UUID) async throws -> InvestigationHypothesis {
        guard let h = try await fetchHypothesis(id) else { throw InvestigationHypothesisError.hypothesisNotFound(id) }
        return h
    }
    private func requireHypothesisCAS(_ id: UUID, expectedRevision: Int) async throws -> InvestigationHypothesis {
        let h = try await requireHypothesis(id)
        guard h.revision == expectedRevision else { throw InvestigationHypothesisError.revisionConflict(expected: expectedRevision, actual: h.revision) }
        return h
    }
    private func requireRequest(_ id: UUID) async throws -> EvidenceRequest {
        guard let r = (try await database.query("\(reqSelect) WHERE id = ? LIMIT 1;", [.uuid(id)])).first.flatMap(decodeRequest) else {
            throw InvestigationHypothesisError.requestNotFound(id)
        }
        return r
    }
    private func requireRequestCAS(_ id: UUID, expectedRevision: Int) async throws -> EvidenceRequest {
        let r = try await requireRequest(id)
        guard r.revision == expectedRevision else { throw InvestigationHypothesisError.revisionConflict(expected: expectedRevision, actual: r.revision) }
        return r
    }
    private func requireCell(caseID: UUID, dimension: WorksheetDimension) async throws -> WorksheetCell {
        guard let c = try await cell(caseID: caseID, dimension: dimension) else { throw InvestigationHypothesisError.cellAnswerRequiresEvidence(dimension) }
        return c
    }

    private func requireOpenCase(_ caseID: UUID) async throws {
        let rows = try await database.query("SELECT status FROM investigation_cases WHERE id = ? LIMIT 1;", [.uuid(caseID)])
        guard let status = rows.first?.string(0) else { throw InvestigationHypothesisError.caseNotFound(caseID) }
        if status == InvestigationCaseStatus.closed.rawValue { throw InvestigationHypothesisError.caseClosed(caseID) }
    }

    private nonisolated func decodeHypothesis(_ r: SQLRow) -> InvestigationHypothesis? {
        guard let id = r.uuid(0), let caseID = r.uuid(1), let kind = r.string(2).flatMap(HypothesisKind.init(rawValue:)),
              let statement = r.string(3), let status = r.string(4).flatMap(HypothesisStatus.init(rawValue:)),
              let rev = r.int(6), let actor = r.string(7), let created = r.date(8), let updated = r.date(9) else { return nil }
        return InvestigationHypothesis(id: id, caseID: caseID, kind: kind, statement: statement, status: status,
                                       originHypothesisID: r.uuid(5), revision: Int(rev), actor: actor, createdAt: created, updatedAt: updated)
    }
    private nonisolated func decodeRequest(_ r: SQLRow) -> EvidenceRequest? {
        guard let id = r.uuid(0), let caseID = r.uuid(1), let desc = r.string(3),
              let status = r.string(4).flatMap(EvidenceRequestStatus.init(rawValue:)),
              let rev = r.int(5), let actor = r.string(6), let created = r.date(7), let updated = r.date(8) else { return nil }
        return EvidenceRequest(id: id, caseID: caseID, hypothesisID: r.uuid(2), description: desc, status: status,
                               revision: Int(rev), actor: actor, createdAt: created, updatedAt: updated)
    }
    private nonisolated func decodeCell(_ r: SQLRow) -> WorksheetCell? {
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

    /// One SAVEPOINT around a mutation body.
    private func tx(_ prefix: String, _ id: UUID, _ extra: String = "", _ body: () async throws -> Void) async throws {
        let sp = "\(prefix)_\(id.uuidString.replacingOccurrences(of: "-", with: ""))\(extra.isEmpty ? "" : "_" + extra.replacingOccurrences(of: "-", with: ""))"
        do {
            try await database.exec("SAVEPOINT \(sp);")
            try await body()
            try await database.exec("RELEASE SAVEPOINT \(sp);")
        } catch {
            try? await database.exec("ROLLBACK TO SAVEPOINT \(sp);")
            try? await database.exec("RELEASE SAVEPOINT \(sp);")
            throw error
        }
    }
}
