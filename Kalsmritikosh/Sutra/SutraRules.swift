//
//  SutraRules.swift
//  Kalsmritikosh
//
//  Conformance roadmap 1.0.x-A (Level 1 — real conformance). The prose doctrine
//  in a Sutra becomes TYPED RULES with stable IDs, and an assessment produces
//  exactly one outcome per rule — fail-closed: a mandatory rule nobody evaluated
//  is `notEvaluated` and blocks conformance instead of passing silently (the
//  prior checker's prohibited-conclusions check passed by construction because
//  callers defaulted it to empty). The exact Sutra JSON and its SHA-256 are
//  frozen into the assessment so a certificate can never drift from the
//  constitution it was checked against.
//
//  Deterministic + LLM-free (capability discipline). Evaluators are either
//  deterministic gates the app records (standard of proof, open items, reserved
//  human decisions, phase reach) or an explicit recorded human attestation —
//  never inference, never a default.
//

import Foundation
import CryptoKit

// MARK: - Typed rules

public nonisolated enum RuleKind: String, Sendable, Codable {
    case obligation, humanDecision, prohibition
}

public nonisolated enum RuleSeverity: String, Sendable, Codable {
    case mandatory, advisory
}

public nonisolated struct SutraRule: Sendable, Codable, Equatable, Hashable, Identifiable {
    /// Stable across releases for an unchanged doctrine line: "<phase>.<kind>.<index>".
    public let id: String
    public let phaseKind: PersonaJobKind
    public let kind: RuleKind
    public let severity: RuleSeverity
    public let text: String

    public init(id: String, phaseKind: PersonaJobKind, kind: RuleKind,
                severity: RuleSeverity, text: String) {
        self.id = id; self.phaseKind = phaseKind; self.kind = kind
        self.severity = severity; self.text = text
    }
}

/// Every mandatory rule ends in exactly one of these — there is no silent pass.
public nonisolated enum RuleOutcome: String, Sendable, Codable {
    case passed
    case failed
    case notApplicable      // deterministic condition only (e.g. phase not reached)
    case notEvaluated       // fail-closed: blocks conformance
    case approvedDeviation  // visible, never hidden
    case evaluatorError     // fail-closed: blocks conformance
}

public nonisolated struct RuleEvaluation: Sendable, Codable, Equatable, Identifiable {
    public var id: String { rule.id }
    public let rule: SutraRule
    public let outcome: RuleOutcome
    /// Which deterministic gate or recorded human action produced this outcome.
    public let evaluatorID: String
    public let detail: String

    public init(rule: SutraRule, outcome: RuleOutcome, evaluatorID: String, detail: String) {
        self.rule = rule; self.outcome = outcome; self.evaluatorID = evaluatorID; self.detail = detail
    }
}

public nonisolated enum SutraRuleCompiler {
    /// Deterministic derivation: one typed rule per doctrine line, in phase order.
    /// IDs are positional within a Sutra version — any doctrine edit ships as an
    /// amendment (version bump), so an ID never silently changes meaning.
    public static func rules(for sutra: Sutra) -> [SutraRule] {
        var out: [SutraRule] = []
        for phase in sutra.phases {
            for (i, text) in phase.obligations.enumerated() {
                out.append(SutraRule(id: "\(phase.kind.rawValue).obligation.\(i)",
                                     phaseKind: phase.kind, kind: .obligation,
                                     severity: .mandatory, text: text))
            }
            for (i, text) in phase.humanDecisions.enumerated() {
                out.append(SutraRule(id: "\(phase.kind.rawValue).humanDecision.\(i)",
                                     phaseKind: phase.kind, kind: .humanDecision,
                                     severity: .mandatory, text: text))
            }
            for (i, text) in phase.prohibitedConclusions.enumerated() {
                out.append(SutraRule(id: "\(phase.kind.rawValue).prohibition.\(i)",
                                     phaseKind: phase.kind, kind: .prohibition,
                                     severity: .mandatory, text: text))
            }
        }
        return out
    }
}

// MARK: - Facts (what the run actually recorded)

