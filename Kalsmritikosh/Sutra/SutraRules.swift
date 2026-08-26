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
    /// Whether an authorized deviation may resolve this rule. Prohibitions are
    /// NON-waivable: no free-text justification can authorize asserting a
    /// prohibited conclusion — a deviation attempt on a non-waivable rule fails.
    public let waivable: Bool

    public init(id: String, phaseKind: PersonaJobKind?, kind: RuleKind,
                severity: RuleSeverity, text: String,
                applicability: String? = nil,
                evaluatorVersion: String = "v1",
                requiredEvidence: [String] = [],
                humanRole: String? = nil,
                authorityReferences: [String] = [],
                waivable: Bool = true) {
        self.id = id; self.phaseKind = phaseKind; self.kind = kind
        self.severity = severity; self.text = text
        self.applicability = applicability
        self.evaluatorVersion = evaluatorVersion
        self.requiredEvidence = requiredEvidence
        self.humanRole = humanRole
        self.authorityReferences = authorityReferences
        self.waivable = waivable
    }

    private enum CodingKeys: String, CodingKey {
        case id, phaseKind, kind, severity, text, applicability,
             evaluatorVersion, requiredEvidence, humanRole, authorityReferences, waivable
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
        self.waivable = try c.decodeIfPresent(Bool.self, forKey: .waivable) ?? true
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
                let meta = enrichment(kind: phase.kind, text: text)
                out.append(SutraRule(id: "\(phase.kind.rawValue).obligation.\(i)",
                                     phaseKind: phase.kind, kind: .obligation,
                                     severity: .mandatory, text: text,
                                     requiredEvidence: meta.requiredEvidence,
                                     authorityReferences: meta.authorityReferences))
            }
            for (i, text) in phase.humanDecisions.enumerated() {
                let meta = enrichment(kind: phase.kind, text: text)
                out.append(SutraRule(id: "\(phase.kind.rawValue).humanDecision.\(i)",
                                     phaseKind: phase.kind, kind: .humanDecision,
                                     severity: .mandatory, text: text,
                                     humanRole: meta.humanRole,
                                     authorityReferences: meta.authorityReferences))
            }
            for (i, text) in phase.prohibitedConclusions.enumerated() {
                // Prohibitions are NON-waivable: no deviation can authorize one.
                out.append(SutraRule(id: "\(phase.kind.rawValue).prohibition.\(i)",
                                     phaseKind: phase.kind, kind: .prohibition,
                                     severity: .mandatory, text: text,
                                     waivable: false))
            }
        }
        return out
    }

    /// Deterministic rule metadata for the KNOWN doctrine lines: which
    /// evidence kinds a rule inspects, who owns its reserved decision, and the
    /// external authority it encodes. Text-keyed so amendments that keep a
    /// line keep its grounding.
    static func enrichment(kind: PersonaJobKind, text: String)
        -> (requiredEvidence: [String], humanRole: String?, authorityReferences: [String]) {
        switch (kind, text) {
        case (.evidenceCustody, "Record custody contemporaneously"):
            return (["custody.record"], nil, ["SWGDE Best Practices", "NIST SP 800-86"])
        case (.evidenceCustody, "Hash evidence as early as possible (SWGDE/NIST)"):
            return (["custody.hash"], nil, ["SWGDE Best Practices", "NIST SP 800-86"])
        case (.findings, "Declare a standard of proof"):
            return ([], nil, ["Evidentiary standards (balance of probabilities … beyond reasonable doubt)"])
        case (.findings, "Approve the findings"):
            return ([], "approver", [])
        case (.caseIntake, "Authorize the scope"):
            return ([], "case owner", [])
        case (.closure, "Decide to close or reopen"):
            return ([], "case owner", [])
        case (.sourceReliability, "Rate each source on the Admiralty scale (A–F × 1–6)"):
            return ([], nil, ["Admiralty/NATO source rating"])
        case (.analysis, _):
            return ([], text.hasPrefix("Record the leading hypothesis") ? "analyst" : nil,
                    ["Analysis of Competing Hypotheses (Heuer)"])
        default:
            return ([], nil, [])
        }
    }
}

