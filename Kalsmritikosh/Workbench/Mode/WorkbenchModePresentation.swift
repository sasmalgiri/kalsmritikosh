//
//  WorkbenchModePresentation.swift
//  Kalsmritikosh
//
//  LAB-006 (Stage C closure) — the presentation slice for a mode. Given the ONE authoritative artifact
//  (a LAB-005 data-quality report, a LAB-004 visual surface), it decides what a Simple vs Advanced
//  surface shows — WITHOUT recomputing anything. Simple is outcome-first: it surfaces the warnings that
//  affect the answer (caution + blocking) and keeps lineage available on demand; Advanced shows every
//  warning and every element with lineage always visible. The input report/surface is identical in both
//  modes — this file returns a VIEW over the same truth, never a different truth.
//

import Foundation

public nonisolated enum WorkbenchModePresentation {

    /// The warnings a mode surfaces from the SAME report. Simple hides pure `info` disclosures to stay
    /// outcome-first (they remain in the report and are reachable on demand); Advanced shows all. Order
    /// is preserved from the report (already deterministic).
    public nonisolated static func warningsToSurface(mode: WorkbenchDatasetMode,
                                                     report: WorkbenchDataQualityReport) -> [WorkbenchQualityWarning] {
        switch mode {
        case .simple:  return report.warnings.filter { $0.severity != .info }
        case .advanced: return report.warnings
        }
    }

    /// Whether lineage is shown inline (Advanced) or offered on demand (Simple). Either way the SAME
    /// EvidenceInspectionTarget is one action away — Simple never hides provenance, it defers it.
    public nonisolated static func showsLineageInline(mode: WorkbenchDatasetMode) -> Bool {
        !WorkbenchModePolicy.capabilities(for: mode).lineageOnDemand
    }

    /// The visual elements a mode surfaces from the SAME surface. Simple leads with the value-bearing
    /// elements (source/scenario/derived/entered) and folds away purely structural headers; Advanced
    /// shows everything. The elements themselves — and their one-action inspection — are unchanged.
    public nonisolated static func elementsToSurface(mode: WorkbenchDatasetMode,
                                                    surface: WorkbenchVisualSurface) -> [WorkbenchVisualElement] {
        switch mode {
        case .simple:
            return surface.elements.filter { element in
                if case .none = element.provenance { return false }   // fold away structural-only elements
                return true
            }
        case .advanced:
            return surface.elements
        }
    }
}
