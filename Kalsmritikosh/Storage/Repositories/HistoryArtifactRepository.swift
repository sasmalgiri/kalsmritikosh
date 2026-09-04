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
    ///
    /// P4-U1 — two doors, one saver. The Dossier's door keeps the historical
    /// default (`reviewState: "verified"`, no dedup triple). The Ask door
    /// passes `reviewState: "unreviewed"` plus (anchorKey, requestShape,
    /// ledgerStamp) so identical asks on an unchanged ledger dedup instead
    /// of piling up rows.
    @discardableResult
    public func save(_ result: HistoryReconstructionResult,
                     narrative: HistoryNarrative? = nil,
                     title: String? = nil,
                     at now: Date,
                     reviewState: String = "verified",
                     anchorKey: String? = nil,
                     requestShape: String? = nil,
                     ledgerStamp: String? = nil) async throws -> UUID {
        let artifactID = UUID()
        let outline = result.outline
        let subject = outline.subject
        let coverageJSON = Self.json(outline.coverage)
        try await database.exec("""
        INSERT INTO history_artifacts
            (id, subject_kind, subject_id, subject_label, corpus_snapshot_id, engine_version,
             request_json, title, summary, coverage_json, quality_json, created_at, superseded_by,
             review_state, anchor_key, request_shape, ledger_stamp)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,NULL,?,?,?,?);
        """, [
            .uuid(artifactID), .text(subject.subject.kindTag),
            subject.canonicalEntityID.map { SQLValue.uuid($0) } ?? .null,
            .text(subject.displayName),
            outline.corpusSnapshotID.map { SQLValue.uuid($0) } ?? .null,
            .text(result.engineVersion), .text("{}"),
            .text(title ?? "History of \(subject.displayName)"),
            narrative.map { SQLValue.text($0.summary) } ?? .null,
            .text(coverageJSON), .text("{}"), .real(now.timeIntervalSince1970),
            .text(reviewState),
            anchorKey.map { SQLValue.text($0) } ?? .null,
            requestShape.map { SQLValue.text($0) } ?? .null,
            ledgerStamp.map { SQLValue.text($0) } ?? .null
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
            // Write from the CANONICAL assessment (Commit C). review_disposition comes from
            // the assessment's review (already reconciled to the item's reviewStatus); the
            // legacy `review_status` column is preserved. Conflict stays DERIVED
            // (contradiction_group_id), so there is no conflict column here.
            let a = item.assessment
            let enc = LegacyEvidenceStatusAdapter.encode(a)
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
                  .text(temporal), .text(actors), .text(enc.rawValue), .real(item.confidence),
                  item.contradictionGroupID.map { SQLValue.uuid($0) } ?? .null,
                  item.alternativeAccountID.map { SQLValue.uuid($0) } ?? .null,
                  .text(item.reviewStatus.rawValue),
                  .text(a.basis.rawValue), .text(a.review.rawValue), .text(a.origin.rawValue),
                  .text(a.availability.rawValue), .text((a.legacyStatus ?? enc).rawValue)])
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

    /// P4-U1 dedup: the current (non-superseded) artifact for an exact
    /// (anchor, request-shape, ledger version) triple — the same story asked
    /// again on an unchanged ledger returns THIS id instead of a new row.
    public func existingCurrent(anchorKey: String, requestShape: String,
                                ledgerStamp: String) async throws -> UUID? {
        let rows = try await database.query("""
        SELECT id FROM history_artifacts
        WHERE anchor_key = ? AND request_shape = ? AND ledger_stamp = ?
          AND superseded_by IS NULL
        ORDER BY created_at DESC LIMIT 1;
        """, [.text(anchorKey), .text(requestShape), .text(ledgerStamp)])
        return rows.first?.uuid(0)
    }

    /// P4-U1 — the durable ledger stamp: core-table counts plus the ingest
    /// watermark. Changes whenever documents, events, facts, or the entity
    /// register change — exactly the things a story stands on. Durable across
    /// restarts (unlike SQLite's per-connection data_version) and cheap
    /// (COUNT + MAX on indexed tables).
    public func currentLedgerStamp() async throws -> String {
        let row = (try await database.query("""
        SELECT (SELECT COUNT(*) FROM knowledge_objects),
               (SELECT CAST(COALESCE(MAX(updated_at), 0) AS INTEGER) FROM knowledge_objects),
               (SELECT COUNT(*) FROM events),
               (SELECT COUNT(*) FROM generic_facts),
               (SELECT COUNT(*) FROM entities WHERE merged_into IS NULL);
        """, [])).first
        let parts = (0..<5).map { row?.int($0) ?? 0 }
        return "ko:\(parts[0]):\(parts[1])|ev:\(parts[2])|gf:\(parts[3])|en:\(parts[4])"
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
           title, summary, coverage_json, created_at, superseded_by,
           review_state, anchor_key, request_shape, ledger_stamp
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
            supersededBy: r.uuid(10),
            reviewState: r.string(11) ?? "verified", anchorKey: r.string(12),
            requestShape: r.string(13), ledgerStamp: r.string(14))
    }
}
