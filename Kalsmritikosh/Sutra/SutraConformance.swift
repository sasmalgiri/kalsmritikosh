//
//  SutraConformance.swift
//  Kalsmritikosh
//
//  Sūtra Engine — roadmap step 4. Proves a completed run satisfied its
//  constitution: obligations met, the decisions the doctrine reserves for a
//  human actually made, and no prohibited conclusion asserted. The sealed
//  receipt becomes a constitutional conformance certificate.
//
//  Pure checker over a RunRecord (the recorded facts of a run) — no live repos,
//  fully testable. The UI builds a RunRecord from what it already records
//  (standard-of-proof declared, open items acknowledged, approval made, …).
//

import Foundation

/// The recorded facts of a run, as far as conformance is concerned.
public nonisolated struct RunRecord: Sendable, Equatable {
    /// Phases the run actually reached.
    public var completedPhaseKinds: Set<PersonaJobKind>
    /// The terminal gates the app records (from the findings phase).
    public var standardOfProofDeclared: Bool
    public var openItemsAcknowledged: Bool
    /// Kinds whose reserved human decision was recorded.
    public var humanDecisionsMade: Set<PersonaJobKind>
    /// Any prohibited conclusion detected in the run (normally empty).
    public var assertedProhibited: [String]

    public init(completedPhaseKinds: Set<PersonaJobKind>,
                standardOfProofDeclared: Bool = false,
                openItemsAcknowledged: Bool = false,
                humanDecisionsMade: Set<PersonaJobKind> = [],
                assertedProhibited: [String] = []) {
        self.completedPhaseKinds = completedPhaseKinds
        self.standardOfProofDeclared = standardOfProofDeclared
        self.openItemsAcknowledged = openItemsAcknowledged
        self.humanDecisionsMade = humanDecisionsMade
        self.assertedProhibited = assertedProhibited
    }
}

public nonisolated struct ConformanceReport: Sendable, Equatable {
    public var metObligations: [String]
    public var unmetObligations: [String]
    public var humanDecisionsPending: [String]
    public var prohibitedAsserted: [String]

    /// Conformant only when nothing is unmet, pending, or prohibited.
    public var isConformant: Bool {
        unmetObligations.isEmpty && humanDecisionsPending.isEmpty && prohibitedAsserted.isEmpty
    }

    public var summaryLine: String {
        isConformant
            ? "Conformant — the run satisfied its constitution."
            : "Not yet conformant — \(unmetObligations.count) unmet · \(humanDecisionsPending.count) decision(s) pending · \(prohibitedAsserted.count) prohibited."
    }

    /// A certificate block for the sealed report.
    public var certificate: String {
        var out = "## Sūtra conformance\n\n**\(summaryLine)**\n\n"
        if !metObligations.isEmpty {
            out += "**Met:**\n"; for m in metObligations { out += "- ✓ \(m)\n" }; out += "\n"
        }
        if !unmetObligations.isEmpty {
            out += "**Unmet:**\n"; for u in unmetObligations { out += "- ✗ \(u)\n" }; out += "\n"
        }
        if !humanDecisionsPending.isEmpty {
            out += "**Decisions pending:**\n"; for d in humanDecisionsPending { out += "- ◻︎ \(d)\n" }; out += "\n"
        }
        if !prohibitedAsserted.isEmpty {
            out += "**Prohibited conclusions asserted:**\n"; for p in prohibitedAsserted { out += "- ⊘ \(p)\n" }; out += "\n"
        }
        return out
    }
}

public nonisolated enum SutraConformance {

    public static func verify(run: RunRecord, against sutra: Sutra) -> ConformanceReport {
        var met: [String] = [], unmet: [String] = [], pending: [String] = []

        // Terminal gates — recorded by the findings phase.
        if run.completedPhaseKinds.contains(.findings) {
            if run.standardOfProofDeclared { met.append("Standard of proof declared") }
            else { unmet.append("Declare a standard of proof") }

            if run.openItemsAcknowledged { met.append("Open contradictions & gaps surfaced and acknowledged") }
            else { unmet.append("Surface every open contradiction and gap") }
        }

        // Every reached phase that reserves a human decision must have made it.
        for phase in sutra.phases where run.completedPhaseKinds.contains(phase.kind) {
            guard !phase.humanDecisions.isEmpty else { continue }
            if run.humanDecisionsMade.contains(phase.kind) {
                met.append("\(phase.title): human decision recorded")
            } else {
                pending.append(contentsOf: phase.humanDecisions.map { "\(phase.title): \($0)" })
            }
        }

        return ConformanceReport(metObligations: met, unmetObligations: unmet,
                                 humanDecisionsPending: pending, prohibitedAsserted: run.assertedProhibited)
    }
}
