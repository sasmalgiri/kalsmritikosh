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
    public nonisolated var parserVersion: String { "1" }

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
            var sheetNames: [String: String] = [:]
            if entries.contains("xl/workbook.xml") {
                sheetNames = Self.parseWorkbookSheetNames(try zip.read("xl/workbook.xml"))
            }
            let sheetPaths = entries
                .filter { $0.hasPrefix("xl/worksheets/sheet") && $0.hasSuffix(".xml") }
                .sorted()
            guard !sheetPaths.isEmpty else {
                return Self.empty(documentID, logicalSourceID, sourceVersionID, filename, hash, [
                    ParserWarning(severity: .error, code: "xlsx.no_worksheets", message: "No worksheets in XLSX.")
                ], .corrupt)
            }

            for (i, path) in sheetPaths.enumerated() {
                let name = sheetNames[path] ?? sheetNames["sheet\(i + 1)"] ?? "Sheet \(i + 1)"
                let sheetData = try zip.read(path)
                let rows = Self.parseSheetRows(sheetData, sharedStrings: shared)
                let formulaRows = Self.parseSheetFormulas(sheetData)   // PAR-005 — additive
                let columnCount = rows.map(\.count).max() ?? 0
                let headers = rows.first ?? []
                add(.spreadsheetSheet,
                    "Sheet \"\(name)\": \(rows.count) rows × \(columnCount) columns",
                    SourceLocator(sheet: name),
                    ["rowCount": AnyCodable(.int(Int64(rows.count))),
                     "columnCount": AnyCodable(.int(Int64(columnCount))),
                     "headers": AnyCodable(.array(headers.map { .string($0) }))])
                for (r, row) in rows.enumerated() {
                    let padded = row + Array(repeating: "", count: max(0, columnCount - row.count))
                    var attrs: [String: AnyCodable] = [
                        "row": AnyCodable(.int(Int64(r))),
                        "isHeader": AnyCodable(.bool(r == 0)),
                        "cells": AnyCodable(.array(padded.map { .string($0) }))]
                    // PAR-005 — carry per-cell formulas so a formula-vs-value query can
                    // distinguish `=A1+B1` from a literal, WITHOUT altering the cell text
                    // above. Only attached when the row actually has a formula.
                    let formulas = r < formulaRows.count ? formulaRows[r] : []
                    if formulas.contains(where: { !$0.isEmpty }) {
                        let paddedF = formulas + Array(repeating: "", count: max(0, columnCount - formulas.count))
                        attrs["cellFormulas"] = AnyCodable(.array(paddedF.map { .string($0) }))
                    }
                    add(.spreadsheetRow, padded.joined(separator: " | "),
                        SourceLocator(row: r, sheet: name), attrs)
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

    /// Rows of cell strings for a worksheet (shared-string + inline resolved).
    static func parseSheetRows(_ data: Data, sharedStrings: [String]) -> [[String]] {
        let xml = String(decoding: data, as: UTF8.self)
        var rows: [[String]] = []
        var cursor = xml.startIndex
        while cursor < xml.endIndex {
            guard let rowOpen = xml.range(of: "<row", range: cursor..<xml.endIndex),
                  let rowClose = xml.range(of: "</row>", range: rowOpen.upperBound..<xml.endIndex) else { break }
            let row = String(xml[rowOpen.upperBound..<rowClose.lowerBound])
            var cells: [String] = []
            var inner = row.startIndex
            while inner < row.endIndex {
                guard let cellOpen = row.range(of: "<c", range: inner..<row.endIndex),
                      let cellGT = row.range(of: ">", range: cellOpen.upperBound..<row.endIndex) else { break }
                let header = String(row[cellOpen.upperBound..<cellGT.lowerBound])
                let selfClosing = header.hasSuffix("/")
                let body: String
                let advance: String.Index
                if selfClosing {
                    body = ""; advance = cellGT.upperBound
                } else if let end = row.range(of: "</c>", range: cellGT.upperBound..<row.endIndex) {
                    body = String(row[cellGT.upperBound..<end.lowerBound]); advance = end.upperBound
                } else {
                    body = ""; advance = cellGT.upperBound
                }
                let plain = DocxLoader.stripTags(body)
                if header.contains("t=\"s\""), let idx = Int(plain.trimmingCharacters(in: .whitespaces)),
                   idx >= 0, idx < sharedStrings.count {
                    cells.append(sharedStrings[idx])
                } else {
                    cells.append(plain)
                }
                inner = advance
            }
            rows.append(cells)
            cursor = rowClose.upperBound
        }
        return rows
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
        let xml = String(decoding: data, as: UTF8.self)
        var rows: [[String]] = []
        var cursor = xml.startIndex
        while cursor < xml.endIndex {
            guard let rowOpen = xml.range(of: "<row", range: cursor..<xml.endIndex),
                  let rowClose = xml.range(of: "</row>", range: rowOpen.upperBound..<xml.endIndex) else { break }
            let row = String(xml[rowOpen.upperBound..<rowClose.lowerBound])
            var formulas: [String] = []
            var inner = row.startIndex
            while inner < row.endIndex {
                guard let cellOpen = row.range(of: "<c", range: inner..<row.endIndex),
                      let cellGT = row.range(of: ">", range: cellOpen.upperBound..<row.endIndex) else { break }
                let header = String(row[cellOpen.upperBound..<cellGT.lowerBound])
                let advance: String.Index
                let body: String
                if header.hasSuffix("/") {
                    body = ""; advance = cellGT.upperBound
                } else if let end = row.range(of: "</c>", range: cellGT.upperBound..<row.endIndex) {
                    body = String(row[cellGT.upperBound..<end.lowerBound]); advance = end.upperBound
                } else {
                    body = ""; advance = cellGT.upperBound
                }
                formulas.append(cellFormula(inBody: body) ?? "")
                inner = advance
            }
            rows.append(formulas)
            cursor = rowClose.upperBound
        }
        return rows
    }
}
