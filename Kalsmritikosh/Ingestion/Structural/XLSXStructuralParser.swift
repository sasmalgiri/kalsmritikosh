//
//  XLSXStructuralParser.swift
//  Kalsmritikosh
//
//  A3 — XLSX into structured spreadsheet EvidenceBlocks: one spreadsheetSheet
//  block per worksheet + one spreadsheetRow block per row carrying its cells
//  (JSON) with a sheet/row locator. Same structured shape as the CSV parser, so
//  exact cell / row / sum / filter queries are answerable DETERMINISTICALLY
//  (no LLM). Parses shared strings, workbook sheet names, and sheet cells from
//  the OOXML ZIP. Deterministic.
//

import Foundation
import CryptoKit

public struct XLSXStructuralParser: StructuralParser {
    public nonisolated var supportedTypes: Set<SourceType> { [.xlsx] }
    public nonisolated var parserName: String { "xlsx-ooxml" }
    /// "2" — F31: native cell/row positions, workbook-relationship sheet order, cached value ≠ formula.
    public nonisolated var parserVersion: String { "2" }

    public nonisolated init() {}

    public func parse(
        data: Data,
        filename: String,
        type: SourceType,
        logicalSourceID: UUID,
        sourceVersionID: UUID
    ) async throws -> ParsedDocument {
        let documentID = UUID()
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("xlsx-\(UUID().uuidString).xlsx")
        try data.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        var blocks: [EvidenceBlock] = []
        let warnings: [ParserWarning] = []
        var ordinal = 0

        func add(_ kind: EvidenceBlockKind, _ text: String, _ locator: SourceLocator, _ attrs: [String: AnyCodable] = [:]) {
            blocks.append(EvidenceBlock(
                documentID: documentID, sourceVersionID: sourceVersionID, ordinal: ordinal,
                kind: kind, rawText: text, locator: locator, extractionMethod: .native, attributes: attrs
            ))
            ordinal += 1
        }

        do {
            let zip = try ZIPReader(url: tmp)
            let entries = try zip.entries().map(\.name)

            var shared: [String] = []
            if entries.contains("xl/sharedStrings.xml") {
                shared = Self.parseSharedStrings(try zip.read("xl/sharedStrings.xml"))
            }
            // F31 — sheets in workbook order, named + located through the relationships part.
            let sheets = Self.orderedSheets(
                workbook: entries.contains("xl/workbook.xml") ? try zip.read("xl/workbook.xml") : nil,
                relationships: entries.contains("xl/_rels/workbook.xml.rels") ? try zip.read("xl/_rels/workbook.xml.rels") : nil,
                entries: entries)
            guard !sheets.isEmpty else {
                return Self.empty(documentID, logicalSourceID, sourceVersionID, filename, hash, [
                    ParserWarning(severity: .error, code: "xlsx.no_worksheets", message: "No worksheets in XLSX.")
                ], .corrupt)
            }

            // PAR-005 — cell number-format codes (custom + built-in) from styles.xml, once.
            var numberFormats: [Int: String] = [:]
            if entries.contains("xl/styles.xml") {
                numberFormats = Self.parseNumberFormats(try zip.read("xl/styles.xml"))
            }
            for sheet in sheets {
                let name = sheet.name
                // F31 — rows at their native row numbers, cells at their native columns.
                let rows = Self.parseSheet(try zip.read(sheet.path), sharedStrings: shared, formats: numberFormats)
                    .filter { $0.values.contains { !$0.isEmpty } || $0.formulas.contains { !$0.isEmpty } }
                let columnCount = rows.map(\.values.count).max() ?? 0
                let headers = rows.first?.values ?? []
                add(.spreadsheetSheet,
                    "Sheet \"\(name)\": \(rows.count) rows × \(columnCount) columns",
                    SourceLocator(sheet: name),
                    ["rowCount": AnyCodable(.int(Int64(rows.count))),
                     "columnCount": AnyCodable(.int(Int64(columnCount))),
                     "headers": AnyCodable(.array(headers.map { .string($0) }))])
                func pad(_ xs: [String]) -> [String] { xs + Array(repeating: "", count: max(0, columnCount - xs.count)) }
                for (position, row) in rows.enumerated() {
                    let padded = pad(row.values)
                    var attrs: [String: AnyCodable] = [
                        "row": AnyCodable(.int(Int64(row.index))),
                        "isHeader": AnyCodable(.bool(position == 0)),
                        "cells": AnyCodable(.array(padded.map { .string($0) }))]
                    // PAR-005 — carry per-cell formulas so a formula-vs-value query can
                    // distinguish `=A1+B1` from a literal, WITHOUT altering the cell text
                    // above. Only attached when the row actually has a formula.
                    if row.formulas.contains(where: { !$0.isEmpty }) {
                        attrs["cellFormulas"] = AnyCodable(.array(pad(row.formulas).map { .string($0) }))
                    }
                    // PAR-005 — per-cell number-format codes (date/%/currency), additive.
                    if row.formats.contains(where: { !$0.isEmpty }) {
                        attrs["cellFormats"] = AnyCodable(.array(pad(row.formats).map { .string($0) }))
                    }
                    add(.spreadsheetRow, padded.joined(separator: " | "),
                        SourceLocator(row: row.index, sheet: name), attrs)
                }
            }
        } catch {
            return Self.empty(documentID, logicalSourceID, sourceVersionID, filename, hash, [
                ParserWarning(severity: .error, code: "xlsx.unreadable", message: "\(error)")
            ], .corrupt)
        }

        let status: ExtractionStatus = blocks.isEmpty ? .empty : (warnings.isEmpty ? .complete : .partial)
        return ParsedDocument(
            id: documentID, logicalSourceID: logicalSourceID, sourceVersionID: sourceVersionID,
            filename: filename, detectedType: .xlsx,
            mimeType: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            contentHash: hash, blocks: blocks, warnings: warnings, extractionStatus: status
        )
    }

