//
//  SyncTables.swift
//  Kalsmritikosh
//
//  X-5 — which of the person's own tables sync, which columns, and which columns point at a
//  document (those are made portable: a document's local id differs on every device, so it
//  travels as the SHA-256 of its source file plus the SHA-256 of its text).
//
//  Evidence (documents, passages, facts, entities, vectors…) never syncs: each device derives
//  it from the bytes it has, with the same pipeline. Links to derived things (a tag on a fact
//  or an entity) stay on the device that made them — only links to documents travel.
//

import Foundation

nonisolated struct SyncTable: Sendable {
    let name: String
    /// Primary-key columns, in the order used to build the row key.
    let keyColumns: [String]
    /// Columns sent and received (key columns included).
    let columns: [String]
    /// Columns that hold a document id.
    let objectColumns: Set<String>
    /// Only rows matching this SQL condition sync (e.g. tag links on documents).
    let rowFilter: String?

    var nonKeyColumns: [String] { columns.filter { !keyColumns.contains($0) } }

    static let all: [SyncTable] = [
        SyncTable(name: "user_tags", keyColumns: ["id"],
                  columns: ["id", "name", "color", "created_at", "retired_at", "merged_into"], objectColumns: [], rowFilter: nil),
        SyncTable(name: "user_tag_links", keyColumns: ["tag_id", "subject_kind", "subject_id"],
                  columns: ["tag_id", "subject_kind", "subject_id", "created_at", "removed_at"],
                  objectColumns: ["subject_id"], rowFilter: "subject_kind = 'object'"),
        SyncTable(name: "user_groups", keyColumns: ["id"],
                  columns: ["id", "name", "parent_id", "sort_index", "created_at", "retired_at"], objectColumns: [], rowFilter: nil),
        SyncTable(name: "user_group_members", keyColumns: ["group_id", "object_id"],
                  columns: ["group_id", "object_id", "added_at", "removed_at"], objectColumns: ["object_id"], rowFilter: nil),
        SyncTable(name: "annotations", keyColumns: ["id"],
                  columns: ["id", "object_id", "quote", "note", "color", "stance", "created_at", "removed_at"],
                  objectColumns: ["object_id"], rowFilter: nil),
        SyncTable(name: "pdf_marks", keyColumns: ["id"],
                  columns: ["id", "object_id", "page", "kind", "rects_json", "color", "quote", "contents", "annotation_id",
                            "created_at", "removed_at"], objectColumns: ["object_id"], rowFilter: nil),
        SyncTable(name: "smart_collections", keyColumns: ["id"],
                  columns: ["id", "name", "query", "created_at", "retired_at"], objectColumns: [], rowFilter: nil),
        SyncTable(name: "automation_rules", keyColumns: ["id"],
                  columns: ["id", "name", "query", "action", "action_value", "enabled", "created_at", "retired_at"],
                  objectColumns: [], rowFilter: nil),
        SyncTable(name: "review_codes", keyColumns: ["id"],
                  columns: ["id", "object_id", "code", "reviewer", "coded_at", "removed_at"], objectColumns: ["object_id"], rowFilter: nil),
        SyncTable(name: "watchlists", keyColumns: ["id"],
                  columns: ["id", "name", "created_at", "retired_at"], objectColumns: [], rowFilter: nil),
        SyncTable(name: "watchlist_entries", keyColumns: ["id"],
                  columns: ["id", "watchlist_id", "term", "note", "created_at", "removed_at"], objectColumns: [], rowFilter: nil),
        SyncTable(name: "pinned_questions", keyColumns: ["id"],
                  columns: ["id", "question", "created_at", "retired_at"], objectColumns: [], rowFilter: nil),
        SyncTable(name: "case_issues", keyColumns: ["id"],
                  columns: ["id", "name", "description", "created_at", "retired_at"], objectColumns: [], rowFilter: nil),
        SyncTable(name: "case_issue_links", keyColumns: ["issue_id", "subject_kind", "subject_id"],
                  columns: ["issue_id", "subject_kind", "subject_id", "created_at", "removed_at"],
                  objectColumns: ["subject_id"], rowFilter: "subject_kind = 'object'"),
    ]

    static func named(_ name: String) -> SyncTable? { all.first { $0.name == name } }

    /// The key separator used by the change-capture triggers (v150) and in portable keys.
    static let keySeparator: Character = "|"
}

nonisolated extension SyncValue {
    init(_ v: SQLValue) {
        switch v {
        case .null: self = .null
        case .integer(let i): self = .int(i)
        case .real(let d): self = .real(d)
        case .text(let s): self = .text(s)
        case .blob(let d): self = .text(d.base64EncodedString())
        }
    }

    var sql: SQLValue {
        switch self {
        case .null: return .null
        case .int(let i): return .integer(i)
        case .real(let d): return .real(d)
        case .text(let s): return .text(s)
        }
    }

    /// A short readable form, for conflict lists.
    var display: String {
        switch self {
        case .null: return "(empty)"
        case .int(let i): return String(i)
        case .real(let d): return String(d)
        case .text(let s): return s
        }
    }
}
