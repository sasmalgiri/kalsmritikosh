//
//  WorkProductRunRepository.swift
//  Kalsmritikosh
//
//  OPS-004 — persistent, reopenable WorkProductRun ledger (schema v72).
//
//  Guarantees:
//  • SAVEPOINT-atomic: save() writes all four tables or rolls back entirely.
//  • Immutable once saved: runs are never updated; each compose() creates a new run.
//  • Canonical isolation: save/delete never touches claims, events, evidence, or entities.
//  • Reopen fidelity: reopen() reconstructs the exact AssembledWorkProduct that was saved,
//    including full citation records, section preambles, and manifest fields.
//  • Fail-closed: reopen() on an unknown ID throws WorkProductRunError.runNotFound.
//

import Foundation

public enum WorkProductRunError: Error, Equatable {
    case runNotFound(UUID)
}

public actor WorkProductRunRepository {
    private let database: Database

    public init(database: Database) { self.database = database }

    // MARK: - Save

    /// Persist `assembled` as an immutable run record linked to `workspaceID`.
    /// SAVEPOINT-atomic: all four tables written or nothing is written.
    /// PJE-006C: the SQL lives in the SHARED WorkProductRunPersistenceWriter — the
    /// same implementation the workflow-coordinated build path uses. One store.
    @discardableResult
    public func save(
        _ assembled: AssembledWorkProduct,
        workspaceID: UUID,
        subjectLabel: String,
        corpusSnapshotID: UUID? = nil
    ) async throws -> WorkProductRun {
        let runID = UUID()
        let sp = "wpr_save_\(runID.uuidString.replacingOccurrences(of: "-", with: ""))"
        return try await database.withSavepoint(sp) { db in
            try WorkProductRunPersistenceWriter.insert(
                assembled: assembled,
                runID: runID,
                workspaceID: workspaceID,
                subjectLabel: subjectLabel,
                corpusSnapshotID: corpusSnapshotID,
                database: db)
        }
    }

    // MARK: - Reopen

    /// Reconstruct the exact AssembledWorkProduct that was saved under `runID`.
    /// Throws WorkProductRunError.runNotFound when the ID is not in the ledger.
    public func reopen(_ runID: UUID) async throws -> AssembledWorkProduct {
        let runRows = try await database.query("""
        SELECT workspace_id, template, title, subtitle, subject_label,
               corpus_snapshot_id, schema_version, app_version, composed_at,
               finding_count, disclaimer
          FROM work_product_runs WHERE id = ?;
        """, [.uuid(runID)])
        guard let r = runRows.first else { throw WorkProductRunError.runNotFound(runID) }

        let composedAt = Date(timeIntervalSince1970: r.double(8) ?? 0)
        let appVersion = r.string(7) ?? "dev"
        let schemaVersion = Int(r.int(6) ?? 0)
        let template = WorkProductTemplate(rawValue: r.string(1) ?? "") ?? .generalSummary
        let title = r.string(2) ?? ""
        let subtitle = r.string(3)
        let disclaimer = r.string(10)

        let secRows = try await database.query("""
        SELECT id, ordinal, title, preamble
          FROM work_product_sections WHERE run_id = ? ORDER BY ordinal;
        """, [.uuid(runID)])

        var sections: [WorkProductSection] = []
        for secRow in secRows {
            guard let sectionID = secRow.uuid(0) else { continue }
            let secTitle = secRow.string(2) ?? ""
            let preamble = jsonStrings(secRow.string(3))

            let claimRows = try await database.query("""
            SELECT id, ordinal, text, epistemic_status, confidence, review_state,
                   source_claim_id, assertability_decision,
                   supporting_json, contradicting_json
              FROM work_product_claim_occurrences
             WHERE section_id = ? ORDER BY ordinal;
            """, [.uuid(sectionID)])

            var claims: [WorkProductClaim] = []
            for cr in claimRows {
                let claimID = cr.uuid(0) ?? UUID()
                let status = EpistemicStatus(rawValue: cr.string(3) ?? "") ?? .directEvidence
                let confidence = cr.double(4)
                let reviewState = cr.string(5)
                let sourceClaimID = cr.uuid(6)
                let assertabilityDecision = cr.string(7)
                    .flatMap { AssertabilityDecision(rawValue: $0) }
                let supporting = jsonCitations(cr.string(8))
                let contradicting = jsonCitations(cr.string(9))
                claims.append(WorkProductClaim(
                    id: claimID, text: cr.string(2) ?? "",
                    status: status,
                    supporting: supporting, contradicting: contradicting,
                    confidence: confidence, reviewState: reviewState,
                    sourceClaimID: sourceClaimID,
                    assertabilityDecision: assertabilityDecision))
            }
            sections.append(WorkProductSection(
                id: sectionID, title: secTitle,
                preamble: preamble, claims: claims))
        }

        let workProduct = WorkProduct(
            id: runID, template: template, title: title,
            subtitle: subtitle, sections: sections, disclaimer: disclaimer)

        let manifest = try await loadManifest(
            runID: runID, composedAt: composedAt,
            appVersion: appVersion, schemaVersion: schemaVersion)
        return AssembledWorkProduct(workProduct: workProduct, manifest: manifest)
    }

    // MARK: - List

    /// All runs for a workspace, most recent first.
    public func runs(inWorkspace workspaceID: UUID) async throws -> [WorkProductRun] {
        let rows = try await database.query("""
        SELECT id, workspace_id, template, title, subtitle, subject_label,
               corpus_snapshot_id, schema_version, app_version, composed_at,
               finding_count, disclaimer
          FROM work_product_runs
         WHERE workspace_id = ?
         ORDER BY composed_at DESC;
        """, [.uuid(workspaceID)])
        return rows.compactMap { decodeRun($0) }
    }

    // MARK: - Delete

    /// Hard-delete a run and all child rows via CASCADE. Never touches canonical evidence.
    public func delete(_ runID: UUID) async throws {
        try await database.exec(
            "DELETE FROM work_product_runs WHERE id = ?;", [.uuid(runID)])
    }

    // MARK: - Manifest

    /// Load the stored ExportManifest for a run.
    public func manifest(forRun runID: UUID) async throws -> ExportManifest {
        let runRows = try await database.query(
            "SELECT app_version, schema_version, composed_at FROM work_product_runs WHERE id = ?;",
            [.uuid(runID)])
        guard let r = runRows.first else { throw WorkProductRunError.runNotFound(runID) }
        return try await loadManifest(
            runID: runID,
            composedAt: Date(timeIntervalSince1970: r.double(2) ?? 0),
            appVersion: r.string(0) ?? "dev",
            schemaVersion: Int(r.int(1) ?? 0))
    }

    // MARK: - Private helpers

    private func loadManifest(
        runID: UUID, composedAt: Date, appVersion: String, schemaVersion: Int
    ) async throws -> ExportManifest {
        let mfRows = try await database.query("""
        SELECT exported_at, workspace_title, workspace_template,
               source_version_ids, source_hashes, selected_finding_count,
               citation_map_json, applied_redactions_json,
               review_status_summary, known_limitations_json
          FROM work_product_manifests WHERE run_id = ?;
        """, [.uuid(runID)])
        guard let mfRow = mfRows.first else {
            return ExportManifest(exportedAt: composedAt, appVersion: appVersion,
                                  schemaVersion: schemaVersion)
        }
        let exportedAt = Date(timeIntervalSince1970: mfRow.double(0) ?? composedAt.timeIntervalSince1970)
        return ExportManifest(
            exportedAt: exportedAt, appVersion: appVersion, schemaVersion: schemaVersion,
            workspaceTitle: mfRow.string(1), workspaceTemplate: mfRow.string(2),
            sourceVersionIDs: jsonStrings(mfRow.string(3)),
            sourceHashes: jsonStrings(mfRow.string(4)),
            selectedFindingCount: Int(mfRow.int(5) ?? 0),
            citationMap: jsonCitationMap(mfRow.string(6)),
            appliedRedactions: jsonStrings(mfRow.string(7)),
            reviewStatusSummary: mfRow.string(8),
            knownLimitations: jsonStrings(mfRow.string(9)))
    }

    private func decodeRun(_ r: SQLRow) -> WorkProductRun? {
        guard let id = r.uuid(0), let wsID = r.uuid(1),
              let templateStr = r.string(2),
              let template = WorkProductTemplate(rawValue: templateStr) else { return nil }
        return WorkProductRun(
            id: id, workspaceID: wsID, template: template,
            title: r.string(3) ?? "", subtitle: r.string(4),
            subjectLabel: r.string(5) ?? "",
            corpusSnapshotID: r.uuid(6),
            schemaVersion: Int(r.int(7) ?? 0),
            appVersion: r.string(8) ?? "dev",
            composedAt: Date(timeIntervalSince1970: r.double(9) ?? 0),
            findingCount: Int(r.int(10) ?? 0),
            disclaimer: r.string(11))
    }

    private func jsonStrings(_ s: String?) -> [String] {
        guard let s, let data = s.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    private func jsonCitations(_ s: String?) -> [CitationRecord] {
        guard let s, let data = s.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([CitationRecord].self, from: data)) ?? []
    }

    private func jsonCitationMap(_ s: String?) -> [CitationMapEntry] {
        guard let s, let data = s.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([CitationMapEntry].self, from: data)) ?? []
    }
}
