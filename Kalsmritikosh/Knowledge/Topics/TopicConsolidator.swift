//
//  TopicConsolidator.swift
//  Kalsmritikosh
//
//  Topic-Ledger (owner rule, 2026-09-18) — MINIMIZE topics to the few that
//  actually carry context. A subject with too little evidence is NOT a real
//  topic; standing alone it pollutes investigation / history reconstruction.
//  So a THIN subject is merged into its CLOSEST substantive subject (by shared
//  content terms), contributing its facts there instead of spawning a noise
//  topic. When nothing substantive exists, the single largest subject becomes
//  the sole topic and absorbs the rest. Result: a handful of rich topics, each
//  backed by real evidence.
//
//  Pure and deterministic; operates on subject→facts groups before spines are
//  built, so the downstream topic build sees only consolidated subjects.
//

import Foundation

public enum TopicConsolidator {

    public struct SubjectFacts: Sendable, Equatable {
        public let subject: String
        public let facts: [GenericFact]
        public init(subject: String, facts: [GenericFact]) {
            self.subject = subject; self.facts = facts
        }
    }

    /// A subject is substantive when it carries at least `minDistinctFacts`
    /// distinct field=value facts. Thin subjects merge into the closest one.
    /// `closed` subjects are matters whose membership was decided by EVIDENCE
    /// (every document naming the identifier — the subject spine), so they are
    /// kept but never receive folded facts. A shared word is not evidence: on
    /// the owner's archive, résumés sharing "sasmal" with the patent folded in
    /// and the patent topic listed "Bengali: Read – Write – Speak".
    public nonisolated static func consolidate(
        _ input: [SubjectFacts], minDistinctFacts: Int = 4, closed: Set<String> = []
    ) -> [SubjectFacts] {
        guard input.count > 1 else { return input }

        func distinctCount(_ s: SubjectFacts) -> Int {
            Set(s.facts.map { "\($0.field.lowercased())|\($0.value.lowercased())" }).count
        }
        // Rank by evidence weight so the "closest / largest" tie-breaks are stable.
        let ranked = input.sorted {
            let a = distinctCount($0), b = distinctCount($1)
            return a != b ? a > b : $0.subject < $1.subject
        }
        // A closed matter is always kept, however few its facts.
        let substantive = ranked.filter { distinctCount($0) >= minDistinctFacts || closed.contains($0.subject) }
        let thin = ranked.filter { distinctCount($0) < minDistinctFacts && !closed.contains($0.subject) }
        let hosts = substantive.filter { !closed.contains($0.subject) }

        // No substantive subject at all → the largest becomes the sole topic and
        // absorbs everyone else (still one real, evidence-backed topic).
        if substantive.isEmpty {
            let host = ranked[0]
            let merged = ranked.dropFirst().flatMap { $0.facts }
            return [SubjectFacts(subject: host.subject, facts: host.facts + merged)]
        }

        // Accumulate each substantive subject's facts; thin subjects fold into the
        // closest substantive by content-term overlap (ties → the largest).
        var bucket: [String: [GenericFact]] = [:]
        var order: [String] = []
        for s in substantive { bucket[s.subject] = s.facts; order.append(s.subject) }

        let subTerms: [(subject: String, terms: Set<String>)] =
            hosts.map { ($0.subject, terms(of: $0)) }

        for t in thin {
            // Only closed matters exist: nothing may absorb by vocabulary.
            guard let largestHost = hosts.first else { continue }
            let tt = terms(of: t)
            var bestSubject = largestHost.subject       // fallback: the largest
            var bestScore = -1.0
            for cand in subTerms {
                let score = jaccard(tt, cand.terms)
                if score > bestScore { bestScore = score; bestSubject = cand.subject }
            }
            // With several real topics to choose from, a thin subject sharing NO
            // term with any of them has no "closest" one. Folding it into the
            // largest anyway corrupted that topic — on the owner's archive a
            // shift-schedule spreadsheet collected 41 unrelated sources. It stays
            // out of the topic layer instead; its facts remain in the ledger.
            // (With a single host the owner's rule stands: it absorbs everything.)
            if bestScore <= 0, hosts.count > 1 { continue }
            // One shared word is not "closest" either: that is how the shift
            // schedule still gathered 41 sources. With a choice of hosts, a fold
            // needs at least two shared content terms.
            if hosts.count > 1,
               let host = subTerms.first(where: { $0.subject == bestSubject }),
               tt.intersection(host.terms).count < 2 { continue }
            bucket[bestSubject, default: []].append(contentsOf: t.facts)
        }

        return order.map { SubjectFacts(subject: $0, facts: bucket[$0] ?? []) }
    }

    nonisolated static func terms(of s: SubjectFacts) -> Set<String> {
        let selector = PassageAnswerSelector()
        var out = selector.contentTerms(s.subject)
        for f in s.facts.prefix(20) {
            out.formUnion(selector.contentTerms(f.field + " " + f.value))
        }
        return out
    }

    nonisolated static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty || !b.isEmpty else { return 0 }
        let inter = a.intersection(b).count
        let uni = a.union(b).count
        return uni == 0 ? 0 : Double(inter) / Double(uni)
    }
}
