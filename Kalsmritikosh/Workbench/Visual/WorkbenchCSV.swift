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
        // "\r\n" is checked separately: Swift's grapheme-cluster Characters
        // mean a CRLF inside the value matches neither "\n" nor "\r" alone.
        guard value.contains(",") || value.contains("\"") || value.contains("\n")
                || value.contains("\r") || value.contains("\r\n") else {
            return value
        }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Parse RFC-4180 CSV into a grid — quoted fields, escaped quotes,
    /// CR/LF/CRLF row endings. The inverse of render(); Excel's "Save as
    /// CSV" lands here, so imported spreadsheets become real datasets.
    public static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var i = text.startIndex
        while i < text.endIndex {
            let ch = text[i]
            if inQuotes {
                if ch == "\"" {
                    let next = text.index(after: i)
                    if next < text.endIndex, text[next] == "\"" {
                        field.append("\""); i = next
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(ch)
                }
            } else {
                switch ch {
                case "\"": inQuotes = true
                case ",":  row.append(field); field = ""
                // NOTE: Swift treats CRLF as ONE grapheme-cluster Character,
                // so "\r\n" is its own case — no lookahead needed.
                case "\r", "\n", "\r\n":
                    row.append(field); field = ""
                    rows.append(row); row = []
                default:
                    field.append(ch)
                }
            }
            i = text.index(after: i)
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        // Drop fully-empty trailing rows (a final newline is not a row).
        while rows.last?.allSatisfy(\.isEmpty) == true { rows.removeLast() }
        return rows
    }

    /// The record as a plain grid (header + rows, projection-aware) — the
    /// shared shape behind the XLSX export and the chart panel.
    public static func grid(_ record: WorkbenchDatasetRecord,
                            projection: WorkbenchScenarioProjection? = nil) -> [[String]] {
        parse(render(record, projection: projection))
    }
}

// MARK: - Dataset report (the Word/PDF export body)

/// Plain-text report of a dataset for a reader outside the app — what the
/// table says, where every value stands (provenance counts), and what the
/// quality check flagged. Pure and unit-tested; DocumentExporter turns it
/// into DOCX/PDF.
public nonisolated enum WorkbenchReport {
    public static func render(_ record: WorkbenchDatasetRecord,
                              projection: WorkbenchScenarioProjection? = nil,
                              quality: WorkbenchDataQualityReport? = nil) -> String {
        let fields = record.fields.sorted { $0.ordinal < $1.ordinal }
        let grid = WorkbenchCSV.grid(record, projection: projection)
        let dataRows = grid.dropFirst()

        var sourceCells = 0, calculated = 0, entered = 0
        for cell in record.cells {
            switch cell.kind {
            case .sourceValue: sourceCells += 1
            case .deterministicCalculation: calculated += 1
            default: entered += 1
            }
        }

        var out = "DATASET: \(record.dataset.title)\n"
        out += String(repeating: "=", count: min(72, 9 + record.dataset.title.count)) + "\n"
        out += "Fields: \(fields.map(\.name).joined(separator: ", "))\n"
        out += "Rows: \(dataRows.count) · Revision: \(record.dataset.revision)\n"
        out += "Provenance: \(sourceCells) source-bound · \(calculated) calculated · \(entered) entered\n"
        if projection != nil { out += "View: scenario overlay applied (base data untouched)\n" }
        out += "\n"

        // The table itself, pipe-separated for a text reader.
        out += fields.map(\.name).joined(separator: " | ") + "\n"
        for row in dataRows {
            out += row.joined(separator: " | ") + "\n"
        }

        if let quality {
            out += "\nQUALITY\n"
            if quality.isClean {
                out += "No warnings — the dataset passed every check.\n"
            } else {
                for warning in quality.warnings {
                    out += "- [\(warning.severity.rawValue)] \(warning.message)\n"
                }
            }
        }
        out += "\nGenerated by Kalsmritikosh — every source value drills to evidence kept on-device.\n"
        return out
    }
}
