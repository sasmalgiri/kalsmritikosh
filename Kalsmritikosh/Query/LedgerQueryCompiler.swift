//
//  LedgerQueryCompiler.swift
//  Kalsmritikosh
//
//  Turns a LedgerQuery (subject + filters) into a strictly READ-ONLY,
//  parameterized SELECT. Safety comes from construction, not from scrubbing:
//    • table/column expressions come ONLY from the catalog (never user input),
//    • every user value is a bound parameter (never string-interpolated),
//    • the statement is always a single SELECT with a bounded LIMIT.
//  A second, values-inlined string is produced purely for the "View the SQL"
//  panel — it is displayed, never executed.
//

import Foundation

public struct CompiledColumn: Sendable {
    public let label: String
    public let kind: QueryValueKind
}

public struct CompiledQuery: Sendable {
    public let sql: String            // parameterized — executed
    public let bindings: [SQLValue]
    public let columns: [CompiledColumn]
    public let displaySQL: String     // values inlined — shown to the user
}

public enum LedgerQueryCompiler {

    public static func compile(_ q: LedgerQuery,
                               subjects: [QuerySubject] = LedgerQueryCatalog.subjects) -> CompiledQuery? {
        guard let subject = subjects.first(where: { $0.id == q.subjectID }) else { return nil }

        // Columns — from the requested keys (or defaults), selectable only.
        let wantKeys = q.columns.isEmpty ? subject.defaultColumns : q.columns
        var colFields = wantKeys.compactMap { key in subject.fields.first { $0.key == key && $0.selectable } }
        if colFields.isEmpty {
            colFields = subject.defaultColumns.compactMap { key in subject.fields.first { $0.key == key } }
        }
        let selectList = colFields.map { $0.sqlExpr }.joined(separator: ", ")
        let columns = colFields.map { CompiledColumn(label: $0.label, kind: $0.kind) }

        // WHERE — base safety clause + user filters (bound).
        var whereParts: [String] = []
        var whereDisplay: [String] = []
        var bindings: [SQLValue] = []
        if let base = subject.baseWhere { whereParts.append("(\(base))"); whereDisplay.append("(\(base))") }
        for filter in q.filters {
            guard let c = compileFilter(filter, subject: subject) else { continue }
            whereParts.append(c.clause)
            whereDisplay.append(c.display)
            bindings.append(contentsOf: c.bindings)
        }

        // ORDER BY — sort field must be a known field.
        var orderClause = ""
        let sortKey = q.sortFieldKey ?? subject.defaultSortKey
        if let sortKey, let sf = subject.fields.first(where: { $0.key == sortKey }) {
            let desc = q.sortFieldKey != nil ? q.sortDescending : subject.defaultSortDescending
            orderClause = " ORDER BY \(sf.sqlExpr) \(desc ? "DESC" : "ASC")"
        }

        let limit = max(1, min(q.limit, 1000))
        let head = "SELECT \(selectList) FROM \(subject.fromClause)"
        let whereClause = whereParts.isEmpty ? "" : " WHERE \(whereParts.joined(separator: " AND "))"
        let whereDisp = whereDisplay.isEmpty ? "" : " WHERE \(whereDisplay.joined(separator: " AND "))"

        let sql = "\(head)\(whereClause)\(orderClause) LIMIT ?;"
        bindings.append(.integer(Int64(limit)))
        let displaySQL = "\(head)\(whereDisp)\(orderClause) LIMIT \(limit);"

        return CompiledQuery(sql: sql, bindings: bindings, columns: columns, displaySQL: displaySQL)
    }

    // MARK: - Filters

    private struct FilterClause { let clause: String; let display: String; let bindings: [SQLValue] }

    private static func compileFilter(_ f: QueryFilter, subject: QuerySubject) -> FilterClause? {
        guard let field = subject.field(f.fieldKey), field.filterable else { return nil }
        let expr = field.sqlExpr
        let v = f.value.trimmingCharacters(in: .whitespacesAndNewlines)

        switch f.op {
        case .contains:
            guard !v.isEmpty else { return nil }
            return .init(clause: "\(expr) LIKE ? ESCAPE '\\'",
                         display: "\(expr) LIKE '%\(sqlText(v))%'",
                         bindings: [.text("%\(escapeLike(v))%")])
        case .startsWith:
            guard !v.isEmpty else { return nil }
            return .init(clause: "\(expr) LIKE ? ESCAPE '\\'",
                         display: "\(expr) LIKE '\(sqlText(v))%'",
                         bindings: [.text("\(escapeLike(v))%")])
        case .isEqual, .isNot:
            guard !v.isEmpty else { return nil }
            let sqlOp = f.op == .isEqual ? "=" : "<>"
            if field.kind == .number {
                guard let n = Double(v) else { return nil }
                return .init(clause: "\(expr) \(sqlOp) ?", display: "\(expr) \(sqlOp) \(v)", bindings: [.real(n)])
            }
            return .init(clause: "\(expr) \(sqlOp) ?", display: "\(expr) \(sqlOp) '\(sqlText(v))'", bindings: [.text(v)])
        case .equals, .greaterThan, .lessThan:
            guard let n = Double(v) else { return nil }
            let sqlOp = f.op == .equals ? "=" : (f.op == .greaterThan ? ">" : "<")
            return .init(clause: "\(expr) \(sqlOp) ?", display: "\(expr) \(sqlOp) \(v)", bindings: [.real(n)])
        case .between:
            let v2 = f.value2.trimmingCharacters(in: .whitespacesAndNewlines)
            if field.kind == .date {
                guard let d1 = parseDate(v), let d2 = parseDate(v2) else { return nil }
                return .init(clause: "\(expr) BETWEEN ? AND ?",
                             display: "\(expr) BETWEEN '\(v)' AND '\(v2)'",
                             bindings: [.date(startOfDay(d1)), .date(endOfDay(d2))])
            }
            guard let n1 = Double(v), let n2 = Double(v2) else { return nil }
            return .init(clause: "\(expr) BETWEEN ? AND ?",
                         display: "\(expr) BETWEEN \(v) AND \(v2)",
                         bindings: [.real(n1), .real(n2)])
        case .onDate:
            guard let d = parseDate(v) else { return nil }
            return .init(clause: "\(expr) BETWEEN ? AND ?",
                         display: "\(expr) is on \(v)",
                         bindings: [.date(startOfDay(d)), .date(endOfDay(d))])
        case .before:
            guard let d = parseDate(v) else { return nil }
            return .init(clause: "\(expr) < ?", display: "\(expr) before \(v)", bindings: [.date(startOfDay(d))])
        case .after:
            guard let d = parseDate(v) else { return nil }
            return .init(clause: "\(expr) > ?", display: "\(expr) after \(v)", bindings: [.date(endOfDay(d))])
        }
    }

    // MARK: - Helpers

    private static func escapeLike(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "%", with: "\\%")
         .replacingOccurrences(of: "_", with: "\\_")
    }
    private static func sqlText(_ s: String) -> String { s.replacingOccurrences(of: "'", with: "''") }

    private static let dateParser: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f
    }()
    private static func parseDate(_ s: String) -> Date? {
        dateParser.date(from: s.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    private static func startOfDay(_ d: Date) -> Date { Calendar(identifier: .gregorian).startOfDay(for: d) }
    private static func endOfDay(_ d: Date) -> Date {
        let cal = Calendar(identifier: .gregorian)
        return cal.date(byAdding: .init(day: 1, second: -1), to: cal.startOfDay(for: d)) ?? d
    }
}
