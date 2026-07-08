//
//  LogisticsTableMapper.swift
//  Kalsmritikosh
//
//  Optional, domain-specific post-processor for the ocr-table-pipeline port —
//  a faithful Swift translation of the original's Type-1 / Type-2 German
//  logistics header mapping (test14.py HEADER_VARIANTS + test15.py
//  build_dataframe merged-column forward-fill).
//
//  It is NOT wired into the general ingest path (most documents are not these
//  logistics forms). A caller that KNOWS it is processing Type-1/Type-2 sheets
//  runs a TableOCR grid through `map(_:)` to get labelled, merged-column-
//  filled rows, then `DocumentExporter.xlsx(grid:)` to reproduce the original
//  Excel output.
//

import Foundation

public struct MappedTable: Sendable {
    public enum Kind: String, Sendable { case type1, type2 }
    public let kind: Kind
    public let headers: [String]
    /// Data rows, aligned to `headers`, with merged columns forward-filled.
    public let rows: [[String]]

    /// Header row + data rows — ready for `DocumentExporter.xlsx(grid:)`.
    public func asGrid() -> [[String]] { [headers] + rows }
}

public enum LogisticsTableMapper {

    // Fixed column schemas (ported verbatim from test15.py).
    static let type1Headers = [
        "Uhrzeit", "Halle_Anlage", "Anzahl", "Zuege_Waggons", "Abfahrt",
        "Datum_Uhrzeit_Leer_Voll", "Uhrzeit_DB", "Begruendung"
    ]
    static let type2Headers = [
        "Uhrzeit", "Gleis", "Anzahl", "Waggons", "Station", "Abr.",
        "Halle", "Datum_Uhrzeit_beladen", "Uhrzeit_DB", "Begruendung"
    ]
    /// Columns that carry down when blank (merged cells) — TYPE*_MERGED.
    static let type1Merged: Set<Int> = [0, 6, 7]
    static let type2Merged: Set<Int> = [0, 8, 9]

    /// Header-cell variants (test14.py HEADER_VARIANTS, flattened + normalized).
    static let headerVariants: [String] = [
        "uhrzeit", "uhr zeiten", "zeit", "zeitpunkt",
        "gleis", "gleiss", "gleise", "glei5",
        "anzahl", "anzal", "anz.", "anz a hl",
        "waggons", "wagons", "waggon", "waggonanzahl", "wagen",
        "station", "ort", "bahnhof", "lieferort",
        "abr.", "abr", "abruf", "abrf", "abrufzeit",
        "halle", "hallee", "anlage",
        "datum", "date", "versanddatum", "beladedatum", "beladen",
        "leer/voll", "entladung",
        "zuege", "zuge", "zug", "abfahrt", "abfahrtzeit",
        "db", "begruendung", "begrundung", "bemerkung", "grund", "erklaerung"
    ]

    /// Map a raw OCR grid to a labelled Type-1/Type-2 table. Returns nil when
    /// the column count matches neither schema (i.e. not a logistics sheet).
    public static func map(_ grid: [[String]]) -> MappedTable? {
        guard !grid.isEmpty else { return nil }
        let colCount = grid.map(\.count).max() ?? 0

        let kind: MappedTable.Kind
        let headers: [String]
        let merged: Set<Int>
        switch colCount {
        case type2Headers.count: kind = .type2; headers = type2Headers; merged = type2Merged
        case type1Headers.count: kind = .type1; headers = type1Headers; merged = type1Merged
        default: return nil
        }

        // Drop a leading header row if the OCR captured one.
        var dataRows = grid
        if let first = grid.first, looksLikeHeaderRow(first) { dataRows.removeFirst() }

        // Forward-fill merged columns (build_dataframe's last_vals logic).
        var lastVals = [String](repeating: "", count: headers.count)
        var out: [[String]] = []
        for raw in dataRows {
            var row = [String](repeating: "", count: headers.count)
            for c in 0..<headers.count {
                let value = c < raw.count ? raw[c] : ""
                if merged.contains(c) {
                    if !value.trimmingCharacters(in: .whitespaces).isEmpty { lastVals[c] = value }
                    row[c] = lastVals[c]
                } else {
                    row[c] = value
                }
            }
            out.append(row)
        }
        return MappedTable(kind: kind, headers: headers, rows: out)
    }

    /// A row is a header row when ≥2 cells match known header variants
    /// (is_header_match in test14.py, with ü→u / ä→a normalization).
    static func looksLikeHeaderRow(_ row: [String]) -> Bool {
        let hits = row.reduce(into: 0) { acc, cell in
            let norm = cell.lowercased()
                .replacingOccurrences(of: "ü", with: "u")
                .replacingOccurrences(of: "ä", with: "a")
            if headerVariants.contains(where: { norm.contains($0) }) { acc += 1 }
        }
        return hits >= 2
    }
}
