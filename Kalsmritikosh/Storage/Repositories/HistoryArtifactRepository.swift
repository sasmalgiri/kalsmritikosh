//
//  HistoryArtifactRepository.swift
//  Kalsmritikosh
//
//  HIST-060/061/063 (Universal History program, Phase 9). Persists a reconstruction
//  result as a versioned artifact (header + chapters + items + evidence + gaps).
//  Rebuild → new artifact + supersede link; the old artifact stays loadable
//  (preserve-not-delete). Raw sqlite3 C-API style; JSON columns with stable coding.
//

import Foundation

public actor HistoryArtifactRepository {
    private let database: Database
    public init(database: Database) { self.database = database }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970; e.outputFormatting = [.sortedKeys]; return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970; return d
    }()

    // MARK: - Save

    /// Persist a reconstruction result + optional rendered narrative as ONE artifact.
    /// Returns the new artifact id.
    @discardableResult
    public func save(_ result: HistoryReconstructionResult,
                     narrative: HistoryNarrative? = nil,
                     title: String? = nil,
                     at now: Date) async throws -> UUID {
        let artifactID = UUID()
        let outline = result.outline
        let subject = outline.subject
        let coverageJSON = Self.json(outline.coverage)
        try await database.exec("""
        INSERT INTO history_artifacts
            (id, subject_kind, subject_id, subject_label, corpus_snapshot_id, engine_version,
             request_json, title, summary, coverage_json, quality_json, created_at, superseded_by)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,NULL);
        """, [
            .uuid(artifactID), .text(subject.subject.kindTag),
            subject.canonicalEntityID.map { SQLValue.uuid($0) } ?? .null,
            .text(subject.displayName),
            outline.corpusSnapshotID.map { SQLValue.uuid($0) } ?? .null,
            .text(result.engineVersion), .text("{}"),
            .text(title ?? "History of \(subject.displayName)"),
            narrative.map { SQLValue.text($0.summary) } ?? .null,
            .text(coverageJSON), .text("{}"), .real(now.timeIntervalSince1970)
        ])

        // Chapter id per ordinal, plus a map item→chapter for item rows.
        var chapterIDByOrdinal: [Int: UUID] = [:]
        var chapterIDForItem: [UUID: UUID] = [:]
        let renderedByOrdinal = Dictionary(uniqueKeysWithValues: (narrative?.chapters ?? []).map { ($0.ordinal, $0.prose) })
        for plan in outline.chapters {
            let cid = UUID()
            chapterIDByOrdinal[plan.ordinal] = cid
            plan.itemIDs.forEach { chapterIDForItem[$0] = cid }
            try await database.exec("""
            INSERT INTO history_chapters (id, artifact_id, ordinal, title, subtitle, deterministic_text, generated_text, confidence)
            VALUES (?,?,?,?,?,?,NULL,?);
            """, [.uuid(cid), .uuid(artifactID), .integer(Int64(plan.ordinal)), .text(plan.title),
                  plan.subtitle.map { SQLValue.text($0) } ?? .null,
                  .text(renderedByOrdinal[plan.ordinal] ?? ""), .real(0.6)])
        }

        for item in outline.items {
            let temporal = Self.json(TemporalPair(start: item.start, end: item.end))
            let actors = Self.json(item.actors)
            // Dual-write (S0.5 item 2, Commit B): keep legacy `status` + `review_status`,
            // and populate the separated dimensions. review_disposition comes from the
            // item's OWN review status (its vocabulary), NOT from the evidence status —
            // the other dimensions come from decoding evidenceStatus. Conflict stays
            // DERIVED (contradiction_group_id), so no conflict column here.
            let a = LegacyEvidenceStatusAdapter.decode(item.evidenceStatus)
            let reviewDisp = Self.reviewDisposition(from: item.reviewStatus)
            try await database.exec("""
            INSERT INTO history_items
                (id, artifact_id, chapter_id, item_kind, title, description, temporal_json,
                 actors_json, status, confidence, contradiction_group_id, alternative_account_id, review_status,
                 evidence_basis, review_disposition, proposal_origin, availability_status, legacy_status)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);
            """, [.uuid(item.id), .uuid(artifactID),
                  chapterIDForItem[item.id].map { SQLValue.uuid($0) } ?? .null,
                  .text(item.kind.rawValue), .text(item.title),
                  item.description.map { SQLValue.text($0) } ?? .null,
                  .text(temporal), .text(actors), .text(item.evidenceStatus.rawValue), .real(item.confidence),
                  item.contradictionGroupID.map { SQLValue.uuid($0) } ?? .null,
                  item.alternativeAccountID.map { SQLValue.uuid($0) } ?? .null,
                  .text(item.reviewStatus.rawValue),
                  .text(a.basis.rawValue), .text(reviewDisp.rawValue), .text(a.origin.rawValue),
                  .text(a.availability.rawValue), .text(item.evidenceStatus.rawValue)])
            for ev in item.evidence {
                try await database.exec("""
                INSERT OR IGNORE INTO history_item_evidence
                    (history_item_id, knowledge_object_id, evidence_block_id, assertion_id,
                     generic_fact_id, event_id, source_version_id, locator_json, evidence_role)
                VALUES (?,?,?,?,?,?,?,NULL,?);
                """, [.uuid(item.id), .uuid(ev.objectID),
                      ev.blockID.map { SQLValue.uuid($0) } ?? .text(""),
                      ev.assertionID.map { SQLValue.uuid($0) } ?? .null,
                      ev.genericFactID.map { SQLValue.uuid($0) } ?? .null,
                      ev.eventID.map { SQLValue.uuid($0) } ?? .null,
                      ev.sourceVersionID.map { SQLValue.uuid($0) } ?? .null,
                      .text(ev.role.rawValue)])
            }
        }

        for gap in outline.gaps {
            try await database.exec("""
            INSERT INTO history_gaps (id, artifact_id, gap_kind, description, temporal_json, expected_evidence_json, confidence, review_status)
            VALUES (?,?,?,?,?,?,?,?);
            """, [.uuid(gap.id), .uuid(artifactID), .text(gap.kind.rawValue), .text(gap.description),
                  gap.affectedPeriod.map { SQLValue.text(Self.json($0)) } ?? .null,
                  .text(Self.json(gap.expectedEvidenceTypes)), .real(gap.confidence),
                  .text(gap.status.rawValue)])
        }
        return artifactID
    }

    // MARK: - Load / query

    public func header(id: UUID) async throws -> HistoryArtifact? {
        let rows = try await database.query("\(Self.headerColumns) FROM history_artifacts WHERE id = ?;", [.uuid(id)])
        return rows.first.flatMap(Self.decodeHeader)
    }

    /// Current (non-superseded) artifacts for a subject, newest first.
    public func current(subjectID: Entity.ID) async throws -> [HistoryArtifact] {
        let rows = try await database.query("""
        \(Self.headerColumns) FROM history_artifacts
        WHERE subject_id = ? AND superseded_by IS NULL ORDER BY created_at DESC;
        """, [.uuid(subjectID)])
        return rows.compactMap(Self.decodeHeader)
    }

    public func supersede(_ oldID: UUID, by newID: UUID, at now: Date) async throws {
        try await database.exec("UPDATE history_artifacts SET superseded_by = ? WHERE id = ?;", [.uuid(newID), .uuid(oldID)])
    }

    public func itemCount(artifactID: UUID) async throws -> Int {
        Int((try await database.query("SELECT COUNT(*) FROM history_items WHERE artifact_id = ?;", [.uuid(artifactID)])).first?.int(0) ?? 0)
    }
    public func gapCount(artifactID: UUID) async throws -> Int {
        Int((try await database.query("SELECT COUNT(*) FROM history_gaps WHERE artifact_id = ?;", [.uuid(artifactID)])).first?.int(0) ?? 0)
    }
    public func evidenceCount(itemID: UUID) async throws -> Int {
        Int((try await database.query("SELECT COUNT(*) FROM history_item_evidence WHERE history_item_id = ?;", [.uuid(itemID)])).first?.int(0) ?? 0)
    }

    // MARK: - Coding

    private struct TemporalPair: Codable { let start: TemporalValue?; let end: TemporalValue? }
    private static func json<T: Encodable>(_ v: T) -> String {
        (try? String(data: encoder.encode(v), encoding: .utf8) ?? "{}") ?? "{}"
    }

    /// Map a history item's own review status → the shared ReviewDisposition vocabulary
    /// (S0.5 item 2). Deterministic, matches the v62 SQL backfill of `review_disposition`.
    nonisolated static func reviewDisposition(from s: HistoryReviewStatus) -> ReviewDisposition {
        switch s {
        case .unreviewed: return .unreviewed
        case .accepted:   return .confirmed
        case .corrected:  return .corrected
        case .rejected:   return .rejected
        }
    }

    private static let headerColumns = """
    SELECT id, subject_kind, subject_id, subject_label, corpus_snapshot_id, engine_version,
           title, summary, coverage_json, created_at, superseded_by
    """
    private nonisolated static func decodeHeader(_ r: SQLRow) -> HistoryArtifact? {
        guard let id = r.uuid(0), let kind = r.string(1), let label = r.string(3),
              let engine = r.string(5), let title = r.string(6),
              let covJSON = r.string(8), let covData = covJSON.data(using: .utf8),
              let coverage = try? decoder.decode(HistoryCoverage.self, from: covData)
        else { return nil }
        return HistoryArtifact(
            id: id, subjectKind: kind, subjectID: r.uuid(2), subjectLabel: label,
            corpusSnapshotID: r.uuid(4), engineVersion: engine, title: title, summary: r.string(7),
            coverage: coverage, createdAt: Date(timeIntervalSince1970: r.double(9) ?? 0),
            supersededBy: r.uuid(10))
    }
}
