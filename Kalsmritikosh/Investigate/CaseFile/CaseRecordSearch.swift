//
//  CaseRecordSearch.swift
//  Kalsmritikosh
//
//  Smart-map S4 (SEARCH-01) — case search over the case's OWN records, not only its documents: questions and
//  allegations, people, chronology entries and notes, hypotheses, contradictions, evidence requests, tasks and actions
//  (with their contracts), report items, supplied reports and results, report points with their qualifications,
//  interviews, statement addenda, exhibits and money movements. The records are the case map's projection (the one
//  read of the case's stores); the query is the same tree, compiled by the same plan and matched by the same matcher as
//  the document search. Clauses that describe a document (file name, tag, file and stated dates, recorded mentions) do
//  not apply to a record: they are unknown for it, so a record is listed only when the clauses that apply decide it.
//  The result names every class searched with its count, and every class of case data that is NOT searched.
//  Deterministic; nothing is sent anywhere.
//

import Foundation

public nonisolated struct CaseRecordSearchHit: Identifiable, Sendable, Equatable {
    public var id: CaseMapNodeID { record }
    public let record: CaseMapNodeID
    public let classLabel: String
    public let title: String
    public let satisfied: [String]
    public let bases: [CaseSearchMatchBasis]
    public let occurrences: Int
    /// The matched words in the record's text (title, wording, qualifications), highlighted.
    public let witnesses: [CaseSearchWitness]
}

public nonisolated struct CaseRecordSearchResult: Sendable, Equatable {
    public struct ClassCount: Sendable, Equatable, Hashable {
        public let label: String
        public let searched: Int
        public let matched: Int
    }
    public let hits: [CaseRecordSearchHit]
    public let classes: [ClassCount]
    /// Classes of case data this search does not read, by name (from the registered case data inventory).
    public let unindexed: [String]
    /// Parts of the case that could not be read for this search (their records were not searched).
    public let notLoaded: [String]
    public let notes: [String]

    public var searched: Int { classes.reduce(0) { $0 + $1.searched } }

    public var lines: [String] {
        var out = ["Case records searched: \(searched) (" + classes.filter { $0.searched > 0 }.map { "\($0.label) \($0.searched)" }.joined(separator: ", ") + ")."]
        out.append("\(hits.count) matching record\(hits.count == 1 ? "" : "s").")
        for n in notLoaded { out.append("Not searched — could not be read: \(n)") }
        if !unindexed.isEmpty { out.append("Not searched by case search (kept in the case, read elsewhere): " + unindexed.joined(separator: "; ") + ".") }
        return out + notes
    }
}

