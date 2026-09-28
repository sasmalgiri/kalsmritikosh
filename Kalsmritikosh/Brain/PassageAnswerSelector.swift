//
//  PassageAnswerSelector.swift
//  Kalsmritikosh
//
//  Answer-quality uplift W1+W4 (deterministic core) — the gate that decides,
//  from a pool of retrieved candidates, whether ANY passage actually answers the
//  question, and which one. It encodes the anti-dump discipline the live diagnostic
//  exposed ("who drafted the claims?" was answered with a boilerplate heading +
//  subject-field dump while the real passage ranked lower):
//
//   1. BOILERPLATE candidates can never be the answer.
//   2. A bare SUBJECT-FIELD fact (applicant, application-number …) cannot answer a
//      non-field question (e.g. an actor/"who did X" question).
//   3. A passage must actually share the question's CONTENT terms; for an actor
//      question it must also carry an action verb (drafted/prepared/filed…).
//   4. If nothing clears the floor, ABSTAIN — never pad with the closest noise.
//
//  Pure and deterministic: no DB, no model. It ranks the candidates the retriever
//  already gathered, so it composes with (does not replace) the reranker ladder.
//

import Foundation

public struct AnswerCandidate: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case passage, fieldFact, boilerplate }
    public let text: String
    public let kind: Kind
    public let sourceID: String
    public init(text: String, kind: Kind, sourceID: String) {
        self.text = text; self.kind = kind; self.sourceID = sourceID
    }
}

public enum SelectedAnswer: Sendable, Equatable {
    case passage(text: String, sourceID: String)
    case abstain(reason: String)
}

public struct PassageAnswerSelector: Sendable {
    public nonisolated init() {}

    /// Action verbs that mark an "actor" question ("who DRAFTED/PREPARED …") and
    /// the passages that answer one. Stored stemmed so "drafted"/"draft" and
    /// "prepared"/"prepare" both match (the vocabulary bridge the diagnostic
    /// needed without a model call).
    nonisolated static let actionVerbStems: Set<String> = [
        "draft", "prepar", "file", "sign", "writ", "wrote", "send", "sent",
        "submit", "issu", "author", "compos", "review", "amend", "negoti",
    ]

    nonisolated static let stopwords: Set<String> = [
        "who", "what", "when", "where", "which", "whom", "whose", "why", "how",
        "the", "a", "an", "of", "to", "in", "on", "for", "is", "are", "was",
        "were", "has", "have", "had", "did", "does", "do", "me", "tell", "show",
        "give", "please", "and", "or", "that", "this", "these", "those", "with",
        "from", "by", "at", "as", "it", "be", "been", "into", "about", "list",
    ]

    /// Choose the best answering passage, or abstain.
    public nonisolated func select(question: String, candidates: [AnswerCandidate]) -> SelectedAnswer {
        let qTerms = contentTerms(question)
        let isActor = mentionsActionVerb(question)

        // Rule 1 + 2: only real passages may answer; boilerplate and (for a
        // non-field/actor question) bare field-facts are removed up front.
        let eligible = candidates.filter { c in
            switch c.kind {
            case .boilerplate: return false
            case .fieldFact:   return !isActor          // field-facts never answer an actor question
            case .passage:     return true
            }
        }
        guard !eligible.isEmpty else {
            return .abstain(reason: "No passage in the archive addresses this question.")
        }

        // Rule 3: score by shared content terms; actor questions require an
        // action verb in the passage and reward a named actor.
        @Sendable func score(_ c: AnswerCandidate) -> Double {
            let terms = contentTerms(c.text)
            let overlap = Double(qTerms.intersection(terms).count)
            guard overlap > 0 else { return 0 }
            var s = overlap
            if isActor {
                guard mentionsActionVerb(c.text) else { return 0 } // must describe the action
                s += 1
                if containsNamedActor(c.text) { s += 1 }
            }
            return s
        }

        var scored: [(candidate: AnswerCandidate, score: Double)] = []
        for c in eligible {
            let s = score(c)
            if s > 0 { scored.append((c, s)) }
        }
        scored.sort { a, b in
            a.score != b.score ? a.score > b.score : a.candidate.text < b.candidate.text
        }

        // Rule 4: floor. Require at least one shared content term (score ≥ 1);
        // an actor answer needs the verb too (score ≥ 2 by construction).
        let floor: Double = isActor ? 2 : 1
        guard let best = scored.first, best.score >= floor else {
            return .abstain(reason: "No source states an answer to this question.")
        }
        return .passage(text: best.candidate.text, sourceID: best.candidate.sourceID)
    }

    // MARK: - term helpers

    nonisolated func contentTerms(_ text: String) -> Set<String> {
        let parts = text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
        var out: Set<String> = []
        for p in parts where !p.isEmpty {
            if p.count >= 3 && !Self.stopwords.contains(p) {
                out.insert(Self.stem(p))
            }
        }
        return out
    }

    nonisolated func mentionsActionVerb(_ text: String) -> Bool {
        let parts = text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
        for p in parts where !p.isEmpty {
            if Self.actionVerbStems.contains(Self.stem(p)) { return true }
        }
        return false
    }

    /// A rough named-actor signal: a capitalized multiword run or a firm marker
    /// ("&", "Ltd", "LLP") in the ORIGINAL-case text.
    nonisolated func containsNamedActor(_ text: String) -> Bool {
        if text.contains(" & ") || text.contains("LLP") || text.contains("Ltd") { return true }
        // two consecutive Capitalized words → a likely proper name
        let words = text.components(separatedBy: .whitespacesAndNewlines)
        var prevCap = false
        for w in words {
            let capped = w.first.map { $0.isUppercase } ?? false
            if capped && prevCap { return true }
            prevCap = capped
        }
        return false
    }

    /// Light stemmer: strip common inflections so "drafted"→"draft",
    /// "prepared"→"prepar", "claims"→"claim". Deterministic, no dependencies.
    nonisolated static func stem(_ w: String) -> String {
        var s = w
        for suffix in ["ing", "ed", "es", "s"] where s.count > 4 && s.hasSuffix(suffix) {
            s = String(s.dropLast(suffix.count)); break
        }
        return s
    }
}
