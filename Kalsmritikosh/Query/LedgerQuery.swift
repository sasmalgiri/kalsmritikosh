//
//  LedgerQuery.swift
//  Kalsmritikosh
//
//  A friendly, SAFE query surface over the ledger. Users build a question by
//  picking a subject and adding filters (no SQL to write); the compiler turns
//  that into a strictly READ-ONLY, parameterized SELECT over a whitelisted set
//  of tables/columns. There is no raw-SQL path: field names and operators come
//  only from the fixed catalog below, and every user value is a bound parameter
//  — so nothing the user types can change the shape of the query or write data.
//  Privileged documents are excluded at the source.
//
//  This mirrors the industry pattern (Metabase/Airtable): a no-code builder for
//  everyone, plus a transparent "here's the SQL it generated" view for the
//  curious — never an arbitrary SQL box.
//

import Foundation

// MARK: - Model

public enum QueryValueKind: String, Sendable { case text, number, date, choice, fileName }

public enum QueryOperator: String, Sendable, CaseIterable, Equatable {
    case contains, isEqual, isNot, startsWith        // text / choice
    case equals, greaterThan, lessThan, between       // number
    case onDate, before, after                        // date

    public var label: String {
        switch self {
        case .contains: return "contains"
        case .isEqual: return "is"
        case .isNot: return "is not"
        case .startsWith: return "starts with"
        case .equals: return "="
        case .greaterThan: return "greater than"
        case .lessThan: return "less than"
        case .between: return "between"
        case .onDate: return "on"
        case .before: return "before"
        case .after: return "after"
        }
    }

    public static func operators(for kind: QueryValueKind) -> [QueryOperator] {
        switch kind {
        case .text, .fileName: return [.contains, .isEqual, .isNot, .startsWith]
        case .choice:          return [.isEqual, .isNot]
        case .number:          return [.equals, .greaterThan, .lessThan, .between]
        case .date:            return [.onDate, .before, .after, .between]
        }
    }

    public var needsSecondValue: Bool { self == .between }
}

public struct QueryFilter: Identifiable, Sendable, Equatable {
    public var id = UUID()
    public var fieldKey: String
    public var op: QueryOperator
    public var value: String = ""
    public var value2: String = ""     // for `between`
    public init(fieldKey: String, op: QueryOperator, value: String = "", value2: String = "") {
        self.fieldKey = fieldKey; self.op = op; self.value = value; self.value2 = value2
    }
}

public struct LedgerQuery: Sendable, Equatable {
    public var subjectID: String
    public var filters: [QueryFilter]
    public var columns: [String]        // field keys; empty → subject defaults
    public var sortFieldKey: String?
    public var sortDescending: Bool
    public var limit: Int
    public init(subjectID: String, filters: [QueryFilter] = [], columns: [String] = [],
                sortFieldKey: String? = nil, sortDescending: Bool = false, limit: Int = 100) {
        self.subjectID = subjectID; self.filters = filters; self.columns = columns
        self.sortFieldKey = sortFieldKey; self.sortDescending = sortDescending; self.limit = limit
    }
}

// MARK: - Catalog (the only place table/column names live)

public struct QueryField: Sendable, Identifiable {
    public var id: String { key }
    public let key: String
    public let label: String
    public let sqlExpr: String          // whitelisted expression — NEVER from user input
    public let kind: QueryValueKind
    public let options: [String]
    public let filterable: Bool
    public let selectable: Bool
    public init(_ key: String, _ label: String, _ sqlExpr: String, _ kind: QueryValueKind,
                options: [String] = [], filterable: Bool = true, selectable: Bool = true) {
        self.key = key; self.label = label; self.sqlExpr = sqlExpr; self.kind = kind
        self.options = options; self.filterable = filterable; self.selectable = selectable
    }
}

public struct QuerySubject: Sendable, Identifiable {
    public let id: String
    public let label: String
    public let systemImage: String
    public let fromClause: String
    public let baseWhere: String?
    public let fields: [QueryField]
    public let defaultColumns: [String]
    public let defaultSortKey: String?
    public let defaultSortDescending: Bool

    public func field(_ key: String) -> QueryField? { fields.first { $0.key == key } }
}

