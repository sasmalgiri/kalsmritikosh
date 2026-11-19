//
//  AIMethodReviewContract.swift
//  Kalsmritikosh
//
//  Case plan 2026-11-16 (AI-15) — the structured contract for an AI's review of the professional methods against a case
//  question, and its deterministic check against exactly what was sent. Scaffolding only: this decides nothing about how
//  good any AI is; it decides what the app keeps from whatever comes back.
//
//  Reply (JSON): {"methods": [{"method_id": "...", "outcome": "usefulNow|alreadyCovered|needsInput|usefulLater|inapplicable",
//    "reason": "...", "checks": [{"observation": "...", "target": "...", "predicts": {"<explanation>": "<expected>"},
//    "evidence": [{"document": 1, "quote": "..."}]}]}]}
//  Checked: every method id must be one the app registers (others are dropped, with the reason); an outcome outside the
//  vocabulary is dropped; every quote must be in its document word for word (CaseContradictionFinder.verbatim) — a check
//  whose quotes do not verify is kept but labelled UNGROUNDED; a registered method the reply does not cover is "not
//  assessed", never silently assumed. The reply's checks become shortlist candidates (origin .method), merged and ranked by
//  the same rules as the offline review. Nothing here calls a model.
//

import Foundation

public nonisolated enum AIMethodReviewContract {

    public struct Check: Sendable, Equatable {
        public let methodID: String
        public let observation: String
        public let target: String
        /// What each competing explanation predicts would be observed (the AI's words).
        public let predicts: [String: String]
        /// Quotes that were found word for word in the documents sent, with the document's object id.
        public let verifiedQuotes: [(objectID: UUID, quote: String)]
        /// True when no quote verified: the check is shown labelled as ungrounded (the AI's suggestion only).
        public let ungrounded: Bool
        public static func == (a: Check, b: Check) -> Bool {
            a.methodID == b.methodID && a.observation == b.observation && a.target == b.target && a.predicts == b.predicts
                && a.ungrounded == b.ungrounded && a.verifiedQuotes.map(\.quote) == b.verifiedQuotes.map(\.quote)
        }
    }

    public struct Result: Sendable, Equatable {
        /// One assessment per registered method: the AI's where it gave a valid one, "not assessed" where it did not.
        public let assessments: [CaseMethodAssessment]
        public let checks: [Check]
        /// What was dropped, each with why.
        public let dropped: [String]
        /// The registered methods the reply did not cover.
        public let notCovered: [String]
    }

    /// The task text sent with the case (the reply format and its rules; the question and documents are sent beside it).
    public static func task(question: String, methods: [CaseMethodReviewMethod]) -> String {
        """
        Question: \(question)
        Review each of these methods for this question: \(methods.map { "\($0.id) (\($0.label))" }.joined(separator: "; ")).
        For each, give outcome usefulNow, alreadyCovered, needsInput, usefulLater or inapplicable, with a reason, and any checks
        that would tell the explanations apart: what to observe, from what or whom, what each explanation predicts, and the
        exact words of the documents (with their number) the check rests on. Quote only words that are in the documents.
        Reply with JSON only: {"methods": [{"method_id": "...", "outcome": "...", "reason": "...", "checks": [{"observation": "...", "target": "...", "predicts": {"...": "..."}, "evidence": [{"document": 1, "quote": "..."}]}]}]}
        """
    }

    /// Check a reply against the registered methods and exactly the documents sent (document N is `documents[N-1]`).
    public static func verify(reply: String, methods: [CaseMethodReviewMethod], documents: [(objectID: UUID, text: String)]) -> Result {
        var dropped: [String] = []
        var byMethod: [String: CaseMethodAssessment] = [:]
        var checks: [Check] = []
        let registered = Dictionary(methods.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let body = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        let json = body.firstIndex(of: "{").map { String(body[$0...]) } ?? body
        guard let data = json.data(using: .utf8), let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["methods"] as? [[String: Any]] else {
            let notAssessed = methods.map { notAssessedRow($0, "The AI's reply could not be read, so this method was not assessed.") }
            return Result(assessments: notAssessed, checks: [], dropped: ["The reply is not the expected JSON."], notCovered: methods.map(\.id))
        }
        for raw in list {
            guard let id = raw["method_id"] as? String, let m = registered[id] else {
                dropped.append("not a registered method: \((raw["method_id"] as? String) ?? "no id")"); continue
            }
            guard let o = (raw["outcome"] as? String).flatMap(CaseMethodApplicability.init(rawValue:)), o != .notAssessed else {
                dropped.append("\(m.label): an outcome outside the vocabulary"); continue
            }
            let reason = ((raw["reason"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !reason.isEmpty else { dropped.append("\(m.label): no reason given"); continue }
            byMethod[id] = CaseMethodAssessment(methodID: id, methodVersion: m.version, label: m.label, outcome: o,
                                                reason: "The AI's suggestion: " + reason,
                                                contributes: CaseMethodReview.contributes[String(id.dropFirst(CaseMethodReview.prefix.count))] ?? "",
                                                priorRunID: nil)
            for c in (raw["checks"] as? [[String: Any]]) ?? [] {
                let observation = ((c["observation"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !observation.isEmpty else { dropped.append("\(m.label): a check with nothing to observe"); continue }
                var quotes: [(UUID, String)] = []
                for e in (c["evidence"] as? [[String: Any]]) ?? [] {
                    guard let n = e["document"] as? Int, (1...max(1, documents.count)).contains(n), !documents.isEmpty,
                          let q = (e["quote"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !q.isEmpty else {
                        dropped.append("\(m.label): a quote citing a document that was not sent"); continue
                    }
                    if CaseContradictionFinder.verbatim(q, in: documents[n - 1].text) { quotes.append((documents[n - 1].objectID, q)) }
                    else { dropped.append("\(m.label): a quote not found word for word in document \(n)") }
                }
                let predicts = (c["predicts"] as? [String: String]) ?? [:]
                checks.append(Check(methodID: id, observation: observation, target: (c["target"] as? String) ?? "",
                                    predicts: predicts, verifiedQuotes: quotes, ungrounded: quotes.isEmpty))
            }
        }
        let notCovered = methods.filter { byMethod[$0.id] == nil }.map(\.id)
        let assessments = methods.map { byMethod[$0.id] ?? notAssessedRow($0, "The AI's reply did not cover this method, so it was not assessed.") }
        return Result(assessments: assessments, checks: checks, dropped: dropped, notCovered: notCovered)
    }

    /// The reply's checks as shortlist candidates (merged and ranked with the offline ones by CaseCheckShortlist).
    public static func candidates(_ r: Result) -> [CaseCheckCandidate] {
        r.checks.enumerated().map { i, c in
            CaseCheckCandidate(id: "ai:\(i):" + c.methodID, title: (c.ungrounded ? "AI suggestion (ungrounded): " : "AI suggestion: ") + c.observation,
                               observation: c.observation, target: c.target, origin: .method)
        }
    }

    static func notAssessedRow(_ m: CaseMethodReviewMethod, _ why: String) -> CaseMethodAssessment {
        CaseMethodAssessment(methodID: m.id, methodVersion: m.version, label: m.label, outcome: .notAssessed, reason: why,
                             contributes: CaseMethodReview.contributes[String(m.id.dropFirst(CaseMethodReview.prefix.count))] ?? "", priorRunID: nil)
    }
}
