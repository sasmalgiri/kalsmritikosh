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

    public init() {}

    public func ingest(fileAt url: URL, type: SourceType) async throws -> KnowledgeObject {
        switch type {
        case .pptx:
            return try ingestPPTX(at: url)
        case .ppt, .keynote:
            let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
            let size = (attrs[.size] as? Int64) ?? 0
            return KnowledgeObject(
                sourceFile: url,
                sourceType: type,
                content: type == .ppt
                    ? "Legacy PowerPoint .ppt binary; OLE2 parsing pending."
                    : "Apple Keynote package; native parsing pending.",
                metadata: [
                    "filename": AnyCodable(.string(url.lastPathComponent)),
                    "binarySize": AnyCodable(.int(size)),
                    "loaderStub": AnyCodable(.string(type == .ppt ? "ppt-legacy" : "keynote-package"))
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
                slideOrdinal(lhs) < slideOrdinal(rhs)
            }
        guard !slideNames.isEmpty else {
            throw IngestorError.parseFailure(url, reason: "no slides in PPTX")
        }
        var pieces: [String] = []
        for (i, name) in slideNames.enumerated() {
            let data = try zip.read(name)
            let text = DocxLoader.stripTags(String(decoding: data, as: UTF8.self))
            pieces.append("# Slide \(i + 1)")
            if !text.isEmpty { pieces.append(text) }
        }
        let content = pieces.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if content.isEmpty { throw IngestorError.empty(url) }
        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let size = (attrs[.size] as? Int64) ?? 0
        return KnowledgeObject(
            sourceFile: url,
            sourceType: .pptx,
            content: content,
            metadata: [
                "filename": AnyCodable(.string(url.lastPathComponent)),
                "loader": AnyCodable(.string("pptx-ooxml")),
                "slideCount": AnyCodable(.int(Int64(slideNames.count))),
                "binarySize": AnyCodable(.int(size))
            ]
        )
    }

    private func slideOrdinal(_ name: String) -> Int {
        // ppt/slides/slide12.xml → 12
        let stripped = name
            .replacingOccurrences(of: "ppt/slides/slide", with: "")
            .replacingOccurrences(of: ".xml", with: "")
        return Int(stripped) ?? 0
    }
}
