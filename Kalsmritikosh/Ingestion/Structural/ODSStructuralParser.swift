//
//  ODSStructuralParser.swift
//  Kalsmritikosh
//
//  A3 — OpenDocument Spreadsheet (.ods) into structured EvidenceBlocks. Reads
//  `content.xml` from the ZIP and walks each `<table:table>` → `<table:table-
//  row>` → `<table:table-cell>`, honoring `table:number-columns-repeated` /
//  `table:number-rows-repeated`, emitting one .spreadsheetSheet block per sheet
//  and one .spreadsheetRow block per row with cells as JSON — the same
//  structured shape as CSV/XLSX so exact cell / row / sum / filter queries are
//  answerable DETERMINISTICALLY (no LLM). Replaces the legacy stripTags flatten.
//

import Foundation
import CryptoKit

public struct ODSStructuralParser: StructuralParser {
    public nonisolated var supportedTypes: Set<SourceType> { [.ods] }
    public nonisolated var parserName: String { "ods-opendocument" }
    public nonisolated var parserVersion: String { "1" }

    // Guard against ODS files that pad rows/columns with huge repeat counts.
    private static let maxRepeat = 4096

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
            .appendingPathComponent("ods-\(UUID().uuidString).ods")
        try data.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        var blocks: [EvidenceBlock] = []
        var ordinal = 0
        func add(_ kind: EvidenceBlockKind, _ text: String, _ locator: SourceLocator, _ attrs: [String: AnyCodable]) {
            blocks.append(EvidenceBlock(
                documentID: documentID, sourceVersionID: sourceVersionID, ordinal: ordinal,
                kind: kind, rawText: text, locator: locator, extractionMethod: .native, attributes: attrs
            ))
            ordinal += 1
        }

        do {
            let zip = try ZIPReader(url: tmp)
            let xml = String(decoding: try zip.read("content.xml"), as: UTF8.self)
            let sheets = Self.sheets(xml)
            guard !sheets.isEmpty else {
                return Self.empty(documentID, logicalSourceID, sourceVersionID, filename, hash, .empty)
            }
            for sheet in sheets {
                let rows = sheet.rows
                let columnCount = rows.map(\.count).max() ?? 0
                let headers = rows.first ?? []
                add(.spreadsheetSheet,
                    "Sheet \"\(sheet.name)\": \(rows.count) rows × \(columnCount) columns",
                    SourceLocator(sheet: sheet.name),
                    ["rowCount": AnyCodable(.int(Int64(rows.count))),
                     "columnCount": AnyCodable(.int(Int64(columnCount))),
                     "headers": AnyCodable(.array(headers.map { .string($0) }))])
                for (r, row) in rows.enumerated() {
                    let padded = row + Array(repeating: "", count: max(0, columnCount - row.count))
                    add(.spreadsheetRow,
                        padded.joined(separator: " | "),
                        SourceLocator(row: r, sheet: sheet.name),
                        ["row": AnyCodable(.int(Int64(r))),
                         "isHeader": AnyCodable(.bool(r == 0)),
                         "cells": AnyCodable(.array(padded.map { .string($0) }))])
                }
            }
        } catch {
            return Self.empty(documentID, logicalSourceID, sourceVersionID, filename, hash, .corrupt)
        }

