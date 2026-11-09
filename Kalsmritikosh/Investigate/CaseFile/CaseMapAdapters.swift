//
//  CaseMapAdapters.swift
//  Kalsmritikosh
//
//  Smart-map S3 (docs/IME_Full_Smart_Map_Implementation_TODO_2026-11-08.md: GRAPH-06, GRAPH-07). Two read paths over the
//  existing case stores, both on demand — never part of a map load or a pan:
//
//  • coverage(caseID:) counts every registered case store (CaseDataInventory) for the case, so the map can reconcile its
//    counts with the whole case instead of presenting the projected items as everything.
//  • omittedRecords(...) reads, a page at a time, a store the map does not draw (contact log, credibility observations,
//    hold notices, redactions, review batches, conflict checks, the work log), under the branch it belongs to: a
//    person's contacts, an interview's credibility notes, a person's hold notices, or the case's for the case itself.
//    The rows are the canonical rows, read again each time; nothing is copied into the map.
//

import Foundation
import os

/// A store the map does not draw, reachable from the branch it belongs to.
public nonisolated enum CaseMapOmittedStore: String, Sendable, CaseIterable, Identifiable {
    case contacts, credibility, holdNotices, redactions, reviewBatches, conflictChecks, workLog
    public var id: String { rawValue }
    public var table: String {
        switch self {
        case .contacts: return "case_contacts"
        case .credibility: return "case_credibility"
        case .holdNotices: return "case_hold_notices"
        case .redactions: return "case_redaction_log"
        case .reviewBatches: return "case_review_batches"
        case .conflictChecks: return "case_conflict_checks"
        case .workLog: return "case_actions"
        }
    }
    public var title: String {
        switch self {
        case .contacts: return "Contact log"
        case .credibility: return "Credibility observations"
        case .holdNotices: return "Hold notices"
        case .redactions: return "Redactions"
        case .reviewBatches: return "Review batches"
        case .conflictChecks: return "Conflict checks"
        case .workLog: return "Work log (every recorded change)"
        }
    }
    /// The stores that belong under a record of this kind (the case itself holds the case-wide ones).
    public static func stores(for kind: CaseMapRecordKind) -> [CaseMapOmittedStore] {
        switch kind {
        case .person: return [.contacts, .holdNotices]
        case .interview: return [.credibility]
        case .caseFile: return [.holdNotices, .redactions, .reviewBatches, .conflictChecks, .workLog]
        default: return []
        }
    }
}

/// One row of an omitted store, as read now.
public nonisolated struct CaseMapOmittedRecord: Sendable, Equatable, Identifiable {
    public let id: String
    public let line: String
    public let by: String?
    public let at: Date?
}

public nonisolated struct CaseMapOmittedPage: Sendable, Equatable {
    public let store: CaseMapOmittedStore
    public let rows: [CaseMapOmittedRecord]
    /// All rows of this store under the branch (the page is `rows`; nothing beyond it is dropped — read the next page).
    public let total: Int
    public let offset: Int
    public var remaining: Int { max(0, total - offset - rows.count) }
}

extension CaseMapRepository {

    /// GRAPH-06 — the case's row count in every registered store. A store that cannot be counted is reported with the
    /// reason (never as zero). Tables absent from this ledger are skipped.
    public func coverage(caseID: UUID) async throws -> (counts: [String: Int?], problems: [String: String]) {
        try await CaseAccessPolicy.requireRead(database, caseID: caseID)
        let present = Set(try await tableNames())
        var counts: [String: Int?] = [:]
        var problems: [String: String] = [:]
        let c = SQLValue.uuid(caseID)
        for e in CaseDataInventory.entries where present.contains(e.table) {
            let sql: String?
            var binds: [SQLValue] = [c]
            switch e.lifecycle {
            case .caseID: sql = e.table == "investigation_cases" ? "SELECT COUNT(*) FROM investigation_cases WHERE id = ?;" : "SELECT COUNT(*) FROM \"\(e.table)\" WHERE case_id = ?;"
            case .undeclaredChild(let column, let parent):
                sql = present.contains(parent) ? "SELECT COUNT(*) FROM \"\(e.table)\" WHERE \(column) IN (SELECT id FROM \"\(parent)\" WHERE case_id = ?);" : nil
            case .taskEngine:
                sql = "SELECT COUNT(*) FROM professional_tasks WHERE id IN (SELECT task_id FROM case_task_links WHERE case_id = ?);"
            case .cascade(let parent) where parent == "professional_tasks":
                sql = "SELECT COUNT(*) FROM \"\(e.table)\" WHERE task_id IN (SELECT task_id FROM case_task_links WHERE case_id = ?);"
            case .cascade(let parent) where parent == "investigation_hypotheses":
                sql = "SELECT COUNT(*) FROM \"\(e.table)\" WHERE hypothesis_id IN (SELECT id FROM investigation_hypotheses WHERE case_id = ?);"
            case .cascade, .erasureRecord, .notCaseData:
                sql = nil; binds = []
            }
            guard let sql else { continue }
            do { counts[e.table] = Int(try await countRows(sql, binds) ?? 0) } catch {
                KalsmritikoshLog.app.error("Case map coverage: \(e.table, privacy: .public) not counted: \(error.localizedDescription, privacy: .public)")
                counts[e.table] = .some(nil)
                problems[e.table] = error.localizedDescription
            }
        }
        return (counts, problems)
    }

