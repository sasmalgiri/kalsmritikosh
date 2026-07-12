//
//  TableQueryEngine.swift
//  Kalsmritikosh
//
//  A6.4 — deterministic structured-table query path. Spreadsheet parsers
//  (CSV / XLSX / ODS) persist each row's cells on `.spreadsheetRow` evidence
//  blocks (attributes["cells"]) with the header row on the `.spreadsheetSheet`
//  block (attributes["headers"]). This engine answers aggregate / lookup
//  questions about a table by reading those cells directly — NO LLM, fully
//  deterministic and exact. It is the "read the persisted cells" path A6.4 asks
//  for; the value is computed from evidence, never generated.
//

import Foundation

public struct TableQueryEngine: Sendable {

    public nonisolated init() {}

    /// The aggregate a table question asks for.
    public enum Aggregate: String, Sendable, CaseIterable {
        case sum, average, min, max, count
    }

    public struct Result: Sendable, Hashable {
        public let aggregate: Aggregate
        public let column: String?
        public let value: Double
        /// Rows that contributed (numeric cells found), for the evidence count.
        public let rowsConsidered: Int
    }

    // MARK: - Table extraction

    /// Header labels for a sheet, from the `.spreadsheetSheet` block.
    static func headers(_ blocks: [EvidenceBlock]) -> [String] {
        guard let sheet = blocks.first(where: { $0.kind == .spreadsheetSheet }),
              case .array(let arr)? = sheet.attributes["headers"]?.value else { return [] }
        return arr.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
    }

    /// Data rows (cells) from the `.spreadsheetRow` blocks in order, excluding
    /// the header row (row 0 / isHeader).
    static func dataRows(_ blocks: [EvidenceBlock]) -> [[String]] {
        blocks
            .filter { $0.kind == .spreadsheetRow }
            .sorted { ($0.locator.row ?? 0) < ($1.locator.row ?? 0) }
            .filter { block in
                if case .bool(let isHeader)? = block.attributes["isHeader"]?.value { return !isHeader }
                return (block.locator.row ?? 0) != 0
            }
            .compactMap { block in
                guard case .array(let cells)? = block.attributes["cells"]?.value else { return nil }
                return cells.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
            }
    }

    /// Zero-based index of a column whose header matches `name` (case- and
    /// whitespace-insensitive, substring-tolerant), or nil.
    static func columnIndex(_ name: String, headers: [String]) -> Int? {
        let target = name.lowercased().trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return nil }
        // Exact match first, then contains.
        if let exact = headers.firstIndex(where: { $0.lowercased().trimmingCharacters(in: .whitespaces) == target }) {
            return exact
        }
        return headers.firstIndex(where: { $0.lowercased().contains(target) })
    }

    /// Parse a numeric cell — strips currency symbols, thousands separators,
    /// and surrounding whitespace. Returns nil for non-numeric cells.
    static func numeric(_ cell: String) -> Double? {
        let cleaned = cell.filter { $0.isNumber || $0 == "." || $0 == "-" }
        guard !cleaned.isEmpty, cleaned != "-", cleaned != "." else { return nil }
        return Double(cleaned)
    }

    // MARK: - Evaluation

    /// Evaluate an aggregate over a named column (nil column ⇒ count of rows).
    /// Deterministic; returns nil when the column can't be resolved or no
    /// numeric cells exist for a numeric aggregate.
    public func evaluate(
        _ aggregate: Aggregate,
        column: String?,
        blocks: [EvidenceBlock]
    ) -> Result? {
        let rows = Self.dataRows(blocks)
        guard !rows.isEmpty else { return nil }

        if aggregate == .count && column == nil {
            return Result(aggregate: .count, column: nil, value: Double(rows.count), rowsConsidered: rows.count)
        }

        guard let column,
              let idx = Self.columnIndex(column, headers: Self.headers(blocks)) else { return nil }
        let values = rows.compactMap { row -> Double? in
            idx < row.count ? Self.numeric(row[idx]) : nil
        }

        switch aggregate {
        case .count:
            return Result(aggregate: .count, column: column, value: Double(values.count), rowsConsidered: values.count)
        case .sum:
            guard !values.isEmpty else { return nil }
            return Result(aggregate: .sum, column: column, value: values.reduce(0, +), rowsConsidered: values.count)
        case .average:
            guard !values.isEmpty else { return nil }
            return Result(aggregate: .average, column: column, value: values.reduce(0, +) / Double(values.count), rowsConsidered: values.count)
        case .min:
            guard let m = values.min() else { return nil }
            return Result(aggregate: .min, column: column, value: m, rowsConsidered: values.count)
        case .max:
            guard let m = values.max() else { return nil }
            return Result(aggregate: .max, column: column, value: m, rowsConsidered: values.count)
        }
    }

    /// Detect an aggregate + column from a natural-language table question.
    /// Deterministic keyword mapping — no model. Returns nil when the question
    /// isn't a recognizable table aggregate.
    public func parseQuestion(_ question: String, headers: [String]) -> (Aggregate, String?)? {
        let q = question.lowercased()
        let aggregate: Aggregate?
        if q.contains("how many") || q.contains("number of") || q.contains("count") {
            aggregate = .count
        } else if q.contains("total") || q.contains("sum") || q.contains("altogether") {
            aggregate = .sum
        } else if q.contains("average") || q.contains("mean ") {
            aggregate = .average
        } else if q.contains("highest") || q.contains("maximum") || q.contains("max ") || q.contains("largest") {
            aggregate = .max
        } else if q.contains("lowest") || q.contains("minimum") || q.contains("min ") || q.contains("smallest") {
            aggregate = .min
        } else {
            aggregate = nil
        }
        guard let aggregate else { return nil }
        // Match a header mentioned in the question.
        let column = headers.first(where: { q.contains($0.lowercased()) })
        // "how many rows/records/entries" ⇒ count with no column.
        if aggregate == .count, column == nil,
           q.contains("row") || q.contains("record") || q.contains("entr") || q.contains("how many") {
            return (.count, nil)
        }
        guard column != nil else { return nil }
        return (aggregate, column)
    }
}