    private static func empty(_ id: UUID, _ logical: UUID, _ version: UUID, _ filename: String,
                              _ hash: String, _ warnings: [ParserWarning], _ status: ExtractionStatus) -> ParsedDocument {
        ParsedDocument(id: id, logicalSourceID: logical, sourceVersionID: version, filename: filename,
                       detectedType: .xlsx, contentHash: hash, blocks: [], warnings: warnings, extractionStatus: status)
    }

    // MARK: - OOXML parsing (pure)

    static func parseSharedStrings(_ data: Data) -> [String] {
        let xml = String(decoding: data, as: UTF8.self)
        var strings: [String] = []
        var cursor = xml.startIndex
        while cursor < xml.endIndex {
            guard let siOpen = xml.range(of: "<si", range: cursor..<xml.endIndex),
                  let siClose = xml.range(of: "</si>", range: siOpen.upperBound..<xml.endIndex) else { break }
            strings.append(DocxLoader.stripTags(String(xml[siOpen.upperBound..<siClose.lowerBound])))
            cursor = siClose.upperBound
        }
        return strings
    }

    static func parseWorkbookSheetNames(_ data: Data) -> [String: String] {
        let xml = String(decoding: data, as: UTF8.self)
        var map: [String: String] = [:]
        var cursor = xml.startIndex
        var index = 1
        while cursor < xml.endIndex {
            guard let open = xml.range(of: "<sheet ", range: cursor..<xml.endIndex),
                  let close = xml.range(of: "/>", range: open.upperBound..<xml.endIndex) else { break }
            let attrs = String(xml[open.upperBound..<close.lowerBound])
            if let nameRange = attrs.range(of: "name=\""),
               let valueEnd = attrs.range(of: "\"", range: nameRange.upperBound..<attrs.endIndex) {
                let name = String(attrs[nameRange.upperBound..<valueEnd.lowerBound])
                map["xl/worksheets/sheet\(index).xml"] = name
                map["sheet\(index)"] = name
            }
            index += 1
            cursor = close.upperBound
        }
        return map
    }

