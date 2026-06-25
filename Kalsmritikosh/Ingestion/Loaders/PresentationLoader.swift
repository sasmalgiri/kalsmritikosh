//
//  PresentationLoader.swift
//  Kalsmritikosh
//
//  Real PPTX support via ZIPReader (slides under `ppt/slides/slide*.xml`).
//  Legacy .ppt (binary OLE2) and Keynote `.key` packages stay as
//  metadata-only stubs until a dedicated parser lands.
//

import Foundation

public struct PresentationLoader: Ingestor {
    public let supportedTypes: Set<SourceType> = [.pptx, .ppt, .keynote]

    public nonisolated init() {}

    public func ingest(fileAt url: URL, type: SourceType) async throws -> KnowledgeObject {
        switch type {
        case .pptx:
            return try ingestPPTX(at: url)
        case .ppt:
            // Legacy PowerPoint .ppt (OLE2). Atom-record parsing is
            // complex; the lean scanner over PowerPoint Document /
            // Pictures (skipped) / outline streams recovers slide
            // text and speaker notes.
            let extraction = try LegacyOfficeScanner.extractText(at: url, kind: .ppt)
            if extraction.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw IngestorError.empty(url)
            }
            let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
            let size = (attrs[.size] as? Int64) ?? 0
            return KnowledgeObject(
                sourceFile: url,
                sourceType: .ppt,
                content: extraction.text,
                metadata: [
                    "filename": AnyCodable(.string(url.lastPathComponent)),
                    "binarySize": AnyCodable(.int(size)),
                    "loader": AnyCodable(.string("ppt-lean-ole2")),
                    "streamsScanned": AnyCodable(.int(Int64(extraction.streamsScanned))),
                    "bytesScanned": AnyCodable(.int(Int64(extraction.bytesScanned))),
                    "runCount": AnyCodable(.int(Int64(extraction.runCount)))
                ],
                confidence: .medium
            )
        case .keynote:
            // Apple Keynote ships as a bundle (.key directory or
            // tar.gz) — different format entirely. Leave the stub
            // until we wire a real Keynote parser.
            let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
            let size = (attrs[.size] as? Int64) ?? 0
            return KnowledgeObject(
                sourceFile: url,
                sourceType: .keynote,
                content: "Apple Keynote package; native parsing pending.",
                metadata: [
                    "filename": AnyCodable(.string(url.lastPathComponent)),
                    "binarySize": AnyCodable(.int(size)),
                    "loaderStub": AnyCodable(.string("keynote-package"))
                ],
                confidence: .low
            )
        default:
            throw IngestorError.unsupportedType(type)
        }
    }

    private func ingestPPTX(at url: URL) throws -> KnowledgeObject {
        let zip = try ZIPReader(url: url)
        let entries = try zip.entries()
        let slideNames = entries
            .map(\.name)
            .filter { $0.hasPrefix("ppt/slides/slide") && $0.hasSuffix(".xml") }
            .sorted { lhs, rhs in
                slideOrdinal(lhs, prefix: "ppt/slides/slide") <
                slideOrdinal(rhs, prefix: "ppt/slides/slide")
            }
        // Inspired by python-pptx: speaker notes live in a parallel
        // tree under ppt/notesSlides/. Pull them into a per-slide
        // dictionary so they can be emitted right under their slide
        // body — much of the real content of a deck lives in notes.
        var notesBySlide: [Int: String] = [:]
        for entry in entries where entry.name.hasPrefix("ppt/notesSlides/notesSlide") && entry.name.hasSuffix(".xml") {
            let ord = slideOrdinal(entry.name, prefix: "ppt/notesSlides/notesSlide")
            if let data = try? zip.read(entry.name) {
                let text = Self.extractDrawingMLText(data)
                if !text.isEmpty { notesBySlide[ord] = text }
            }
        }
        guard !slideNames.isEmpty else {
            throw IngestorError.parseFailure(url, reason: "no slides in PPTX")
        }
        var pieces: [String] = []
        var slidesWithNotes = 0
        for (i, name) in slideNames.enumerated() {
            let slideNum = i + 1
            let data = try zip.read(name)
            let text = Self.extractDrawingMLText(data)
            pieces.append("# Slide \(slideNum)")
            if !text.isEmpty { pieces.append(text) }
            if let notes = notesBySlide[slideNum], !notes.isEmpty {
                pieces.append("**Speaker notes:**")
                pieces.append(notes)
                slidesWithNotes += 1
            }
        }
        let content = pieces.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if content.isEmpty { throw IngestorError.empty(url) }
        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let size = (attrs[.size] as? Int64) ?? 0
        return KnowledgeObject(
            sourceFile: url,
            sourceType: .pptx,
            content: content,
            metadata: [
                "filename": AnyCodable(.string(url.lastPathComponent)),
                "loader": AnyCodable(.string("pptx-ooxml-v2")),
                "slideCount": AnyCodable(.int(Int64(slideNames.count))),
                "slidesWithNotes": AnyCodable(.int(Int64(slidesWithNotes))),
                "binarySize": AnyCodable(.int(size))
            ]
        )
    }

    private func slideOrdinal(_ name: String, prefix: String) -> Int {
        let stripped = name
            .replacingOccurrences(of: prefix, with: "")
            .replacingOccurrences(of: ".xml", with: "")
        return Int(stripped) ?? 0
    }

    /// PPTX uses DrawingML for text: `<a:p>` paragraphs containing
    /// `<a:r>` runs, each holding `<a:t>` text leaves. We walk the
    /// XML extracting one paragraph per `<a:p>` (separated by blank
    /// lines) so slide bullet points stay as separate text blocks
    /// instead of collapsing into one space-flattened blob — same
    /// boundary preservation the DocxLoader v2 does for `<w:p>`.
    static func extractDrawingMLText(_ data: Data) -> String {
        let xml = String(decoding: data, as: UTF8.self)
        var paragraphs: [String] = []
        var cursor = xml.startIndex
        while cursor < xml.endIndex {
            guard let pOpen = xml.range(of: "<a:p", range: cursor..<xml.endIndex) else { break }
            // Skip self-closing <a:p/> (an empty paragraph).
            let scanFrom = pOpen.upperBound
            guard let pHeadClose = xml.range(of: ">", range: scanFrom..<xml.endIndex) else { break }
            let pClose = xml.range(of: "</a:p>", range: pHeadClose.upperBound..<xml.endIndex)
            let bodyStart = pHeadClose.upperBound
            let bodyEnd = pClose?.lowerBound ?? xml.endIndex
            let body = String(xml[bodyStart..<bodyEnd])
            // Pull <a:t>...</a:t> leaves from this paragraph and
            // concatenate them as one logical paragraph string.
            var runs: [String] = []
            var bcursor = body.startIndex
            while bcursor < body.endIndex {
                guard let tOpen = body.range(of: "<a:t", range: bcursor..<body.endIndex),
                      let tHead = body.range(of: ">", range: tOpen.upperBound..<body.endIndex),
                      let tClose = body.range(of: "</a:t>", range: tHead.upperBound..<body.endIndex)
                else { break }
                let runText = String(body[tHead.upperBound..<tClose.lowerBound])
                runs.append(DocxLoader.stripTags(runText))
                bcursor = tClose.upperBound
            }
            let para = runs.joined(separator: "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !para.isEmpty { paragraphs.append(para) }
            cursor = pClose?.upperBound ?? bodyEnd
        }
        return paragraphs.joined(separator: "\n\n")
    }
}
