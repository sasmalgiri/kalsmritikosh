//
//  WorkbenchDataQualityEvaluator.swift
//  Kalsmritikosh
//
//  LAB-005 (Stage C) — the pure, deterministic evaluator that turns a dataset (optionally under a
//  scenario) plus externally-collected facts into a list of evidence-quality warnings. It computes the
//  record-derivable checks itself (missing value, missing custody hash, duplicate source), folds in the
//  externally-collected facts (stale / inaccessible source, low OCR, ambiguous identity, mixed date
//  precision, unsupported transformation, non-independent corroboration, unresolved contradiction,
//  incomplete workspace scope, formula-vs-displayed discrepancy), and — when a scenario is supplied —
//  flags its unreviewed overlay values. Every source-mapped warning carries its exact drill-through
//  lineage. It reads only its inputs: no database, no clock, no mutation of canonical evidence.
//

import Foundation

public nonisolated enum WorkbenchDataQualityEvaluator {

    public nonisolated static func evaluate(record: WorkbenchDatasetRecord,
                                            scenario: WorkbenchScenarioProjection? = nil,
                                            scenarioID: UUID? = nil,
                                            inputs: WorkbenchQualityInputs = WorkbenchQualityInputs()) -> WorkbenchDataQualityReport {
        var warnings: [WorkbenchQualityWarning] = []
        let fieldName = Dictionary(uniqueKeysWithValues: record.fields.map { ($0.id, $0.name) })

        func firstBinding(_ cellID: UUID) -> WorkbenchSourceBinding? { record.bindings(forCell: cellID).first }
        func lineage(_ cellID: UUID) -> EvidenceInspectionTarget? { firstBinding(cellID).map(EvidenceInspectionTarget.from) }

        // MARK: Record-derivable checks

        for cell in record.cells {
            let col = fieldName[cell.fieldID] ?? "field"
            // Missing value — a cell with no value.
            if cell.value == nil || cell.value?.trimmingCharacters(in: .whitespaces).isEmpty == true {
                warnings.append(WorkbenchQualityWarning(kind: .missingValue, severity: .caution,
                                                        targetID: cell.id.uuidString, message: "Missing value in \(col).",
                                                        lineage: lineage(cell.id)))
            }
            // Missing custody hash — a source value with no bound SourceVersion (no custody anchor).
            if cell.kind == .sourceValue {
                let binding = firstBinding(cell.id)
                if binding == nil || binding?.sourceVersionID == nil {
                    warnings.append(WorkbenchQualityWarning(kind: .missingCustodyHash, severity: .caution,
                                                            targetID: cell.id.uuidString,
                                                            message: "Source value in \(col) has no bound source version (no custody hash).",
                                                            lineage: binding.map(EvidenceInspectionTarget.from)))
                }
            }
            // Formula-vs-displayed discrepancy — a stored derived value that no longer matches its formula.
            if inputs.formulaDiscrepancyCellIDs.contains(cell.id) {
                warnings.append(WorkbenchQualityWarning(kind: .formulaVsDisplayedDiscrepancy, severity: .blocking,
                                                        targetID: cell.id.uuidString,
                                                        message: "Displayed value in \(col) does not match its recomputed formula.",
                                                        lineage: lineage(cell.id)))
            }
            // Externally-flagged per-cell facts.
            if inputs.lowOCRCellIDs.contains(cell.id) {
                warnings.append(WorkbenchQualityWarning(kind: .lowOCRConfidence, severity: .caution,
                                                        targetID: cell.id.uuidString, message: "Low OCR confidence for \(col).", lineage: lineage(cell.id)))
            }
            if inputs.ambiguousIdentityCellIDs.contains(cell.id) {
                warnings.append(WorkbenchQualityWarning(kind: .ambiguousIdentity, severity: .caution,
                                                        targetID: cell.id.uuidString, message: "Ambiguous entity identity behind \(col).", lineage: lineage(cell.id)))
            }
            if inputs.nonIndependentCorroborationCellIDs.contains(cell.id) {
                warnings.append(WorkbenchQualityWarning(kind: .nonIndependentCorroboration, severity: .caution,
                                                        targetID: cell.id.uuidString, message: "Corroboration for \(col) is not independent.", lineage: lineage(cell.id)))
            }
        }

        // Duplicate source — the same canonical origin bound to more than one cell.
        var byTarget: [String: [UUID]] = [:]
        for cell in record.cells where cell.kind == .sourceValue {
            if let b = firstBinding(cell.id), b.sourceVersionID != nil {
                byTarget["\(b.targetKind.rawValue)|\(b.targetID)", default: []].append(cell.id)
            }
        }
        for (key, cells) in byTarget where cells.count > 1 {
            for cellID in cells {
                warnings.append(WorkbenchQualityWarning(kind: .duplicateSource, severity: .info,
                                                        targetID: cellID.uuidString,
                                                        message: "The same source (\(key)) backs multiple cells.",
                                                        lineage: lineage(cellID)))
            }
        }

        // MARK: Binding-mapped external facts (stale / inaccessible source versions)

        for binding in record.bindings {
            guard let sv = binding.sourceVersionID else { continue }
            if inputs.staleSourceVersionIDs.contains(sv) {
                warnings.append(WorkbenchQualityWarning(kind: .staleSourceVersion, severity: .caution,
                                                        targetID: binding.cellID.uuidString,
                                                        message: "A bound source version has been superseded.",
                                                        lineage: EvidenceInspectionTarget.from(binding)))
            }
            if inputs.inaccessibleSourceVersionIDs.contains(sv) {
                warnings.append(WorkbenchQualityWarning(kind: .inaccessibleSource, severity: .blocking,
                                                        targetID: binding.cellID.uuidString,
                                                        message: "A bound source is currently inaccessible.",
                                                        lineage: EvidenceInspectionTarget.from(binding)))
            }
        }

        // MARK: Field-level + dataset-level external facts

        for fieldID in inputs.mixedDatePrecisionFieldIDs {
            warnings.append(WorkbenchQualityWarning(kind: .mixedDatePrecision, severity: .info, targetID: fieldID.uuidString,
                                                    message: "Column \(fieldName[fieldID] ?? "field") mixes date precisions.", lineage: nil))
        }
        for kind in inputs.unsupportedTransformationKinds {
            warnings.append(WorkbenchQualityWarning(kind: .unsupportedTransformation, severity: .caution, targetID: kind,
                                                    message: "Transformation '\(kind)' is not supported and was not computed.", lineage: nil))
        }
        for ref in inputs.unresolvedContradictionRefs {
            warnings.append(WorkbenchQualityWarning(kind: .unresolvedContradiction, severity: .blocking, targetID: ref,
                                                    message: "An unresolved contradiction touches this dataset.", lineage: nil))
        }
        if !inputs.workspaceScopeComplete {
            warnings.append(WorkbenchQualityWarning(kind: .incompleteWorkspaceScope, severity: .caution, targetID: nil,
                                                    message: "The workspace scope behind this dataset is incomplete.", lineage: nil))
        }

        // MARK: Scenario — unreviewed overlay values

        if let scenario {
            for entry in scenario.diff() {
                let key = "\(entry.rowID.uuidString)|\(entry.fieldID.uuidString)"
                if !inputs.reviewedScenarioTargets.contains(key) {
                    warnings.append(WorkbenchQualityWarning(kind: .unreviewedScenarioValue, severity: .caution,
                                                            targetID: key,
                                                            message: "Scenario value (\(entry.originalValue ?? "∅") → \(entry.scenarioValue ?? "∅")) has not been promoted through review.",
                                                            lineage: scenario.originalBindings(rowID: entry.rowID, fieldID: entry.fieldID).first.map(EvidenceInspectionTarget.from)))
                }
            }
        }

        // Deterministic ordering: by kind, then target.
        warnings.sort {
            if $0.kind.rawValue != $1.kind.rawValue { return $0.kind.rawValue < $1.kind.rawValue }
            return ($0.targetID ?? "") < ($1.targetID ?? "")
        }
        return WorkbenchDataQualityReport(datasetID: record.dataset.id, scenarioID: scenarioID, warnings: warnings)
    }
}
