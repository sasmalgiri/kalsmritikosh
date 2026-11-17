//
//  CaseClaimCheck.swift
//  Kalsmritikosh
//
//  Case plan 2026-11-16 (SEARCH-15) — "Check this claim" without AI: from the words of a point, a question or any item, two
//  editable queries in the case search's own syntax (CaseSearchQuery):
//    • supporting — records that name the claim's subject and state its figures;
//    • contrary   — records that name the same subject but do NOT state those figures (candidates that may say something
//                   else; reading them decides, the query does not).
//  Both are shown before anything runs, with what each means; the person edits them, and the case search runs them with its
//  usual receipt (what was searched, what was not). A quote matching a record never verifies a causal reading.
//  Deterministic text handling; nothing calls a model.
//

import Foundation

public nonisolated enum CaseClaimCheck {

    public struct Plan: Sendable, Equatable {
        public let claim: String
        /// The words or names the claim is about (each becomes a clause of both queries).
        public let subject: [String]
        /// The figures the claim states (amount clauses).
        public let figures: [String]
        public let supporting: String
        /// nil: the claim states no figure, so there is no "same subject, other figure" query to run.
        public let contrary: String?
        /// What the two queries mean, in plain words.
        public let explanation: String
    }

    static let stopWords: Set<String> = [
        "about", "after", "again", "against", "also", "because", "been", "before", "being", "between", "both", "but", "could", "does",
        "during", "each", "from", "have", "having", "into", "more", "most", "only", "other", "over", "said", "same", "should", "since",
        "such", "than", "that", "their", "them", "then", "there", "these", "they", "this", "those", "through", "under", "until", "very",
        "was", "were", "what", "when", "where", "which", "while", "who", "whom", "why", "will", "with", "would", "your", "investigate",
        "paid", "payment", "twice", "claim", "point", "question",
    ]

    /// Build the two queries from the claim's words. `maxTerms` bounds the subject so the query stays readable.
    public static func plan(claim: String, maxTerms: Int = 4) -> Plan {
        let text = claim.replacingOccurrences(of: "\"", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        // Names first (two or more capitalised words in a row, as written), then distinctive words.
        var subject: [String] = []
        let ns = text as NSString
        if let re = try? NSRegularExpression(pattern: #"\b[A-Z][\p{L}'’-]+(?:\s+[A-Z][\p{L}'’-]+)+\b"#) {
            for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let name = ns.substring(with: m.range)
                if !subject.contains(name) { subject.append(name) }
            }
        }
        // When the claim names someone or something, the names are the subject: every other word required as well would
        // miss a record that states the fact in other words (a bank line does not say "invoice"). Plain words are the
        // subject only when the claim names nothing.
        if subject.isEmpty {
            let words = text.components(separatedBy: CharacterSet.letters.inverted)
                .filter { $0.count >= 4 && !stopWords.contains($0.lowercased()) }
            for w in words where !subject.contains(where: { $0.caseInsensitiveCompare(w) == .orderedSame }) { subject.append(w) }
        }
        subject = Array(subject.prefix(maxTerms))

        // Amounts written with a currency (₹, Rs, INR, $, USD, €, £ …, lakh and crore read exactly), in the order written,
        // each once; the clause matches the figure in any currency (the search never converts).
        var figures: [String] = []
        for a in CaseContradictionFinder.amounts(in: text).sorted(by: { $0.range.location < $1.range.location }) {
            let clause = "amount:" + NSDecimalNumber(decimal: a.value).stringValue
            if !figures.contains(clause) { figures.append(clause) }
        }

        func clause(_ s: String) -> String { s.contains(" ") ? "\"\(s)\"" : s }
        let subjectQuery = subject.map(clause).joined(separator: " ")
        let figureQuery = figures.count > 1 ? "(" + figures.joined(separator: " OR ") + ")" : (figures.first ?? "")
        let supporting = [subjectQuery, figureQuery].filter { !$0.isEmpty }.joined(separator: " ")
        let contrary = figures.isEmpty || subjectQuery.isEmpty ? nil : subjectQuery + " NOT " + figureQuery

        var explanation = subject.isEmpty
            ? "The claim names nothing distinctive to search for; type the words to look for."
            : "Supporting: records naming " + subject.map { "“\($0)”" }.joined(separator: ", ")
              + (figures.isEmpty ? "." : " and stating " + figures.map { $0.replacingOccurrences(of: "amount:", with: "") }.joined(separator: " or ") + ".")
        if let contrary, !contrary.isEmpty {
            explanation += " Contrary: records naming the same but not stating that figure — they may give another one; read them to decide."
        } else if !subject.isEmpty {
            explanation += " The claim states no figure, so there is no other-figure query; read the supporting records for statements against it."
        }
        return Plan(claim: claim, subject: subject, figures: figures, supporting: supporting, contrary: contrary, explanation: explanation)
    }

}

