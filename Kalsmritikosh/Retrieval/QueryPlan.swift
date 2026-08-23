//
//  QueryPlan.swift
//  Kalsmritikosh
//
//  RET-001 — the query compiler. Consolidates the existing query-analysis
//  signals (UserIntent, QueryCategory, LLMQueryClass) into ONE explicit,
//  inspectable plan that names what the question actually asks for:
//
//    • target subjects        — the entities/scope the answer is about
//    • requested fields        — the facets the answer must supply (amount, date, employer…)
//    • time scope              — the timeframe, if any
//    • preferred source roles  — which KIND of document is authoritative for this question
//    • evidence policy         — corroboration / duplicate-independence rules
//
//  This is the input to RET-003 (DocumentFitness). Fitness scores a candidate
//  document by how well its role + the fields it carries MATCH this plan —
//  replacing the raw mention-density heuristic that currently decides authority.
//
//  Design notes:
//  • Deterministic and offline — zero model calls. It reads the question text
//    and the already-computed intent/category/class.
//  • Domain-neutral: `RequestedField` and `PreferredSourceRole` are generic
//    (any-subject contract). Domain packs (SEM-004…008) may later enrich the
//    role/field mapping; absence of a pack still yields a usable plan.
//  • `PreferredSourceRole` is a lightweight local enum PENDING SEM-001, which
//    will introduce the canonical DocumentRole. Kept separate to avoid a
//    premature schema dependency; consolidate when SEM-001 lands.
//

import Foundation

/// A facet the question asks the answer to supply. Open-ended via `.other`.
public enum RequestedField: String, Codable, Sendable, Hashable, CaseIterable {
    case monetaryAmount     // "how much", "amount", currency symbols
    case counterparty       // "to whom", "paid to", "from whom"
    case date               // "when", "on what date"
    case employment         // "where worked", "employer", "which company", "role/position"
    case location           // "where", "which city/place"
    case definition         // "what is", "explain"
    case status             // "granted/pending/final/approved", "current status"
    case quantity           // "how many", counts
    case contactInfo        // phone/email/address
    case terms              // contract terms/clauses/conditions
    case identity           // "who is", identity of a person/org
    case cause              // "why", root cause
    case other              // catch-all when no specific facet is detected
}

/// The kind of document that is *authoritative* for a question. Ranked, not exclusive.
/// PENDING SEM-001 canonical DocumentRole — kept local to avoid a schema dependency.
public enum PreferredSourceRole: String, Codable, Sendable, Hashable, CaseIterable {
    case biographical       // résumé / CV / profile — authoritative for employment/identity
    case transactional      // receipt / invoice / bank statement — authoritative for payments
    case contractual        // contract / agreement — authoritative for terms
    case official           // patent grant / certificate / registration — authoritative for status
    case correspondence     // email / letter / message — context, rarely the primary authority
    case report             // report / article / study
    case identityDocument   // ID / passport / licence
    case any                // no strong preference
}

/// The corroboration rules the answer must respect.
public nonisolated struct EvidencePolicy: Codable, Sendable, Hashable {
    /// At least two independent sources required before a material claim ships.
    public let requiresCorroboration: Bool
    /// Duplicate copies of the same source never count as independent corroboration.
    public let duplicatesAreNotIndependent: Bool
    /// Minimum distinct source families for a corroborated claim (when required).
    public let minIndependentSources: Int

    public nonisolated init(
        requiresCorroboration: Bool,
        duplicatesAreNotIndependent: Bool = true,
        minIndependentSources: Int = 2
    ) {
        self.requiresCorroboration = requiresCorroboration
        self.duplicatesAreNotIndependent = duplicatesAreNotIndependent
        self.minIndependentSources = requiresCorroboration ? max(2, minIndependentSources) : 1
    }
}

