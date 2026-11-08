//
//  InvestigationDeskReviewRepository.swift
//  Kalsmritikosh
//
//  INV-08 / INV-12 — the durable store for case-scoped desk review decisions (schema v100
//  investigation_desk_reviews). One disposition per (case, item_kind, item_id): recording a decision
//  replaces the case's prior disposition for that item. It only records a soft reference to a shared item;
//  it never mutates the shared source-reliability / contradiction / gap authorities.
//

import Foundation

public actor InvestigationDeskReviewRepository {
    private let database: Database

    public init(database: Database) { self.database = database }

    /// Record (or replace) the case's disposition of one shared item. One SAVEPOINT; unique per
    /// (case, kind, item).
    @discardableResult
    public func record(caseID: UUID, itemKind: DeskItemKind, itemID: String, decision: DeskDecision,
                       note: String?, actor: String, at date: Date) async throws -> InvestigationDeskReview {
        let cleanActor = actor.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanActor.isEmpty else { throw InvestigationDeskError.blankActor }
        let cleanItem = itemID.trimmingCharacters(in: .whitespacesAndNewlines)
        let sp = "invdesk_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let noteValue: SQLValue = note.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : .text($0) } ?? .null
        // F28 — read the prior created_at, replace and insert in ONE isolated savepoint.
        try await database.withSavepoint(sp) { db in
            // Preserve the original created_at if a prior disposition exists.
            var created = date
            if let existing = try db.query(
                "SELECT created_at FROM investigation_desk_reviews WHERE case_id = ? AND item_kind = ? AND item_id = ? LIMIT 1;",
                [.uuid(caseID), .text(itemKind.rawValue), .text(cleanItem)]).first, let c = existing.date(0) {
                created = c
            }
            try db.exec("DELETE FROM investigation_desk_reviews WHERE case_id = ? AND item_kind = ? AND item_id = ?;",
                        [.uuid(caseID), .text(itemKind.rawValue), .text(cleanItem)])
            try db.exec("""
                INSERT INTO investigation_desk_reviews (id, case_id, item_kind, item_id, decision, note, actor, created_at, updated_at)
                VALUES (?,?,?,?,?,?,?,?,?);
                """, [.uuid(UUID()), .uuid(caseID), .text(itemKind.rawValue), .text(cleanItem), .text(decision.rawValue),
                      noteValue, .text(cleanActor), .date(created), .date(date)])
        }
        return try await requireReview(caseID: caseID, itemKind: itemKind, itemID: cleanItem)
    }

    public func review(caseID: UUID, itemKind: DeskItemKind, itemID: String) async throws -> InvestigationDeskReview? {
        (try await database.query("\(selectAll) WHERE case_id = ? AND item_kind = ? AND item_id = ? LIMIT 1;",
                                  [.uuid(caseID), .text(itemKind.rawValue), .text(itemID.trimmingCharacters(in: .whitespacesAndNewlines))])).first.flatMap(decode)
    }

    public func reviews(caseID: UUID) async throws -> [InvestigationDeskReview] {
        (try await database.query("\(selectAll) WHERE case_id = ? ORDER BY item_kind ASC, created_at ASC;", [.uuid(caseID)])).compactMap(decode)
    }

    /// The case's dispositions for a kind, indexed by item id — powers the desk projections.
    public func reviewsByItem(caseID: UUID, itemKind: DeskItemKind) async throws -> [String: InvestigationDeskReview] {
        let rows = try await database.query("\(selectAll) WHERE case_id = ? AND item_kind = ?;", [.uuid(caseID), .text(itemKind.rawValue)])
        var out: [String: InvestigationDeskReview] = [:]
        for r in rows { if let rev = decode(r) { out[rev.itemID] = rev } }
        return out
    }

    // MARK: - v170: decisions with reasons, source versions and history

    /// Record one decision (confirm / dismiss / defer) in the append-only history, with the version of each
    /// side's document, and keep the current desk disposition in step — in ONE savepoint. A deferral leaves
    /// the item undecided at the desk (the earlier disposition is replaced, and stays in the history).
    @discardableResult
    public func recordDecision(caseID: UUID, itemKind: DeskItemKind, itemID: String, decision: CaseReviewDecision,
                               reason: CaseReviewReason?, note: String?, sourceVersions: [UUID: UUID],
                               passages: [UUID: String] = [:],
                               actor: String, at date: Date) async throws -> CaseReviewDecisionRecord {
        let cleanActor = actor.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanActor.isEmpty else { throw InvestigationDeskError.blankActor }
        let cleanItem = itemID.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanNote = note.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if decision == .dismissed, reason == nil { throw InvestigationDeskError.reasonRequired }
        if reason == .other, cleanNote == nil { throw InvestigationDeskError.noteRequired }
        // S5 (REASON-06) — an explanation or an unresolved finding is recorded with its rationale.
        if decision.needsNote, cleanNote == nil { throw InvestigationDeskError.noteRequired }
        let passagesJSON = CaseReviewDecisionRecord.encodePassages(passages)
        let id = UUID()
        let sp = "invdec_\(id.uuidString.replacingOccurrences(of: "-", with: ""))"
        try await database.withSavepoint(sp) { db in
            try db.exec("""
                INSERT INTO investigation_review_decisions (id, case_id, item_kind, item_id, decision, reason, note, source_versions_json, actor, decided_at, passages_json)
                VALUES (?,?,?,?,?,?,?,?,?,?,?);
                """, [.uuid(id), .uuid(caseID), .text(itemKind.rawValue), .text(cleanItem), .text(decision.rawValue),
                      reason.map { .text($0.rawValue) } ?? .null, cleanNote.map { .text($0) } ?? .null,
                      .text(CaseReviewDecisionRecord.encodeVersions(sourceVersions)), .text(cleanActor), .date(date), .optionalText(passagesJSON)])
            var created = date
            if let existing = try db.query(
                "SELECT created_at FROM investigation_desk_reviews WHERE case_id = ? AND item_kind = ? AND item_id = ? LIMIT 1;",
                [.uuid(caseID), .text(itemKind.rawValue), .text(cleanItem)]).first, let c = existing.date(0) {
                created = c
            }
            // Replace-kind write: the current disposition only; every decision stays in the history above.
            try db.exec("DELETE FROM investigation_desk_reviews WHERE case_id = ? AND item_kind = ? AND item_id = ?;",
                        [.uuid(caseID), .text(itemKind.rawValue), .text(cleanItem)])
            if let desk = decision.deskDecision {
                let deskNote = [reason?.label, cleanNote].compactMap { $0 }.joined(separator: ": ")
                try db.exec("""
                    INSERT INTO investigation_desk_reviews (id, case_id, item_kind, item_id, decision, note, actor, created_at, updated_at)
                    VALUES (?,?,?,?,?,?,?,?,?);
                    """, [.uuid(UUID()), .uuid(caseID), .text(itemKind.rawValue), .text(cleanItem), .text(desk.rawValue),
                          deskNote.isEmpty ? .null : .text(deskNote), .text(cleanActor), .date(created), .date(date)])
            }
        }
        return CaseReviewDecisionRecord(id: id, caseID: caseID, itemKind: itemKind, itemID: cleanItem, decision: decision, reason: reason,
                                        note: cleanNote, sourceVersions: sourceVersions, actor: cleanActor, decidedAt: date, passages: passages)
    }

    /// Every recorded decision of a kind in the case, per item, oldest first.
    public func decisionHistory(caseID: UUID, itemKind: DeskItemKind) async throws -> [String: [CaseReviewDecisionRecord]] {
        let rows = try await database.query("""
            SELECT id, case_id, item_kind, item_id, decision, reason, note, source_versions_json, actor, decided_at, passages_json
            FROM investigation_review_decisions WHERE case_id = ? AND item_kind = ? ORDER BY decided_at ASC, rowid ASC;
            """, [.uuid(caseID), .text(itemKind.rawValue)])
        var out: [String: [CaseReviewDecisionRecord]] = [:]
        for r in rows {
            guard let id = r.uuid(0), let c = r.uuid(1), let kind = r.string(2).flatMap(DeskItemKind.init(rawValue:)),
                  let item = r.string(3), let decision = r.string(4).flatMap(CaseReviewDecision.init(rawValue:)),
                  let actor = r.string(8), let at = r.date(9) else { continue }
            out[item, default: []].append(CaseReviewDecisionRecord(
                id: id, caseID: c, itemKind: kind, itemID: item, decision: decision,
                reason: r.string(5).flatMap(CaseReviewReason.init(rawValue:)), note: r.string(6),
                sourceVersions: CaseReviewDecisionRecord.decodeVersions(r.string(7)), actor: actor, decidedAt: at,
                passages: CaseReviewDecisionRecord.decodePassages(r.string(10))))
        }
        return out
    }

    // MARK: - Internals

    private let selectAll = "SELECT id, case_id, item_kind, item_id, decision, note, actor, created_at, updated_at FROM investigation_desk_reviews"

    private func requireReview(caseID: UUID, itemKind: DeskItemKind, itemID: String) async throws -> InvestigationDeskReview {
        guard let r = try await review(caseID: caseID, itemKind: itemKind, itemID: itemID) else {
            throw InvestigationDeskError.blankActor   // unreachable after a successful insert
        }
        return r
    }

    private nonisolated func decode(_ r: SQLRow) -> InvestigationDeskReview? {
        guard let id = r.uuid(0), let caseID = r.uuid(1), let kind = r.string(2).flatMap(DeskItemKind.init(rawValue:)),
              let itemID = r.string(3), let decision = r.string(4).flatMap(DeskDecision.init(rawValue:)),
              let actor = r.string(6), let created = r.date(7), let updated = r.date(8) else { return nil }
        return InvestigationDeskReview(id: id, caseID: caseID, itemKind: kind, itemID: itemID, decision: decision,
                                       note: r.string(5), actor: actor, createdAt: created, updatedAt: updated)
    }
}
