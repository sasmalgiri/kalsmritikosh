//
//  AmcacheLoader.swift
//  Kalsmritikosh
//
//  HOST-6c — searchable-text surface for Amcache, produced BY the structural
//  parser and joined, so the searchable text and the citable blocks cannot
//  disagree. Its own loader because the bytes are a binary registry hive.
//
//  The joined text keeps the "present, not executed" paragraph: the search
//  surface must not be able to imply something the citable blocks refuse to.
//

import Foundation

public struct AmcacheLoader: Ingestor {
    public let supportedTypes: Set<SourceType> = [.amcache]

    private let parser = AmcacheStructuralParser()

    public nonisolated init() {}

    public func ingest(fileAt url: URL, type: SourceType) async throws -> KnowledgeObject {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { throw IngestorError.unreadable(url, underlying: error) }

        let parsed = try await parser.parse(
            data: data, filename: url.lastPathComponent, type: .amcache,
            logicalSourceID: UUID(), sourceVersionID: UUID())

        if parsed.extractionStatus == .corrupt {
            throw IngestorError.unreadable(url, underlying: NSError(
                domain: "Kalsmritikosh.AmcacheLoader", code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                            parsed.warnings.first?.message ?? "not a decodable Amcache hive"]))
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
                "loader": AnyCodable(.string("windows-amcache")),
                "entryCount": AnyCodable(.int(Int64(parsed.blocks.filter { $0.kind == .logRecord }.count)))
            ],
            confidence: .high
        )
    }
}