    // MARK: - F31 workbook → ordered sheets (through the relationships part)

    /// One worksheet in workbook order: its visible name and its ZIP path.
    struct SheetRef: Equatable {
        let name: String
        let path: String
    }

    /// Worksheets in WORKBOOK order, named and located through `xl/_rels/workbook.xml.rels`
    /// (`<sheet r:id>` → `<Relationship Id Target>`), not by guessing that the Nth `<sheet>` lives in
    /// `sheetN.xml`. Worksheet files the workbook doesn't reference follow, in numeric order
    /// (sheet2 before sheet10), named "Sheet N" by position.
    static func orderedSheets(workbook: Data?, relationships: Data?, entries: [String]) -> [SheetRef] {
        let worksheetFiles = entries
            .filter { $0.hasPrefix("xl/worksheets/") && $0.hasSuffix(".xml") && !$0.contains("/_rels/") }
            .sorted { a, b in
                let na = trailingNumber(a), nb = trailingNumber(b)
                return na != nb ? na < nb : a < b
            }
        var targets: [String: String] = [:]
        if let relationships {
            for attrs in tagAttributes("Relationship", in: String(decoding: relationships, as: UTF8.self)) {
                guard let id = attr("Id", in: attrs), var target = attr("Target", in: attrs) else { continue }
                if target.hasPrefix("/") { target.removeFirst() } else { target = "xl/" + target }
                targets[id] = target.replacingOccurrences(of: "/./", with: "/")
            }
        }
        var result: [SheetRef] = []
        var claimed: Set<String> = []
        if let workbook {
            for attrs in tagAttributes("sheet", in: String(decoding: workbook, as: UTF8.self)) {
                guard let name = attr("name", in: attrs),
                      let rid = attr("r:id", in: attrs), let path = targets[rid],
                      worksheetFiles.contains(path), !claimed.contains(path) else { continue }
                result.append(SheetRef(name: xmlUnescape(name), path: path))
                claimed.insert(path)
            }
        }
        for path in worksheetFiles where !claimed.contains(path) {
            result.append(SheetRef(name: "Sheet \(result.count + 1)", path: path))
        }
        return result
    }

    private static func trailingNumber(_ path: String) -> Int {
        let digits = (path as NSString).deletingPathExtension.reversed().prefix { $0.isNumber }
        return Int(String(digits.reversed())) ?? Int.max
    }

    /// Attribute strings of every `<tag …>` / `<tag …/>` (exact tag name — `<sheet` never matches `<sheets>`).
    private static func tagAttributes(_ tag: String, in xml: String) -> [String] {
        var out: [String] = []
        var cursor = xml.startIndex
        while let open = xml.range(of: "<\(tag)", range: cursor..<xml.endIndex) {
            cursor = open.upperBound
            guard cursor < xml.endIndex, let next = xml[cursor...].first,
                  next == " " || next == "/" || next == ">" || next == "\n" || next == "\t" || next == "\r",
                  let gt = xml.range(of: ">", range: cursor..<xml.endIndex) else { continue }
            var attrs = String(xml[cursor..<gt.lowerBound])
            if attrs.hasSuffix("/") { attrs.removeLast() }
            out.append(attrs)
            cursor = gt.upperBound
        }
        return out
    }

    private static func xmlUnescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    // MARK: - F31 worksheet → rows at their native positions

    /// One `<row>` of a worksheet: its 0-based row index (from `row@r`) and its cells placed by
    /// column (from `c@r`, A = 0). `values` is the displayed value (shared / inline string, or the
    /// cached `<v>` — for a formula cell that is the last computed result); `formulas` holds the
    /// formula text ("" for literals) and `formats` the number-format code, all column-aligned.
    struct SheetRow: Equatable {
        let index: Int
        let values: [String]
        let formulas: [String]
        let formats: [String]
    }

