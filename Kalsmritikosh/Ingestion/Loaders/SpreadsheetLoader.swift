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

    public init() {}

    public func ingest(fileAt url: URL, type: SourceType) async throws -> KnowledgeObject {
        switch type {
        case .csv:
            return try ingestCSV(at: url)
        case .xlsx:
            return try ingestXLSX(at: url)
        case .ods:
            return try ingestODS(at: url)
        case .xls:
            return binaryStub(at: url, type: .xls, note: "Legacy .xls BIFF binary; OLE2 parsing pending.", stubTag: "xls-legacy")
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

        // Walk every sheet under xl/worksheets/
        let sheetNames = entries
            .map(\.name)
            .filter { $0.hasPrefix("xl/worksheets/sheet") && $0.hasSuffix(".xml") }
            .sorted()
        guard !sheetNames.isEmpty else {
            throw IngestorError.parseFailure(url, reason: "no worksheets in XLSX")
        }

        var lines: [String] = []
        for sheet in sheetNames {
            let data = try zip.read(sheet)
            lines.append("# \(sheet)")
            lines.append(contentsOf: parseSheet(data, sharedStrings: sharedStrings))
        }
        let content = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if content.isEmpty { throw IngestorError.empty(url) }
        return KnowledgeObject(
            sourceFile: url,
            sourceType: .xlsx,
            content: content,
            metadata: [
                "filename": AnyCodable(.string(url.lastPathComponent)),
                "loader": AnyCodable(.string("xlsx-ooxml")),
                "sheetCount": AnyCodable(.int(Int64(sheetNames.count)))
            ]
        )
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
