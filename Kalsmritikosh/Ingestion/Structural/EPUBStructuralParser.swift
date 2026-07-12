//
//  EPUBStructuralParser.swift
//  Kalsmritikosh
//
//  A3 — EPUB into structured EvidenceBlocks in reading order. Resolves the OPF
//  spine (reusing EpubLoader.opfPath/parseOPF), then walks each spine chapter's
//  XHTML body in document order emitting typed blocks: headings → sectionHeading
//  (with a running sectionPath), <p> → paragraph, <li> → listItem, <blockquote>
//  → quote. The book's dc:title becomes a documentTitle block. Each block
//  carries a locator with the chapter's archive-member path + section path +
//  per-chapter paragraph index, so a citation reopens the exact chapter and
//  spot. Deterministic, zero-LLM.
//

import Foundation
import CryptoKit

public struct EPUBStructuralParser: StructuralParser {
    public nonisolated var supportedTypes: Set<SourceType> { [.epub] }
    public nonisolated var parserName: String { "epub-opf" }
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
            .appendingPathComponent("epub-\(UUID().uuidString).epub")
        try data.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        var blocks: [EvidenceBlock] = []
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
            let containerData = try zip.read("META-INF/container.xml")
            guard let opfPath = EpubLoader.opfPath(from: containerData) else {
                return Self.empty(documentID, logicalSourceID, sourceVersionID, filename, hash, [
                    ParserWarning(severity: .error, code: "epub.no_rootfile", message: "container.xml has no rootfile path.")
                ], .corrupt)
            }
            let opfData = try zip.read(opfPath)
            let opfDir = (opfPath as NSString).deletingLastPathComponent
            let (manifest, spine, title) = EpubLoader.parseOPF(opfData)
            guard !spine.isEmpty else {
                return Self.empty(documentID, logicalSourceID, sourceVersionID, filename, hash, [
                    ParserWarning(severity: .error, code: "epub.empty_spine", message: "OPF spine is empty.")
                ], .corrupt)
            }

            if let title, !title.isEmpty {
                add(.documentTitle, title, SourceLocator(sectionPath: [title]))
            }

            var chapter = 0
            for idref in spine {
                guard let href = manifest[idref] else { continue }
                let chapterPath = opfDir.isEmpty ? href : "\(opfDir)/\(href)"
                guard let chapterData = try? zip.read(chapterPath) else { continue }
                let htmlBlocks = Self.htmlBlocks(String(decoding: chapterData, as: UTF8.self))
                guard !htmlBlocks.isEmpty else { continue }
                chapter += 1
                var sectionStack: [String] = []
                var paragraphIndex = 0
                for hb in htmlBlocks {
                    let attrs: [String: AnyCodable] = ["chapter": AnyCodable(.int(Int64(chapter)))]
                    if let level = hb.headingLevel {
                        if sectionStack.count >= level { sectionStack.removeSubrange((level - 1)..<sectionStack.count) }
                        while sectionStack.count < level - 1 { sectionStack.append("") }
                        sectionStack.append(hb.text)
                        let path = sectionStack.filter { !$0.isEmpty }
                        add(.sectionHeading, hb.text,
                            SourceLocator(sectionPath: path, archiveMemberPath: chapterPath), attrs)
                    } else {
                        let path = sectionStack.filter { !$0.isEmpty }
                        add(hb.kind, hb.text,
                            SourceLocator(sectionPath: path.isEmpty ? nil : path,
                                          paragraphIndex: paragraphIndex,
                                          archiveMemberPath: chapterPath), attrs)
                        paragraphIndex += 1
                    }
                }
            }
        } catch {
            return Self.empty(documentID, logicalSourceID, sourceVersionID, filename, hash, [
                ParserWarning(severity: .error, code: "epub.unreadable", message: "\(error)")
            ], .corrupt)
        }

        let status: ExtractionStatus = blocks.isEmpty ? .empty : .complete
        return ParsedDocument(
            id: documentID, logicalSourceID: logicalSourceID, sourceVersionID: sourceVersionID,
            filename: filename, detectedType: .epub, mimeType: "application/epub+zip",
            contentHash: hash, blocks: blocks, extractionStatus: status
        )
    }

    private static func empty(_ id: UUID, _ logical: UUID, _ version: UUID, _ filename: String,
                              _ hash: String, _ warnings: [ParserWarning], _ status: ExtractionStatus) -> ParsedDocument {
        ParsedDocument(id: id, logicalSourceID: logical, sourceVersionID: version, filename: filename,
                       detectedType: .epub, contentHash: hash, blocks: [], warnings: warnings, extractionStatus: status)
    }

    // MARK: - XHTML reading-order parsing (pure)

    struct HTMLBlock {
        let tag: String
        let text: String
        var headingLevel: Int? {
            guard tag.count == 2, tag.hasPrefix("h"), let n = Int(tag.dropFirst()) else { return nil }
            return (1...6).contains(n) ? n : nil
        }
        var kind: EvidenceBlockKind {
            switch tag {
            case "li": return .listItem
            case "blockquote": return .quote
            default: return .paragraph
            }
        }
    }

    /// Block-level elements in true document order. At each cursor position it
    /// picks the NEAREST opening block tag (not all-of-one-tag-then-the-next),
    /// so headings and paragraphs interleave correctly. Nested blocks collapse
    /// into their outer block (cursor jumps past the outer close).
    static func htmlBlocks(_ html: String) -> [HTMLBlock] {
        // Scope to <body> when present to drop <head> script/style noise.
        var scope = html
        if let bodyOpen = html.range(of: "<body"),
           let bodyHead = html.range(of: ">", range: bodyOpen.upperBound..<html.endIndex),
           let bodyClose = html.range(of: "</body>", range: bodyHead.upperBound..<html.endIndex) {
            scope = String(html[bodyHead.upperBound..<bodyClose.lowerBound])
        }
        let blockTags = ["h1", "h2", "h3", "h4", "h5", "h6", "p", "li", "blockquote"]
        var out: [HTMLBlock] = []
        var cursor = scope.startIndex
        while cursor < scope.endIndex {
            var best: (tag: String, head: Range<String.Index>, openLower: String.Index)?
            for tag in blockTags {
                guard let o = scope.range(of: "<\(tag)", range: cursor..<scope.endIndex),
                      let head = scope.range(of: ">", range: o.upperBound..<scope.endIndex) else { continue }
                // Real tag boundary: char after the name is a space, '>' or '/'.
                let after = scope[o.upperBound]
                guard after == " " || after == ">" || after == "/" || after == "\n" || after == "\t" else { continue }
                if best == nil || o.lowerBound < best!.openLower {
                    best = (tag, head, o.lowerBound)
                }
            }
            guard let b = best,
                  let close = scope.range(of: "</\(b.tag)>", range: b.head.upperBound..<scope.endIndex) else { break }
            let body = String(scope[b.head.upperBound..<close.lowerBound])
            let plain = DocxLoader.stripTags(body).trimmingCharacters(in: .whitespacesAndNewlines)
            if !plain.isEmpty { out.append(HTMLBlock(tag: b.tag, text: plain)) }
            cursor = close.upperBound
        }
        return out
    }
}
