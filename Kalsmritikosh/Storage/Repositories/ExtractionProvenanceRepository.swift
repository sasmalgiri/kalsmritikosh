//
//  ExtractionProvenanceRepository.swift
//  Kalsmritikosh
//
//  Smart-map S2 / SRC-02 — reads the provenance of a passage from the structural evidence layer: the block's
//  extraction method, confidence, language and source version, the reader run that wrote it (v178
//  `evidence_blocks.parser_run_id` → `parser_runs`: reader, reader version, start/end, status, recognition engines)
//  and the version's document profile (coverage). Read-only; raw sqlite3 style through the Database actor.
//

import Foundation

public actor ExtractionProvenanceRepository {
    private let database: Database

    public init(database: Database) { self.database = database }

    /// The provenance of one passage; nil when the block is not in the ledger.
    public func provenance(blockID: UUID) async throws -> ExtractionProvenance? {
        guard let b = try await database.query("""
            SELECT b.id, b.source_version_id, b.extraction_method, b.extraction_confidence, b.language, b.parser_run_id
            FROM evidence_blocks b WHERE b.id = ? LIMIT 1;
            """, [.uuid(blockID)]).first else { return nil }
        let method = b.string(2).flatMap(ExtractionMethod.init(rawValue:))
        return try await assemble(blockID: b.uuid(0), version: b.uuid(1), method: method, confidence: b.double(3), language: b.string(4),
                                  runID: b.uuid(5), mixture: nil)
    }

    /// The provenance of the passage a citation names: its block when known; else the block of the version (or the
    /// document) that holds the quoted words; else the document's passages taken together. Nil when nothing resolves.
    public func provenance(objectID: UUID?, sourceVersionID: UUID?, blockID: UUID?, quote: String?) async throws -> ExtractionProvenance? {
        if let blockID, let p = try await provenance(blockID: blockID) { return p }
        let rows: [SQLRow]
        if let sourceVersionID {
            rows = try await database.query("""
                SELECT b.id, b.raw_text, b.extraction_method FROM evidence_blocks b
                WHERE b.source_version_id = ? AND b.superseded_by_run IS NULL ORDER BY b.ordinal LIMIT 20000;
                """, [.uuid(sourceVersionID)])
        } else if let objectID {
            rows = try await database.query("""
                SELECT b.id, b.raw_text, b.extraction_method FROM evidence_blocks b
                JOIN evidence_block_objects o ON o.evidence_block_id = b.id
                WHERE o.knowledge_object_id = ? AND b.superseded_by_run IS NULL ORDER BY b.ordinal LIMIT 20000;
                """, [.uuid(objectID)])
        } else {
            return nil
        }
        guard !rows.isEmpty else { return nil }
        if let quote = quote?.trimmingCharacters(in: .whitespacesAndNewlines), !quote.isEmpty {
            let needle = StudioEvidenceResolver.norm(quote)
            if let hit = rows.first(where: { StudioEvidenceResolver.norm($0.string(1) ?? "").contains(needle) }), let id = hit.uuid(0) {
                return try await provenance(blockID: id)
            }
        }
        // The document as a whole: the kind most of its passages have, with the mixture said in words.
        var counts: [TextProvenanceKind: Int] = [:]
        for r in rows {
            let kind = r.string(2).flatMap(ExtractionMethod.init(rawValue:)).map(TextProvenanceKind.init(method:)) ?? .original
            counts[kind, default: 0] += 1
        }
        let total = rows.count
        let transformed = total - (counts[.original] ?? 0)
        let kind: TextProvenanceKind = transformed == 0 ? .original
            : (counts.filter { $0.key != .original }.max { $0.value < $1.value }?.key ?? .recognized)
        let parts: [String] = counts.filter { $0.key != .original }.map { "\($0.value) \($0.key.badge.lowercased())" }.sorted()
        let mixture: String
        if transformed == 0 {
            mixture = "All \(total) passage(s) are the file's own text."
        } else if transformed == total {
            mixture = "All \(total) passage(s) are \(kind.badge.lowercased()) — none is the file's own text layer."
        } else {
            mixture = "\(transformed) of \(total) passages are not the file's own text (\(parts.joined(separator: ", "))); the rest are original text."
        }
        // The newest run of the version (the document's own runs when only the document is known).
        var version: UUID? = sourceVersionID
        if version == nil, let first = rows.first?.uuid(0) {
            version = try await database.query("SELECT source_version_id FROM evidence_blocks WHERE id = ? LIMIT 1;", [.uuid(first)]).first?.uuid(0)
        }
        let representative = rows.first { (r: SQLRow) -> Bool in
            (r.string(2).flatMap(ExtractionMethod.init(rawValue:)).map(TextProvenanceKind.init(method:)) ?? .original) == kind
        }
        let method = representative?.string(2).flatMap(ExtractionMethod.init(rawValue:))
        return try await assemble(blockID: nil, version: version, method: method, confidence: nil, language: nil, runID: nil, mixture: mixture)
    }

    private func assemble(blockID: UUID?, version: UUID?, method: ExtractionMethod?, confidence: Double?, language: String?,
                          runID: UUID?, mixture: String?) async throws -> ExtractionProvenance {
        var run: SQLRow?
        var recordedForPassage = runID != nil
        if let runID {
            run = try await database.query("SELECT parser, parser_version, started_at, ended_at, engines, status FROM parser_runs WHERE id = ? LIMIT 1;",
                                           [.uuid(runID)]).first
            if run == nil { recordedForPassage = false }
        }
        if run == nil, let version {
            run = try await database.query("""
                SELECT parser, parser_version, started_at, ended_at, engines, status FROM parser_runs
                WHERE source_version_id = ? ORDER BY started_at DESC, rowid DESC LIMIT 1;
                """, [.uuid(version)]).first
        }
        if blockID == nil { recordedForPassage = true }   // a document-level reading names its newest run as such
        var coverage: String?
        if let version, let p = try await database.query("""
            SELECT extraction_status, block_count, page_count, warning_count FROM document_profiles WHERE source_version_id = ? LIMIT 1;
            """, [.uuid(version)]).first {
            let status = p.string(0).flatMap(ExtractionStatus.init(rawValue:))
            var parts: [String] = [Self.coverageWords(status)]
            if let n = p.int(1) { parts.append("\(n) passage(s)") }
            if let pages = p.int(2) { parts.append("\(pages) page(s)") }
            if let w = p.int(3), w > 0 { parts.append("\(w) reader warning(s)") }
            coverage = parts.joined(separator: " · ")
        } else if let status = run?.string(5).flatMap(ExtractionStatus.init(rawValue:)) {
            coverage = Self.coverageWords(status)
        }
        let engines = ExtractionEngineIdentity.decodeEngines(run?.string(4))
        let kind = method.map(TextProvenanceKind.init(method:)) ?? .original
        return ExtractionProvenance(
            kind: kind, method: method, sourceVersionID: version, blockID: blockID, reader: run?.string(0), readerVersion: run?.string(1),
            engine: method.flatMap { engines[$0.rawValue] },
            extractedAt: run?.date(3) ?? run?.date(2), runRecordedForPassage: recordedForPassage, language: language,
            confidence: confidence, coverage: coverage, mixture: mixture)
    }

    nonisolated static func coverageWords(_ status: ExtractionStatus?) -> String {
        switch status {
        case .complete?: return "complete"
        case .partial?: return "partial — some parts were not read"
        case .unsupported?: return "not read — the format is not supported"
        case .encrypted?: return "not read — the file is encrypted"
        case .corrupt?: return "not read — the file is damaged"
        case .empty?: return "no text found"
        case .deferred?: return "waiting — recognition has not run yet"
        case .failed?: return "the reading failed"
        case nil: return "not recorded"
        }
    }
}
