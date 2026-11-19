//
//  CaseCoverageReadout+Load.swift
//  Kalsmritikosh
//
//  Package B's case reading coverage, read from the ledger in one place: the workspace's coverage manifest,
//  limited to the case's authorised source versions. Used by the case overview (AppState.caseCoverage) and
//  by the case evidence search's receipt (M5), so both say the same about what was and was not read.
//  Reads only; no extraction, no writes.
//

import Foundation
import os

extension CaseCoverageReadout {
    /// `caseID` (IN-12): also trace the coverage to the case's intake inventory (`intake`). A failure to read the
    /// inventory is logged and leaves `intake` nil; it never hides the coverage itself.
    public nonisolated static func load(database: Database, workspaceID: UUID, scope: Set<UUID>, caseID: UUID? = nil) async throws -> CaseCoverageReadout {
        let builder = CaseCoverageManifestBuilder(repository: CaseCoverageRepository(database: database),
                                                  readiness: SourceReadinessRepository(database: database),
                                                  container: ContainerInspectionRepository(database: database))
        let manifest = try await builder.build(workspaceID: workspaceID, generatedAt: Date())
        // The case's own versions too: one the manifest does not list is still counted, by name (LS14).
        let ids = manifest.canonicalSources.map(\.sourceVersionID) + manifest.unadmittedContainerMembers.map(\.parentSourceVersionID)
            + Array(scope)
        let coverageRepo = CaseCoverageRepository(database: database)
        let labels = try await coverageRepo.labels(for: ids)
        let logical = try await coverageRepo.logicalSources(for: Array(scope.subtracting(manifest.canonicalSources.map(\.sourceVersionID))))
        let withText = Set(try await KnowledgeObjectRepository(database: database).sourceVersionsByObject(inSourceVersionIDs: scope).values.flatMap { $0 })
        var readout = CaseCoverageReadout.make(manifest: manifest, scope: scope, labels: labels, hasLedgerText: withText, logicalSources: logical)
        if let caseID {
            let intake = await InvestigationWorkspaceIntake(cases: InvestigationCaseRepository(database: database),
                                                      workspaces: WorkspaceRepository(database: database), coverage: coverageRepo)
            do {
                readout.intake = try await intake.reconciliation(caseID: caseID)
            } catch {
                KalsmritikoshLog.app.error("Case intake inventory unavailable: \(String(describing: error), privacy: .public)")
            }
        }
        return readout
    }
}
