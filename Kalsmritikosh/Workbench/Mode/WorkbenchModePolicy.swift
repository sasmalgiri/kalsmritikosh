//
//  WorkbenchModePolicy.swift
//  Kalsmritikosh
//
//  LAB-006 (Stage C closure) — Simple and Advanced are two PRESENTATIONS of the ONE Workbench/DataLab,
//  never two engines and never two data stores. The mode lives on the dataset itself (WorkbenchDatasetMode,
//  schema v92); this policy maps that mode to the set of controls a surface should expose. Simple offers
//  prepared, outcome-first, guided controls with minimal terminology and lineage available on demand;
//  Advanced exposes the full detailed controls (raw cell editing, the formula editor, transformation
//  recipes, the scenario builder, the quality-issue list, multi-view layouts, method attachment, saved
//  layouts). Crucially, BOTH modes act on the same dataset, the same LAB-002 transform engine, the same
//  LAB-003 scenario engine, the same LAB-005 quality analysis and the same SensitiveScope — this file
//  decides only what is SHOWN, never forks what is TRUE.
//

import Foundation

/// The closed set of DataLab controls a mode may expose. The first group is available in both modes
/// (Simple presents them outcome-first); the second group is Advanced-only detail.
public nonisolated enum WorkbenchModeControl: String, Codable, Sendable, Equatable, CaseIterable {
    // Shared, outcome-first (both modes)
    case preparedDatasets
    case outcomeFirstControls
    case recommendedAnalyses
    case naturalLanguageDataLab
    case lineageInspection
    // Advanced-only detail
    case rawFieldRowCellEditing
    case formulaEditor
    case transformationRecipes
    case scenarioBuilder
    case qualityIssueList
    case multiViewLayouts
    case methodAttachment
    case savedLayouts
}

/// How much domain terminology a presentation uses.
public nonisolated enum WorkbenchTerminologyLevel: String, Codable, Sendable, Equatable {
    case minimal
    case full
}

/// The resolved capabilities for a mode. `controls` is exactly the set a surface may expose; the rest
/// are presentation defaults. This is a pure value — it holds no data and owns no persistence.
public nonisolated struct WorkbenchModeCapabilities: Sendable, Equatable {
    public let mode: WorkbenchDatasetMode
    public let controls: Set<WorkbenchModeControl>
    public let terminology: WorkbenchTerminologyLevel
    public let lineageOnDemand: Bool   // Simple: lineage is available on demand; Advanced: always shown
    public let safeDefaults: Bool

    public nonisolated init(mode: WorkbenchDatasetMode, controls: Set<WorkbenchModeControl>,
                            terminology: WorkbenchTerminologyLevel, lineageOnDemand: Bool, safeDefaults: Bool) {
        self.mode = mode; self.controls = controls; self.terminology = terminology
        self.lineageOnDemand = lineageOnDemand; self.safeDefaults = safeDefaults
    }

    public nonisolated func exposes(_ control: WorkbenchModeControl) -> Bool { controls.contains(control) }
}

public nonisolated enum WorkbenchModePolicy {

    /// The controls both modes share (Simple presents these; Advanced also exposes the detail set).
    private nonisolated static let sharedControls: Set<WorkbenchModeControl> =
        [.preparedDatasets, .outcomeFirstControls, .recommendedAnalyses, .naturalLanguageDataLab, .lineageInspection]

    private nonisolated static let advancedDetailControls: Set<WorkbenchModeControl> =
        [.rawFieldRowCellEditing, .formulaEditor, .transformationRecipes, .scenarioBuilder,
         .qualityIssueList, .multiViewLayouts, .methodAttachment, .savedLayouts]

    /// The capabilities for a mode. Simple = guided, outcome-first, minimal terminology, safe defaults,
    /// lineage on demand, NO formula editor / raw editing / multi-view. Advanced = every control, full
    /// terminology, lineage always shown.
    public nonisolated static func capabilities(for mode: WorkbenchDatasetMode) -> WorkbenchModeCapabilities {
        switch mode {
        case .simple:
            return WorkbenchModeCapabilities(mode: .simple, controls: sharedControls,
                                             terminology: .minimal, lineageOnDemand: true, safeDefaults: true)
        case .advanced:
            return WorkbenchModeCapabilities(mode: .advanced, controls: sharedControls.union(advancedDetailControls),
                                             terminology: .full, lineageOnDemand: false, safeDefaults: false)
        }
    }

    /// Advanced exposes a strict superset of Simple's controls — the same engine, more surface. This is
    /// the structural guarantee that Simple never does anything Advanced cannot (one truth, two views).
    public nonisolated static var advancedIsSupersetOfSimple: Bool {
        capabilities(for: .advanced).controls.isSuperset(of: capabilities(for: .simple).controls)
    }
}