public enum LedgerQueryCatalog {
    public static let subjects: [QuerySubject] = [
        QuerySubject(
            id: "documents", label: "Documents", systemImage: "doc.text",
            fromClause: "knowledge_objects k JOIN files f ON f.id = k.file_id",
            baseWhere: "(k.privileged = 0 OR k.privileged IS NULL)",
            fields: [
                QueryField("file", "File", "f.url", .fileName),
                QueryField("type", "Type", "k.source_type", .text),
                QueryField("added", "Added", "k.created_at", .date),
                QueryField("confidence", "Confidence", "k.confidence", .number)
            ],
            defaultColumns: ["file", "type", "added", "confidence"],
            defaultSortKey: "added", defaultSortDescending: true),

        QuerySubject(
            id: "people", label: "People & organizations", systemImage: "person.2",
            fromClause: "entities",
            baseWhere: "kind IN ('person','organization','vendor','client') AND review_status IS NULL AND merged_into IS NULL",
            fields: [
                QueryField("name", "Name", "value", .text),
                QueryField("kind", "Kind", "kind", .choice, options: ["person", "organization", "vendor", "client"]),
                QueryField("confidence", "Confidence", "confidence", .number)
            ],
            defaultColumns: ["name", "kind", "confidence"],
            defaultSortKey: "name", defaultSortDescending: false),

        QuerySubject(
            id: "events", label: "Events", systemImage: "calendar",
            fromClause: "events",
            baseWhere: "review_status IS NULL",
            fields: [
                QueryField("date", "Date", "date", .date),
                QueryField("title", "Title", "title", .text),
                QueryField("kind", "Kind", "kind", .choice,
                           options: ["emailSent", "emailReceived", "contractSigned", "contractModified",
                                     "invoiceIssued", "invoicePaid", "meetingHeld", "taskAssigned",
                                     "deliveryDelayed", "deliveryCompleted", "other"]),
                QueryField("status", "Status", "status", .choice,
                           options: ["observed", "asserted", "derived", "inferred", "contradicted", "unsupported", "reviewed", "rejected"])
            ],
            defaultColumns: ["date", "title", "kind", "status"],
            defaultSortKey: "date", defaultSortDescending: true),

        QuerySubject(
            id: "relationships", label: "Relationships", systemImage: "point.topleft.down.to.point.bottomright.curvepath",
            fromClause: "relationships r JOIN entities a ON a.id = r.from_entity_id JOIN entities b ON b.id = r.to_entity_id",
            baseWhere: "a.review_status IS NULL AND a.merged_into IS NULL AND b.review_status IS NULL AND b.merged_into IS NULL",
            fields: [
                QueryField("from", "From", "a.value", .text),
                QueryField("kind", "Kind", "r.kind", .text),
                QueryField("to", "To", "b.value", .text),
                QueryField("weight", "Times seen", "r.weight", .number)
            ],
            defaultColumns: ["from", "kind", "to", "weight"],
            defaultSortKey: "weight", defaultSortDescending: true),

        QuerySubject(
            id: "conflicts", label: "Conflicts", systemImage: "exclamationmark.2",
            fromClause: "contradictions",
            baseWhere: nil,
            fields: [
                QueryField("description", "Conflict", "description", .text),
                QueryField("severity", "Severity", "severity", .choice, options: ["low", "medium", "high"]),
                QueryField("status", "Status", "status", .choice, options: ["open", "resolved", "dismissed"]),
                QueryField("kind", "Kind", "kind", .text),
                QueryField("detected", "Detected", "detected_at", .date, filterable: false, selectable: false)
            ],
            defaultColumns: ["description", "severity", "status"],
            defaultSortKey: "detected", defaultSortDescending: true),

        QuerySubject(
            id: "gaps", label: "Missing evidence", systemImage: "questionmark.folder",
            fromClause: "gap_nodes",
            baseWhere: "dismissed = 0",
            fields: [
                QueryField("description", "Gap", "description", .text),
                QueryField("reason", "Why it matters", "reason", .text),
                QueryField("kind", "Kind", "kind", .text)
            ],
            defaultColumns: ["description", "reason", "kind"],
            defaultSortKey: nil, defaultSortDescending: false)
    ]

    public static func subject(_ id: String) -> QuerySubject? { subjects.first { $0.id == id } }
}