    /// Parse a worksheet into rows at their NATIVE positions. Row / cell references are honoured;
    /// when absent, the next row / column after the previous one is assumed (as Excel does).
    static func parseSheet(_ data: Data, sharedStrings: [String], formats: [Int: String]) -> [SheetRow] {
        let full = String(decoding: data, as: UTF8.self)
        // Only <sheetData> holds cells; <rowBreaks>, <cols> etc. live outside it.
        var xml = Substring(full)
        if let open = full.range(of: "<sheetData"),
           let close = full.range(of: "</sheetData>", range: open.upperBound..<full.endIndex) {
            xml = full[open.upperBound..<close.lowerBound]
        }
        var rows: [SheetRow] = []
        var nextRow = 0
        var cursor = xml.startIndex
        while let rowOpen = xml.range(of: "<row", range: cursor..<xml.endIndex),
              let rowGT = xml.range(of: ">", range: rowOpen.upperBound..<xml.endIndex) {
            let rowHeader = String(xml[rowOpen.upperBound..<rowGT.lowerBound])
            let rowIndex = attr("r", in: rowHeader).flatMap(Int.init).map { $0 - 1 } ?? nextRow
            nextRow = rowIndex + 1
            if rowHeader.hasSuffix("/") {                       // <row r="3"/> — present but empty
                rows.append(SheetRow(index: rowIndex, values: [], formulas: [], formats: []))
                cursor = rowGT.upperBound
                continue
            }
            guard let rowClose = xml.range(of: "</row>", range: rowGT.upperBound..<xml.endIndex) else { break }
            let body = xml[rowGT.upperBound..<rowClose.lowerBound]
            var cells: [Int: (value: String, formula: String, format: String)] = [:]
            var nextColumn = 0
            var inner = body.startIndex
            while let cellOpen = body.range(of: "<c", range: inner..<body.endIndex) {
                inner = cellOpen.upperBound
                guard inner < body.endIndex, let next = body[inner...].first,
                      next == " " || next == ">" || next == "/" || next == "\n" || next == "\t" || next == "\r",
                      let cellGT = body.range(of: ">", range: inner..<body.endIndex) else { continue }
                let header = String(body[inner..<cellGT.lowerBound])
                let cellBody: String
                if header.hasSuffix("/") {
                    cellBody = ""; inner = cellGT.upperBound
                } else if let end = body.range(of: "</c>", range: cellGT.upperBound..<body.endIndex) {
                    cellBody = String(body[cellGT.upperBound..<end.lowerBound]); inner = end.upperBound
                } else {
                    cellBody = ""; inner = cellGT.upperBound
                }
                let column = attr("r", in: header).flatMap(columnIndex(ofReference:)) ?? nextColumn
                nextColumn = column + 1
                cells[column] = (cellValue(header: header, body: cellBody, sharedStrings: sharedStrings),
                                 cellFormula(inBody: cellBody) ?? "",
                                 formats.isEmpty ? "" : (formats[cellStyleIndex(inHeader: header) ?? 0] ?? ""))
            }
            let width = (cells.keys.max() ?? -1) + 1
            rows.append(SheetRow(index: rowIndex,
                                 values: (0..<width).map { cells[$0]?.value ?? "" },
                                 formulas: (0..<width).map { cells[$0]?.formula ?? "" },
                                 formats: (0..<width).map { cells[$0]?.format ?? "" }))
            cursor = rowClose.upperBound
        }
        return rows
    }

    /// "C12" → 2 (A = 0). nil when the reference has no column letters.
    static func columnIndex(ofReference ref: String) -> Int? {
        var n = 0
        var sawLetter = false
        for ch in ref.uppercased() {
            guard let a = ch.asciiValue, a >= 65, a <= 90 else { break }
            n = n * 26 + Int(a - 64)
            sawLetter = true
        }
        return sawLetter ? n - 1 : nil
    }

