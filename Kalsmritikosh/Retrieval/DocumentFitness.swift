//
//  DocumentFitness.swift
//  Kalsmritikosh
//
//  RET-003 — question-conditioned document fitness. Replaces the mention-DENSITY
//  authority heuristic (a document that merely mentions the subject a lot wins)
//  with a reusable rule: a document is authoritative for a question to the extent
//  that its ROLE and the FIELDS it carries MATCH the compiled QueryPlan.
//
//  This is the general rule the pack requires (§7 "no hard-coded boost to fix a
//  single example"): it scores ANY candidate by fit, so a receipt wins a payment
//  question and a résumé wins an employment question — for the same reason, not
//  by name. Density becomes at most a weak tie-breaker, never the authority.
//
//  Scope of THIS file: the pure, deterministic scorer + a bridge role-inference
//  from general signals (filename / source type / detected fields). It does NOT
//  yet modify HybridRetriever — wiring is a separate, eval-gated step so live
//  ranking is not changed until the scorer is proven on the real corpus.
//
//  Role inference is a BRIDGE pending SEM-001's canonical DocumentRole; it uses
//  reusable signal patterns, not per-document special cases.
//

import Foundation

/// Signals about a candidate document, assembled from the ledger at query time.
/// `presentFields` is what the document actually contains (detected over its text
/// / blocks); `roleHints` are inferred roles (a document may read as more than one).
public struct DocumentSignals: Sendable, Hashable {
    public let objectID: KnowledgeObject.ID
    public let fileName: String
    public let sourceType: SourceType
    public let roleHints: [PreferredSourceRole]
    public let presentFields: Set<RequestedField>
    /// Per-subject mention count (the OLD authority signal) — retained only as a
    /// weak tie-breaker, never the primary score.
    public let subjectMentionCount: Int

    public nonisolated init(
        objectID: KnowledgeObject.ID,
        fileName: String,
        sourceType: SourceType,
        roleHints: [PreferredSourceRole],
        presentFields: Set<RequestedField>,
        subjectMentionCount: Int = 0
    ) {
        self.objectID = objectID
        self.fileName = fileName
        self.sourceType = sourceType
        self.roleHints = roleHints
        self.presentFields = presentFields
        self.subjectMentionCount = subjectMentionCount
    }
}

/// The fitness verdict for one candidate document against one QueryPlan.
public struct DocumentFitness: Sendable, Hashable, Comparable {
    public let objectID: KnowledgeObject.ID
    public let score: Double
    public let matchedRole: PreferredSourceRole?
    public let matchedFields: [RequestedField]
    public let rationale: String

    public static func < (a: DocumentFitness, b: DocumentFitness) -> Bool { a.score < b.score }
}

public struct DocumentFitnessScorer: Sendable {
    public nonisolated init() {}

    // Weights: role fit dominates, field fit next, density is a whisker.
    private nonisolated static let wRole = 1.0
    private nonisolated static let wField = 0.8
    private nonisolated static let wDensity = 0.05
    private nonisolated static let correspondencePenalty = 0.5

    /// Score a candidate against the plan. Higher = more authoritative for THIS question.
    public nonisolated func score(plan: QueryPlan, candidate: DocumentSignals) -> DocumentFitness {
        // Role fit: best (highest-ranked) preferred role the candidate satisfies.
        // Earlier in preferredSourceRoles == more authoritative, so weight by rank.
        var roleScore = 0.0
        var matchedRole: PreferredSourceRole?
        let ranked = plan.preferredSourceRoles
        for (idx, role) in ranked.enumerated() where role != .any && role != .correspondence {
            if candidate.roleHints.contains(role) {
                // rank 0 -> 1.0, rank 1 -> ~0.83, decaying; take the best match only.
                let rankWeight = 1.0 / (1.0 + Double(idx))
                if rankWeight > roleScore { roleScore = rankWeight; matchedRole = role }
            }
        }

        // Field fit: fraction of requested fields the document actually carries.
        let requested = plan.requestedFields.filter { $0 != .other }
        let matched = requested.filter { candidate.presentFields.contains($0) }
        let fieldScore = requested.isEmpty ? 0.0 : Double(matched.count) / Double(requested.count)

        // Correspondence penalty: if a SPECIFIC role was requested but this doc is only
        // correspondence (email/letter), it is context, not authority — dock it.
        let specificRequested = ranked.contains { $0 != .any && $0 != .correspondence }
        let onlyCorrespondence = candidate.roleHints.allSatisfy { $0 == .correspondence || $0 == .any }
        let penalty = (specificRequested && onlyCorrespondence) ? Self.correspondencePenalty : 0.0

        // Density: weak tie-breaker only (log-damped so a 186× email can't dominate).
        let density = Self.wDensity * log1p(Double(max(0, candidate.subjectMentionCount)))

        let total = Self.wRole * roleScore + Self.wField * fieldScore + density - penalty

        let rationale = "role=\(matchedRole?.rawValue ?? "none")(\(String(format: "%.2f", roleScore))) "
            + "fields=\(matched.map(\.rawValue))(\(matched.count)/\(requested.count)) "
            + "density=\(String(format: "%.2f", density)) penalty=\(penalty)"

        return DocumentFitness(
            objectID: candidate.objectID,
            score: total,
            matchedRole: matchedRole,
            matchedFields: matched,
            rationale: rationale
        )
    }