/// The recorded facts an assessment may consult. Extends the legacy RunRecord
/// shape with explicit attestations so no rule can pass by default.
public nonisolated struct ConformanceFacts: Sendable, Equatable {
    public var completedPhaseKinds: Set<PersonaJobKind>
    public var standardOfProofDeclared: Bool
    public var openItemsAcknowledged: Bool
    public var humanDecisionsMade: Set<PersonaJobKind>
    public var assertedProhibited: [String]
    /// Rule IDs the responsible human explicitly attested as satisfied — the
    /// recorded evaluation for rules with no deterministic gate. An unattested
    /// mandatory rule stays `notEvaluated` and blocks conformance.
    public var attestedRuleIDs: Set<String>

    public init(completedPhaseKinds: Set<PersonaJobKind>,
                standardOfProofDeclared: Bool = false,
                openItemsAcknowledged: Bool = false,
                humanDecisionsMade: Set<PersonaJobKind> = [],
                assertedProhibited: [String] = [],
                attestedRuleIDs: Set<String> = []) {
        self.completedPhaseKinds = completedPhaseKinds
        self.standardOfProofDeclared = standardOfProofDeclared
        self.openItemsAcknowledged = openItemsAcknowledged
        self.humanDecisionsMade = humanDecisionsMade
        self.assertedProhibited = assertedProhibited
        self.attestedRuleIDs = attestedRuleIDs
    }
}

// MARK: - Assessment (one outcome per rule, Sutra frozen by hash)

public nonisolated enum ConformanceStatus: String, Sendable, Codable {
    case conformant, notConformant, indeterminate

    public var summaryLine: String {
        switch self {
        case .conformant:    return "Conformant — every mandatory rule evaluated and satisfied."
        case .notConformant: return "Not conformant — at least one mandatory rule failed."
        case .indeterminate: return "Indeterminate — mandatory rule(s) not yet evaluated; conformance cannot be claimed."
        }
    }
}

public nonisolated struct ConformanceAssessment: Sendable, Codable, Equatable {
    public let sutraCitation: String
    /// Canonical (sorted-keys) JSON of the exact Sutra assessed against, frozen here.
    public let sutraSnapshotJSON: String
    public let sutraSHA256: String
    public let evaluations: [RuleEvaluation]
    public let assessedAt: Date

    /// Fail-closed rollup: failed beats everything; any mandatory
    /// notEvaluated/evaluatorError makes the whole assessment indeterminate.
    public var status: ConformanceStatus {
        let mandatory = evaluations.filter { $0.rule.severity == .mandatory }
        if mandatory.contains(where: { $0.outcome == .failed }) { return .notConformant }
        if mandatory.contains(where: { $0.outcome == .notEvaluated || $0.outcome == .evaluatorError }) {
            return .indeterminate
        }
        return .conformant
    }

    /// Rules still awaiting an explicit evaluation (drives the attestation UI).
    public var unevaluated: [RuleEvaluation] {
        evaluations.filter { $0.outcome == .notEvaluated || $0.outcome == .evaluatorError }
    }

    /// SHA-256 over the canonical encoding of all rule evaluations — what the seal signs.
    public var ruleEvaluationsSHA256: String {
        (try? ConformanceCanonical.sha256(of: evaluations)) ?? ""
    }

    /// Per-rule certificate block for the sealed report. Claims exactly what was
    /// evaluated, by which evaluator — nothing blanket.
    public var certificate: String {
        var out = "## Sūtra conformance (per-rule)\n\n"
        out += "**Constitution:** \(sutraCitation)\n"
        out += "**Constitution SHA-256:** `\(sutraSHA256)`\n"
        out += "**Status:** \(status.summaryLine)\n\n"
        let mark: (RuleOutcome) -> String = {
            switch $0 {
            case .passed: return "✓"; case .failed: return "✗"
            case .notApplicable: return "–"; case .notEvaluated: return "◻︎"
            case .approvedDeviation: return "△"; case .evaluatorError: return "⚠"
            }
        }
        for e in evaluations {
            out += "- \(mark(e.outcome)) `\(e.rule.id)` [\(e.outcome.rawValue)] \(e.rule.text) — _\(e.evaluatorID)_: \(e.detail)\n"
        }
        out += "\n_\(LegalNotice.conformanceScopeNote)_\n"
        return out
    }

    /// Back-compatible summary in the legacy report shape (UI already renders it).
    public func legacyReport() -> ConformanceReport {
        var met: [String] = [], unmet: [String] = [], pending: [String] = []
        for e in evaluations {
            switch (e.outcome, e.rule.kind) {
            case (.passed, _):                     met.append(e.rule.text)
            case (.failed, .humanDecision):        pending.append(e.rule.text)
            case (.failed, _):                     unmet.append(e.rule.text)
            case (.notEvaluated, _), (.evaluatorError, _): unmet.append("\(e.rule.text) (not evaluated)")
            case (.notApplicable, _), (.approvedDeviation, _): break
            }
        }
        return ConformanceReport(metObligations: met, unmetObligations: unmet,
                                 humanDecisionsPending: pending,
                                 prohibitedAsserted: evaluations
                                     .filter { $0.rule.kind == .prohibition && $0.outcome == .failed }
                                     .map(\.rule.text),
                                 constitution: sutraCitation)
    }
}

