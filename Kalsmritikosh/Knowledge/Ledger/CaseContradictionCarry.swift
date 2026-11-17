//
//  CaseContradictionCarry.swift
//  Kalsmritikosh
//
//  Case plan 2026-11-16 (SEARCH-13 / SEARCH-14) — comparing across pages of a large case. A page of the contradiction
//  check compared only its own documents, so two accounts of one subject on different pages were never set side by side.
//  When the check continues past the first page, the earlier documents that share a subject with the page — a person
//  named in full, a record identifier the document states of itself, or a reference such as INV-104 — are carried into
//  the comparison (bounded), and only the pairs between the page and a carried document are kept, so a pair is never
//  reported twice. Everything is on this Mac by fixed rules; a shared surname alone carries nothing.
//

import Foundation

nonisolated enum CaseContradictionCarry {
    /// At most this many earlier documents are carried into one page's comparison (time and memory bound).
    static let maxCarried = 120

    /// The subjects a document can be matched on: full names (first and last word, lowercased), the record identifiers
    /// it states of itself, and reference-like tokens (letters, a dash, digits).
    static func keys(_ d: CaseContradictionFinder.Document) -> Set<String> {
        var out = Set<String>()
        for s in ProceedingEventExtractor.rawSentences(of: d.text) {
            for f in CaseContradictionFinder.Names.fullNames(in: s) {
                let t = ProceedingEventExtractor.nameTokens(CaseContradictionFinder.Names.strippingTitles(f.name))
                if t.count >= 2, let first = t.first, let last = t.last { out.insert("name:" + first.lowercased() + " " + last.lowercased()) }
            }
        }
        for (kind, value) in CaseContradictionFinder.recordIDs(d.text) { out.insert("id:\(kind):\(value)") }
        if let re = referenceRegex {
            let ns = d.text as NSString
            for m in re.matches(in: d.text, range: NSRange(location: 0, length: ns.length)) { out.insert("ref:" + ns.substring(with: m.range).uppercased()) }
        }
        return out
    }
    static let referenceRegex = try? NSRegularExpression(pattern: #"\b[A-Z]{2,5}-\d{2,}\b"#)

    /// The earlier documents worth carrying into this page's comparison: those sharing a key with any page document, most
    /// shared keys first, then by document id (stable), at most `limit`.
    static func carried(page: [CaseContradictionFinder.Document], earlier: [CaseContradictionFinder.Document],
                        limit: Int = maxCarried) -> [CaseContradictionFinder.Document] {
        let pageKeys = page.reduce(into: Set<String>()) { $0.formUnion(keys($1)) }
        guard !pageKeys.isEmpty, limit > 0 else { return [] }
        let pageIDs = Set(page.map(\.objectID))
        var scored: [(doc: CaseContradictionFinder.Document, shared: Int)] = []
        for d in earlier where !pageIDs.contains(d.objectID) {
            let n = keys(d).intersection(pageKeys).count
            if n > 0 { scored.append((d, n)) }
        }
        scored.sort { a, b in a.shared != b.shared ? a.shared > b.shared : a.doc.objectID.uuidString < b.doc.objectID.uuidString }
        return scored.prefix(limit).map(\.doc)
    }

    /// The rules' findings between the page and the carried documents only (pairs inside the page were found by the page's
    /// own run, pairs inside the earlier pages by theirs).
    static func crossFindings(page: [CaseContradictionFinder.Document], carried: [CaseContradictionFinder.Document]) -> [CaseContradictionFinder.Finding] {
        guard !carried.isEmpty else { return [] }
        let inPage = Set(page.map(\.objectID)), inCarried = Set(carried.map(\.objectID))
        return CaseContradictionFinder.ruleFindings(page + carried).filter {
            (inPage.contains($0.objectA) && inCarried.contains($0.objectB)) || (inCarried.contains($0.objectA) && inPage.contains($0.objectB))
        }
    }
}
