//
//  UtmpLoader.swift
//  Kalsmritikosh
//
//  HOST-4 — searchable-text surface for Linux login accounting, produced BY the
//  structural parser and joined, so the searchable text and the citable blocks
//  cannot disagree. Its own loader because the bytes are binary: TextLoader
//  would either throw or hand back the fixed-width padding as mojibake, which
//  the plugin adapter would mistake for usable text.
//

import Foundation

public struct UtmpLoader: Ingestor {
    public let supportedTypes: Set<SourceType> = [.loginRecord]

    private let parser = UtmpStructuralParser()

    public nonisolated init() {}

    public func ingest(fileAt url: URL, type: SourceType) async throws -> KnowledgeObject {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { throw IngestorError.unreadable(url, underlying: error) }

        let parsed = try await parser.parse(
            data: data, filename: url.lastPathComponent, type: .loginRecord,
            logicalSourceID: UUID(), sourceVersionID: UUID())

        if parsed.extractionStatus == .corrupt {
            throw IngestorError.unreadable(url, underlying: NSError(
                domain: "Kalsmritikosh.UtmpLoader", code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                            parsed.warnings.first?.message ?? "not readable login accounting"]))
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
                "loader": AnyCodable(.string("linux-login-accounting-utmp")),
                "recordCount": AnyCodable(.int(Int64(parsed.blocks.filter { $0.kind == .logRecord }.count)))
            ],
            // High: every field of every record is decoded exactly, with no
            // uninterpreted layer — the opposite of the event-log case.
            confidence: .high
        )
    }
}
