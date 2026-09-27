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
        _ input: [SubjectFacts], minDistinctFacts: Int = 4, closed: Set<String> = [],
        nonSubjects: Set<String> = []
    ) -> [SubjectFacts] {
        guard input.count > 1 else { return input }
        // P1.13 — one subject, one topic: labels that differ only in case or
        // spacing ("HYBRID RELUCTANCE INDUCTION MOTOR" / "Hybrid Reluctance
        // Induction Motor") merge first. The most-evidenced spelling is kept.
        var byKey: [String: [SubjectFacts]] = [:]
        var keyOrder: [String] = []
        for s in input {
            let key = s.subject.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            if byKey[key] == nil { keyOrder.append(key) }
            byKey[key, default: []].append(s)
        }
        let input: [SubjectFacts] = keyOrder.compactMap { key in
            guard let group = byKey[key], let lead = group.max(by: {
                $0.facts.count != $1.facts.count ? $0.facts.count < $1.facts.count : $0.subject > $1.subject
            }) else { return nil }
            if group.count == 1 { return lead }
            return SubjectFacts(subject: lead.subject, facts: group.flatMap(\.facts))
        }
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
        // P1.13 — a label that is not a SUBJECT (a bounce notice, a camera or
        // attachment stem) is thin however many facts it carries: on the
        // owner's archive "Delivery Status Notification (Failure)" and
        // "image-bc523fd4" were standing topics.
        func isSubstantive(_ s: SubjectFacts) -> Bool {
            if closed.contains(s.subject) { return true }
            // P1.19 — `nonSubjects`: labels the CALLER knows are not matters
            // (subjects of automated mail — "… wants to chat", portal alerts).
            let lowered = s.subject.lowercased()
            if nonSubjects.contains(where: { $0.lowercased() == lowered }) { return false }
            return distinctCount(s) >= minDistinctFacts && !isNonSubjectLabel(s.subject)
        }
        let substantive = ranked.filter(isSubstantive)
        let thin = ranked.filter { !isSubstantive($0) }
        let hosts = substantive.filter { !closed.contains($0.subject) }

        // No substantive subject at all → the largest becomes the sole topic and
        // absorbs everyone else (still one real, evidence-backed topic).
        if substantive.isEmpty {
            // Prefer a real subject as the sole host; a transport/stem label
            // hosts only when nothing else exists.
            let host = ranked.first(where: { !isNonSubjectLabel($0.subject) }) ?? ranked[0]
            let merged = ranked.filter { $0.subject != host.subject }.flatMap { $0.facts }
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

    // MARK: - P1.13 non-subject labels (universal, shape + small vocabularies)

    /// Mail-transport notices: the message is ABOUT delivery, not a matter.
    nonisolated static let transportPhrases: [String] = [
        "delivery status notification", "undeliverable", "undelivered mail",
        "mail delivery failed", "mail delivery failure", "mail delivery subsystem",
        "returned mail", "delivery failure", "failure notice", "delivery has failed",
        "message not delivered", "could not be delivered",
    ]
    /// Words that name a FILE KIND, not a subject ("IMG", "Picture", "scan").
    nonisolated static let genericStemWords: Set<String> = [
        "img", "image", "images", "picture", "pic", "photo", "photos", "scan", "scanned",
        "screenshot", "screen", "shot", "dsc", "dscn", "pxl", "whatsapp", "document", "doc",
        "file", "untitled", "attachment", "new", "copy", "final", "page", "sheet", "book",
        "pdf", "jpg", "jpeg", "png", "heic", "video", "vid", "audio", "rec", "recording",
        "wa", "vid", "mov", "mp4", "aud", "ptt",   // WhatsApp media stems ("IMG-20231129-WA0004")
    ]

    /// True when `label` names transport or a file kind rather than a subject.
    public nonisolated static func isNonSubjectLabel(_ label: String) -> Bool {
        let lower = label.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lower.isEmpty else { return true }
        if transportPhrases.contains(where: { lower.hasPrefix($0) || lower == $0 }) { return true }
        // Machine stem: after dropping digits and hash-like runs, only file-kind
        // words (or nothing) remain — "image-bc523fd4", "img20200115_19590228",
        // "Picture-8776713c", "IMG_4471". A stem with any real word stays a subject.
        let words = lower.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let meaningful = words.filter { w in
            if w.allSatisfy(\.isNumber) { return false }
            if w.count >= 6, w.allSatisfy({ $0.isHexDigit }), w.contains(where: \.isNumber) { return false }
            let letters = w.filter(\.isLetter)
            if genericStemWords.contains(letters) { return false }
            return !letters.isEmpty
        }
        return meaningful.isEmpty
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
