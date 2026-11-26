//
//  FollowUpSuggester.swift
//  Kalsmritikosh
//
//  Unified path SEARCH-16 (owner 2026-11-22) — not tested yet.
//
//  Follow-up questions under an answer, drawn deterministically from what the answer already
//  stands on: the people/organisations and dated events in its cited documents and, in a case,
//  the case briefing's open items (conflicts, documents not read, missing evidence). No model call.
//  A suggestion is only a question the person may ask — it is never an answer and never evidence.
//

import Foundation

public nonisolated enum FollowUpSuggester {

    public struct Input: Sendable {
        public var question: String
        public var people: [String] = []
        public var organisations: [String] = []
        /// Dated events in the cited documents (title).
        public var events: [String] = []
        /// Case open items.
        public var conflicts: [String] = []
        public var unreadDocuments: [String] = []
        public var missingEvidence: [String] = []
        public init(question: String) { self.question = question }
    }

    public static let maximum = 4

    /// Up to `maximum` questions, open case items first (they are what the investigation still lacks),
    /// then the cited people, organisations and events. Never repeats the question asked.
    public static func suggestions(_ input: Input) -> [String] {
        let asked = input.question.lowercased()
        var out: [String] = []
        func add(_ s: String) {
            guard out.count < maximum, !out.contains(s), !asked.contains(s.lowercased()) else { return }
            out.append(s)
        }
        func clip(_ s: String, _ n: Int = 60) -> String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.count <= n ? t : String(t.prefix(n)) + "…"
        }
        if let c = input.conflicts.first { add("Which documents disagree about \(clip(c))?") }
        if let m = input.missingEvidence.first { add("What evidence is still missing about \(clip(m))?") }
        if let d = input.unreadDocuments.first { add("What could not be read in \(clip(d, 50)), and why?") }
        for p in input.people.prefix(2) where !asked.contains(p.lowercased()) {
            add("What else do the documents say about \(clip(p, 40))?")
        }
        for o in input.organisations.prefix(1) where !asked.contains(o.lowercased()) {
            add("Who at \(clip(o, 40)) is involved, and how?")
        }
        if let e = input.events.first { add("What happened before and after \(clip(e))?") }
        if !input.people.isEmpty || !input.events.isEmpty, !asked.contains("timeline") {
            add("Show the timeline of these events")
        }
        return out
    }
}
