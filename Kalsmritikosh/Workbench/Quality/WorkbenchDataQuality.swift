//
//  WorkbenchDataQuality.swift
//  Kalsmritikosh
//
//  LAB-005 (Stage C) — the DataLab's evidence-quality warning model, generalising a stale-data warning
//  system to the full set of evidence-quality concerns. A warning is a DETERMINISTIC observation about a
//  dataset (optionally under a scenario), carrying its target, an honest severity, and — where it maps
//  to a source — its exact drill-through lineage. This is a pure analysis layer: it produces warnings,
//  it never mutates canonical evidence, never resolves a contradiction, and never silently "fixes"
//  anything. It reuses the LAB-004 EvidenceInspectionTarget so a warning opens the same one-action
//  inspection as any other surface element.
//

import Foundation

/// The closed set of evidence-quality concerns (contract §6).
public nonisolated enum WorkbenchQualityWarningKind: String, Codable, Sendable, Equatable, CaseIterable {
    case missingValue
    case staleSourceVersion
    case inaccessibleSource
    case ambiguousIdentity
    case mixedDatePrecision
    case unsupportedTransformation
    case duplicateSource
    case nonIndependentCorroboration
    case missingCustodyHash
    case unresolvedContradiction
    case incompleteWorkspaceScope
    case unreviewedScenarioValue
    case lowOCRConfidence
    case formulaVsDisplayedDiscrepancy
}

/// How much a warning should weigh on trust. `blocking` means the value should not be relied on without
/// resolution; `caution` is a real quality concern; `info` is a disclosure. Severity is a FIXED property
/// of the warning kind — never a function of a confidence score.
public nonisolated enum WorkbenchQualitySeverity: String, Codable, Sendable, Equatable, CaseIterable {
    case info
    case caution
    case blocking
}

public nonisolated struct WorkbenchQualityWarning: Identifiable, Sendable, Equatable {
    public let id: String
    public let kind: WorkbenchQualityWarningKind
    public let severity: WorkbenchQualitySeverity
    public let targetID: String?
    public let message: String
    public let lineage: EvidenceInspectionTarget?

    public nonisolated init(kind: WorkbenchQualityWarningKind, severity: WorkbenchQualitySeverity,
                            targetID: String?, message: String, lineage: EvidenceInspectionTarget?) {
        self.id = "\(kind.rawValue)|\(targetID ?? "-")"
        self.kind = kind; self.severity = severity; self.targetID = targetID
        self.message = message; self.lineage = lineage
    }
}

/// The deterministic quality report for a dataset (optionally under a scenario).
public nonisolated struct WorkbenchDataQualityReport: Sendable, Equatable {
    public let datasetID: UUID
    public let scenarioID: UUID?
    public let warnings: [WorkbenchQualityWarning]

    public nonisolated init(datasetID: UUID, scenarioID: UUID?, warnings: [WorkbenchQualityWarning]) {
        self.datasetID = datasetID; self.scenarioID = scenarioID; self.warnings = warnings
    }

    public nonisolated func warnings(of kind: WorkbenchQualityWarningKind) -> [WorkbenchQualityWarning] {
        warnings.filter { $0.kind == kind }
    }
    public nonisolated var hasBlocking: Bool { warnings.contains { $0.severity == .blocking } }
    public nonisolated var kinds: Set<WorkbenchQualityWarningKind> { Set(warnings.map(\.kind)) }
    public nonisolated var isClean: Bool { warnings.isEmpty }
}

/// Externally-collected facts the evaluator cannot derive from the dataset record alone (they come from
/// the readiness / typed-field / contradiction / workspace authorities via the analyzer). Each defaults
/// empty, so a caller that cannot determine a fact simply does not raise that warning — never a guess.
public nonisolated struct WorkbenchQualityInputs: Sendable {
    public var staleSourceVersionIDs: Set<UUID>
    public var inaccessibleSourceVersionIDs: Set<UUID>
    public var lowOCRCellIDs: Set<UUID>
    public var ambiguousIdentityCellIDs: Set<UUID>
    public var mixedDatePrecisionFieldIDs: Set<UUID>
    public var unsupportedTransformationKinds: [String]
    public var nonIndependentCorroborationCellIDs: Set<UUID>
    public var unresolvedContradictionRefs: [String]
    public var workspaceScopeComplete: Bool
    public var reviewedScenarioTargets: Set<String>   // "row|field" keys already promoted-through-review
    public var formulaDiscrepancyCellIDs: Set<UUID>

    public nonisolated init(staleSourceVersionIDs: Set<UUID> = [], inaccessibleSourceVersionIDs: Set<UUID> = [],
                            lowOCRCellIDs: Set<UUID> = [], ambiguousIdentityCellIDs: Set<UUID> = [],
                            mixedDatePrecisionFieldIDs: Set<UUID> = [], unsupportedTransformationKinds: [String] = [],
                            nonIndependentCorroborationCellIDs: Set<UUID> = [], unresolvedContradictionRefs: [String] = [],
                            workspaceScopeComplete: Bool = true, reviewedScenarioTargets: Set<String> = [],
                            formulaDiscrepancyCellIDs: Set<UUID> = []) {
        self.staleSourceVersionIDs = staleSourceVersionIDs
        self.inaccessibleSourceVersionIDs = inaccessibleSourceVersionIDs
        self.lowOCRCellIDs = lowOCRCellIDs
        self.ambiguousIdentityCellIDs = ambiguousIdentityCellIDs
        self.mixedDatePrecisionFieldIDs = mixedDatePrecisionFieldIDs
        self.unsupportedTransformationKinds = unsupportedTransformationKinds
        self.nonIndependentCorroborationCellIDs = nonIndependentCorroborationCellIDs
        self.unresolvedContradictionRefs = unresolvedContradictionRefs
        self.workspaceScopeComplete = workspaceScopeComplete
        self.reviewedScenarioTargets = reviewedScenarioTargets
        self.formulaDiscrepancyCellIDs = formulaDiscrepancyCellIDs
    }
}
