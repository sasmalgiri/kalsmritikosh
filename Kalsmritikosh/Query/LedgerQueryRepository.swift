//
//  LedgerQueryRepository.swift
//  Kalsmritikosh
//
//  Runs a compiled LedgerQuery against the ledger — read-only, through the
//  Database actor, exactly like every other repository. It only ever executes
//  the single parameterized SELECT the compiler produced, and returns the rows
//  already formatted for display, so the UI stays dumb.
//

import Foundation

public enum LedgerQueryError: Error, LocalizedError, Sendable {
    case unknownSubject
    public var errorDescription: String? {
        switch self { case .unknownSubject: return "That subject isn't available to query." }
    }
}

public actor LedgerQueryRepository {
    private let database: Database
    public init(database: Database) { self.database = database }

    public struct QueryResult: Sendable {
        public let columns: [CompiledColumn]
        public let rows: [[String]]
        public let sql: String        // display SQL (values inlined)
        public let truncated: Bool     // hit the row limit
    }

    public func run(_ query: LedgerQuery) async throws -> QueryResult {
        guard let compiled = LedgerQueryCompiler.compile(query) else { throw LedgerQueryError.unknownSubject }
        let raw = try await database.query(compiled.sql, compiled.bindings)

        var rows: [[String]] = []
        rows.reserveCapacity(raw.count)
        for r in raw {
            var cells: [String] = []
            cells.reserveCapacity(compiled.columns.count)
            for (i, col) in compiled.columns.enumerated() {
                cells.append(format(r, i, col.kind))
            }
            rows.append(cells)
        }
        let limit = max(1, min(query.limit, 1000))
        return QueryResult(columns: compiled.columns, rows: rows, sql: compiled.displaySQL,
                           truncated: rows.count >= limit)
    }

    private func format(_ r: SQLRow, _ i: Int, _ kind: QueryValueKind) -> String {
        switch kind {
        case .fileName:
            let s = r.string(i) ?? ""
            if let u = URL(string: s), !u.lastPathComponent.isEmpty { return u.lastPathComponent }
            return (s as NSString).lastPathComponent.isEmpty ? s : (s as NSString).lastPathComponent
        case .text, .choice:
            return r.string(i) ?? ""
        case .number:
            if let d = r.double(i) {
                if d == d.rounded() && abs(d) < 1e15 { return String(Int64(d)) }
                return String(format: "%.2f", d)
            }
            if let n = r.int(i) { return String(n) }
            return r.string(i) ?? ""
        case .date:
            return r.date(i).map { $0.formatted(date: .abbreviated, time: .omitted) } ?? (r.string(i) ?? "")
        }
    }
}
