//
//  MFTLoader.swift
//  Kalsmritikosh
//
//  HOST-5 — searchable-text surface for an NTFS master file table, produced BY
//  the structural parser and joined, so the searchable text and the citable
//  blocks cannot disagree. Its own loader because the bytes are binary.
//
//  The joined text keeps the DELETED markers and the stale-path notes: a search
//  for a filename must not return a hit that reads as though the file were
//  still there.
//

import Foundation

public struct MFTLoader: Ingestor {
    public let supportedTypes: Set<SourceType> = [.masterFileTable]

    private let parser = MFTStructuralParser()

    public nonisolated init() {}

    public func ingest(fileAt url: URL, type: SourceType) async throws -> KnowledgeObject {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { throw IngestorError.unreadable(url, underlying: error) }

        let parsed = try await parser.parse(
            data: data, filename: url.lastPathComponent, type: .masterFileTable,
            logicalSourceID: UUID(), sourceVersionID: UUID())

        if parsed.extractionStatus == .corrupt {
            throw IngestorError.unreadable(url, underlying: NSError(
                domain: "Kalsmritikosh.MFTLoader", code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                            parsed.warnings.first?.message ?? "not a readable NTFS master file table"]))
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
                "loader": AnyCodable(.string("ntfs-master-file-table")),
                "recordCount": AnyCodable(.int(Int64(parsed.blocks.filter { $0.kind == .logRecord }.count)))
            ],
            confidence: .high
        )
    }
}
