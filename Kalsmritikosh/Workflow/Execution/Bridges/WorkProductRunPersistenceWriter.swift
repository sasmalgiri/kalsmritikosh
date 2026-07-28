//
//  WorkProductRunPersistenceWriter.swift
//  Kalsmritikosh
//
//  PJE-006C — the ONE shared SQL implementation that persists an immutable
//  WorkProductRun (run + sections + claim occurrences + manifest).
//
//  Used by BOTH:
//   • WorkProductRunRepository.save (the standalone OPS-004 path), and
//   • WorkflowRunRepository.applyWorkProductBuild (the workflow-coordinated path,
//     inside the SAME SAVEPOINT as the artifact link, step-state update and event).
//
//  This is one shared persistence implementation — not a second store.
//  Callers own the SAVEPOINT; this writer only issues the INSERTs.
//

import Foundation

internal enum WorkProductRunPersistenceWriter {

    /// Insert the immutable work-product run and all child rows.
    /// `runID` is the work-product run's ID (supplied so a coordinated caller can
    /// link the workflow artifact to it inside the same SAVEPOINT).
    @discardableResult
    static func insert(
        assembled: AssembledWorkProduct,
        runID: UUID,
        workspaceID: UUID,
        subjectLabel: String,
        corpusSnapshotID: UUID?,
        database: isolated Database
    ) throws -> WorkProductRun {
        let wp = assembled.workProduct
        let mf = assembled.manifest
        let composedAt = mf.exportedAt
        let findingCount = mf.selectedFindingCount
        let encoder = JSONEncoder()

        let run = WorkProductRun(
            id: runID, workspaceID: workspaceID,
            template: wp.template, title: wp.title,
            subtitle: wp.subtitle, subjectLabel: subjectLabel,
            corpusSnapshotID: corpusSnapshotID,
            schemaVersion: mf.schemaVersion, appVersion: mf.appVersion,
            composedAt: composedAt, findingCount: findingCount,
            disclaimer: wp.disclaimer)

        try database.exec("""
        INSERT INTO work_product_runs
            (id, workspace_id, template, title, subtitle, subject_label,
             corpus_snapshot_id, schema_version, app_version, composed_at,
             finding_count, disclaimer)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?);
        """, [.uuid(runID), .uuid(workspaceID),
              .text(wp.template.rawValue), .text(wp.title),
              .optionalText(wp.subtitle), .text(subjectLabel),
              corpusSnapshotID.map { SQLValue.text($0.uuidString) } ?? .null,
              .integer(Int64(mf.schemaVersion)), .text(mf.appVersion),
              .real(composedAt.timeIntervalSince1970),
              .integer(Int64(findingCount)), .optionalText(wp.disclaimer)])

        for (sIdx, section) in wp.sections.enumerated() {
            let sectionID = UUID()
            let preambleJSON = (try? encoder.encode(section.preamble))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
            try database.exec("""
            INSERT INTO work_product_sections (id, run_id, ordinal, title, preamble)
            VALUES (?,?,?,?,?);
            """, [.uuid(sectionID), .uuid(runID),
                  .integer(Int64(sIdx)), .text(section.title), .text(preambleJSON)])

            for (cIdx, claim) in section.claims.enumerated() {
                let supJSON = (try? encoder.encode(claim.supporting))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
                let conJSON = (try? encoder.encode(claim.contradicting))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
                try database.exec("""
                INSERT INTO work_product_claim_occurrences
                    (id, section_id, run_id, ordinal, text, epistemic_status,
                     confidence, review_state, source_claim_id,
                     assertability_decision, supporting_json, contradicting_json)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?);
                """, [.uuid(claim.id), .uuid(sectionID), .uuid(runID),
                      .integer(Int64(cIdx)), .text(claim.text),
                      .text(claim.status.rawValue),
                      claim.confidence.map { SQLValue.real($0) } ?? .null,
                      .optionalText(claim.reviewState),
                      claim.sourceClaimID.map { SQLValue.text($0.uuidString) } ?? .null,
                      .optionalText(claim.assertabilityDecision?.rawValue),
                      .text(supJSON), .text(conJSON)])
            }
        }

        let svIDsJSON = (try? encoder.encode(mf.sourceVersionIDs))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let svHashesJSON = (try? encoder.encode(mf.sourceHashes))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let cmJSON = (try? encoder.encode(mf.citationMap))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let arJSON = (try? encoder.encode(mf.appliedRedactions))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let klJSON = (try? encoder.encode(mf.knownLimitations))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

        try database.exec("""
        INSERT INTO work_product_manifests
            (run_id, exported_at, workspace_title, workspace_template,
             source_version_ids, source_hashes, selected_finding_count,
             citation_map_json, applied_redactions_json,
             review_status_summary, known_limitations_json)
        VALUES (?,?,?,?,?,?,?,?,?,?,?);
        """, [.uuid(runID), .real(composedAt.timeIntervalSince1970),
              .optionalText(mf.workspaceTitle), .optionalText(mf.workspaceTemplate),
              .text(svIDsJSON), .text(svHashesJSON),
              .integer(Int64(findingCount)), .text(cmJSON), .text(arJSON),
              .optionalText(mf.reviewStatusSummary), .text(klJSON)])

        return run
    }
}