/// The compiled, explicit plan for a question. Inspectable and Codable so it can
/// be logged, shown in the quality strip, and asserted against in tests.
public nonisolated struct QueryPlan: Codable, Sendable, Hashable {
    public let rawQuestion: String
    public let targetSubjects: [String]
    public let requestedFields: [RequestedField]
    public let timeScope: UserIntent.Timeframe?
    /// Source roles ranked most→least authoritative for THIS question.
    public let preferredSourceRoles: [PreferredSourceRole]
    public let category: QueryCategory
    public let queryClass: LLMQueryClass
    public let evidencePolicy: EvidencePolicy
    public let rationale: String

    public nonisolated init(
        rawQuestion: String,
        targetSubjects: [String],
        requestedFields: [RequestedField],
        timeScope: UserIntent.Timeframe?,
        preferredSourceRoles: [PreferredSourceRole],
        category: QueryCategory,
        queryClass: LLMQueryClass,
        evidencePolicy: EvidencePolicy,
        rationale: String
    ) {
        self.rawQuestion = rawQuestion
        self.targetSubjects = targetSubjects
        self.requestedFields = requestedFields
        self.timeScope = timeScope
        self.preferredSourceRoles = preferredSourceRoles
        self.category = category
        self.queryClass = queryClass
        self.evidencePolicy = evidencePolicy
        self.rationale = rationale
    }
}

/// Compiles a question + its already-computed signals into a `QueryPlan`.
/// Deterministic, offline, no model calls.
public struct QueryPlanCompiler: Sendable {
    public nonisolated init() {}

    public nonisolated func compile(
        intent: UserIntent,
        category: QueryCategory,
        queryClass: LLMQueryClass
    ) -> QueryPlan {
        let q = intent.rawQuestion.lowercased()

        let subjects = Self.targetSubjects(from: intent)
        let fields = Self.requestedFields(in: q)
        let roles = Self.preferredRoles(for: fields, question: q)
        let policy = EvidencePolicy(requiresCorroboration: Self.requiresCorroboration(queryClass))

        let rationale = "subjects=\(subjects.count); fields=\(fields.map(\.rawValue)); "
            + "roles=\(roles.map(\.rawValue)); corroboration=\(policy.requiresCorroboration)"

        return QueryPlan(
            rawQuestion: intent.rawQuestion,
            targetSubjects: subjects,
            requestedFields: fields,
            timeScope: intent.timeframe,
            preferredSourceRoles: roles,
            category: category,
            queryClass: queryClass,
            evidencePolicy: policy,
            rationale: rationale
        )
    }

    /// Mirror of `LLMQueryClass.requiresCorroboration` computed here so the compiler
    /// stays nonisolated (that property is main-actor isolated at its definition).
    nonisolated static func requiresCorroboration(_ c: LLMQueryClass) -> Bool {
        switch c {
        case .complex, .reconstruction, .deepReconstruction, .investigation:
            return true
        case .deterministic, .ordinary, .moderate, .unsupported:
            return false
        }
    }

    // MARK: - Subject extraction

    nonisolated static func targetSubjects(from intent: UserIntent) -> [String] {
        var subjects: [String] = []
        switch intent.scope {
        case .person(let n), .organization(let n), .project(let n), .folder(let n):
            subjects.append(n)
        case .global:
            break
        }
        for h in intent.entityHints where !subjects.contains(where: { $0.caseInsensitiveCompare(h) == .orderedSame }) {
            subjects.append(h)
        }
        return subjects
    }

    // MARK: - Field detection (deterministic keyword patterns)