// MARK: - Facts (what the run actually recorded)

/// One actor-bound attestation of one rule (audit 2026-08-25 item 1): WHO
/// attested, in what role, WHY, and when — replacing the blanket toggle.
public nonisolated struct RuleAttestation: Sendable, Codable, Equatable {
    public let actor: String
    public let role: String?
    public let rationale: String
    public let at: Date
    public init(actor: String, role: String? = nil, rationale: String, at: Date) {
        self.actor = actor; self.role = role; self.rationale = rationale; self.at = at
    }
}

/// A TYPED deviation authorization (audit item 8): who authorized departing
/// from a rule, in what role, why, and when. Decodes legacy plain-string
/// justifications as "unattributed" so v109 facts still verify.
public nonisolated struct DeviationAuthorization: Sendable, Codable, Equatable {
    public let authorizedBy: String
    public let role: String?
    public let justification: String
    public let at: Date?

    public init(authorizedBy: String, role: String? = nil, justification: String, at: Date?) {
        self.authorizedBy = authorizedBy; self.role = role
        self.justification = justification; self.at = at
    }

    private enum CodingKeys: String, CodingKey { case authorizedBy, role, justification, at }

    public init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let s = try? single.decode(String.self) {
            self.authorizedBy = "unattributed"; self.role = nil; self.justification = s; self.at = nil
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.authorizedBy = try c.decode(String.self, forKey: .authorizedBy)
        self.role = try c.decodeIfPresent(String.self, forKey: .role)
        self.justification = try c.decode(String.self, forKey: .justification)
        self.at = try c.decodeIfPresent(Date.self, forKey: .at)
    }
}

/// The recorded facts an assessment may consult. Extends the legacy RunRecord
/// shape with explicit attestations so no rule can pass by default. Codable so
/// verification bundles can carry the facts and REPLAY the evaluators.
public nonisolated struct ConformanceFacts: Sendable, Equatable, Codable {
    public var completedPhaseKinds: Set<PersonaJobKind>
    public var standardOfProofDeclared: Bool
    public var openItemsAcknowledged: Bool
    public var humanDecisionsMade: Set<PersonaJobKind>
    public var assertedProhibited: [String]
    /// Rule IDs the responsible human explicitly attested as satisfied — the
    /// recorded evaluation for rules with no deterministic gate. An unattested
    /// mandatory rule stays `notEvaluated` and blocks conformance.
    public var attestedRuleIDs: Set<String>
    /// Authorized deviations: rule ID → TYPED authorization (who, role, why,
    /// when). A deviation is VISIBLE on the certificate (`approvedDeviation`)
    /// and downgrades the rollup to `conformantWithDeviations` — never plain
    /// conformant. Non-waivable rules refuse deviations outright.
    public var approvedDeviations: [String: DeviationAuthorization]
    /// Evidence kinds actually BOUND to the run (e.g. "custody.record",
    /// "custody.hash"). A rule whose `requiredEvidence` names a kind absent
    /// here stays `notEvaluated` — an attestation cannot substitute for
    /// evidence the run doesn't hold.
    public var presentEvidenceKinds: Set<String>
    /// Actor-bound per-rule attestations (rule ID → who/why/when). The UI
    /// records THESE; the bare `attestedRuleIDs` set remains for programmatic
    /// callers and is reported as "unattributed" on the certificate.
    public var attestations: [String: RuleAttestation]
    /// Phases that MUST be reached for the run to conform. A rule of an
    /// unreached required phase FAILS instead of going notApplicable (audit
    /// item: "an unreached required phase must fail, not become N/A").
    /// `assess` injects the Sutra's declared set; default = the findings phase.
    public var requiredPhaseKinds: Set<PersonaJobKind>
    /// Run-binding components (sixth audit): the receipt seal and case
    /// revision that, with the envelope's runID, hash to runStateSHA256 —
    /// carried INSIDE the signed facts so an outside verifier can RECOMPUTE
    /// the run binding instead of trusting it. nil on legacy facts.
    public var runReceiptSeal: String? = nil
    public var runCaseRevision: Int? = nil
    /// PHASE B (seventh audit): the subset of completedPhaseKinds that was
    /// MACHINE-OBSERVED from the case's own ledgers (vs. asserted by a test
    /// or an external caller). Signed with the facts; the certificate prints
    /// the observed/attested split per phase. nil on legacy facts.
    public var observedPhaseKinds: Set<PersonaJobKind>? = nil

    public init(completedPhaseKinds: Set<PersonaJobKind>,
                standardOfProofDeclared: Bool = false,
                openItemsAcknowledged: Bool = false,
                humanDecisionsMade: Set<PersonaJobKind> = [],
                assertedProhibited: [String] = [],
                attestedRuleIDs: Set<String> = [],
                approvedDeviations: [String: DeviationAuthorization] = [:],
                presentEvidenceKinds: Set<String> = [],
                attestations: [String: RuleAttestation] = [:],
                requiredPhaseKinds: Set<PersonaJobKind> = []) {
        self.completedPhaseKinds = completedPhaseKinds
        self.standardOfProofDeclared = standardOfProofDeclared
        self.openItemsAcknowledged = openItemsAcknowledged
        self.humanDecisionsMade = humanDecisionsMade
        self.assertedProhibited = assertedProhibited
        self.attestedRuleIDs = attestedRuleIDs
        self.approvedDeviations = approvedDeviations
        self.presentEvidenceKinds = presentEvidenceKinds
        self.attestations = attestations
        self.requiredPhaseKinds = requiredPhaseKinds
    }
}