public nonisolated enum CaseRecordSearch {

    /// The record classes searched, with the name the result uses.
    public static let searchedKinds: [(CaseMapRecordKind, String)] = [
        (.allegation, "Questions and allegations"), (.person, "People"), (.journal, "Chronology entries and notes"),
        (.hypothesis, "Hypotheses"), (.contradiction, "Contradictions"), (.request, "Evidence requests"),
        (.task, "Tasks and actions (with their results)"), (.reportItem, "Report items"), (.report, "Supplied reports and results"),
        (.reportPoint, "Report points (with their qualifications)"), (.interview, "Interviews"), (.addendum, "Statement addenda"),
        (.exhibit, "Exhibits"), (.moneyTransaction, "Money movements"),
    ]

    /// Case data the record search does not read: every registered case store the map does not draw as an item, and the
    /// drawn kinds that are not records of their own (searched with the record they belong to, or by the document search).
    public static var unindexedCategories: [String] {
        let searched = Set(searchedKinds.map(\.0))
        var out: [String] = []
        for e in CaseDataInventory.entries {
            switch e.lifecycle { case .notCaseData, .erasureRecord: continue; default: break }
            let first = e.map.components(separatedBy: " ").first ?? ""
            if let k = CaseMapRecordKind(rawValue: first) {
                if searched.contains(k) || [.document, .caseFile, .qualification].contains(k) { continue }
            }
            let what = e.map.replacingOccurrences(of: "not shown as an item: ", with: "").replacingOccurrences(of: "not shown: ", with: "")
            out.append("\(what) [\(e.table)]")
        }
        return out
    }

    /// Search the case's records in `projection` with the compiled `plan`.
    public static func run(_ plan: CaseSearchPlan, projection p: CaseMapProjection) -> CaseRecordSearchResult {
        let labels = Dictionary(uniqueKeysWithValues: searchedKinds)
        var counts: [CaseMapRecordKind: (Int, Int)] = [:]
        var hits: [CaseRecordSearchHit] = []
        for n in p.nodes {
            guard let label = labels[n.id.kind] else { continue }
            counts[n.id.kind, default: (0, 0)].0 += 1
            let text = ([n.title] + [n.wording].compactMap { $0 } + n.qualifications.map { "Qualified — \($0)" }).joined(separator: "\n")
            let docText = plan.hasTextLeaves ? CaseSearchDocumentText(text, options: plan.options, needsLiteral: plan.needsLiteral, needsAmounts: plan.needsAmounts) : nil
            var facts = CaseSearchDocumentFacts(fileName: "")
            if let m = n.money { facts.recordedMoney = [(m.amount, m.currency)] }
            var outcomes = CaseSearchEvaluator.leafOutcomes(plan, text: docText, facts: facts)
            for (i, leaf) in plan.leaves.enumerated() {
                switch leaf {
                case .fileName, .statedDate, .stored(.tag), .stored(.modified):
                    outcomes[i] = nil   // a document's field: not applicable to a record
                case .person(let needle):
                    if n.id.kind == .person {
                        let hit = CaseSearchEvaluator.containsRun(CaseSearchText.tokens(of: n.title, options: plan.options), needle)
                        outcomes[i] = CaseSearchLeafOutcome(matched: hit, ranges: [], detail: hit ? "the person recorded in the case: \(n.title)" : nil, basis: .recordedField)
                    } else { outcomes[i] = nil }
                case .stored(.type(let v)):
                    let words = Set([n.id.kind.rawValue.lowercased(), n.kind.rawValue.lowercased(), n.kind.label.lowercased(), label.lowercased()])
                    let hit = words.contains(v.lowercased())
                    outcomes[i] = CaseSearchLeafOutcome(matched: hit, ranges: [], detail: hit ? "a case record of kind “\(label)”" : nil, basis: .recordedField)
                case .stored(.event(let d)):
                    if let date = n.eventDate {
                        let hit = d.holds(date, in: plan.options.timeZone)
                        outcomes[i] = CaseSearchLeafOutcome(matched: hit, ranges: [], detail: hit ? "its recorded date \(n.dateLabel ?? "")" : nil, basis: .recordedField)
                    } else { outcomes[i] = nil }
                default: break
                }
            }
            guard plan.evaluate({ outcomes[$0]?.matched }) == true else { continue }
            counts[n.id.kind, default: (0, 0)].1 += 1
            var satisfied: [String] = [], bases = Set<CaseSearchMatchBasis>(), ranges: [Range<Int>] = []
            for (i, o) in outcomes.enumerated() {
                guard let o, plan.positive[i], o.matched else { continue }
                satisfied.append(plan.clauseText[i] + (o.detail.map { " — \($0)" } ?? ""))
                bases.insert(o.basis)
                ranges += o.ranges
            }
            ranges.sort { $0.lowerBound < $1.lowerBound }
            var merged: [Range<Int>] = []
            for r in ranges {
                if let last = merged.last, last.overlaps(r) { merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, r.upperBound) } else { merged.append(r) }
            }
            hits.append(CaseRecordSearchHit(record: n.id, classLabel: label, title: n.title, satisfied: satisfied,
                                            bases: CaseSearchMatchBasis.allCases.filter(bases.contains), occurrences: merged.count,
                                            witnesses: witnesses(text, merged, max: plan.options.witnessesPerDocument)))
        }
        hits.sort { ($0.classLabel, $0.title.lowercased(), $0.record.key) < ($1.classLabel, $1.title.lowercased(), $1.record.key) }
        let classes = searchedKinds.map { k, label in CaseRecordSearchResult.ClassCount(label: label, searched: counts[k]?.0 ?? 0, matched: counts[k]?.1 ?? 0) }
        var notes: [String] = []
        if plan.leaves.contains(where: { if case .fileName = $0 { return true }; if case .statedDate = $0 { return true }; if case .stored(.tag) = $0 { return true }; if case .stored(.modified) = $0 { return true }; return false }) {
            notes.append("Clauses about a file (its name, tag, modified or stated date) do not apply to case records; a record is listed only when the clauses that apply to it decide it.")
        }
        if case .not = plan.query.root { notes.append("Records that LACK what you typed are listed only when every clause applies to them.") }
        return CaseRecordSearchResult(hits: hits, classes: classes, unindexed: unindexedCategories,
                                      notLoaded: p.failedParts.map { "\($0.label) (\(p.parts[$0].map(describe) ?? ""))" }, notes: notes)
    }

    static func describe(_ s: CaseMapPartState) -> String {
        switch s {
        case .loaded: return "read"
        case .failed(let why): return why
        case .unavailable(let why): return why
        }
    }

    static func witnesses(_ text: String, _ ranges: [Range<Int>], max: Int) -> [CaseSearchWitness] {
        let ns = text as NSString
        return ranges.prefix(max).compactMap { r in
            guard r.upperBound <= ns.length else { return nil }
            let from = Swift.max(0, r.lowerBound - 60), to = Swift.min(ns.length, r.upperBound + 60)
            let window = ns.rangeOfComposedCharacterSequences(for: NSRange(location: from, length: to - from))
            let snippet = (ns.substring(with: window) as NSString).replacingOccurrences(of: "\n", with: " ")
            let lead = window.location > 0 ? 1 : 0
            return CaseSearchWitness(snippet: (lead == 1 ? "…" : "") + snippet + (window.location + window.length < ns.length ? "…" : ""),
                                     highlights: [(r.lowerBound - window.location + lead)..<(r.upperBound - window.location + lead)],
                                     matchedText: ns.substring(with: NSRange(location: r.lowerBound, length: r.count)), range: r,
                                     passageID: nil, passageOrdinal: nil, page: nil, crossesPassageBoundary: false)
        }
    }
}
