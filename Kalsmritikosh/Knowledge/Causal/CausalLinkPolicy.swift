//
//  CausalLinkPolicy.swift
//  Kalsmritikosh
//
//  W-6 (unit 1.8) — the ANSWER-REACHABILITY gate for causal links. Only
//  two relation kinds may reach the graph-retrieval layer, the
//  relationship composer, and story connectives:
//
//    · CAUSED   — lexically grounded ("because of", "due to" in the text).
//    · ENABLED  — a precondition kind (contract signed → invoice issued).
//
//  CONTRIBUTED_TO is a HEURISTIC adjacency signal (shared entities + close
//  timing). It is advisory only — surfaced in the health panel's
//  "heuristic links: N — advisory, not used in answers" row, never as an
//  answer's causal claim. FOLLOWED is temporal sequence, not causation,
//  and is likewise advisory for answer purposes.
//
//  Pure and deterministic so CI proves it.
//

import Foundation

public enum CausalLinkPolicy {

    /// True when a link is strong enough to author a causal claim in an
    /// answer. CAUSED requires a lexical trigger (source == .lexicalTrigger,
    /// or a user/ontology assertion); ENABLED is a precondition relation.
    public nonisolated static func reachesAnswers(_ link: CausalLink) -> Bool {
        switch link.relation {
        case .caused:
            // Grounded only when it came from text, a human, or a domain
            // rule — never a bare heuristic that got stamped CAUSED.
            return link.source == .lexicalTrigger
                || link.source == .user
                || link.source == .ontology
                || link.source == .llm
        case .enabled:
            return true
        case .contributedTo, .followed, .prevented:
            // contributedTo/followed are advisory; prevented needs explicit
            // assertion, which arrives as .user (handled as .caused-class
            // upstream) — the heuristic never emits it.
            return link.source == .user
        }
    }

    /// Filter a link set to those that may author answers, then apply the
    /// per-source outgoing budget (strongest first). This is the read-side
    /// twin of the discoverer's emission cap: even if older ledger rows
    /// pre-date the emission budget, answers stay bounded.
    public nonisolated static func boundedForAnswers(
        _ links: [CausalLink],
        maxOutgoingPerEvent: Int = 3
    ) -> [CausalLink] {
        let eligible = links.filter(reachesAnswers).sorted { $0.confidence > $1.confidence }
        var outByEvent: [Event.ID: Int] = [:]
        var kept: [CausalLink] = []
        for link in eligible {
            let n = outByEvent[link.sourceEventID, default: 0]
            guard n < maxOutgoingPerEvent else { continue }
            outByEvent[link.sourceEventID] = n + 1
            kept.append(link)
        }
        return kept
    }

    /// The advisory remainder — the heuristic links that did NOT reach
    /// answers. The health panel counts these for the "advisory, not used
    /// in answers" row.
    public nonisolated static func advisoryCount(_ links: [CausalLink]) -> Int {
        links.filter { !reachesAnswers($0) }.count
    }
}
