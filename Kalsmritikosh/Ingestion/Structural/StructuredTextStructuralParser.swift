//
//  StructuredTextStructuralParser.swift
//  Kalsmritikosh
//
//  PAR-008 — structural adapters for HTML, JSON, XML and log files. Each becomes typed,
//  ordered EvidenceBlocks (not one flat text blob), so citations and exact queries work:
//   • JSON → one block per leaf value, its section path = the key/index path;
//   • HTML/XML → one block per element's text, boilerplate (script/style) dropped;
//   • log  → one `.logRecord` block per line.
//
//  Deterministic, offline. Never throws for empty/partial input — sets extractionStatus.
//

import Foundation
import CryptoKit

public struct StructuredTextStructuralParser: StructuralParser {
    public nonisolated var supportedTypes: Set<SourceType> { [.html, .json, .xml, .log] }
    public nonisolated var parserName: String { "structured-text" }
    public nonisolated var parserVersion: String { "1" }

    public nonisolated init() {}

    public func parse(
        data: Data, filename: String, type: SourceType,
        logicalSourceID: UUID, sourceVersionID: UUID
    ) async throws -> ParsedDocument {
        let documentID = UUID()
        let text = String(decoding: data, as: UTF8.self)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()

        var blocks: [EvidenceBlock] = []
        var warnings: [ParserWarning] = []

        func add(_ kind: EvidenceBlockKind, _ raw: String, path: [String]? = nil) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            blocks.append(EvidenceBlock(
                documentID: documentID, sourceVersionID: sourceVersionID,
                ordinal: blocks.count, kind: kind, rawText: trimmed,
                locator: SourceLocator(sectionPath: (path?.isEmpty ?? true) ? nil : path)))
        }

        switch type {
        case .json:
            if let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
                Self.flattenJSON(obj, path: [], into: { p, v in add(.paragraph, "\(p.joined(separator: ".")): \(v)", path: p) })
            } else {
                warnings.append(ParserWarning(severity: .error, code: "json.invalid", message: "Could not parse JSON."))
            }
        case .html, .xml:
            for (pathParts, elementText) in Self.elementTexts(in: text, isHTML: type == .html) {
                add(.paragraph, elementText, path: pathParts.isEmpty ? nil : pathParts)
            }
        case .log:
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                add(.logRecord, String(line))
            }
        default:
            break
        }

        let status: ExtractionStatus = blocks.isEmpty
            ? (warnings.isEmpty ? .empty : .partial)
            : (warnings.isEmpty ? .complete : .partial)
        return ParsedDocument(
            id: documentID, logicalSourceID: logicalSourceID, sourceVersionID: sourceVersionID,
            filename: filename, detectedType: type, mimeType: Self.mime(for: type),
            contentHash: hash, blocks: blocks, warnings: warnings, extractionStatus: status)
    }

    private nonisolated static func mime(for type: SourceType) -> String {
        switch type {
        case .html: return "text/html"
        case .json: return "application/json"
        case .xml:  return "application/xml"
        case .log:  return "text/plain"
        default:    return "text/plain"
        }
    }

    // MARK: - JSON (pure)

    /// Depth-first flatten to (keyPath, scalarValue) pairs. Objects recurse by key,
    /// arrays by index. Scalars (string/number/bool/null) are the leaves.
    static func flattenJSON(_ value: Any, path: [String], into emit: ([String], String) -> Void) {
        switch value {
        case let dict as [String: Any]:
            for key in dict.keys.sorted() { flattenJSON(dict[key]!, path: path + [key], into: emit) }
        case let arr as [Any]:
            for (i, v) in arr.enumerated() { flattenJSON(v, path: path + ["[\(i)]"], into: emit) }
        case let s as String:
            emit(path.isEmpty ? ["value"] : path, s)
        case let n as NSNumber:
            emit(path.isEmpty ? ["value"] : path, n.stringValue)
        case is NSNull:
            emit(path.isEmpty ? ["value"] : path, "null")
        default:
            emit(path.isEmpty ? ["value"] : path, String(describing: value))
        }
    }

    // MARK: - HTML / XML (pure)

    /// Element text nodes with their tag path. Boilerplate tags (script/style/head for
    /// HTML) are skipped. Simple, dependency-free tag scanner — good enough for citation
    /// blocks; not a validating parser.
    static func elementTexts(in xml: String, isHTML: Bool) -> [(path: [String], text: String)] {
        let skip: Set<String> = isHTML ? ["script", "style", "head", "meta", "link", "noscript"] : []
        var out: [(path: [String], text: String)] = []
        var stack: [String] = []
        var i = xml.startIndex
        var textStart = xml.startIndex
        func flushText(upTo end: String.Index) {
            guard textStart < end else { return }
            if let last = stack.last, skip.contains(last.lowercased()) { return }
            let raw = String(xml[textStart..<end])
            let decoded = Self.decodeEntities(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            if !decoded.isEmpty { out.append((stack, decoded)) }
        }
        while i < xml.endIndex {
            guard let lt = xml.range(of: "<", range: i..<xml.endIndex) else {
                flushText(upTo: xml.endIndex); break
            }
            flushText(upTo: lt.lowerBound)
            guard let gt = xml.range(of: ">", range: lt.upperBound..<xml.endIndex) else { break }
            let tagBody = String(xml[lt.upperBound..<gt.lowerBound])
            if tagBody.hasPrefix("!") || tagBody.hasPrefix("?") {
                // comment / doctype / processing instruction — skip
            } else if tagBody.hasPrefix("/") {
                let name = tagName(tagBody.dropFirst())
                if let idx = stack.lastIndex(of: name) { stack.removeSubrange(idx..<stack.count) }
            } else {
                let name = tagName(Substring(tagBody))
                if !tagBody.hasSuffix("/"), !Self.voidHTMLTags.contains(name.lowercased()) || !isHTML {
                    if !tagBody.hasSuffix("/") { stack.append(name) }
                }
            }
            i = gt.upperBound
            textStart = i
        }
        return out
    }

    private nonisolated static let voidHTMLTags: Set<String> = [
        "area","base","br","col","embed","hr","img","input","link","meta","param","source","track","wbr"
    ]

    private static func tagName(_ body: Substring) -> String {
        let trimmed = body.drop(while: { $0 == " " })
        return String(trimmed.prefix(while: { !$0.isWhitespace && $0 != "/" && $0 != ">" }))
    }

    /// Decode the handful of XML/HTML entities that matter for readable text.
    static func decodeEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&")
         .replacingOccurrences(of: "&lt;", with: "<")
         .replacingOccurrences(of: "&gt;", with: ">")
         .replacingOccurrences(of: "&quot;", with: "\"")
         .replacingOccurrences(of: "&#39;", with: "'")
         .replacingOccurrences(of: "&nbsp;", with: " ")
    }
}