// MARK: - The receipt of a check (v194; case plan 2026-11-16, SEARCH-15 / CHANGE-11)

public nonisolated struct CaseClaimCheckRecord: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let caseID: UUID
    public let item: String
    public let claim: String
    public let supportingQuery: String
    public let contraryQuery: String?
    public let ranQuery: String
    public let checkedBy: String
    public let checkedAt: Date
}

extension CaseFileRepository {

    /// Record a "Check this claim" run against the item it checked (append-only) and bind it to that item as it is now, so a
    /// later change to the item makes the check stale with the reason (CaseDerivation.staleness).
    @discardableResult
    public func recordClaimCheck(caseID: UUID, item: CaseMapNodeID, plan: CaseClaimCheck.Plan, ran: String, projection: CaseMapProjection,
                                 actor: String, at date: Date = Date()) async throws -> UUID {
        let who = try Self.clean(actor, "Actor"), query = try Self.clean(ran, "The search")
        guard item.caseID == caseID else { throw CaseWorkError.notInCase("item") }
        let id = UUID()
        try await write("cf_claim", caseID: caseID, actor: who, action: "claimChecked", detail: query, at: date) { db in
            try db.exec("""
                INSERT INTO case_claim_checks (id, case_id, item_kind, item_id, claim, supporting_query, contrary_query, ran_query, saved_search_id,
                    case_revision, checked_by, checked_at)
                VALUES (?,?,?,?,?,?,?,?,NULL,?,?,?);
                """, [.uuid(id), .uuid(caseID), .text(item.kind.rawValue), .text(item.recordID.lowercased()), .text(plan.claim), .text(plan.supporting),
                      .optionalText(plan.contrary), .text(query), .optionalText(projection.node(item)?.revision), .text(who), .date(date)])
        }
        _ = try await bindDerivation(caseID: caseID, derived: .claimCheck, derivedID: id.uuidString, label: "Check of “\(plan.claim.prefix(60))”",
                                     inputs: [item.key], projection: projection, actor: who, at: date)
        return id
    }

    public func claimChecks(caseID: UUID) async throws -> [CaseClaimCheckRecord] {
        try await CaseAccessPolicy.requireRead(database, caseID: caseID)
        return try await database.query("""
            SELECT id, case_id, item_kind, item_id, claim, supporting_query, contrary_query, ran_query, checked_by, checked_at
            FROM case_claim_checks WHERE case_id = ? ORDER BY checked_at, rowid;
            """, [.uuid(caseID)]).compactMap { r in
            guard let id = r.uuid(0), let c = r.uuid(1), let k = r.string(2), let i = r.string(3), let ran = r.string(7), let by = r.string(8),
                  let at = r.date(9) else { return nil }
            return CaseClaimCheckRecord(id: id, caseID: c, item: k + ":" + i, claim: r.string(4) ?? "", supportingQuery: r.string(5) ?? "",
                                        contraryQuery: r.string(6), ranQuery: ran, checkedBy: by, checkedAt: at)
        }
    }
}
