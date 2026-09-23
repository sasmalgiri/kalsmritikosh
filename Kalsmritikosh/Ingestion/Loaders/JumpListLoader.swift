//
//  JumpListLoader.swift
//  Kalsmritikosh
//
//  HOST-6b — searchable-text surface for a Windows jump list, produced BY the
//  structural parser and joined, so the searchable text and the citable blocks
//  cannot disagree. Its own loader because the bytes are binary.
//

import Foundation

public struct JumpListLoader: Ingestor {
    public let supportedTypes: Set<SourceType> = [.jumpList]

    private let parser = JumpListStructuralParser()

    public nonisolated init() {}

    public func ingest(fileAt url: URL, type: SourceType) async throws -> KnowledgeObject {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { throw IngestorError.unreadable(url, underlying: error) }

        let parsed = try await parser.parse(
            data: data, filename: url.lastPathComponent, type: .jumpList,
            logicalSourceID: UUID(), sourceVersionID: UUID())

        if parsed.extractionStatus == .corrupt {
            throw IngestorError.unreadable(url, underlying: NSError(
                domain: "Kalsmritikosh.JumpListLoader", code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                            parsed.warnings.first?.message ?? "not a readable jump list"]))
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
                "loader": AnyCodable(.string("windows-jump-list"))
            ],
            confidence: .high
        )
    }
}