    /// The displayed value of one cell: shared string, inline string, or the cached `<v>`.
    private static func cellValue(header: String, body: String, sharedStrings: [String]) -> String {
        switch attr("t", in: header) {
        case "s":
            if let raw = cellRawValue(inBody: body), let idx = Int(raw.trimmingCharacters(in: .whitespaces)),
               idx >= 0, idx < sharedStrings.count {
                return sharedStrings[idx]
            }
            return ""
        case "inlineStr":
            if let open = body.range(of: "<is"), let close = body.range(of: "</is>", range: open.upperBound..<body.endIndex),
               let gt = body.range(of: ">", range: open.upperBound..<close.lowerBound) {
                return DocxLoader.stripTags(String(body[gt.upperBound..<close.lowerBound]))
            }
            return ""
        default:
            return cellRawValue(inBody: body) ?? ""
        }
    }

    /// Rows of cell strings for a worksheet (shared-string + inline resolved), column-aligned,
    /// in file order.
    static func parseSheetRows(_ data: Data, sharedStrings: [String]) -> [[String]] {
        parseSheet(data, sharedStrings: sharedStrings, formats: [:]).map(\.values)
    }

    // MARK: - PAR-005 number-format model

    /// A subset of the OOXML built-in number-format ids (numFmtId → format code). Custom
    /// formats (id ≥ 164) come from styles.xml and override these. Enough to answer
    /// "is this cell a date / percentage / currency?" deterministically.
    static let builtinNumberFormats: [Int: String] = [
        0: "General", 1: "0", 2: "0.00", 3: "#,##0", 4: "#,##0.00",
        9: "0%", 10: "0.00%", 11: "0.00E+00", 12: "# ?/?", 13: "# ??/??",
        14: "mm-dd-yy", 15: "d-mmm-yy", 16: "d-mmm", 17: "mmm-yy", 18: "h:mm AM/PM",
        19: "h:mm:ss AM/PM", 20: "h:mm", 21: "h:mm:ss", 22: "m/d/yy h:mm",
        37: "#,##0 ;(#,##0)", 38: "#,##0 ;[Red](#,##0)", 39: "#,##0.00;(#,##0.00)",
        40: "#,##0.00;[Red](#,##0.00)", 44: "_(\"$\"* #,##0.00_)", 45: "mm:ss",
        46: "[h]:mm:ss", 47: "mmss.0", 48: "##0.0E+0", 49: "@"
    ]

    /// Map each cellXf index (a cell's `s="N"`) to its number-format CODE, resolving
    /// custom `<numFmt>` entries and falling back to the built-in table. Pure parse of
    /// `xl/styles.xml`; empty map when styles are absent (cells then have no format facet).
    static func parseNumberFormats(_ data: Data) -> [Int: String] {
        let xml = String(decoding: data, as: UTF8.self)
        // Custom numFmtId → formatCode.
        var custom: [Int: String] = [:]
        var cursor = xml.startIndex
        while let open = xml.range(of: "<numFmt ", range: cursor..<xml.endIndex),
              let close = xml.range(of: ">", range: open.upperBound..<xml.endIndex) {
            let attrs = String(xml[open.upperBound..<close.lowerBound])
            if let id = Self.attr("numFmtId", in: attrs).flatMap(Int.init),
               let code = Self.attr("formatCode", in: attrs) {
                custom[id] = code
            }
            cursor = close.upperBound
        }
        // cellXfs: xf entries in order; xfIndex → numFmtId → code.
        guard let xfsOpen = xml.range(of: "<cellXfs"),
              let xfsClose = xml.range(of: "</cellXfs>", range: xfsOpen.upperBound..<xml.endIndex)
        else { return [:] }
        let xfsBlock = String(xml[xfsOpen.upperBound..<xfsClose.lowerBound])
        var result: [Int: String] = [:]
        var idx = 0
        var c = xfsBlock.startIndex
        while let open = xfsBlock.range(of: "<xf", range: c..<xfsBlock.endIndex),
              let close = xfsBlock.range(of: ">", range: open.upperBound..<xfsBlock.endIndex) {
            let attrs = String(xfsBlock[open.upperBound..<close.lowerBound])
            let numFmtId = Self.attr("numFmtId", in: attrs).flatMap(Int.init) ?? 0
            if let code = custom[numFmtId] ?? builtinNumberFormats[numFmtId] {
                result[idx] = code
            }
            idx += 1
            c = close.upperBound
        }
        return result
    }

