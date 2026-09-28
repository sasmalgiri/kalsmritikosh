//
//  ShellLinkLoader.swift
//  Kalsmritikosh
//
//  HOST-6a — searchable-text surface for a Windows shortcut, produced BY the
//  structural parser and joined, so the searchable text and the citable blocks
//  cannot disagree. Its own loader because the bytes are binary: TextLoader
//  would either throw or return the header's padding as mojibake, which the
//  plugin adapter would mistake for usable text.
//
//  The joined text keeps the "this is the TARGET's timestamp, not an access
//  time" wording, deliberately: the searchable surface must not be able to say
//  something the citable blocks refuse to.
//

import Foundation

public struct ShellLinkLoader: Ingestor {
    public let supportedTypes: Set<SourceType> = [.shellLink]

    private let parser = ShellLinkStructuralParser()

    public nonisolated init() {}

    public func ingest(fileAt url: URL, type: SourceType) async throws -> KnowledgeObject {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { throw IngestorError.unreadable(url, underlying: error) }

        let parsed = try await parser.parse(
            data: data, filename: url.lastPathComponent, type: .shellLink,
            logicalSourceID: UUID(), sourceVersionID: UUID())

        if parsed.extractionStatus == .corrupt {
            throw IngestorError.unreadable(url, underlying: NSError(
                domain: "Kalsmritikosh.ShellLinkLoader", code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                            parsed.warnings.first?.message ?? "not a readable Windows shortcut"]))
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
                "loader": AnyCodable(.string("windows-shell-link"))
            ],
            // High: every field reported is read at a fixed offset from a
            // documented structure. What is NOT read (the shell-item id list) is
            // reported as a warning rather than quietly lowering confidence in
            // the fields that were.
            confidence: .high
        )
    }
}
