//
//  PlistLoader.swift
//  Kalsmritikosh
//
//  HOST-1 — the searchable-text surface for a property list, in any of the three
//  wire formats. A plist needs its OWN loader rather than riding the structural-only
//  TextLoader fallback (as html/json/xml/log/sqlite do), because TextLoader on binary
//  plist bytes is wrong in a way that hides itself. Measured on a 133-byte binary
//  SystemVersion.plist, it does NOT throw (the file is under its 200-scalar binary
//  guard) and returns:
//
//      bplist00Ô…_ProductBuildVersion[ProductNameUCount^ProductVersionV25A354UmacOS\u{10}*T26.0
//
//  Key NAMES survive as ASCII runs, so the text looks plausible enough that
//  ExistingParserPluginAdapter sees "the loader produced text" and skips the
//  structural parse on a `.searchCore` request. But no key is joined to its value
//  and the integer 42 is the byte `\u{10}*`, so the indexed text cannot answer what
//  version the machine ran. A larger plist takes the other branch and THROWS on the
//  replacement-character guard, which the adapter turns into a whole-plugin failure.
//  Both outcomes lose the artifact; hence a real loader.
//
//  The text is produced BY the structural parser and joined, so the searchable
//  surface and the citable blocks can never disagree about what the file said.
//

import Foundation

public struct PlistLoader: Ingestor {
    public let supportedTypes: Set<SourceType> = [.plist]

    private let parser = PlistStructuralParser()

    public nonisolated init() {}

    public func ingest(fileAt url: URL, type: SourceType) async throws -> KnowledgeObject {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { throw IngestorError.unreadable(url, underlying: error) }

        let parsed = try await parser.parse(
            data: data, filename: url.lastPathComponent, type: .plist,
            logicalSourceID: UUID(), sourceVersionID: UUID())

        // An undecodable plist is an honest read failure, not an empty document —
        // the distinction is what the lifecycle surface reports to the examiner.
        if parsed.extractionStatus == .corrupt {
            throw IngestorError.unreadable(url, underlying: NSError(
                domain: "Kalsmritikosh.PlistLoader", code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                            parsed.warnings.first?.message ?? "not a decodable property list"]))
        }

        let content = parsed.blocks.map(\.rawText).joined(separator: "\n")
        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw IngestorError.empty(url)
        }

        return KnowledgeObject(
            sourceFile: url,
            sourceType: type,
            content: content,
            metadata: [
                "filename": AnyCodable(.string(url.lastPathComponent)),
                "loader": AnyCodable(.string("plist")),
                "valueCount": AnyCodable(.int(Int64(parsed.blocks.filter { $0.kind == .tableRow }.count)))
            ],
            confidence: parsed.extractionStatus == .complete ? .high : .medium
        )
    }
}