/// The canonical run-binding tuple: `runStateSHA256` is the canonical-JSON
/// SHA-256 of exactly this value. Public so the bundle verifier (and the
/// mirrored CLI) recompute the SAME bytes the app hashed at assessment time.
public nonisolated struct ConformanceRunBinding: Codable, Sendable, Equatable {
    public let runID: UUID
    public let receiptSeal: String
    public let caseRevision: Int
    public init(runID: UUID, receiptSeal: String, caseRevision: Int) {
        self.runID = runID; self.receiptSeal = receiptSeal; self.caseRevision = caseRevision
    }
}

// MARK: - Assessment (one outcome per rule, Sutra frozen by hash)

public nonisolated enum ConformanceStatus: String, Sendable, Codable {
    case conformant, notConformant, indeterminate
    /// Every mandatory rule resolved, but at least one via an authorized
    /// deviation — distinct on the wire and the certificate, never blended
    /// into plain conformant (audit item 8).
    case conformantWithDeviations

    public var summaryLine: String {
        switch self {
        case .conformant:    return "Conformant — every mandatory rule evaluated and satisfied."
        case .conformantWithDeviations: return "Conformant WITH authorized deviations — every departure is on the certificate."
        case .notConformant: return "Not conformant — at least one mandatory rule failed."
        case .indeterminate: return "Indeterminate — mandatory rule(s) not yet evaluated; conformance cannot be claimed."
        }
    }

    /// THE fail-closed rollup — one computation, used by the assessment AND
    /// every verifier (the CLI is generated from this exact file, so a status
    /// recomputed outside the app is the same code, not a mirror).
    public static func rollup(of evaluations: [RuleEvaluation]) -> ConformanceStatus {
        let mandatory = evaluations.filter { $0.rule.severity == .mandatory }
        if mandatory.contains(where: { $0.outcome == .failed }) { return .notConformant }
        if mandatory.contains(where: { $0.outcome == .notEvaluated || $0.outcome == .evaluatorError }) {
            return .indeterminate
        }
        if mandatory.contains(where: { $0.outcome == .approvedDeviation }) {
            return .conformantWithDeviations
        }
        return .conformant
    }
}

