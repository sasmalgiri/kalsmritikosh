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
    /// "2" — F32: XML via XMLParser (CDATA, entities, encodings), comment/CDATA-safe HTML scanner,
    /// malformed XML reported partial.
    public nonisolated var parserVersion: String { "2" }

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
        case .xml:
            // F32 — a real XML parser (CDATA, entities, declared encoding; external entities
            // never resolved). Not well-formed → the tolerant scanner keeps what it can and
            // the document is marked partial, never complete.
            let parsed = Self.xmlElementTexts(data)
            if let failure = parsed.failure {
                warnings.append(ParserWarning(severity: .warning, code: "xml.malformed",
                    message: "XML is not well-formed (\(failure)); text was recovered with a tolerant scanner and may be incomplete."))
                for (pathParts, elementText) in Self.elementTexts(in: text, isHTML: false, warnings: &warnings) {
                    add(.paragraph, elementText, path: pathParts.isEmpty ? nil : pathParts)
                }
            } else {
                for (pathParts, elementText) in parsed.texts {
                    add(.paragraph, elementText, path: pathParts.isEmpty ? nil : pathParts)
                }
            }
        case .html:
            for (pathParts, elementText) in Self.elementTexts(in: text, isHTML: true, warnings: &warnings) {
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

    /// F32 — element texts through Foundation's `XMLParser`: CDATA kept verbatim, named and
    /// numeric entities decoded, the declared encoding honoured, external entities NEVER
    /// resolved. Text runs are split at element boundaries exactly like the scanner, so the
    /// block shape is the same. `failure` is set when the document is not well-formed.
    static func xmlElementTexts(_ data: Data) -> (texts: [(path: [String], text: String)], failure: String?) {
        let collector = XMLTextCollector()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = false
        parser.delegate = collector
        let ok = parser.parse()
        collector.flush()
        if !ok {
            return (collector.out, parser.parserError.map { "\($0.localizedDescription)" } ?? "parse failed")
        }
        return (collector.out, nil)
    }

    private final class XMLTextCollector: NSObject, XMLParserDelegate {
        var out: [(path: [String], text: String)] = []
        private var stack: [String] = []
        private var buffer = ""

        func flush() {
            let t = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { out.append((stack, t)) }
            buffer = ""
        }
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            flush(); stack.append(elementName)
        }
        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?) {
            flush()
            if let idx = stack.lastIndex(of: elementName) { stack.removeSubrange(idx..<stack.count) }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { buffer += string }
        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            buffer += String(decoding: CDATABlock, as: UTF8.self)
        }
    }

    /// Element text nodes with their tag path. Boilerplate tags (script/style/head for
    /// HTML) are skipped. Simple, dependency-free tag scanner — good enough for citation
    /// blocks; not a validating parser. F32 — comments, CDATA and processing instructions are
    /// delimited by THEIR OWN terminators (a '>' inside them no longer ends them early and
    /// leaks the rest as text); CDATA text is kept; an unterminated construct is a warning.
    static func elementTexts(in xml: String, isHTML: Bool) -> [(path: [String], text: String)] {
        var ignored: [ParserWarning] = []
        return elementTexts(in: xml, isHTML: isHTML, warnings: &ignored)
    }

    static func elementTexts(in xml: String, isHTML: Bool,
                             warnings: inout [ParserWarning]) -> [(path: [String], text: String)] {
        let skip: Set<String> = isHTML ? ["script", "style", "head", "meta", "link", "noscript"] : []
        var out: [(path: [String], text: String)] = []
        var stack: [String] = []
        var i = xml.startIndex
        var textStart = xml.startIndex
        var pending = ""                       // text accumulated across CDATA sections
        func skipped() -> Bool { stack.last.map { skip.contains($0.lowercased()) } ?? false }
        func collect(upTo end: String.Index) {
            guard textStart < end, !skipped() else { return }
            pending += Self.decodeEntities(String(xml[textStart..<end]))
        }
        func flush() {
            let t = pending.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { out.append((stack, t)) }
            pending = ""
        }
        func unterminated(_ what: String) {
            warnings.append(ParserWarning(severity: .warning, code: "markup.unterminated",
                                          message: "Unterminated \(what); the remainder was not read."))
        }
        while i < xml.endIndex {
            guard let lt = xml.range(of: "<", range: i..<xml.endIndex) else {
                collect(upTo: xml.endIndex); break
            }
            collect(upTo: lt.lowerBound)
            let rest = xml[lt.lowerBound...]
            // Constructs with their own terminators — never cut at the first '>'.
            if rest.hasPrefix("<!--") {
                guard let end = xml.range(of: "-->", range: lt.upperBound..<xml.endIndex) else { unterminated("comment"); break }
                i = end.upperBound; textStart = i; continue
            }
            if rest.hasPrefix("<![CDATA[") {
                let open = xml.index(lt.lowerBound, offsetBy: 9)
                guard let end = xml.range(of: "]]>", range: open..<xml.endIndex) else { unterminated("CDATA section"); break }
                if !skipped() { pending += String(xml[open..<end.lowerBound]) }   // verbatim, no entity decoding
                i = end.upperBound; textStart = i; continue
            }
            if rest.hasPrefix("<?") {
                guard let end = xml.range(of: "?>", range: lt.upperBound..<xml.endIndex) else { unterminated("processing instruction"); break }
                i = end.upperBound; textStart = i; continue
            }
            flush()
            guard let gt = xml.range(of: ">", range: lt.upperBound..<xml.endIndex) else { unterminated("tag"); break }
            let tagBody = String(xml[lt.upperBound..<gt.lowerBound])
            if tagBody.hasPrefix("!") {
                // doctype / declaration — skip
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
        flush()
        return out
    }

    private nonisolated static let voidHTMLTags: Set<String> = [
        "area","base","br","col","embed","hr","img","input","link","meta","param","source","track","wbr"
    ]

    private static func tagName(_ body: Substring) -> String {
        let trimmed = body.drop(while: { $0 == " " })
        return String(trimmed.prefix(while: { !$0.isWhitespace && $0 != "/" && $0 != ">" }))
    }

    /// Decode the named entities that matter for readable text plus every numeric reference
    /// (`&#233;` / `&#xE9;`). Single pass, so "&amp;lt;" stays the literal text "&lt;".
    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        let named: [String: String] = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " "]
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            guard s[i] == "&", let semi = s[i...].firstIndex(of: ";"),
                  s.distance(from: i, to: semi) <= 10 else {
                out.append(s[i]); i = s.index(after: i); continue
            }
            let name = s[s.index(after: i)..<semi]
            var replacement: String?
            if name.hasPrefix("#x") || name.hasPrefix("#X") {
                replacement = UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else if name.hasPrefix("#") {
                replacement = UInt32(name.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else {
                replacement = named[String(name)]
            }
            if let replacement {
                out += replacement; i = s.index(after: semi)
            } else {
                out.append(s[i]); i = s.index(after: i)
            }
        }
        return out
    }
}
