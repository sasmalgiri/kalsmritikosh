//
//  ReferenceShelfLane.swift
//  Kalsmritikosh
//
//  Unified path SEARCH-17 (owner 2026-11-22) — not tested yet.
//
//  The THREE LANES of an answer, in order, each labelled:
//    1. your documents   — the archive answer, always first, always with its receipt;
//    2. your reference shelf — documents the person added as reference (acts, rules, manuals),
//       searched when the archive found nothing or the question asks what a rule/term means;
//       passages are QUOTED with their document and section, never reworded, never cited as evidence;
//    3. general knowledge — only when the shelf has nothing, and only when that setting is on
//       (GeneralKnowledgeLane).
//  A shelf passage is never part of VerifiedAnswer: it can never enter citations, the answer ledger,
//  case scope, stories or exports. No sentence mixes lanes. Deterministic; no model call.
//

import Foundation

public nonisolated enum ReferenceShelfLane {

    public static let label = "From your reference shelf — not from your documents"
    public static let note = "Reference material you added (rules, acts, manuals). It explains; it is not evidence in your documents."

    /// Questions that ask what something means or how a procedure/rule goes.
    public static func isKnowledgeShaped(_ question: String) -> Bool {
        let q = question.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let openers = ["what is ", "what are ", "what does ", "define ", "definition of ", "meaning of ",
                       "how do i ", "how to ", "what is the procedure", "what is the rule", "what does the law"]
        if openers.contains(where: { q.hasPrefix($0) }) { return true }
        let words = ["procedure", "rule ", "rules", "section ", "regulation", "act ", "guideline", "manual", "policy says"]
        return words.contains(where: { q.contains($0) })
    }

    /// Whether the shelf lane runs for this answer.
    public static func shouldSearch(question: String, archiveFoundNothing: Bool) -> Bool {
        archiveFoundNothing || isKnowledgeShaped(question)
    }

    /// The rendered block: label first, then each passage quoted with "‹document›, ‹section›".
    public static func render(_ hits: [ReferenceShelfRepository.Hit]) -> String? {
        guard !hits.isEmpty else { return nil }
        var lines = [label, note]
        for h in hits.prefix(3) {
            let place = [h.documentTitle, h.section].compactMap { $0 }.joined(separator: ", ")
            let quote = h.text.count > 600 ? String(h.text.prefix(600)) + "…" : h.text
            lines.append("\(place):\n“\(quote)”")
        }
        return lines.joined(separator: "\n\n")
    }
}
