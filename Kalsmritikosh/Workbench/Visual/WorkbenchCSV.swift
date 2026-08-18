//
//  WorkbenchCSV.swift
//  Kalsmritikosh
//
//  DATALAB-UI — deterministic CSV rendering of a dataset record (fields by
//  ordinal, rows by ordinal, RFC-4180 escaping). Pure and unit-tested; the
//  DataLab surface writes the result wherever the user chooses. An optional
//  scenario projection substitutes overlay values without touching the base.
//

import Foundation

public nonisolated enum WorkbenchCSV {

    /// Render the record as CSV. When `projection` is given, excluded rows
    /// are dropped and overridden values substituted (the scenario view of
    /// the same data — the base record is never altered).
    public static func render(_ record: WorkbenchDatasetRecord,
                              projection: WorkbenchScenarioProjection? = nil) -> String {
        let fields = record.fields.sorted { $0.ordinal < $1.ordinal }
        var rows = record.rows.sorted { $0.ordinal < $1.ordinal }
        if let projection {
            rows = rows.filter { !projection.excludedRows.contains($0.id) }
        }
        var cellByKey: [String: WorkbenchCell] = [:]
        for cell in record.cells {
            cellByKey["\(cell.rowID.uuidString)|\(cell.fieldID.uuidString)"] = cell
        }

        var out = fields.map { escape($0.name) }.joined(separator: ",") + "\r\n"
        for row in rows {
            let line = fields.map { field -> String in
                let value: String?
                if let projection {
                    value = projection.projectedValue(rowID: row.id, fieldID: field.id)
                } else {
                    value = cellByKey["\(row.id.uuidString)|\(field.id.uuidString)"]?.value
                }
                return escape(value ?? "")
            }
            out += line.joined(separator: ",") + "\r\n"
        }
        return out
    }

    /// RFC-4180: quote when the value contains a comma, quote, or newline;
    /// double any embedded quotes.
    static func escape(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r") else {
            return value
        }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
