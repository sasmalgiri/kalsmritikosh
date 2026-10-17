//
//  WatchlistMatcher.swift
//  Kalsmritikosh
//
//  N-3 — match a user's list of people or companies against the ledger's
//  canonical entities and their aliases, including other spellings (Aleph's
//  "cross-reference"). Pure and deterministic. Match strength, strongest first:
//
//    exact      same normalised name
//    reordered  same words in another order ("Doe, Jane" = "Jane Doe")
//    spelling   Jaro-Winkler ≥ 0.92 on the whole normalised name
//    initials   "J. Doe" against "Jane Doe" (surname equal, initials agree)
//
//  A match is a lead to check, never an identity claim.
//

import Foundation

public nonisolated struct WatchlistMatch: Sendable, Equatable, Identifiable {
    public enum Strength: String, Sendable { case exact, reordered, spelling, initials }
    public var id: String { term + "→" + entityID.uuidString }
    public let term: String
    public let entityID: UUID
    public let entityName: String
    public let matchedOn: String
    public let strength: Strength
}

public nonisolated enum WatchlistMatcher {

    public struct Candidate: Sendable {
        public let entityID: UUID
        public let name: String
        public let aliases: [String]
        public init(entityID: UUID, name: String, aliases: [String]) {
            self.entityID = entityID; self.name = name; self.aliases = aliases
        }
    }

    public static func normalize(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .init(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: #"[^\p{L}\p{N} ]"#, with: " ", options: .regularExpression)
            .split(separator: " ").joined(separator: " ")
    }

    static func tokens(_ s: String) -> [String] { normalize(s).split(separator: " ").map(String.init) }

    public static func match(terms: [String], candidates: [Candidate], limitPerTerm: Int = 20) -> [WatchlistMatch] {
        var out: [WatchlistMatch] = []
        for term in terms {
            let t = normalize(term)
            guard t.count >= 2 else { continue }
            let tTokens = Set(tokens(term))
            var found: [WatchlistMatch] = []
            for c in candidates {
                var best: (WatchlistMatch.Strength, String)?
                for name in [c.name] + c.aliases {
                    let n = normalize(name)
                    guard !n.isEmpty else { continue }
                    let strength: WatchlistMatch.Strength?
                    if n == t { strength = .exact }
                    else if tTokens.count > 1, Set(tokens(name)) == tTokens { strength = .reordered }
                    else if t.count >= 5, NameSimilarity.jaroWinkler(n, t) >= 0.92 { strength = .spelling }
                    else if initialsAgree(term, name) { strength = .initials }
                    else { strength = nil }
                    if let strength, best.map({ rank($0.0) > rank(strength) }) ?? true { best = (strength, name) }
                }
                if let best {
                    found.append(WatchlistMatch(term: term, entityID: c.entityID, entityName: c.name,
                                                matchedOn: best.1, strength: best.0))
                }
            }
            out += found.sorted { rank($0.strength) < rank($1.strength) }.prefix(limitPerTerm)
        }
        return out
    }

    static func rank(_ s: WatchlistMatch.Strength) -> Int {
        switch s { case .exact: return 0; case .reordered: return 1; case .spelling: return 2; case .initials: return 3 }
    }

    /// "J. Doe" ~ "Jane Doe": same last token, and each earlier token is either equal or an initial of the other.
    static func initialsAgree(_ a: String, _ b: String) -> Bool {
        let x = tokens(a), y = tokens(b)
        guard x.count >= 2, x.count == y.count, x.last == y.last, (x.last?.count ?? 0) >= 3 else { return false }
        var usedInitial = false
        for (p, q) in zip(x.dropLast(), y.dropLast()) {
            if p == q { continue }
            if p.count == 1, q.hasPrefix(p) { usedInitial = true; continue }
            if q.count == 1, p.hasPrefix(q) { usedInitial = true; continue }
            return false
        }
        return usedInitial
    }
}
