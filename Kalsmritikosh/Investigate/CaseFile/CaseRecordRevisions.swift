//
//  CaseRecordRevisions.swift
//  Kalsmritikosh
//
//  Living case map, M7 (plan §6.4): typed before/after records at the canonical mutation boundary. Several case
//  updates used to overwrite the record in place (the case profile — saveProfile logged "profileSaved" with no
//  old or new value — an allegation's disposition and response, a report item's selection, a person, an
//  interview, retractions). Each of those now copies the record's row as it was and as it became into
//  case_records_revisions (schema v173) INSIDE the same savepoint as the change and its case_actions row, so the
//  previous value is kept and both commit or neither does. Nothing is reconstructed later from a log.
//
//  The copy is the row's stored columns as JSON (SQLite json_object over the table's own columns), so a column
//  added by a later migration is kept too. It lives only in the encrypted ledger and goes with case erasure.
//

import Foundation
import os

/// Which record a mutation changes, and how to read its row inside the write.
public nonisolated struct CaseRecordCapture: Sendable, Equatable {
    /// The canonical record kind ("profile", "allegation", "reportItem", "person", "interview", …).
    public let kind: String
    public let table: String
    public let keyColumn: String
    public let recordID: String

    public init(kind: String, table: String, keyColumn: String = "id", recordID: UUID) {
        self.kind = kind; self.table = table; self.keyColumn = keyColumn; self.recordID = recordID.uuidString
    }

    public static func profile(_ caseID: UUID) -> CaseRecordCapture { CaseRecordCapture(kind: "profile", table: "case_profiles", keyColumn: "case_id", recordID: caseID) }
    public static func allegation(_ id: UUID) -> CaseRecordCapture { CaseRecordCapture(kind: "allegation", table: "case_allegations", recordID: id) }
    public static func reportItem(_ id: UUID) -> CaseRecordCapture { CaseRecordCapture(kind: "reportItem", table: "case_report_items", recordID: id) }
    public static func person(_ id: UUID) -> CaseRecordCapture { CaseRecordCapture(kind: "person", table: "case_people", recordID: id) }
    public static func interview(_ id: UUID) -> CaseRecordCapture { CaseRecordCapture(kind: "interview", table: "case_interviews", recordID: id) }
    public static func gridLink(_ id: UUID) -> CaseRecordCapture { CaseRecordCapture(kind: "allegationEvidence", table: "case_allegation_evidence", recordID: id) }
    public static func journal(_ id: UUID) -> CaseRecordCapture { CaseRecordCapture(kind: "journal", table: "case_journal", recordID: id) }
    public static func exhibit(_ id: UUID) -> CaseRecordCapture { CaseRecordCapture(kind: "exhibit", table: "case_exhibits", recordID: id) }
    public static func holdNotice(_ id: UUID) -> CaseRecordCapture { CaseRecordCapture(kind: "holdNotice", table: "case_hold_notices", recordID: id) }
    public static func reviewBatch(_ id: UUID) -> CaseRecordCapture { CaseRecordCapture(kind: "reviewBatch", table: "case_review_batches", recordID: id) }
}

/// One kept before/after copy.
public nonisolated struct CaseRecordRevision: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let caseID: UUID
    /// The case_actions row written in the same savepoint.
    public let actionID: UUID?
    public let recordKind: String
    public let recordID: String
    /// The case action ("profileSaved", "allegationDecided", …).
    public let change: String
    /// The stored row before and after, as JSON (nil before: it did not exist; nil after: removed).
    public let before: String?
    public let after: String?
    public let actor: String
    public let recordedAt: Date

    /// The columns whose stored value differs, by name (sorted).
    public var changedFields: [String] {
        let a = Self.decode(before), b = Self.decode(after)
        return Set(a.keys).union(b.keys).filter { a[$0] != b[$0] }.sorted()
    }
    /// One column's value before and after (as stored text).
    public func value(_ field: String) -> (before: String?, after: String?) { (Self.decode(before)[field], Self.decode(after)[field]) }

    static func decode(_ json: String?) -> [String: String] {
        guard let json, let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var out: [String: String] = [:]
        for (k, v) in obj where !(v is NSNull) { out[k] = "\(v)" }
        return out
    }
}

public nonisolated enum CaseRecordRevisions {

    /// The row as JSON, read inside the caller's savepoint (nil when there is no such row).
    static func rowJSON(_ db: isolated Database, _ c: CaseRecordCapture) throws -> String? {
        let columns = try db.query("PRAGMA table_info(\"\(c.table)\");", []).compactMap { $0.string(1) }
        guard !columns.isEmpty, columns.contains(c.keyColumn) else { return nil }
        let pairs = columns.map { "'\($0)', \"\($0)\"" }.joined(separator: ", ")
        return try db.query("SELECT json_object(\(pairs)) FROM \"\(c.table)\" WHERE \"\(c.keyColumn)\" IN (?, ?, ?) LIMIT 1;",
                            [.text(c.recordID), .text(c.recordID.uppercased()), .text(c.recordID.lowercased())]).first?.string(0)
    }

    /// Keep the before/after copy (inside the same savepoint as the change). Nothing is kept when nothing changed.
    static func record(_ db: isolated Database, caseID: UUID, actionID: UUID, capture c: CaseRecordCapture, change: String,
                       before: String?, after: String?, actor: String, at date: Date) throws {
        guard before != after, before != nil || after != nil else { return }
        try db.exec("""
            INSERT INTO case_record_revisions (id, case_id, action_id, record_kind, record_id, change, before_json, after_json, actor, recorded_at)
            VALUES (?,?,?,?,?,?,?,?,?,?);
            """, [.uuid(UUID()), .uuid(caseID), .uuid(actionID), .text(c.kind), .text(c.recordID.lowercased()), .text(change),
                  .optionalText(before), .optionalText(after), .text(actor), .date(date)])
    }

    /// Every kept copy for a case (optionally one record), oldest first.
    public static func revisions(_ database: Database, caseID: UUID, kind: String? = nil, recordID: UUID? = nil) async throws -> [CaseRecordRevision] {
        var sql = "SELECT id, case_id, action_id, record_kind, record_id, change, before_json, after_json, actor, recorded_at FROM case_record_revisions WHERE case_id = ?"
        var binds: [SQLValue] = [.uuid(caseID)]
        if let kind { sql += " AND record_kind = ?"; binds.append(.text(kind)) }
        if let recordID { sql += " AND record_id = ?"; binds.append(.text(recordID.uuidString.lowercased())) }
        sql += " ORDER BY recorded_at ASC, rowid ASC;"
        return try await database.query(sql, binds).compactMap { r in
            guard let id = r.uuid(0), let c = r.uuid(1), let k = r.string(3), let rid = r.string(4), let ch = r.string(5),
                  let by = r.string(8), let at = r.date(9) else { return nil }
            return CaseRecordRevision(id: id, caseID: c, actionID: r.uuid(2), recordKind: k, recordID: rid, change: ch,
                                      before: r.string(6), after: r.string(7), actor: by, recordedAt: at)
        }
    }
}