// MARK: - Canonical encoding (shared by snapshot hash and the seal)

public nonisolated enum ConformanceCanonical {
    /// Deterministic JSON: sorted keys, ISO-8601 dates, no pretty-printing.
    public static func data<T: Encodable>(of value: T) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return try enc.encode(value)
    }

    public static func sha256<T: Encodable>(of value: T) throws -> String {
        SHA256.hash(data: try data(of: value)).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - The assessor

extension SutraConformance {

    /// Level-1 assessment: exactly one outcome per typed rule, fail-closed.
    /// Pure and deterministic — pass `now` explicitly.
    public static func assess(facts: ConformanceFacts, against sutra: Sutra,
                              at now: Date) -> ConformanceAssessment {
        let rules = SutraRuleCompiler.rules(for: sutra)
        let evaluations = rules.map { evaluate(rule: $0, facts: facts) }
        let snapshotJSON = (try? ConformanceCanonical.data(of: sutra))
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let snapshotSHA = snapshotJSON.isEmpty ? ""
            : SHA256.hash(data: Data(snapshotJSON.utf8)).map { String(format: "%02x", $0) }.joined()
        return ConformanceAssessment(sutraCitation: sutra.citation,
                                     sutraSnapshotJSON: snapshotJSON,
                                     sutraSHA256: snapshotSHA,
                                     evaluations: evaluations,
                                     assessedAt: now)
    }

    /// The doctrine's two findings-phase gates the app records deterministically.
    private static let gateStandardOfProof = "Declare a standard of proof"
    private static let gateOpenItems = "Surface every open contradiction and gap"

    private static func evaluate(rule: SutraRule, facts: ConformanceFacts) -> RuleEvaluation {
        // Deterministic N/A: the run never reached this phase.
        guard facts.completedPhaseKinds.contains(rule.phaseKind) else {
            return RuleEvaluation(rule: rule, outcome: .notApplicable,
                                  evaluatorID: "gate.phaseReach.v1",
                                  detail: "phase not reached in this run")
        }
        switch rule.kind {
        case .humanDecision:
            // The app records reserved decisions; absence in a reached phase is a failure, not a gap.
            return facts.humanDecisionsMade.contains(rule.phaseKind)
                ? RuleEvaluation(rule: rule, outcome: .passed, evaluatorID: "gate.humanDecision.v1",
                                 detail: "reserved decision recorded")
                : RuleEvaluation(rule: rule, outcome: .failed, evaluatorID: "gate.humanDecision.v1",
                                 detail: "reserved decision not recorded")
        case .prohibition:
            if facts.assertedProhibited.contains(rule.text) {
                return RuleEvaluation(rule: rule, outcome: .failed, evaluatorID: "gate.prohibited.v1",
                                      detail: "prohibited conclusion asserted in this run")
            }
            // No default pass: the reviewer must attest the prohibition was respected.
            return facts.attestedRuleIDs.contains(rule.id)
                ? RuleEvaluation(rule: rule, outcome: .passed, evaluatorID: "human.attest.v1",
                                 detail: "reviewer attested the prohibition was respected")
                : RuleEvaluation(rule: rule, outcome: .notEvaluated, evaluatorID: "human.attest.v1",
                                 detail: "awaiting reviewer attestation")
        case .obligation:
            // Deterministic gates the app records for the findings phase.
            if rule.phaseKind == .findings && rule.text == Self.gateStandardOfProof {
                return facts.standardOfProofDeclared
                    ? RuleEvaluation(rule: rule, outcome: .passed, evaluatorID: "gate.standardOfProof.v1",
                                     detail: "standard of proof declared")
                    : RuleEvaluation(rule: rule, outcome: .failed, evaluatorID: "gate.standardOfProof.v1",
                                     detail: "no standard of proof declared")
            }
            if rule.phaseKind == .findings && rule.text == Self.gateOpenItems {
                return facts.openItemsAcknowledged
                    ? RuleEvaluation(rule: rule, outcome: .passed, evaluatorID: "gate.openItems.v1",
                                     detail: "open contradictions & gaps surfaced and acknowledged")
                    : RuleEvaluation(rule: rule, outcome: .failed, evaluatorID: "gate.openItems.v1",
                                     detail: "open items not acknowledged")
            }
            // Everything else requires a recorded attestation — fail-closed.
            return facts.attestedRuleIDs.contains(rule.id)
                ? RuleEvaluation(rule: rule, outcome: .passed, evaluatorID: "human.attest.v1",
                                 detail: "reviewer attested the obligation was met")
                : RuleEvaluation(rule: rule, outcome: .notEvaluated, evaluatorID: "human.attest.v1",
                                 detail: "awaiting reviewer attestation")
        }
    }
}
