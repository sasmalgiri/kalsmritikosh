//
//  InvestigationIdentityDecisionRepository.swift
//  Kalsmritikosh
//
//  INV-03 — the durable, APPEND-ONLY identity-resolution decision log (schema v98
//  `investigation_identity_decisions`). Every proposed / confirmed / rejected / reversed merge is a new
//  row (never an update or delete), so a merge decision is always RECORDED and a reversal never erases the
//  confirmation it undoes. The repository only records decisions; the SHARED canonical merge/unmerge is
//  performed by the service that owns the human gate. Winner/loser are soft references into `entities`.
//

import Foundation

public actor InvestigationIdentityDecisionRepository {
    private let database: Database

    public init(database: Database) { self.database = database }

    /// Append one decision to the case's log with the next sequence number. One SAVEPOINT so the sequence
    /// allocation + insert are atomic. Fails if the case does not exist (FK) or the actor is blank.
    @discardableResult
    public func record(caseID: UUID, kind: IdentityDecisionKind, winnerEntityID: UUID, loserEntityID: UUID,
                       rationale: String?, actor: String, priorDecisionID: UUID?, at date: Date) async throws -> IdentityResolutionDecision {
        let cleanActor = actor.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanActor.isEmpty else { throw IdentityResolutionError.blankActor }
        let id = UUID()
        let sp = savepoint("invdec", id)
        var sequence = 0
        do {
            try await database.exec("SAVEPOINT \(sp);")
            sequence = Int(try await database.query(
                "SELECT COALESCE(MAX(sequence), 0) FROM investigation_identity_decisions WHERE case_id = ?;",
                [.uuid(caseID)]).first?.int(0) ?? 0) + 1
            try await database.exec("""
                INSERT INTO investigation_identity_decisions (id, case_id, sequence, decision_kind, winner_entity_id,
                    loser_entity_id, rationale, actor, prior_decision_id, occurred_at)
                VALUES (?,?,?,?,?,?,?,?,?,?);
                """, [.uuid(id), .uuid(caseID), .integer(Int64(sequence)), .text(kind.rawValue),
                      .uuid(winnerEntityID), .uuid(loserEntityID), opt(rationale), .text(cleanActor),
                      priorDecisionID.map { SQLValue.uuid($0) } ?? .null, .date(date)])
            try await database.exec("RELEASE SAVEPOINT \(sp);")
        } catch {
            try? await database.exec("ROLLBACK TO SAVEPOINT \(sp);")
            try? await database.exec("RELEASE SAVEPOINT \(sp);")
            throw error
        }
        return IdentityResolutionDecision(id: id, caseID: caseID, sequence: sequence, kind: kind,
                                          winnerEntityID: winnerEntityID, loserEntityID: loserEntityID,
                                          rationale: rationale?.trimmingCharacters(in: .whitespacesAndNewlines),
                                          actor: cleanActor, priorDecisionID: priorDecisionID, occurredAt: date)
    }

    public func fetch(decisionID: UUID) async throws -> IdentityResolutionDecision? {
        let rows = try await database.query("\(decisionSelect) WHERE id = ? LIMIT 1;", [.uuid(decisionID)])
        return rows.first.flatMap(decode)
    }

    /// The whole case log, in decision order.
    public func decisions(caseID: UUID) async throws -> [IdentityResolutionDecision] {
        let rows = try await database.query("\(decisionSelect) WHERE case_id = ? ORDER BY sequence ASC;", [.uuid(caseID)])
        return rows.compactMap(decode)
    }

    /// The decisions for one directed (winner, loser) pair, in order — the service reads the LAST one to
    /// decide whether a confirm / reject / reverse is currently legal for that pair.
    public func decisions(caseID: UUID, winnerEntityID: UUID, loserEntityID: UUID) async throws -> [IdentityResolutionDecision] {
        let rows = try await database.query("""
            \(decisionSelect) WHERE case_id = ? AND winner_entity_id = ? AND loser_entity_id = ? ORDER BY sequence ASC;
            """, [.uuid(caseID), .uuid(winnerEntityID), .uuid(loserEntityID)])
        return rows.compactMap(decode)
    }

    // MARK: - Internals

    private let decisionSelect = """
        SELECT id, case_id, sequence, decision_kind, winner_entity_id, loser_entity_id, rationale, actor,
               prior_decision_id, occurred_at
        FROM investigation_identity_decisions
        """

    private nonisolated func decode(_ r: SQLRow) -> IdentityResolutionDecision? {
        guard let id = r.uuid(0), let caseID = r.uuid(1), let seq = r.int(2),
              let kind = r.string(3).flatMap(IdentityDecisionKind.init(rawValue:)),
              let winner = r.uuid(4), let loser = r.uuid(5), let actor = r.string(7),
              let occurredAt = r.date(9) else { return nil }
        return IdentityResolutionDecision(id: id, caseID: caseID, sequence: Int(seq), kind: kind,
                                          winnerEntityID: winner, loserEntityID: loser, rationale: r.string(6),
                                          actor: actor, priorDecisionID: r.uuid(8), occurredAt: occurredAt)
    }

    private nonisolated func opt(_ s: String?) -> SQLValue {
        guard let s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .null }
        return .text(s)
    }

    private nonisolated func savepoint(_ prefix: String, _ id: UUID) -> String {
        "\(prefix)_\(id.uuidString.replacingOccurrences(of: "-", with: ""))"
    }
}
