//
//  WorkbenchDataQualityAnalyzer.swift
//  Kalsmritikosh
//
//  LAB-005 (Stage C) — collects the DB-backed facts the pure evaluator needs and produces a data-quality
//  report for a dataset (optionally under a scenario). It COMPOSES the existing LAB-001/LAB-003 read
//  paths — WorkbenchDatasetRepository.staleBindings for superseded source versions and
//  WorkbenchScenarioRepository for the scenario projection + which overlay values have been promoted
//  through review — so it introduces no new SQL and never writes: canonical evidence stays read-only.
//  Facts the analyzer cannot yet determine (low OCR, ambiguous identity, unresolved contradictions,
//  workspace-scope completeness) are honestly left to the caller's `extraInputs` rather than guessed.
//

import Foundation

public actor WorkbenchDataQualityAnalyzer {
    private let datasets: WorkbenchDatasetRepository
    private let scenarios: WorkbenchScenarioRepository

    public init(datasets: WorkbenchDatasetRepository, scenarios: WorkbenchScenarioRepository) {
        self.datasets = datasets
        self.scenarios = scenarios
    }

    /// Build the deterministic quality report. `extraInputs` supplies facts from other authorities
    /// (readiness / typed fields / contradictions / workspace scope); the analyzer fills in the stale
    /// source versions and the reviewed-scenario targets it can read itself.
    public func report(datasetID: UUID, scenarioID: UUID? = nil,
                       extraInputs: WorkbenchQualityInputs = WorkbenchQualityInputs()) async throws -> WorkbenchDataQualityReport {
        guard let record = try await datasets.fetch(datasetID: datasetID) else { throw WorkbenchError.datasetNotFound(datasetID) }

        var inputs = extraInputs
        // Superseded source versions bound by this dataset (Gate-6 stale detection, read-only).
        let stale = try await datasets.staleBindings(datasetID: datasetID)
        inputs.staleSourceVersionIDs.formUnion(stale.compactMap { $0.sourceVersionID })

        var projection: WorkbenchScenarioProjection?
        if let sid = scenarioID {
            projection = try await scenarios.projection(scenarioID: sid)
            // Which overlay cells have been promoted through an ACCEPTED review → not "unreviewed".
            let ops = Dictionary(uniqueKeysWithValues: (try await scenarios.operations(scenarioID: sid)).map { ($0.id, $0) })
            for review in try await scenarios.reviews(scenarioID: sid) where review.decision == .accepted {
                if let op = ops[review.operationID], let field = op.fieldID {
                    inputs.reviewedScenarioTargets.insert("\(op.rowID.uuidString)|\(field.uuidString)")
                }
            }
        }

        return WorkbenchDataQualityEvaluator.evaluate(record: record, scenario: projection, scenarioID: scenarioID, inputs: inputs)
    }
}
