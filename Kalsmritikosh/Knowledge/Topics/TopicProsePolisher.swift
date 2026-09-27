//
//  TopicProsePolisher.swift
//  Kalsmritikosh
//
//  Topic-Ledger U6 (owner rule 2 — AI connective polish) — OPTIONALLY smooth a
//  deterministic topic spine into readable prose using a reasoning model, adding
//  ONLY grammar/connective words. It never changes the facts: the polished text
//  is accepted only if it preserves every number and proper-noun token the spine
//  carried and invents no new number. When no model is available (the injected
//  reasoner returns nil) or the guard fails, it returns the spine UNCHANGED — so
//  the topic is always at least the deterministic rollup, model or not.
//
//  Pure: the model call is an injected closure, so this is fully unit-testable
//  and the on-device model stays behind the capability boundary.
//

import Foundation

public struct TopicProsePolisher: Sendable {
    /// Injected reasoner: spine text → polished prose, or nil when no model.
    public let reason: @Sendable (_ spine: String) async -> String?

    public init(reason: @escaping @Sendable (_ spine: String) async -> String?) {
        self.reason = reason
    }

    /// Return polished prose if it is available AND preserves every fact;
    /// otherwise the spine unchanged.
    public func polish(spine: String) async -> String {
        guard let candidate = await reason(spine), !candidate.isEmpty else { return spine }
        return Self.preservesFacts(spine: spine, candidate: candidate) ? candidate : spine
    }

    /// The fact-preservation guard: the candidate must contain every number run
    /// from the spine, introduce NO number the spine lacks, and retain every
    /// CONTENT word (the values — not the template's field labels/headings).
    /// Comparison is case-insensitive (prose may lowercase "Patent"). Length is
    /// bounded so it can't ramble.
    public nonisolated static func preservesFacts(spine: String, candidate: String) -> Bool {
        let spineNums = numberRuns(spine)
        let candNums = numberRuns(candidate)
        guard spineNums.isSubset(of: candNums) else { return false }   // no fact dropped
        guard candNums.isSubset(of: spineNums) else { return false }   // no number invented
        let candLower = candidate.lowercased()
        for word in contentWords(spine) where !candLower.contains(word) { return false }
        guard candidate.count <= max(spine.count * 3, spine.count + 200) else { return false }
        return true
    }

    // MARK: - P1.15 cost bounds

    /// Wall-clock budget for ONE topic build's polish calls. Topics are
    /// polished most-evidenced first; past the budget a topic keeps its
    /// deterministic spine (or its still-faithful earlier polish) until the
    /// next build. Measured: ~70 s per call in the test host, 79 topics.
    public static let buildBudgetSeconds: Double = 240
    /// One polish call may not hold the build longer than this.
    public static let callDeadlineSeconds: Double = 60

    /// P1.15 — may an EARLIER polish stand for this spine without a new call?
    /// Yes when it passes the fact guard against the NEW spine and names no
    /// proper noun the spine lacks (the guard alone allows extra words, so a
    /// polish of an older, larger spine could still mention a removed party).
    public nonisolated static func stillFaithful(stored: String, spine: String) -> Bool {
        guard stored != spine, preservesFacts(spine: spine, candidate: stored) else { return false }
        let spineLower = spine.lowercased()
        for sentence in stored.split(whereSeparator: { ".!?\n".contains($0) }) {
            let words = sentence.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" })
            for (i, w) in words.enumerated() where w.count >= 3 {
                guard let first = w.first, first.isUppercase else { continue }
                let lower = w.lowercased()
                // A sentence's first word is capitalised by grammar — pass it
                // only when it is an ordinary opener, never a name.
                if i == 0, sentenceOpeners.contains(lower) { continue }
                if !spineLower.contains(lower) { return false }
            }
        }
        return true
    }

    /// Words prose starts sentences with that are not names.
    static let sentenceOpeners: Set<String> = [
        "the", "this", "these", "that", "those", "its", "their", "his", "her", "they", "there",
        "it", "in", "on", "at", "by", "for", "from", "as", "after", "before", "during", "when",
        "while", "since", "with", "both", "also", "however", "then", "later", "finally", "between",
        "over", "under", "each", "all", "one", "two", "three", "most", "some", "an", "a", "following",
    ]

    nonisolated static func numberRuns(_ text: String) -> Set<String> {
        var out: Set<String> = []; var cur = ""
        for ch in text {
            if ch.isNumber { cur.append(ch) }
            else if !cur.isEmpty { out.insert(cur); cur = "" }
        }
        if !cur.isEmpty { out.insert(cur) }
        return out
    }

    /// Fixed template words the deterministic spine emits (headings/connectors) —
    /// prose may drop these without losing meaning.
    static let templateStop: Set<String> = [
        "topic", "what", "the", "sources", "record", "records", "timeline", "and", "with", "from",
    ]

    /// The VALUE words of a spine that a faithful polish must keep: alphabetic
    /// tokens (len ≥ 4), lowercased, minus the template words and minus any field
    /// LABEL (a token written immediately before a ":" in the spine, e.g.
    /// "Applicant:"). Numbers are checked separately.
    nonisolated static func contentWords(_ spine: String) -> Set<String> {
        var labels: Set<String> = []
        for token in spine.components(separatedBy: .whitespacesAndNewlines) where token.hasSuffix(":") {
            labels.insert(token.dropLast().lowercased())
        }
        var out: Set<String> = []
        for raw in spine.components(separatedBy: CharacterSet.alphanumerics.inverted) where raw.count >= 4 {
            guard raw.contains(where: { $0.isLetter }) else { continue }   // skip pure numbers
            let w = raw.lowercased()
            if templateStop.contains(w) || labels.contains(w) { continue }
            out.insert(w)
        }
        return out
    }
}
