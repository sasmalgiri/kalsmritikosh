//
//  SpreadsheetLoader.swift
//  Kalsmritikosh
//
//  CSV (full), ODS (ZIP + content.xml), and XLSX (Office Open XML —
//  ZIP + `xl/sharedStrings.xml` + `xl/worksheets/sheet*.xml`).
//
//  Legacy binary .xls (BIFF) remains a metadata-only stub — proper
//  support requires an OLE2 / BIFF parser.
//

import Foundation

public struct SpreadsheetLoader: Ingestor {
    public let supportedTypes: Set<SourceType> = [.csv, .xlsx, .xls, .ods]

    public nonisolated init() {}

    public func ingest(fileAt url: URL, type: SourceType) async throws -> KnowledgeObject {
        switch type {
        case .csv:
            return try ingestCSV(at: url)
        case .xlsx:
            return try ingestXLSX(at: url)
        case .ods:
            return try ingestODS(at: url)
        case .xls:
            // Legacy .xls (BIFF8 / OLE2). Full BIFF-record parsing
            // would be ideal, but the lean scanner over Workbook +
            // SST streams recovers cell text + sheet names well
            // enough for FTS and entity extraction.
            let extraction = try LegacyOfficeScanner.extractText(at: url, kind: .xls)
            if extraction.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw IngestorError.empty(url)
            }
            let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
            let size = (attrs[.size] as? Int64) ?? 0
            return KnowledgeObject(
                sourceFile: url,
                sourceType: .xls,
                content: extraction.text,
                metadata: [
                    "filename": AnyCodable(.string(url.lastPathComponent)),
                    "binarySize": AnyCodable(.int(size)),
                    "loader": AnyCodable(.string("xls-lean-ole2")),
                    "streamsScanned": AnyCodable(.int(Int64(extraction.streamsScanned))),
                    "bytesScanned": AnyCodable(.int(Int64(extraction.bytesScanned))),
                    "runCount": AnyCodable(.int(Int64(extraction.runCount)))
                ],
                confidence: .medium
            )
        default:
            throw IngestorError.unsupportedType(type)
        }
    }

    private func ingestCSV(at url: URL) throws -> KnowledgeObject {
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            throw IngestorError.unreadable(url, underlying: error)
        }
        let raw = String(decoding: data, as: UTF8.self)
        if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw IngestorError.empty(url)
        }
        var normalized = raw
        if normalized.hasPrefix("\u{FEFF}") { normalized.removeFirst() }
        normalized = normalized.replacingOccurrences(of: "\r\n", with: "\n")
        return KnowledgeObject(
            sourceFile: url,
            sourceType: .csv,
            content: normalized,
            metadata: [
                "filename": AnyCodable(.string(url.lastPathComponent)),
                "rowCount": AnyCodable(.int(Int64(normalized.split(separator: "\n").count)))
            ]
        )
    }

    private func ingestXLSX(at url: URL) throws -> KnowledgeObject {
        let zip = try ZIPReader(url: url)
        let entries = try zip.entries()

        // Pull shared strings (XLSX cells can reference an indexed string
        // table instead of writing the text inline).
        var sharedStrings: [String] = []
        if entries.contains(where: { $0.name == "xl/sharedStrings.xml" }) {
            let data = try zip.read("xl/sharedStrings.xml")
            sharedStrings = parseSharedStrings(data)
        }

        // Inspired by openpyxl: workbook.xml maps internal sheet ids to
        // user-visible names ("Sheet1" / "Q1 2024 numbers"). Without
        // this, headers in the KO content are useless paths like
        // "xl/worksheets/sheet1.xml". With it, downstream entity
        // extraction sees real section names.
        var sheetNameByPath: [String: String] = [:]
        if entries.contains(where: { $0.name == "xl/workbook.xml" }) {
            let wbData = try zip.read("xl/workbook.xml")
            sheetNameByPath = parseWorkbookSheetNames(wbData)
        }

        let sheetPaths = entries
            .map(\.name)
            .filter { $0.hasPrefix("xl/worksheets/sheet") && $0.hasSuffix(".xml") }
            .sorted()
        guard !sheetPaths.isEmpty else {
            throw IngestorError.parseFailure(url, reason: "no worksheets in XLSX")
        }

        var lines: [String] = []
        for (index, sheetPath) in sheetPaths.enumerated() {
            let data = try zip.read(sheetPath)
            // Prefer the friendly name; fall back to "Sheet N" for
            // workbooks without the mapping.
            let title = sheetNameByPath[sheetPath]
                ?? sheetNameByPath["sheet\(index + 1)"]
                ?? "Sheet \(index + 1)"
            lines.append("# \(title)")
            lines.append("")
            let tableLines = parseSheetAsMarkdownTable(data, sharedStrings: sharedStrings)
            lines.append(contentsOf: tableLines)
            lines.append("")
        }
        let content = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if content.isEmpty { throw IngestorError.empty(url) }
        return KnowledgeObject(
            sourceFile: url,
            sourceType: .xlsx,
            content: content,
            metadata: [
                "filename": AnyCodable(.string(url.lastPathComponent)),
                "loader": AnyCodable(.string("xlsx-ooxml-v2")),
                "sheetCount": AnyCodable(.int(Int64(sheetPaths.count)))
            ]
        )
    }

    /// Maps the worksheet ZIP path (e.g. "xl/worksheets/sheet3.xml")
    /// to its user-visible sheet name. Workbook order matters because
    /// the OOXML spec assigns sheet1, sheet2, … in declaration order.
    private func parseWorkbookSheetNames(_ data: Data) -> [String: String] {
        let xml = String(decoding: data, as: UTF8.self)
        var map: [String: String] = [:]
        var cursor = xml.startIndex
        var index = 1
        while cursor < xml.endIndex {
            guard let open = xml.range(of: "<sheet ", range: cursor..<xml.endIndex),
                  let close = xml.range(of: "/>", range: open.upperBound..<xml.endIndex)
            else { break }
            let attrs = String(xml[open.upperBound..<close.lowerBound])
            // Pull the name="..." attribute via a small scan.
            if let nameRange = attrs.range(of: "name=\"") {
                let valueStart = nameRange.upperBound
                if let valueEnd = attrs.range(of: "\"", range: valueStart..<attrs.endIndex) {
                    let name = String(attrs[valueStart..<valueEnd.lowerBound])
                    let path = "xl/worksheets/sheet\(index).xml"
                    map[path] = name
                    // Secondary key without the path prefix for fallback.
                    map["sheet\(index)"] = name
                }
            }
            index += 1
            cursor = close.upperBound
        }
        return map
    }

    private func ingestODS(at url: URL) throws -> KnowledgeObject {
        let zip = try ZIPReader(url: url)
        let data = try zip.read("content.xml")
        let content = DocxLoader.stripTags(String(decoding: data, as: UTF8.self))
        if content.isEmpty { throw IngestorError.empty(url) }
        return KnowledgeObject(
            sourceFile: url,
            sourceType: .ods,
            content: content,
            metadata: [
                "filename": AnyCodable(.string(url.lastPathComponent)),
                "loader": AnyCodable(.string("ods-opendocument"))
            ]
        )
    }

    private func binaryStub(at url: URL, type: SourceType, note: String, stubTag: String) -> KnowledgeObject {
        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let size = (attrs[.size] as? Int64) ?? 0
        return KnowledgeObject(
            sourceFile: url,
            sourceType: type,
            content: note,
            metadata: [
                "filename": AnyCodable(.string(url.lastPathComponent)),
                "binarySize": AnyCodable(.int(size)),
                "loaderStub": AnyCodable(.string(stubTag))
            ],
            confidence: .low
        )
    }

    // MARK: - XLSX XML parsing

    /// Reads <si><t>...</t></si> entries from sharedStrings.xml. Cheap
    /// streaming scan; doesn't need a full XML parser.
    private func parseSharedStrings(_ data: Data) -> [String] {
        let xml = String(decoding: data, as: UTF8.self)
        var strings: [String] = []
        var cursor = xml.startIndex
        while cursor < xml.endIndex {
            guard let siOpen = xml.range(of: "<si", range: cursor..<xml.endIndex),
                  let siClose = xml.range(of: "</si>", range: siOpen.upperBound..<xml.endIndex)
            else { break }
            let block = String(xml[siOpen.upperBound..<siClose.lowerBound])
            // Strip <t> wrapping; concatenate all text runs.
            let plain = DocxLoader.stripTags(block)
            strings.append(plain)
            cursor = siClose.upperBound
        }
        return strings
    }

    /// Reads sheet rows and emits a markdown table. The first row is
    /// treated as the header. Inspired by openpyxl + markitdown: real
    /// spreadsheet ingestion preserves the table boundary so downstream
    /// NER + Chunker can treat each row as a structured record (and the
    /// brain can answer "what's in the X column?" questions). Falls
    /// back to no table when the sheet has no rows.
    private func parseSheetAsMarkdownTable(_ data: Data, sharedStrings: [String]) -> [String] {
        let rows = parseSheet(data, sharedStrings: sharedStrings)
        guard !rows.isEmpty else { return [] }
        // Split each tab-joined row back into cells.
        let cells: [[String]] = rows.map { $0.components(separatedBy: "\t") }
        let widest = cells.map(\.count).max() ?? 0
        guard widest > 0 else { return [] }
        let normalized = cells.map { row in
            row + Array(repeating: "", count: max(0, widest - row.count))
        }
        var out: [String] = []
        out.append("| " + normalized[0].joined(separator: " | ") + " |")
        out.append("|" + String(repeating: " --- |", count: widest))
        for row in normalized.dropFirst() {
            out.append("| " + row.joined(separator: " | ") + " |")
        }
        return out
    }

    /// Reads <c t="..."><v>idx</v></c> + inline strings, emits one line
    /// per row with cells separated by `\t`.
    private func parseSheet(_ data: Data, sharedStrings: [String]) -> [String] {
        let xml = String(decoding: data, as: UTF8.self)
        var lines: [String] = []
        var cursor = xml.startIndex
        while cursor < xml.endIndex {
            guard let rowOpen = xml.range(of: "<row", range: cursor..<xml.endIndex),
                  let rowClose = xml.range(of: "</row>", range: rowOpen.upperBound..<xml.endIndex)
            else { break }
            let row = String(xml[rowOpen.upperBound..<rowClose.lowerBound])
            var cellValues: [String] = []
            var inner = row.startIndex
            while inner < row.endIndex {
                guard let cellOpen = row.range(of: "<c", range: inner..<row.endIndex),
                      let cellGT = row.range(of: ">", range: cellOpen.upperBound..<row.endIndex)
                else { break }
                let cellHeader = String(row[cellOpen.upperBound..<cellGT.lowerBound])
                let cellEnd = row.range(of: "</c>", range: cellGT.upperBound..<row.endIndex)
                    ?? row.range(of: "/>", range: cellOpen.upperBound..<cellGT.upperBound)
                let cellBodyStart = cellGT.upperBound
                let cellBodyEnd = cellEnd?.lowerBound ?? cellBodyStart
                let body = String(row[cellBodyStart..<cellBodyEnd])
                let isString = cellHeader.contains("t=\"s\"")
                let isInlineStr = cellHeader.contains("t=\"inlineStr\"")
                let plain = DocxLoader.stripTags(body)
                if isString, let idx = Int(plain.trimmingCharacters(in: .whitespaces)),
                   idx >= 0, idx < sharedStrings.count {
                    cellValues.append(sharedStrings[idx])
                } else if isInlineStr {
                    cellValues.append(plain)
                } else if !plain.isEmpty {
                    cellValues.append(plain)
                }
                inner = (cellEnd?.upperBound) ?? cellGT.upperBound
            }
            if !cellValues.isEmpty {
                lines.append(cellValues.joined(separator: "\t"))
            }
            cursor = rowClose.upperBound
        }
        return lines
    }
}