public nonisolated struct ConformanceAssessment: Sendable, Codable, Equatable {
    public let sutraCitation: String
    /// Canonical (sorted-keys) JSON of the exact Sutra assessed against, frozen here.
    public let sutraSnapshotJSON: String
    public let sutraSHA256: String
    public let evaluations: [RuleEvaluation]
    public let assessedAt: Date
    /// The REAL run this assessment binds to (audit item 2). Optional so
    /// pre-binding rows still decode.
    public var runID: UUID? = nil
    /// Hash over the run's immutable identifying state at assessment time.
    public var runStateSHA256: String? = nil
    /// The exact facts consulted — carried so a verifier can RERUN the
    /// evaluators, not merely re-add the outcomes.
    public var facts: ConformanceFacts? = nil
    /// The evidence manifest the run was assessed over (source versions +
    /// content hashes) — exported in bundles; its hash is signed in the seal.
    public var evidenceManifest: [EvidenceManifestEntry]? = nil

    /// Fail-closed rollup: failed beats everything; any mandatory
    /// notEvaluated/evaluatorError makes the whole assessment indeterminate;
    /// any authorized deviation is DISTINCT from plain conformance.
    public var status: ConformanceStatus { ConformanceStatus.rollup(of: evaluations) }

    /// Rules still awaiting an explicit evaluation (drives the attestation UI).
    public var unevaluated: [RuleEvaluation] {
        evaluations.filter { $0.outcome == .notEvaluated || $0.outcome == .evaluatorError }
    }

    /// Deviations are never hidden: a conformant run with authorized deviations
    /// says so on its face (distinct from a clean conformant).
    public var approvedDeviationCount: Int {
        evaluations.filter { $0.outcome == .approvedDeviation }.count
    }
    public var displaySummaryLine: String {
        status == .conformantWithDeviations
            ? "Conformant with \(approvedDeviationCount) authorized deviation(s) — every departure is on the certificate."
            : status.summaryLine
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
        out += "**Status:** \(status.summaryLine)\n"
        // PHASE B — the observed/attested split, on the certificate's face:
        // which reached phases were MACHINE-OBSERVED from the case's own
        // ledgers, and which rest on assertion alone.
        if let facts {
            let reached = facts.completedPhaseKinds
            let observed = facts.observedPhaseKinds ?? []
            if !reached.isEmpty {
                let obs = reached.intersection(observed).map(\.rawValue).sorted().joined(separator: ", ")
                let att = reached.subtracting(observed).map(\.rawValue).sorted().joined(separator: ", ")
                out += "**Phases machine-observed:** \(obs.isEmpty ? "none" : obs)\n"
                out += "**Phases asserted (not machine-observed):** \(att.isEmpty ? "none" : att)\n"
            }
        }
        out += "\n"
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
    /// Pure and deterministic — pass `now` explicitly. `runID`/`runStateSHA256`
    /// bind the assessment to the REAL immutable run; the consulted facts are
    /// embedded so a verifier can rerun the evaluators.
    public static func assess(facts: ConformanceFacts, against sutra: Sutra,
                              at now: Date,
                              runID: UUID? = nil,
                              runStateSHA256: String? = nil) -> ConformanceAssessment {
        // Required phases: the sutra's declared set; legacy sutras default to
        // the findings phase when they have one. An unreached required phase
        // FAILS its rules — a run that never got there cannot be conformant.
        var effectiveFacts = facts
        if effectiveFacts.requiredPhaseKinds.isEmpty {
            let declared = sutra.requiredPhaseKinds
                ?? (sutra.phases.contains { $0.kind == .findings } ? [.findings] : [])
            effectiveFacts.requiredPhaseKinds = Set(declared)
        }
        let rules = SutraRuleCompiler.rules(for: sutra)
        let evaluations = rules.map { evaluate(rule: $0, facts: effectiveFacts) }
        let snapshotJSON = (try? ConformanceCanonical.data(of: sutra))
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let snapshotSHA = snapshotJSON.isEmpty ? ""
            : SHA256.hash(data: Data(snapshotJSON.utf8)).map { String(format: "%02x", $0) }.joined()
        var assessment = ConformanceAssessment(sutraCitation: sutra.citation,
                                               sutraSnapshotJSON: snapshotJSON,
                                               sutraSHA256: snapshotSHA,
                                               evaluations: evaluations,
                                               assessedAt: now)
        assessment.runID = runID
        assessment.runStateSHA256 = runStateSHA256
        assessment.facts = effectiveFacts
        return assessment
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
            // A rule of an unreached REQUIRED phase fails — the run was obliged
            // to get there (audit item 3: required phases never soften to N/A).
            if let phase = rule.phaseKind, facts.requiredPhaseKinds.contains(phase) {
                return RuleEvaluation(rule: rule, outcome: .failed,
                                      evaluatorID: "gate.requiredPhase.v1",
                                      detail: "required phase '\(phase.rawValue)' was not reached")
            }
            return RuleEvaluation(rule: rule, outcome: .notApplicable,
                                  evaluatorID: "gate.applicability.v1",
                                  detail: rule.phaseKind == nil ? "condition not met" : "phase not reached in this run")
        }
        // 2. An authorized, justified deviation — visible, never hidden. A
        //    deviation attempt on a NON-waivable rule (every prohibition) fails:
        //    no free text can authorize asserting a prohibited conclusion.
        if let auth = facts.approvedDeviations[rule.id] {
            guard rule.waivable else {
                return RuleEvaluation(rule: rule, outcome: .failed,
                                      evaluatorID: "gate.nonWaivable.v1",
                                      detail: "deviation refused — this rule is non-waivable (attempted by \(auth.authorizedBy): \(auth.justification))")
            }
            let role = auth.role.map { " (\($0))" } ?? ""
            return RuleEvaluation(rule: rule, outcome: .approvedDeviation,
                                  evaluatorID: "human.deviation.v2",
                                  detail: "authorized deviation by \(auth.authorizedBy)\(role): \(auth.justification)")
        }
        // 3. Declared evidence binding: required kinds must actually be bound to
        //    the run — an attestation cannot substitute for absent evidence.
        let missingEvidence = rule.requiredEvidence.filter { !facts.presentEvidenceKinds.contains($0) }
        if !missingEvidence.isEmpty {
            return RuleEvaluation(rule: rule, outcome: .notEvaluated,
                                  evaluatorID: "gate.evidenceBinding.v1",
                                  detail: "required evidence not bound: \(missingEvidence.joined(separator: ", "))")
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
            if let att = facts.attestations[rule.id] {
                return RuleEvaluation(rule: rule, outcome: .passed, evaluatorID: "human.attest.v2",
                                      detail: Self.attributed("prohibition respected", att))
            }
            return facts.attestedRuleIDs.contains(rule.id)
                ? RuleEvaluation(rule: rule, outcome: .passed, evaluatorID: "human.attest.v1",
                                 detail: "attested (unattributed) that the prohibition was respected")
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
            if let att = facts.attestations[rule.id] {
                return RuleEvaluation(rule: rule, outcome: .passed, evaluatorID: "human.attest.v2",
                                      detail: Self.attributed("obligation met", att))
            }
            return facts.attestedRuleIDs.contains(rule.id)
                ? RuleEvaluation(rule: rule, outcome: .passed, evaluatorID: "human.attest.v1",
                                 detail: "attested (unattributed) that the obligation was met")
                : RuleEvaluation(rule: rule, outcome: .notEvaluated, evaluatorID: "human.attest.v1",
                                 detail: "awaiting reviewer attestation")
        }
    }

    private static func attributed(_ what: String, _ att: RuleAttestation) -> String {
        let role = att.role.map { " (\($0))" } ?? ""
        let when = ISO8601DateFormatter().string(from: att.at)
        return "\(what) — attested by \(att.actor)\(role) at \(when): \(att.rationale)"
    }
}
