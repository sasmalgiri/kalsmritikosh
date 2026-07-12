//
//  CSVStructuralParser.swift
//  Kalsmritikosh
//
//  A3 — CSV into structured spreadsheet EvidenceBlocks (not a flattened blob).
//  Emits one spreadsheetSheet block (headers + shape) and one spreadsheetRow
//  block per row carrying its cells (JSON) with a row/sheet locator, so exact
//  cell / row / sum / filter queries can be answered DETERMINISTICALLY (no LLM)
//  by reading the persisted cells. RFC-4180 aware: quoted fields, escaped
//  quotes, and newlines inside quotes are handled.
//

import Foundation
import CryptoKit

public struct CSVStructuralParser: StructuralParser {
    public nonisolated var supportedTypes: Set<SourceType> { [.csv] }
    public nonisolated var parserName: String { "csv" }
    public nonisolated var parserVersion: String { "1" }

    public nonisolated init() {}

    public func parse(
        data: Data,
        filename: String,
        type: SourceType,
        logicalSourceID: UUID,
        sourceVersionID: UUID
    ) throws -> ParsedDocument {
        let documentID = UUID()
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let text = String(decoding: data, as: UTF8.self)
        let rows = Self.parseCSV(text)
        let sheetName = (filename as NSString).deletingPathExtension

        guard !rows.isEmpty, rows.contains(where: { !$0.allSatisfy(\.isEmpty) }) else {
            return ParsedDocument(
                id: documentID, logicalSourceID: logicalSourceID, sourceVersionID: sourceVersionID,
                filename: filename, detectedType: .csv, mimeType: "text/csv", contentHash: hash,
                blocks: [], extractionStatus: .empty
            )
        }

        let headers = rows[0]
        let columnCount = rows.map(\.count).max() ?? 0
        var blocks: [EvidenceBlock] = []
        var ordinal = 0

        // Sheet block: shape + headers (in attributes for the deterministic path).
        blocks.append(EvidenceBlock(
            documentID: documentID, sourceVersionID: sourceVersionID, ordinal: ordinal,
            kind: .spreadsheetSheet,
            rawText: "Sheet \"\(sheetName)\": \(rows.count) rows × \(columnCount) columns",
            locator: SourceLocator(sheet: sheetName),
            extractionMethod: .native,
            attributes: [
                "rowCount": AnyCodable(.int(Int64(rows.count))),
                "columnCount": AnyCodable(.int(Int64(columnCount))),
                "headers": AnyCodable(.array(headers.map { .string($0) }))
            ]
        ))
        ordinal += 1

        for (r, row) in rows.enumerated() {
            if row.allSatisfy(\.isEmpty) { continue }
            let padded = row + Array(repeating: "", count: max(0, columnCount - row.count))
            blocks.append(EvidenceBlock(
                documentID: documentID, sourceVersionID: sourceVersionID, ordinal: ordinal,
                kind: .spreadsheetRow,
                rawText: padded.joined(separator: " | "),
                locator: SourceLocator(row: r, sheet: sheetName),
                extractionMethod: .native,
                attributes: [
                    "row": AnyCodable(.int(Int64(r))),
                    "isHeader": AnyCodable(.bool(r == 0)),
                    "cells": AnyCodable(.array(padded.map { .string($0) }))
                ]
            ))
            ordinal += 1
        }

        return ParsedDocument(
            id: documentID, logicalSourceID: logicalSourceID, sourceVersionID: sourceVersionID,
            filename: filename, detectedType: .csv, mimeType: "text/csv", contentHash: hash,
            blocks: blocks, extractionStatus: .complete
        )
    }

    // MARK: - RFC-4180 CSV parser (pure)

    /// Parse CSV text into rows of string cells. Handles quoted fields,
    /// escaped quotes (""), and newlines inside quotes. Accepts \n and \r\n.
    static func parseCSV(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var field = ""
        var row: [String] = []
        var inQuotes = false
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" {
                        field.append("\""); i += 2; continue   // escaped quote
                    }
                    inQuotes = false; i += 1; continue
                }
                field.append(c); i += 1; continue
            }
            switch c {
            case "\"":
                inQuotes = true
            case ",":
                row.append(field); field = ""
            case "\r":
                break   // handled with \n
            case "\n":
                row.append(field); field = ""
                rows.append(row); row = []
            default:
                field.append(c)
            }
            i += 1
        }
        // Trailing field/row (no final newline).
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }
}