    /// Rank candidates most→least authoritative for the plan (stable on ties).
    public nonisolated func rank(plan: QueryPlan, candidates: [DocumentSignals]) -> [DocumentFitness] {
        candidates.map { score(plan: plan, candidate: $0) }
            .enumerated()
            .sorted { $0.element.score != $1.element.score ? $0.element.score > $1.element.score : $0.offset < $1.offset }
            .map(\.element)
    }
}

// MARK: - Bridge role inference (pending SEM-001 canonical DocumentRole)

public enum DocumentRoleInference {

    /// Infer role hints from general, reusable signals: filename keywords, source
    /// type, and which fields the text exposes. NOT a per-document special case.
    public nonisolated static func inferRoles(
        fileName: String,
        sourceType: SourceType,
        presentFields: Set<RequestedField>
    ) -> [PreferredSourceRole] {
        let n = fileName.lowercased()
        var roles: [PreferredSourceRole] = []
        func add(_ r: PreferredSourceRole) { if !roles.contains(r) { roles.append(r) } }

        // Filename signals
        if n.contains("resume") || n.contains("cv") || n.contains("curriculum")
            || n.contains("bio") || n.contains("profile") { add(.biographical) }
        if n.contains("receipt") || n.contains("invoice") || n.contains("transaction")
            || n.contains("payment") || n.contains("statement") || n.contains("bill") { add(.transactional) }
        if n.contains("contract") || n.contains("agreement") || n.contains("mou")
            || n.contains("nda") || n.contains("terms") { add(.contractual) }
        if n.contains("patent") || n.contains("certificate") || n.contains("grant")
            || n.contains("registration") || n.contains("licen") { add(.official) }
        if n.contains("report") || n.contains("study") || n.contains("article")
            || n.contains("paper") { add(.report) }

        // Content-field signals (a doc exposing amount+counterparty reads transactional)
        if presentFields.contains(.monetaryAmount) && presentFields.contains(.counterparty) {
            add(.transactional)
        }
        if presentFields.contains(.employment) { add(.biographical) }
        if presentFields.contains(.terms) { add(.contractual) }

        // Source-type signals (email family reads as correspondence)
        switch sourceType {
        case .mbox, .eml, .appleMail, .pst, .msg, .nsf: add(.correspondence)
        default: break
        }

        if roles.isEmpty { add(.any) }
        return roles
    }

    /// Which requested fields a DOCUMENT's text actually exposes. This is the
    /// doc-side complement of `QueryPlanCompiler.requestedFields` (which reads a
    /// QUESTION). Used by fitness field-match. Deterministic; scans a bounded
    /// prefix for speed. Reusable signal patterns, not per-document rules.
    public nonisolated static func presentFields(inText text: String) -> Set<RequestedField> {
        let t = String(text.prefix(6000)).lowercased()
        var f: Set<RequestedField> = []
        let hasDigit = t.contains(where: \.isNumber)

        if hasDigit && (t.contains("₹") || t.contains("$") || t.contains("rs.") || t.contains("inr")
            || t.contains("usd") || t.contains("amount") || t.contains("paid") || t.contains("total")
            || t.contains("balance")) {
            f.insert(.monetaryAmount)
        }
        if t.contains("paid to") || t.contains("payee") || t.contains("recipient")
            || t.contains("beneficiary") || t.contains("transferred to") || t.contains("received from") {
            f.insert(.counterparty)
        }
        if t.contains("worked at") || t.contains("employer") || t.contains("designation")
            || t.contains("position") || t.contains("employed") || t.contains("responsibilit")
            || t.contains("experience") || t.contains("organization") || t.contains("work experience")
            || t.contains("professional") || t.contains("career") {
            f.insert(.employment)
        }
        if t.contains("terms") || t.contains("clause") || t.contains("hereby")
            || t.contains("shall") || t.contains("obligation") || t.contains("agreement") {
            f.insert(.terms)
        }
        if t.contains("granted") || t.contains("approved") || t.contains("issued")
            || t.contains("registered") || t.contains("pending") || t.contains("final version") {
            f.insert(.status)
        }
        return f
    }
}
