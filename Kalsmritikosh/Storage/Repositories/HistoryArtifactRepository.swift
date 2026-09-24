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

    /// Story-reviewer loop (module .storyReviewerLoop) — the review ACTION: record
    /// a user's approve/correct/reject verdict on one history item. The outline
    /// builder already HONORS review_status (rejected items are dropped, corrected
    /// items prioritized), so a subsequent render of this artifact reflects the
    /// verdict. Preserve-not-delete: only the derived item's status changes.
    public func setItemReviewStatus(_ status: HistoryReviewStatus, forItemID id: UUID) async throws {
        try await database.exec(
            "UPDATE history_items SET review_status = ? WHERE id = ?;",
            [.text(status.rawValue), .uuid(id)])
    }

    /// Read one item's current review status (nil = item not found).
    public func itemReviewStatus(forItemID id: UUID) async throws -> HistoryReviewStatus? {
        let rows = try await database.query(
            "SELECT review_status FROM history_items WHERE id = ?;", [.uuid(id)])
        return rows.first?.string(0).flatMap(HistoryReviewStatus.init(rawValue:))
    }

    // MARK: - P2.5 · `history_alternative_accounts` gets a writer
    //
    // The table had NO PRODUCER — and `AlternativeAccountsTests` has been green
    // the whole time, because the suite exercises `AlternativeAccountsBuilder`
    // in memory and never persists. `history_items.alternative_account_id` has
    // been waiting for a value since it was added.
    //
    // WHY THIS MATTERS MORE THAN ITS SIZE. An alternative account IS a surfaced
    // conflict — two irreconcilable versions of one field, both evidenced. The
    // owner's standing rule is that conflicting evidence is shown as a conflict
    // with both sources, never averaged away. Without persistence, a conflict
    // detected during one history build vanished when the build ended, so the
    // same contradiction had to be rediscovered every time and could never be
    // referenced, reviewed, or carried into an answer.

    /// One persisted unresolved conflict.
    public struct StoredAlternativeAccount: Sendable {
        public let id: UUID
        public let artifactID: UUID
        /// "<subjectLabel>|<field>" — the conflict's identity.
        public let subject: String
        public let account: AlternativeAccount
        /// What evidence would settle it, when that is known. `nil` means "we
        /// do not know what would resolve this", which is itself honest and
        /// must not be rendered as "nothing would".
        public let decisiveMissingEvidence: String?
    }

    /// Persist the accounts for an artifact and return the id assigned to each,
    /// keyed by "<subjectLabel>|<field>" so the caller can stamp
    /// `history_items.alternative_account_id` on the items involved.
    ///
    /// Replaces the artifact's existing rows first: an artifact's conflict set
    /// is derived, so a rebuild must REPLACE rather than accumulate. That is the
    /// same append-instead-of-replace defect that grew topics 92 -> 143.
    @discardableResult
    public func saveAlternativeAccounts(
        _ accounts: [AlternativeAccount], artifactID: UUID
    ) async throws -> [String: UUID] {
        // Module .historyChapterReadback — OFF skips persistence entirely, so
        // behaviour returns to today's: conflicts are detected per build and
        // not remembered. No partial state either way, because the DELETE is
        // inside the gate with the INSERTs.
        guard KnowledgeModuleFlags.isEnabled(.historyChapterReadback) else { return [:] }
        try await database.exec(
            "DELETE FROM history_alternative_accounts WHERE artifact_id = ?;", [.uuid(artifactID)])
        var ids: [String: UUID] = [:]
        for account in accounts {
            // Only genuine conflicts are persisted. A single version is not an
            // alternative account, and storing one would invent a disagreement.
            guard account.isUnresolved else { continue }
            let key = "\(account.subjectLabel)|\(account.field)"
            let id = UUID()
            let payload = AccountPayload(
                subjectLabel: account.subjectLabel, field: account.field,
                versions: account.versions.map {
                    AccountPayload.Version(value: $0.value,
                                           sourceBlockIDs: $0.sourceBlockIDs,
                                           status: $0.status.rawValue)
                })
            let json = (try? Self.encoder.encode(payload)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            try await database.exec("""
            INSERT OR REPLACE INTO history_alternative_accounts
                (id, artifact_id, subject, account_json, decisive_missing_evidence)
            VALUES (?,?,?,?,NULL);
            """, [.uuid(id), .uuid(artifactID), .text(key), .text(json)])
            ids[key] = id
        }
        return ids
    }

    /// Read the artifact's unresolved conflicts, deterministic order.
    public func alternativeAccounts(artifactID: UUID) async throws -> [StoredAlternativeAccount] {
        let rows = try await database.query("""
        SELECT id, artifact_id, subject, account_json, decisive_missing_evidence
        FROM history_alternative_accounts WHERE artifact_id = ?
        ORDER BY subject ASC;
        """, [.uuid(artifactID)])
        return rows.compactMap { r in
            guard let id = r.uuid(0), let aid = r.uuid(1), let subject = r.string(2),
                  let json = r.string(3),
                  let payload = try? Self.decoder.decode(AccountPayload.self, from: Data(json.utf8))
            else { return nil }
            let account = AlternativeAccount(
                subjectLabel: payload.subjectLabel, field: payload.field,
                versions: payload.versions.map {
                    AccountVersion(value: $0.value, sourceBlockIDs: $0.sourceBlockIDs,
                                   status: EvidenceStatus(rawValue: $0.status) ?? .sourceAsserted)
                })
            return StoredAlternativeAccount(
                id: id, artifactID: aid, subject: subject,
                account: account, decisiveMissingEvidence: r.string(4))
        }
    }

    public func alternativeAccountCount(artifactID: UUID) async throws -> Int {
        Int((try await database.query(
            "SELECT COUNT(*) FROM history_alternative_accounts WHERE artifact_id = ?;", [.uuid(artifactID)]))
            .first?.int(0) ?? 0)
    }

    /// Record what evidence would settle a conflict. Kept separate from the
    /// write because it is usually learned later — and because `nil` must stay
    /// distinguishable from "nothing would resolve it".
    public func setDecisiveMissingEvidence(_ text: String?, forAccountID id: UUID) async throws {
        try await database.exec("""
        UPDATE history_alternative_accounts SET decisive_missing_evidence = ? WHERE id = ?;
        """, [text.map { SQLValue.text($0) } ?? .null, .uuid(id)])
    }

    /// Codable mirror — `AlternativeAccount` is Hashable but not Codable, and
    /// making a domain type Codable purely for one storage shape couples the
    /// two. This keeps the persisted JSON stable even if the domain type moves.
    struct AccountPayload: Codable {
        struct Version: Codable {
            let value: String
            let sourceBlockIDs: [UUID]
            let status: String
        }
        let subjectLabel: String
        let field: String
        let versions: [Version]
    }

    // MARK: - P2.1 · chapters are READ BACK
    //
    // `history_chapters` was written on EVERY history build (see the insert in
    // `save`) and read by nothing. This repository selected history_items,
    // history_artifacts, history_gaps and history_item_evidence — never
    // chapters. So the chaptering work (titles, subtitles, deterministic prose,
    // the model's rendered prose) was computed, persisted, and thrown away.
    //
    // It was invisible because the test that should have caught it is named
    // "Save persists the full graph and reloads" and asserts header, coverage,
    // itemCount, gapCount, evidenceCount and review status — with no chapter
    // assertion and no chapterCount helper to make one with. A suite can be
    // green and still not check the thing its name claims.

    /// One persisted chapter of a history artifact.
    public struct StoredChapter: Sendable, Equatable {
        public let id: UUID
        public let ordinal: Int
        public let title: String
        public let subtitle: String?
        /// The deterministic rendering — always present, always safe to show.
        public let deterministicText: String
        /// The model's prose, when a generative pass ran. `nil` is the ordinary
        /// case and is NOT a defect: the deterministic text is the fallback, so
        /// a chapter is readable with no model available.
        public let generatedText: String?
        public let confidence: Double
    }

    /// Chapters for an artifact, in reading order.
    public func chapters(artifactID: UUID) async throws -> [StoredChapter] {
        // Module .historyChapterReadback — OFF returns no chapters, and the
        // caller falls back to the unchaptered item list, which is what every
        // surface did before this existed. Safe either way.
        guard KnowledgeModuleFlags.isEnabled(.historyChapterReadback) else { return [] }
        let rows = try await database.query("""
        SELECT id, ordinal, title, subtitle, deterministic_text, generated_text, confidence
        FROM history_chapters WHERE artifact_id = ?
        ORDER BY ordinal ASC;
        """, [.uuid(artifactID)])
        return rows.compactMap { r in
            guard let id = r.uuid(0), let title = r.string(2) else { return nil }
            return StoredChapter(
                id: id,
                ordinal: Int(r.int(1) ?? 0),
                title: title,
                subtitle: r.string(3),
                deterministicText: r.string(4) ?? "",
                generatedText: r.string(5),
                confidence: r.double(6) ?? 0)
        }
    }

    /// Chapter count — the helper whose absence let the "full graph" test pass
    /// without ever looking at a chapter.
    public func chapterCount(artifactID: UUID) async throws -> Int {
        Int((try await database.query(
            "SELECT COUNT(*) FROM history_chapters WHERE artifact_id = ?;", [.uuid(artifactID)]))
            .first?.int(0) ?? 0)
    }

    /// The items belonging to one chapter, in insertion order. Chapters are the
    /// grouping the outline computed; without this, an item's chapter_id was
    /// written and unusable.
    public func itemIDs(chapterID: UUID) async throws -> [UUID] {
        let rows = try await database.query(
            "SELECT id FROM history_items WHERE chapter_id = ? ORDER BY rowid ASC;",
            [.uuid(chapterID)])
        return rows.compactMap { $0.uuid(0) }
    }

    /// Chapters WITH their item ids — one call for the surface that renders a
    /// chaptered history, so it does not N+1 its way through the outline.
    public func chaptersWithItems(artifactID: UUID) async throws
    -> [(chapter: StoredChapter, itemIDs: [UUID])] {
        let cs = try await chapters(artifactID: artifactID)
        var out: [(chapter: StoredChapter, itemIDs: [UUID])] = []
        for c in cs {
            out.append((chapter: c, itemIDs: try await itemIDs(chapterID: c.id)))
        }
        return out
    }

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
