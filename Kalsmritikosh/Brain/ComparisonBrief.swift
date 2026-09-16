//
//  ComparisonBrief.swift
//  Kalsmritikosh
//
//  G3 Workflow C — renders a ComparisonMatrix into a readable, sourced brief:
//  Agreements, Disagreements, and Missing/Unresolved sections, plus a source
//  register. DETERMINISTIC — every line is derived from the matrix cells, so
//  the brief never asserts a comparison the evidence does not support. The
//  free-form model prose (optional) layers on top; this is the floor.
//

import Foundation

public struct ComparisonBrief: Sendable, Equatable {
    public let agreements: [String]
    public let disagreements: [String]
    public let differentUnits: [String]
    public let unresolved: [String]     // single-source / unattested — open questions
    public let sourceRegister: [String] // the sources compared
    public let text: String             // the assembled brief

    /// Build the brief from the matrix cells over a labelled source set.
    /// `sourceLabels` maps a source id to a human label for the register.
    public nonisolated static func make(
        cells: [ComparisonCell],
        sourceLabels: [String: String] = [:]
    ) -> ComparisonBrief {
        func label(_ id: String) -> String { sourceLabels[id] ?? id }
        func statedList(_ c: ComparisonCell) -> String {
            c.stated.map { "\(label($0.sourceID)): \($0.value)" }.joined(separator: "; ")
        }

        var agreements: [String] = []
        var disagreements: [String] = []
        var differentUnits: [String] = []
        var unresolved: [String] = []

        for c in cells {
            switch c.verdict {
            case .agree:
                if let v = c.stated.first?.value {
                    agreements.append("\(c.field): all sources agree — \(v).")
                }
            case .disagree:
                disagreements.append("\(c.field): sources disagree — \(statedList(c)).")
            case .differentUnit:
                differentUnits.append("\(c.field): same figure, different units — \(statedList(c)) (not a conflict).")
            case .singleSource:
                var line = "\(c.field): only \(statedList(c))."
                if !c.silentSourceIDs.isEmpty {
                    line += " Others silent: \(c.silentSourceIDs.map(label).joined(separator: ", "))."
                }
                if !c.explicitNoneSourceIDs.isEmpty {
                    line += " Recorded as none by: \(c.explicitNoneSourceIDs.map(label).joined(separator: ", "))."
                }
                unresolved.append(line)
            case .unattested:
                unresolved.append("\(c.field): no source on file states a value.")
            }
        }

        let register = orderedSources(cells).map(label)

        var parts: [String] = []
        if !agreements.isEmpty { parts.append("Agreements:\n" + agreements.map { "• \($0)" }.joined(separator: "\n")) }
        if !disagreements.isEmpty { parts.append("Disagreements:\n" + disagreements.map { "• \($0)" }.joined(separator: "\n")) }
        if !differentUnits.isEmpty { parts.append("Different units (not conflicts):\n" + differentUnits.map { "• \($0)" }.joined(separator: "\n")) }
        if !unresolved.isEmpty { parts.append("Missing / unresolved:\n" + unresolved.map { "• \($0)" }.joined(separator: "\n")) }
        if !register.isEmpty { parts.append("Sources compared: " + register.joined(separator: ", ") + ".") }

        return ComparisonBrief(
            agreements: agreements, disagreements: disagreements,
            differentUnits: differentUnits, unresolved: unresolved,
            sourceRegister: register,
            text: parts.joined(separator: "\n\n"))
    }

    /// The distinct source ids that appear across the cells, in first-seen order.
    nonisolated static func orderedSources(_ cells: [ComparisonCell]) -> [String] {
        var seen = Set<String>(); var out: [String] = []
        for c in cells { for v in c.values where seen.insert(v.sourceID).inserted { out.append(v.sourceID) } }
        return out
    }
}