    /// GRAPH-07 — one page of an omitted store under a branch. `anchor` nil or the case: the case-wide rows.
    public func omittedRecords(caseID: UUID, store: CaseMapOmittedStore, anchor: CaseMapNodeID?, offset: Int = 0, limit: Int = 50) async throws -> CaseMapOmittedPage {
        try await CaseAccessPolicy.requireRead(database, caseID: caseID)
        let c = SQLValue.uuid(caseID)
        var filter: String
        var binds: [SQLValue]
        let rid: SQLValue? = anchor.flatMap { $0.kind == .caseFile ? nil : SQLValue.text($0.recordID) }
        let ridUpper: SQLValue? = anchor.flatMap { $0.kind == .caseFile ? nil : SQLValue.text($0.recordID.uppercased()) }
        let select: String
        switch store {
        case .contacts:
            select = "SELECT id, mode || coalesce(' — ' || note, ''), by, at FROM case_contacts"
            filter = "person_id IN (SELECT id FROM case_people WHERE case_id = ?)"; binds = [c]
            if let rid, let ridUpper { filter += " AND person_id IN (?, ?)"; binds += [rid, ridUpper] }
        case .credibility:
            select = "SELECT id, factor || ': ' || assessment || coalesce(' — ' || note, ''), by, created_at FROM case_credibility"
            filter = "interview_id IN (SELECT id FROM case_interviews WHERE case_id = ?)"; binds = [c]
            if let rid, let ridUpper { filter += " AND interview_id IN (?, ?)"; binds += [rid, ridUpper] }
        case .holdNotices:
            select = "SELECT id, 'Custodian ' || custodian || CASE WHEN released_at IS NULL THEN ' — in force' ELSE ' — released' END, issued_by, issued_at FROM case_hold_notices"
            filter = "case_id = ?"; binds = [c]
            if let rid, let ridUpper { filter += " AND person_id IN (?, ?)"; binds += [rid, ridUpper] }
        case .redactions:
            select = "SELECT id, location || ' — ' || reason, redacted_by, at FROM case_redaction_log"; filter = "case_id = ?"; binds = [c]
        case .reviewBatches:
            select = "SELECT id, name || ' — ' || status, reviewer, updated_at FROM case_review_batches"; filter = "case_id = ?"; binds = [c]
        case .conflictChecks:
            select = "SELECT id, investigator || ': ' || result, checked_by, checked_at FROM case_conflict_checks"; filter = "case_id = ?"; binds = [c]
        case .workLog:
            select = "SELECT id, action || coalesce(' — ' || detail, ''), actor, at FROM case_actions"; filter = "case_id = ?"; binds = [c]
        }
        let total = Int(try await countRows("SELECT COUNT(*) FROM \(store.table) WHERE \(filter);", binds) ?? 0)
        let order = store == .workLog ? "sequence DESC" : "rowid ASC"
        let rows = try await readRows("\(select) WHERE \(filter) ORDER BY \(order) LIMIT ? OFFSET ?;",
                                          binds + [.integer(Int64(max(1, limit))), .integer(Int64(max(0, offset)))]).compactMap { r -> CaseMapOmittedRecord? in
            guard let id = r.string(0) else { return nil }
            return CaseMapOmittedRecord(id: id, line: r.string(1) ?? "", by: r.string(2), at: r.date(3))
        }
        return CaseMapOmittedPage(store: store, rows: rows, total: total, offset: offset)
    }
}
