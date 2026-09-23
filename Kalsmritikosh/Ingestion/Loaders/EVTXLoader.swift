//
//  EVTXLoader.swift
//  Kalsmritikosh
//
//  HOST-3 — searchable-text surface for a Windows event log, produced BY the
//  structural parser and joined, so the searchable text and the citable blocks
//  cannot disagree. Its own loader for the same reason PlistLoader and
//  RegistryHiveLoader have one: the bytes are binary, and TextLoader would either
//  throw or hand back mojibake the adapter would mistake for usable text.
//
//  The joined text INCLUDES the limitation paragraph, deliberately. A retrieved
//  answer built from this log should be able to quote what the log could not say.
//

import Foundation

public struct EVTXLoader: Ingestor {
    public let supportedTypes: Set<SourceType> = [.eventLog]

    private let parser = EVTXStructuralParser()

    public nonisolated init() {}

    public func ingest(fileAt url: URL, type: SourceType) async throws -> KnowledgeObject {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { throw IngestorError.unreadable(url, underlying: error) }

        let parsed = try await parser.parse(
            data: data, filename: url.lastPathComponent, type: .eventLog,
            logicalSourceID: UUID(), sourceVersionID: UUID())

        if parsed.extractionStatus == .corrupt {
            throw IngestorError.unreadable(url, underlying: NSError(
                domain: "Kalsmritikosh.EVTXLoader", code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                            parsed.warnings.first?.message ?? "not a readable Windows event log"]))
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
                "loader": AnyCodable(.string("windows-eventlog-evtx")),
                "recordCount": AnyCodable(.int(Int64(parsed.blocks.filter { $0.kind == .logRecord }.count)))
            ],
            // Medium, never high: the container is exact but the record content is
            // uninterpreted, and the confidence should say so.
            confidence: .medium
        )
    }
}