        return ParsedDocument(
            id: documentID, logicalSourceID: logicalSourceID, sourceVersionID: sourceVersionID,
            filename: filename, detectedType: .ods,
            mimeType: "application/vnd.oasis.opendocument.spreadsheet",
            contentHash: hash, blocks: blocks,
            extractionStatus: blocks.isEmpty ? .empty : .complete
        )
    }

    private static func empty(_ id: UUID, _ logical: UUID, _ version: UUID, _ filename: String,
                              _ hash: String, _ status: ExtractionStatus) -> ParsedDocument {
        ParsedDocument(id: id, logicalSourceID: logical, sourceVersionID: version, filename: filename,
                       detectedType: .ods, contentHash: hash, blocks: [],
                       warnings: status == .corrupt ? [ParserWarning(severity: .error, code: "ods.unreadable", message: "content.xml unreadable")] : [],
                       extractionStatus: status)
    }

    // MARK: - OpenDocument spreadsheet parsing (pure)

    struct Sheet { let name: String; let rows: [[String]] }

    static func sheets(_ xml: String) -> [Sheet] {
        var out: [Sheet] = []
        var cursor = xml.startIndex
        var index = 0
        while cursor < xml.endIndex {
            guard let open = xml.range(of: "<table:table ", range: cursor..<xml.endIndex),
                  let head = xml.range(of: ">", range: open.upperBound..<xml.endIndex),
                  let close = xml.range(of: "</table:table>", range: head.upperBound..<xml.endIndex) else { break }
            index += 1
            let openTag = String(xml[open.lowerBound..<head.upperBound])
            let name = Self.attr(openTag, "table:name") ?? "Sheet \(index)"
            let body = String(xml[head.upperBound..<close.lowerBound])
            out.append(Sheet(name: name, rows: Self.rows(body)))
            cursor = close.upperBound
        }
        return out
    }

    /// Rows for one table body, honoring row/column repeat counts. Trailing
    /// empty cells and trailing empty rows are trimmed so padding doesn't bloat.
    static func rows(_ body: String) -> [[String]] {
        var result: [[String]] = []
        var cursor = body.startIndex
        while cursor < body.endIndex {
            guard let open = body.range(of: "<table:table-row", range: cursor..<body.endIndex),
                  let head = body.range(of: ">", range: open.upperBound..<body.endIndex) else { break }
            let openTag = String(body[open.lowerBound..<head.upperBound])
            let selfClosing = head.lowerBound > body.startIndex && body[body.index(before: head.lowerBound)] == "/"
            let rowBody: String
            let advance: String.Index
            if selfClosing {
                rowBody = ""; advance = head.upperBound
            } else if let close = body.range(of: "</table:table-row>", range: head.upperBound..<body.endIndex) {
                rowBody = String(body[head.upperBound..<close.lowerBound]); advance = close.upperBound
            } else { break }
            let repeatCount = min(Self.maxRepeat, max(1, Self.attrInt(openTag, "table:number-rows-repeated") ?? 1))
            let cells = Self.cells(rowBody)
            // A repeated empty row is padding — keep just one and let trailing
            // trim drop it; a repeated non-empty row is rare but honored (cap).
            let effective = cells.contains(where: { !$0.isEmpty }) ? repeatCount : 1
            for _ in 0..<effective { result.append(cells) }
            cursor = advance
        }
        // Trim trailing empty rows.
        while let last = result.last, last.allSatisfy(\.isEmpty) { result.removeLast() }
        return result
    }

    static func cells(_ rowBody: String) -> [String] {
        var out: [String] = []
        var cursor = rowBody.startIndex
        while cursor < rowBody.endIndex {
            guard let open = rowBody.range(of: "<table:table-cell", range: cursor..<rowBody.endIndex)
                    ?? rowBody.range(of: "<table:covered-table-cell", range: cursor..<rowBody.endIndex),
                  let head = rowBody.range(of: ">", range: open.upperBound..<rowBody.endIndex) else { break }
            let openTag = String(rowBody[open.lowerBound..<head.upperBound])
            let selfClosing = head.lowerBound > rowBody.startIndex && rowBody[rowBody.index(before: head.lowerBound)] == "/"
            var text = ""
            var advance = head.upperBound
            if !selfClosing {
                // Cell close tag matches whichever variant opened it.
                let closeTag = openTag.hasPrefix("<table:covered") ? "</table:covered-table-cell>" : "</table:table-cell>"
                if let close = rowBody.range(of: closeTag, range: head.upperBound..<rowBody.endIndex) {
                    text = DocxLoader.stripTags(String(rowBody[head.upperBound..<close.lowerBound]))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    advance = close.upperBound
                }
            }
            let repeatCount = min(Self.maxRepeat, max(1, Self.attrInt(openTag, "table:number-columns-repeated") ?? 1))
            for _ in 0..<repeatCount { out.append(text) }
            cursor = advance
        }
        // Trim trailing empty cells (ODS pads rows to a fixed width).
        while let last = out.last, last.isEmpty { out.removeLast() }
        return out
    }

    private static func attr(_ tag: String, _ name: String) -> String? {
        guard let r = tag.range(of: "\(name)=\""),
              let end = tag.range(of: "\"", range: r.upperBound..<tag.endIndex) else { return nil }
        return String(tag[r.upperBound..<end.lowerBound])
    }

    private static func attrInt(_ tag: String, _ name: String) -> Int? {
        guard let s = attr(tag, name) else { return nil }
        return Int(s)
    }
}
