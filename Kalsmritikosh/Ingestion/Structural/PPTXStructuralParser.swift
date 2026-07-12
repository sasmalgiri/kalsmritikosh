//
//  PPTXStructuralParser.swift
//  Kalsmritikosh
//
//  A3 — PPTX into structured slide EvidenceBlocks (not one flattened blob).
//  Walks `ppt/slides/slide*.xml` shape-by-shape: a title placeholder becomes a
//  .slideTitle block, every other text shape's paragraphs become .slideBody
//  blocks, and the parallel `ppt/notesSlides/notesSlide*.xml` tree becomes
//  .slideNotes — each with a slide+shape locator so a citation reopens the deck
//  at the exact slide and shape. Reuses the DrawingML paragraph walk pattern the
//  PresentationLoader already proved. Deterministic, zero-LLM.
//

import Foundation
import CryptoKit

public struct PPTXStructuralParser: StructuralParser {
    public nonisolated var supportedTypes: Set<SourceType> { [.pptx] }
    public nonisolated var parserName: String { "pptx-ooxml" }
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

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pptx-\(UUID().uuidString).pptx")
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
            let entries = try zip.entries().map(\.name)
            let slidePaths = entries
                .filter { $0.hasPrefix("ppt/slides/slide") && $0.hasSuffix(".xml") }
                .sorted { Self.ordinal($0, "ppt/slides/slide") < Self.ordinal($1, "ppt/slides/slide") }
            guard !slidePaths.isEmpty else {
                return Self.empty(documentID, logicalSourceID, sourceVersionID, filename, hash, [
                    ParserWarning(severity: .error, code: "pptx.no_slides", message: "No slides in PPTX.")
                ], .corrupt)
            }

            // Speaker notes live in a parallel tree, keyed by slide ordinal.
            var notesBySlide: [Int: String] = [:]
            for name in entries where name.hasPrefix("ppt/notesSlides/notesSlide") && name.hasSuffix(".xml") {
                let ord = Self.ordinal(name, "ppt/notesSlides/notesSlide")
                if let data = try? zip.read(name) {
                    let text = Self.paragraphs(String(decoding: data, as: UTF8.self)).joined(separator: "\n")
                    if !text.isEmpty { notesBySlide[ord] = text }
                }
            }

            for (i, path) in slidePaths.enumerated() {
                let slideNum = i + 1
                let xml = String(decoding: try zip.read(path), as: UTF8.self)
                var shapeIndex = 0
                for shape in Self.shapes(xml) {
                    let paras = Self.paragraphs(shape.body)
                    guard !paras.isEmpty else { continue }
                    shapeIndex += 1
                    let shapeRef = "shape\(shapeIndex)"
                    if shape.isTitle {
                        add(.slideTitle, paras.joined(separator: " "),
                            SourceLocator(slide: slideNum, shape: shapeRef))
                    } else {
                        for para in paras {
                            add(.slideBody, para, SourceLocator(slide: slideNum, shape: shapeRef))
                        }
                    }
                }
                if let notes = notesBySlide[slideNum], !notes.isEmpty {
                    add(.slideNotes, notes, SourceLocator(slide: slideNum, shape: "notes"))
                }
            }
        } catch {
            return Self.empty(documentID, logicalSourceID, sourceVersionID, filename, hash, [
                ParserWarning(severity: .error, code: "pptx.unreadable", message: "\(error)")
            ], .corrupt)
        }

        let status: ExtractionStatus = blocks.isEmpty ? .empty : .complete
        return ParsedDocument(
            id: documentID, logicalSourceID: logicalSourceID, sourceVersionID: sourceVersionID,
            filename: filename, detectedType: .pptx,
            mimeType: "application/vnd.openxmlformats-officedocument.presentationml.presentation",
            contentHash: hash, blocks: blocks, extractionStatus: status
        )
    }

    private static func empty(_ id: UUID, _ logical: UUID, _ version: UUID, _ filename: String,
                              _ hash: String, _ warnings: [ParserWarning], _ status: ExtractionStatus) -> ParsedDocument {
        ParsedDocument(id: id, logicalSourceID: logical, sourceVersionID: version, filename: filename,
                       detectedType: .pptx, contentHash: hash, blocks: [], warnings: warnings, extractionStatus: status)
    }

    // MARK: - DrawingML parsing (pure)

    static func ordinal(_ name: String, _ prefix: String) -> Int {
        Int(name.replacingOccurrences(of: prefix, with: "").replacingOccurrences(of: ".xml", with: "")) ?? 0
    }

    struct Shape { let isTitle: Bool; let body: String }

    /// Split a slide's `<p:spTree>` into its `<p:sp>` shapes, flagging each as a
    /// title placeholder (`<p:ph type="title"/>` or `ctrTitle`). The `body` is
    /// the shape XML, from which `paragraphs(_:)` pulls the text runs.
    static func shapes(_ xml: String) -> [Shape] {
        var result: [Shape] = []
        var cursor = xml.startIndex
        while cursor < xml.endIndex {
            guard let open = xml.range(of: "<p:sp>", range: cursor..<xml.endIndex)
                    ?? xml.range(of: "<p:sp ", range: cursor..<xml.endIndex),
                  let close = xml.range(of: "</p:sp>", range: open.upperBound..<xml.endIndex) else { break }
            let body = String(xml[open.upperBound..<close.lowerBound])
            let isTitle = body.contains("type=\"title\"") || body.contains("type=\"ctrTitle\"")
            result.append(Shape(isTitle: isTitle, body: body))
            cursor = close.upperBound
        }
        return result
    }

    /// One string per `<a:p>` paragraph, concatenating its `<a:t>` run leaves —
    /// same boundary preservation the PresentationLoader does, returned as an
    /// array so each bullet becomes its own evidence block.
    static func paragraphs(_ xml: String) -> [String] {
        var paragraphs: [String] = []
        var cursor = xml.startIndex
        while cursor < xml.endIndex {
            guard let pOpen = xml.range(of: "<a:p", range: cursor..<xml.endIndex),
                  let pHead = xml.range(of: ">", range: pOpen.upperBound..<xml.endIndex) else { break }
            let pClose = xml.range(of: "</a:p>", range: pHead.upperBound..<xml.endIndex)
            let body = String(xml[pHead.upperBound..<(pClose?.lowerBound ?? xml.endIndex)])
            var runs = ""
            var bcursor = body.startIndex
            while bcursor < body.endIndex {
                guard let tOpen = body.range(of: "<a:t", range: bcursor..<body.endIndex),
                      let tHead = body.range(of: ">", range: tOpen.upperBound..<body.endIndex),
                      let tClose = body.range(of: "</a:t>", range: tHead.upperBound..<body.endIndex) else { break }
                runs += DocxLoader.stripTags(String(body[tHead.upperBound..<tClose.lowerBound]))
                bcursor = tClose.upperBound
            }
            let para = runs.trimmingCharacters(in: .whitespacesAndNewlines)
            if !para.isEmpty { paragraphs.append(para) }
            cursor = pClose?.upperBound ?? pHead.upperBound
        }
        return paragraphs
    }
}
