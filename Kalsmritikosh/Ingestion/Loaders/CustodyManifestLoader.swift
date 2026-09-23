//
//  CustodyManifestLoader.swift
//  Kalsmritikosh
//
//  HOST-8 — searchable-text surface for the chain of custody, produced BY the
//  structural parser and joined, so the searchable text and the citable blocks
//  cannot disagree about who acquired the evidence.
//
//  A manifest whose JSON will not decode is an honest READ FAILURE, not an empty
//  document. Someone intended to document the chain and the documentation cannot
//  be read — that must surface in the lifecycle as a problem, not as a file with
//  nothing in it.
//

import Foundation

public struct CustodyManifestLoader: Ingestor {
    public let supportedTypes: Set<SourceType> = [.custodyManifest]

    private let parser = CustodyManifestStructuralParser()

    public nonisolated init() {}

    public func ingest(fileAt url: URL, type: SourceType) async throws -> KnowledgeObject {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { throw IngestorError.unreadable(url, underlying: error) }

        let parsed = try await parser.parse(
            data: data, filename: url.lastPathComponent, type: .custodyManifest,
            logicalSourceID: UUID(), sourceVersionID: UUID())

        if parsed.extractionStatus == .corrupt {
            throw IngestorError.unreadable(url, underlying: NSError(
                domain: "Kalsmritikosh.CustodyManifestLoader", code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                            parsed.warnings.first?.message
                            ?? "custody manifest is not readable JSON"]))
        }

        let content = parsed.blocks.map(\.rawText).joined(separator: "\n")
        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw IngestorError.empty(url)
        }

        let record = CustodyRecord.decode(data) ?? .undocumented
        var meta: [String: AnyCodable] = [
            "filename": AnyCodable(.string(url.lastPathComponent)),
            "loader": AnyCodable(.string("chain-of-custody")),
            "custodyComplete": AnyCodable(.bool(record.isComplete)),
            "recordStatus": AnyCodable(.string(record.recordStatus.rawValue))
        ]
        if let caseNumber = record.caseNumber { meta["caseNumber"] = AnyCodable(.string(caseNumber)) }
        if let evidence = record.evidenceNumber { meta["evidenceNumber"] = AnyCodable(.string(evidence)) }
        if !record.missingFields.isEmpty {
            meta["custodyMissing"] = AnyCodable(.string(
                record.missingFields.map(\.rawValue).joined(separator: ",")))
        }

        return KnowledgeObject(
            sourceFile: url,
            sourceType: type,
            content: content,
            metadata: meta,
            // An incomplete chain is medium confidence rather than high: the facts
            // are exactly as stated, but the attestation around them is partial.
            confidence: record.isComplete ? .high : .medium)
    }
}
