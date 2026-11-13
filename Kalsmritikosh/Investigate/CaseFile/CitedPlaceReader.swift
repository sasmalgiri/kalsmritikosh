//
//  CitedPlaceReader.swift
//  Kalsmritikosh
//
//  S18 (SRC-01) — the last advertised locators reach their place: a spreadsheet citation (sheet, row, cell or cell
//  range) opens the cited sheet with the cited row and cell selected; a slide citation opens that slide. The file read
//  is the one CitedSourceResolver chose — the cited VERSION (its kept copy, or the file only when its bytes are the
//  cited ones) — and it is read with the same structural parser the intake used, so the rows and slide numbers are the
//  locator's own (rows 0-based as the parsers record them, slides 1-based). A place that is not in the file is said
//  (`missing`), never replaced by another place silently.
//

import Foundation
import os

public nonisolated enum CitedPlaceReader {

    public struct SheetRow: Equatable, Sendable {
        /// The row's index as the parser recorded it (0-based; the locator's `row`).
        public let index: Int
        public let cells: [String]
    }

    public struct SheetPlace: Equatable, Sendable {
        public let sheet: String
        public let sheetNames: [String]
        /// The rows shown: a window around the cited row (all rows of a small sheet).
        public let rows: [SheetRow]
        public let totalRows: Int
        /// The cited row (locator index) and cell column (0-based), when the citation names them.
        public let selectedRow: Int?
        public let selectedColumn: Int?
        /// The value of the cited cell, when both row and column are named and present.
        public var selectedValue: String? {
            guard let r = selectedRow, let c = selectedColumn, let row = rows.first(where: { $0.index == r }), c < row.cells.count else { return nil }
            return row.cells[c]
        }
    }

    public struct SlidePlace: Equatable, Sendable {
        public let number: Int
        public let count: Int
        public let title: String?
        public let body: [String]
        public let notes: String?
    }

    public enum Content: Equatable, Sendable {
        case sheet(SheetPlace)
        case slide(SlidePlace)
        /// The cited place is not in this file (a sheet, row or slide it does not have) or the file could not be read.
        case missing(String)
    }

    /// Rows shown either side of the cited row.
    public static let window = 40

    /// A1-style reference ("C12", "$B$2") → (0-based row, 0-based column). Column-only ("C") gives a nil row.
    public static func cellReference(_ ref: String) -> (row: Int?, column: Int?) {
        let s = ref.replacingOccurrences(of: "$", with: "").trimmingCharacters(in: .whitespaces).uppercased()
        let letters = s.prefix { $0.isASCII && $0.isLetter }
        let digits = s.dropFirst(letters.count)
        var column: Int?
        if !letters.isEmpty {
            var n = 0
            for ch in letters { n = n * 26 + Int((ch.asciiValue ?? 65) - 64) }
            column = n - 1
        }
        let row = Int(digits).flatMap { $0 >= 1 ? $0 - 1 : nil }
        return (row, column)
    }

    /// Read the cited place out of `url` (a file with `fileExtension`).
    public static func read(url: URL, place: CitedSourceResolver.CitedPlace) async -> Content {
        let ext = url.pathExtension.lowercased()
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            KalsmritikoshLog.ui.error("Cited place: file not read: \(error.localizedDescription, privacy: .public)")
            return .missing("The file could not be read here.")
        }
        return await read(data: data, fileExtension: ext, filename: url.lastPathComponent, place: place)
    }

    public static func read(data: Data, fileExtension ext: String, filename: String,
                            place: CitedSourceResolver.CitedPlace) async -> Content {
        switch place {
        case .sheetCell(let sheet, let row, let column, let cellRange):
            return await readSheet(data: data, ext: ext, filename: filename, sheet: sheet, row: row, column: column, cellRange: cellRange)
        case .slide(let n):
            return await readSlide(data: data, ext: ext, filename: filename, number: n)
        default:
            return .missing("This place is not a sheet or a slide.")
        }
    }

    static func parser(forExtension ext: String) -> (any StructuralParser, SourceType)? {
        switch ext {
        case "csv": return (CSVStructuralParser(), .csv)
        case "xlsx": return (XLSXStructuralParser(), .xlsx)
        case "ods": return (ODSStructuralParser(), .ods)
        case "xls": return (XlsStructuralParser(), .xls)
        case "pptx": return (PPTXStructuralParser(), .pptx)
        default: return nil
        }
    }

    private static func parse(_ data: Data, ext: String, filename: String) async -> ParsedDocument? {
        guard let (parser, type) = parser(forExtension: ext) else { return nil }
        do {
            return try await parser.parse(data: data, filename: filename, type: type, logicalSourceID: UUID(), sourceVersionID: UUID())
        } catch {
            KalsmritikoshLog.ui.error("Cited place: file not parsed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static func cells(_ block: EvidenceBlock) -> [String] {
        if case .array(let xs)? = block.attributes["cells"]?.value {
            return xs.map { if case .string(let s) = $0 { return s }; return "" }
        }
        return block.rawText.components(separatedBy: " | ")
    }

    private static func readSheet(data: Data, ext: String, filename: String, sheet: String?, row: Int?, column: String?,
                                  cellRange: String?) async -> Content {
        guard let doc = await parse(data, ext: ext, filename: filename) else { return .missing("This spreadsheet could not be read here.") }
        let names = doc.blocks.filter { $0.kind == .spreadsheetSheet }.compactMap(\.locator.sheet)
        guard let target = sheet ?? names.first else { return .missing("This spreadsheet has no sheets.") }
        guard names.contains(target) else { return .missing("The cited sheet “\(target)” is not in this version of the file.") }
        let all = doc.blocks.filter { $0.kind == .spreadsheetRow && $0.locator.sheet == target }
            .compactMap { b in b.locator.row.map { SheetRow(index: $0, cells: cells(b)) } }
        var selectedRow = row, selectedColumn: Int?
        if let range = cellRange {
            let start = cellReference(String(range.split(separator: ":").first ?? Substring(range)))
            selectedRow = selectedRow ?? start.row
            selectedColumn = start.column
        }
        if let c = column { selectedColumn = cellReference(c).column ?? selectedColumn }
        if let r = selectedRow, !all.contains(where: { $0.index == r }) {
            return .missing("The cited row \(r + 1) of sheet “\(target)” is not in this version of the file.")
        }
        let shown: [SheetRow]
        if let r = selectedRow, let at = all.firstIndex(where: { $0.index == r }) {
            shown = Array(all[max(0, at - window)..<min(all.count, at + window + 1)])
        } else {
            shown = Array(all.prefix(window * 2 + 1))
        }
        return .sheet(SheetPlace(sheet: target, sheetNames: names, rows: shown, totalRows: all.count,
                                 selectedRow: selectedRow, selectedColumn: selectedColumn))
    }

    private static func readSlide(data: Data, ext: String, filename: String, number: Int) async -> Content {
        guard let doc = await parse(data, ext: ext, filename: filename) else { return .missing("This presentation could not be read here.") }
        let count = doc.blocks.compactMap(\.locator.slide).max() ?? 0
        let on = doc.blocks.filter { $0.locator.slide == number }
        guard number >= 1, !on.isEmpty else { return .missing("The cited slide \(number) is not in this version of the file (it has \(count)).") }
        return .slide(SlidePlace(number: number, count: count,
                                 title: on.first { $0.kind == .slideTitle }?.rawText,
                                 body: on.filter { $0.kind == .slideBody }.map(\.rawText),
                                 notes: on.first { $0.kind == .slideNotes }?.rawText))
    }
}
