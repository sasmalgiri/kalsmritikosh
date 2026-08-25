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
    /// nil = a GLOBAL rule (from Sutra.globalRequirements) — applies to the whole run.
    public let phaseKind: PersonaJobKind?
    public let kind: RuleKind
    public let severity: RuleSeverity
    public let text: String
    /// Restricted, declared applicability expression. nil = the default condition
    /// (phase reached for phase rules, always for global rules). Supported:
    /// "always" · "phase_reached(<kind>)". Anything else is an evaluatorError —
    /// an expression nobody can parse must never silently pass or skip.
    public let applicability: String?
    public let evaluatorVersion: String
    /// Declared evidence kinds this rule expects (bound in later slices; recorded
    /// on the certificate so the expectation is visible even before binding).
    public let requiredEvidence: [String]
    /// The role whose recorded decision/attestation satisfies a human rule.
    public let humanRole: String?
    /// Citations to the external authority this rule encodes (e.g. "FRCP 26(b)(5)").
    public let authorityReferences: [String]

    public init(id: String, phaseKind: PersonaJobKind?, kind: RuleKind,
                severity: RuleSeverity, text: String,
                applicability: String? = nil,
                evaluatorVersion: String = "v1",
                requiredEvidence: [String] = [],
                humanRole: String? = nil,
                authorityReferences: [String] = []) {
        self.id = id; self.phaseKind = phaseKind; self.kind = kind
        self.severity = severity; self.text = text
        self.applicability = applicability
        self.evaluatorVersion = evaluatorVersion
        self.requiredEvidence = requiredEvidence
        self.humanRole = humanRole
        self.authorityReferences = authorityReferences
    }

    private enum CodingKeys: String, CodingKey {
        case id, phaseKind, kind, severity, text, applicability,
             evaluatorVersion, requiredEvidence, humanRole, authorityReferences
    }

    /// Back-compatible decode: rows written before the schema depth landed
    /// carry only the first five fields.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.phaseKind = try c.decodeIfPresent(PersonaJobKind.self, forKey: .phaseKind)
        self.kind = try c.decode(RuleKind.self, forKey: .kind)
        self.severity = try c.decode(RuleSeverity.self, forKey: .severity)
        self.text = try c.decode(String.self, forKey: .text)
        self.applicability = try c.decodeIfPresent(String.self, forKey: .applicability)
        self.evaluatorVersion = try c.decodeIfPresent(String.self, forKey: .evaluatorVersion) ?? "v1"
        self.requiredEvidence = try c.decodeIfPresent([String].self, forKey: .requiredEvidence) ?? []
        self.humanRole = try c.decodeIfPresent(String.self, forKey: .humanRole)
        self.authorityReferences = try c.decodeIfPresent([String].self, forKey: .authorityReferences) ?? []
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
        // Global requirements apply to the run as a whole, regardless of phase.
        for (i, text) in (sutra.globalRequirements ?? []).enumerated() {
            out.append(SutraRule(id: "global.requirement.\(i)", phaseKind: nil,
                                 kind: .obligation, severity: .mandatory, text: text,
                                 applicability: "always"))
        }
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
    /// Authorized deviations: rule ID → recorded justification. A deviation is
    /// VISIBLE on the certificate (`approvedDeviation`), never hidden — the run
    /// can still be conformant, but the departure travels with it.
    public var approvedDeviations: [String: String]

    public init(completedPhaseKinds: Set<PersonaJobKind>,
                standardOfProofDeclared: Bool = false,
                openItemsAcknowledged: Bool = false,
                humanDecisionsMade: Set<PersonaJobKind> = [],
                assertedProhibited: [String] = [],
                attestedRuleIDs: Set<String> = [],
                approvedDeviations: [String: String] = [:]) {
        self.completedPhaseKinds = completedPhaseKinds
        self.standardOfProofDeclared = standardOfProofDeclared
        self.openItemsAcknowledged = openItemsAcknowledged
        self.humanDecisionsMade = humanDecisionsMade
        self.assertedProhibited = assertedProhibited
        self.attestedRuleIDs = attestedRuleIDs
        self.approvedDeviations = approvedDeviations
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

    /// The restricted applicability language: nil (default), "always", or
    /// "phase_reached(<kind>)". Returns nil when the expression cannot be
    /// parsed — the caller records an evaluatorError (fail-closed: an
    /// expression nobody can parse must never silently pass or skip).
    private static func applicable(rule: SutraRule, facts: ConformanceFacts) -> Bool? {
        switch rule.applicability {
        case nil:
            // Default condition: phase rules apply when their phase was reached;
            // global rules (no phase) always apply.
            guard let phase = rule.phaseKind else { return true }
            return facts.completedPhaseKinds.contains(phase)
        case "always":
            return true
        case let expr? where expr.hasPrefix("phase_reached(") && expr.hasSuffix(")"):
            let raw = String(expr.dropFirst("phase_reached(".count).dropLast())
            guard let kind = PersonaJobKind(rawValue: raw) else { return nil }
            return facts.completedPhaseKinds.contains(kind)
        default:
            return nil
        }
    }

    /// Internal (not private) so the fail-closed evaluator paths — including
    /// expressions no built-in Sutra produces yet — are directly testable.
    static func evaluate(rule: SutraRule, facts: ConformanceFacts) -> RuleEvaluation {
        // 1. Declared applicability — deterministic, or fail-closed on parse failure.
        guard let isApplicable = applicable(rule: rule, facts: facts) else {
            return RuleEvaluation(rule: rule, outcome: .evaluatorError,
                                  evaluatorID: "gate.applicability.v1",
                                  detail: "unparseable applicability expression '\(rule.applicability ?? "")' — fail closed")
        }
        guard isApplicable else {
            return RuleEvaluation(rule: rule, outcome: .notApplicable,
                                  evaluatorID: "gate.applicability.v1",
                                  detail: rule.phaseKind == nil ? "condition not met" : "phase not reached in this run")
        }
        // 2. An authorized, justified deviation — visible, never hidden.
        if let justification = facts.approvedDeviations[rule.id] {
            return RuleEvaluation(rule: rule, outcome: .approvedDeviation,
                                  evaluatorID: "human.deviation.v1",
                                  detail: "authorized deviation: \(justification)")
        }
        switch rule.kind {
        case .humanDecision:
            // The app records reserved decisions; absence in a reached phase is a failure, not a gap.
            guard let phase = rule.phaseKind else {
                return RuleEvaluation(rule: rule, outcome: .evaluatorError,
                                      evaluatorID: "gate.humanDecision.v1",
                                      detail: "human-decision rule without a phase — fail closed")
            }
            return facts.humanDecisionsMade.contains(phase)
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
