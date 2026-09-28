//
//  PrefetchLoader.swift
//  Kalsmritikosh
//
//  HOST-6d — searchable-text surface for a Windows prefetch file, produced BY
//  the structural parser and joined, so the searchable text and the citable
//  blocks cannot disagree. Its own loader because the bytes are binary.
//
//  Confidence is HIGH for the uncompressed versions (every field the format
//  defines is read) and MEDIUM for a compressed one, where only the fact of
//  execution survives and the run times do not.
//

import Foundation

public struct PrefetchLoader: Ingestor {
    public let supportedTypes: Set<SourceType> = [.prefetch]

    private let parser = PrefetchStructuralParser()

    public nonisolated init() {}

    public func ingest(fileAt url: URL, type: SourceType) async throws -> KnowledgeObject {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { throw IngestorError.unreadable(url, underlying: error) }

        let parsed = try await parser.parse(
            data: data, filename: url.lastPathComponent, type: .prefetch,
            logicalSourceID: UUID(), sourceVersionID: UUID())

        if parsed.extractionStatus == .corrupt {
            throw IngestorError.unreadable(url, underlying: NSError(
                domain: "Kalsmritikosh.PrefetchLoader", code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                            parsed.warnings.first?.message ?? "not a readable prefetch file"]))
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
                "loader": AnyCodable(.string("windows-prefetch"))
            ],
            confidence: parsed.extractionStatus == .complete ? .high : .medium
        )
    }
}