    /// The style index (`s="N"`) of a cell header, or nil if unstyled (implicitly 0).
    static func cellStyleIndex(inHeader header: String) -> Int? {
        Self.attr("s", in: header).flatMap(Int.init)
    }

    /// Extract a double-quoted attribute value from an XML attribute string. F31 — the name must
    /// start the string or follow whitespace, so `r` never matches inside `spans`/`customFormat`
    /// and `Id` never matches `sheetId`.
    private static func attr(_ name: String, in attrs: String) -> String? {
        var cursor = attrs.startIndex
        while let key = attrs.range(of: "\(name)=\"", range: cursor..<attrs.endIndex) {
            let atBoundary = key.lowerBound == attrs.startIndex
                || attrs[attrs.index(before: key.lowerBound)].isWhitespace
            if atBoundary, let end = attrs.range(of: "\"", range: key.upperBound..<attrs.endIndex) {
                return String(attrs[key.upperBound..<end.lowerBound])
            }
            cursor = key.upperBound
        }
        return nil
    }

    // MARK: - PAR-005 formula/value model

    /// The formula expression of a cell (`<f>…</f>`), or nil if the cell holds a literal
    /// value. This is the "formula vs value" distinction: two cells can DISPLAY 42 while
    /// one is the literal 42 and the other is `=A1+B1` — an exact query must tell them apart.
    static func cellFormula(inBody body: String) -> String? {
        guard let open = body.range(of: "<f"),
              let gt = body.range(of: ">", range: open.upperBound..<body.endIndex) else { return nil }
        // Self-closing `<f/>` (shared-formula slave) carries no expression here.
        if body[open.upperBound..<gt.lowerBound].contains("/") { return nil }
        guard let close = body.range(of: "</f>", range: gt.upperBound..<body.endIndex) else { return nil }
        let expr = DocxLoader.stripTags(String(body[gt.upperBound..<close.lowerBound]))
            .trimmingCharacters(in: .whitespaces)
        return expr.isEmpty ? nil : expr
    }

    /// The cached raw value of a cell (`<v>…</v>`), or nil if absent. For a formula cell
    /// this is the last computed result stored in the file.
    static func cellRawValue(inBody body: String) -> String? {
        guard let open = body.range(of: "<v>"),
              let close = body.range(of: "</v>", range: open.upperBound..<body.endIndex) else { return nil }
        return DocxLoader.stripTags(String(body[open.upperBound..<close.lowerBound]))
    }

    /// Per-cell formula expressions for each row, aligned to `parseSheetRows`' cell order
    /// (empty string where a cell has no formula). Additive to the text path.
    static func parseSheetFormulas(_ data: Data) -> [[String]] {
        parseSheet(data, sharedStrings: [], formats: [:]).map(\.formulas)
    }

    /// Per-cell number-format codes for each row (empty string where a cell is unstyled or
    /// its style has no format). `formats` is `parseNumberFormats(styles.xml)`. Aligned to
    /// `parseSheetRows`' cell order. Additive to the text path.
    static func parseSheetFormats(_ data: Data, formats: [Int: String]) -> [[String]] {
        guard !formats.isEmpty else { return [] }
        return parseSheet(data, sharedStrings: [], formats: formats).map(\.formats)
    }
}
