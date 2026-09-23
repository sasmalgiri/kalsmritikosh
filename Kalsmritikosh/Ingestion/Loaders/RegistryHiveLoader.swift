//
//  RegistryHiveLoader.swift
//  Kalsmritikosh
//
//  HOST-2 — searchable-text surface for a Windows registry hive. Like PlistLoader,
//  a hive needs its own loader because the bytes are binary: TextLoader would
//  either throw (aborting the whole plugin) or return mojibake that the adapter
//  would mistake for usable text. The text is produced BY the structural parser
//  and joined, so the searchable surface and the citable blocks always agree.
//

import Foundation

public struct RegistryHiveLoader: Ingestor {
    public let supportedTypes: Set<SourceType> = [.registryHive]

    private let parser = RegistryHiveStructuralParser()

    public nonisolated init() {}

    public func ingest(fileAt url: URL, type: SourceType) async throws -> KnowledgeObject {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { throw IngestorError.unreadable(url, underlying: error) }

        let parsed = try await parser.parse(
            data: data, filename: url.lastPathComponent, type: .registryHive,
            logicalSourceID: UUID(), sourceVersionID: UUID())

        if parsed.extractionStatus == .corrupt {
            throw IngestorError.unreadable(url, underlying: NSError(
                domain: "Kalsmritikosh.RegistryHiveLoader", code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                            parsed.warnings.first?.message ?? "not a decodable registry hive"]))
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
                "loader": AnyCodable(.string("windows-registry-regf")),
                "keyCount": AnyCodable(.int(Int64(parsed.blocks.filter { $0.kind == .sectionHeading }.count))),
                "valueCount": AnyCodable(.int(Int64(parsed.blocks.filter { $0.kind == .tableRow }.count)))
            ],
            confidence: parsed.extractionStatus == .complete ? .high : .medium
        )
    }
}
