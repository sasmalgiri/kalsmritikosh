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
        var created = date
        do {
            try await database.exec("SAVEPOINT \(sp);")
            // Preserve the original created_at if a prior disposition exists.
            if let existing = try await database.query(
                "SELECT created_at FROM investigation_desk_reviews WHERE case_id = ? AND item_kind = ? AND item_id = ? LIMIT 1;",
                [.uuid(caseID), .text(itemKind.rawValue), .text(cleanItem)]).first, let c = existing.date(0) {
                created = c
            }
            try await database.exec("DELETE FROM investigation_desk_reviews WHERE case_id = ? AND item_kind = ? AND item_id = ?;",
                                    [.uuid(caseID), .text(itemKind.rawValue), .text(cleanItem)])
            try await database.exec("""
                INSERT INTO investigation_desk_reviews (id, case_id, item_kind, item_id, decision, note, actor, created_at, updated_at)
                VALUES (?,?,?,?,?,?,?,?,?);
                """, [.uuid(UUID()), .uuid(caseID), .text(itemKind.rawValue), .text(cleanItem), .text(decision.rawValue),
                      note.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : .text($0) } ?? .null,
                      .text(cleanActor), .date(created), .date(date)])
            try await database.exec("RELEASE SAVEPOINT \(sp);")
        } catch {
            try? await database.exec("ROLLBACK TO SAVEPOINT \(sp);")
            try? await database.exec("RELEASE SAVEPOINT \(sp);")
            throw error
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