    nonisolated static func requestedFields(in q: String) -> [RequestedField] {
        var fields: [RequestedField] = []
        func add(_ f: RequestedField) { if !fields.contains(f) { fields.append(f) } }

        // Monetary amount
        if q.contains("how much") || q.contains("amount") || q.contains("paid") || q.contains("cost")
            || q.contains("price") || q.contains("₹") || q.contains("rs.") || q.contains("$")
            || q.contains("fee") || q.contains("balance") {
            add(.monetaryAmount)
        }
        // Counterparty / payee
        if q.contains("to whom") || q.contains("paid to") || q.contains("payee")
            || q.contains("from whom") || q.contains("recipient") || q.contains("sender") {
            add(.counterparty)
        }
        // Employment / biographical detail (a person's own record is authoritative)
        if (q.contains("work") && (q.contains("where") || q.contains("company") || q.contains("employ")))
            || q.contains("employer") || q.contains("employed") || q.contains("position")
            || q.contains("job title") || q.contains("designation") || q.contains("role at")
            || q.contains("experience") || q.contains("career") || q.contains("background")
            || q.contains("qualification") || q.contains("education") || q.contains("profile")
            || q.contains("skills") || q.contains("expertise") {
            add(.employment)
        }
        // Date / when
        if q.contains("when") || q.contains("what date") || q.contains("which year")
            || q.contains("date of") || q.contains("deadline") {
            add(.date)
        }
        // Location
        if q.hasPrefix("where") && !fields.contains(.employment) || q.contains("which city")
            || q.contains("located") || q.contains("address of") {
            add(.location)
        }
        // Terms
        if q.contains("terms") || q.contains("clause") || q.contains("condition")
            || q.contains("obligation") || q.contains("what were the terms") {
            add(.terms)
        }
        // Status
        if q.contains("status") || q.contains("granted") || q.contains("pending")
            || q.contains("approved") || q.contains("final version") || q.contains("current") {
            add(.status)
        }
        // Quantity
        if q.contains("how many") || q.contains("number of") || q.contains("count of") {
            add(.quantity)
        }
        // Contact (avoid brand names like "PhonePe" — require a contact-specific phrase)
        if q.contains("phone number") || q.contains("contact number") || q.contains("email address")
            || q.contains("contact details") || q.contains("contact info") || q.contains("mobile number") {
            add(.contactInfo)
        }
        // Definition / identity / cause
        if q.hasPrefix("what is") || q.hasPrefix("what are") || q.contains("explain") || q.contains("describe") {
            add(.definition)
        }
        if q.hasPrefix("who is") || q.hasPrefix("who was") || q.contains("identity of") {
            add(.identity)
        }
        if q.hasPrefix("why") || q.contains("root cause") || q.contains("reason for") {
            add(.cause)
        }

        if fields.isEmpty { add(.other) }
        return fields
    }

    // MARK: - Source-role preference

    nonisolated static func preferredRoles(for fields: [RequestedField], question q: String) -> [PreferredSourceRole] {
        var roles: [PreferredSourceRole] = []
        func add(_ r: PreferredSourceRole) { if !roles.contains(r) { roles.append(r) } }

        for f in fields {
            switch f {
            case .monetaryAmount, .counterparty:
                add(.transactional)               // a receipt/invoice wins a payment question
            case .employment:
                add(.biographical)                // a résumé wins "where worked"
            case .terms:
                add(.contractual)
            case .status:
                add(.official)                    // a grant/certificate wins a status question
            case .identity:
                add(.biographical); add(.identityDocument)
            case .definition, .cause:
                add(.report)
            case .date, .location, .quantity, .contactInfo, .other:
                break
            }
        }
        // A question that NAMES a contract/agreement/amendment is authoritatively
        // answered by the contractual document itself (and its amendments) — the
        // status, terms, and evolution of a contract live there, not in the
        // correspondence that merely references it. Prepend `.contractual` so it
        // outranks the (often high-mention) email pile in the fitness ranking;
        // without this a "contract status over time" question mapped only to
        // `.official` and the authoritative .md contract/amendment were evicted
        // by supplier email density (measured: temporal T3 retrieval recall 0.00).
        if q.contains("contract") || q.contains("agreement")
            || q.contains("amendment") || q.contains("clause") {
            roles.removeAll { $0 == .contractual }
            roles.insert(.contractual, at: 0)
        }

        // Correspondence is context, never a strong default authority.
        add(.correspondence)
        add(.any)
        return roles
    }
}
