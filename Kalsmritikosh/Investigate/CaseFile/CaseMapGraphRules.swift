//
//  CaseMapGraphRules.swift
//  Kalsmritikosh
//
//  Smart-map S3 (docs/IME_Full_Smart_Map_Implementation_TODO_2026-11-08.md: GRAPH-05, GRAPH-06, GRAPH-11, MAP-02, MAP-04,
//  MAP-07, MAP-10, MAP-11). PURE rules over the ONE case projection — no second graph engine, no store:
//
//  • Containment (GRAPH-05): placing a record in a branch may not make a branch contain itself through other placements;
//    investigative relationships (supports, challenges, mentions…) may form cycles and every walk stays cycle-safe.
//  • Coverage (GRAPH-06): the map's counts are reconciled with every case store of CaseDataInventory, so "N in the case"
//    never passes for complete case coverage when stores the map does not draw hold records.
//  • Shared work (GRAPH-11): one action or result serving several questions is one record counted once, and its result
//    reaches every question it serves.
//  • Semantic zoom (MAP-02): richer content at higher zoom; zoom changes presentation only.
//  • Branch folds (MAP-04): fold the work and material hanging under a record, nested; a folded branch states how much
//    it holds and how much of it is new, blocked or waiting for review — a fold never hides pending work silently.
//  • Distributions (MAP-07): records by date (at their own precision) and money by amount, per currency; a bucket is a
//    subset of record identities that every presentation highlights.
//  • View explanations (MAP-10) and the visual rules (MAP-11): one card size, one line width, whatever the certainty.
//

import Foundation

// MARK: - GRAPH-05 containment

public nonisolated enum CaseMapContainment {
    /// Would placing `member` in the branch anchored on `frame` make a branch contain itself? `placements` are the active
    /// (frame, member) pairs. Walks what `member` already contains (each record once), so it terminates on any input.
    public static func wouldCycle(frame: CaseMapNodeID, member: CaseMapNodeID, placements: [(frame: CaseMapNodeID, member: CaseMapNodeID)]) -> Bool {
        if frame == member { return true }
        var children: [CaseMapNodeID: [CaseMapNodeID]] = [:]
        for p in placements { children[p.frame, default: []].append(p.member) }
        var seen = Set<CaseMapNodeID>()
        var stack = [member]
        while let next = stack.popLast() {
            if next == frame { return true }
            guard seen.insert(next).inserted else { continue }
            stack += children[next] ?? []
        }
        return false
    }
}

// MARK: - GRAPH-06 coverage

/// One case store reconciled against the map.
public nonisolated struct CaseMapCoverageRow: Sendable, Equatable, Identifiable {
    public let table: String
    public let family: String
    /// How the map shows it (a record kind), or where it is reached instead ("not shown: …").
    public let map: String
    /// Rows the case holds in this store (nil: could not be counted — said, not hidden).
    public let rows: Int?
    /// Items of this store on the map (nil: the map does not draw this store).
    public let onMap: Int?
    public let problem: String?
    public var id: String { table }
    public var isDrawn: Bool { onMap != nil }
}

public nonisolated struct CaseMapCoverage: Sendable, Equatable {
    public let rows: [CaseMapCoverageRow]
    /// Stores with records the map does not draw.
    public var undrawn: [CaseMapCoverageRow] { rows.filter { !$0.isDrawn && ($0.rows ?? 0) > 0 } }
    public var uncounted: [CaseMapCoverageRow] { rows.filter { $0.rows == nil } }
    public var recordsNotOnMap: Int { undrawn.reduce(0) { $0 + ($1.rows ?? 0) } }
    /// "Not on the map: 3 contact details, 1 hold notice — see Coverage." (nil when the map draws every store with records).
    public var summary: String? {
        var parts: [String] = []
        if !undrawn.isEmpty {
            parts.append("\(recordsNotOnMap) record(s) in \(undrawn.count) store(s) the map does not draw: "
                         + undrawn.prefix(4).map { "\($0.table.replacingOccurrences(of: "_", with: " ")) (\($0.rows ?? 0))" }.joined(separator: ", ")
                         + (undrawn.count > 4 ? ", …" : ""))
        }
        if !uncounted.isEmpty { parts.append("\(uncounted.count) store(s) could not be counted") }
        return parts.isEmpty ? nil : parts.joined(separator: "; ") + " — see Coverage."
    }

    /// Reconcile counted rows with the projection: a store is drawn when its inventory map value is a record kind the map
    /// projects (or the case / document itself).
    public static func reconcile(counts: [String: Int?], problems: [String: String], projection p: CaseMapProjection) -> CaseMapCoverage {
        var byKind: [CaseMapRecordKind: Int] = [:]
        var qualifications = 0
        for n in p.nodes { byKind[n.id.kind, default: 0] += 1; qualifications += n.qualifications.count }
        // Records drawn as links (or on an item) are counted by the links that come from them.
        var byOrigin: [CaseMapRecordKind: Set<String>] = [:]
        for l in p.links { for o in l.origins { byOrigin[o.kind, default: []].insert(o.recordID) } }
        let rows = CaseDataInventory.entries.compactMap { e -> CaseMapCoverageRow? in
            guard counts.keys.contains(e.table) || problems[e.table] != nil else { return nil }
            let kind = CaseMapRecordKind(rawValue: e.map.components(separatedBy: " ").first ?? "")
            let onMap: Int? = kind.map { k in
                if CaseMapRecordKind.nodeKinds.contains(k) { return byKind[k] ?? 0 }
                if k == .qualification { return qualifications }
                return byOrigin[k]?.count ?? 0
            }
            return CaseMapCoverageRow(table: e.table, family: e.family, map: e.map, rows: counts[e.table] ?? nil, onMap: onMap, problem: problems[e.table])
        }
        return CaseMapCoverage(rows: rows)
    }
}

nonisolated extension CaseMapRecordKind {
    /// Kinds the projection draws as items (the rest are origins of links).
    public static let nodeKinds: Set<CaseMapRecordKind> = [.caseFile, .allegation, .person, .document, .exhibit, .interview, .addendum, .journal,
                                                           .hypothesis, .contradiction, .request, .task, .reportItem, .report, .reportPoint,
                                                           .moneyTransaction, .moneyAccount, .moneyRecord]
}

// MARK: - GRAPH-11 shared work

public nonisolated enum CaseMapSharedWork {
    /// The questions and hypotheses a piece of work (an action or request) serves, each once.
    public static func served(by work: CaseMapNodeID, in p: CaseMapProjection) -> [CaseMapNodeID] {
        var out = Set<CaseMapNodeID>()
        for l in p.links(of: work) where l.from == work && l.type == .requestsEvidenceFor {
            if let n = p.node(l.to), n.kind == .question || n.kind == .hypothesis { out.insert(l.to) }
        }
        return out.sorted()
    }

    /// Results recorded for a piece of work, and the questions each result reaches through it: one result, every
    /// question the work serves — never a copy per question.
    public static func resultsReach(_ work: CaseMapNodeID, in p: CaseMapProjection) -> (results: [CaseMapNodeID], questions: [CaseMapNodeID]) {
        let results = p.links(of: work).filter { $0.to == work && $0.type == .receivedInResponseTo }.map(\.from)
        return (Array(Set(results)).sorted(), served(by: work, in: p))
    }

    /// Work items counted once, however many questions each serves.
    public static func uniqueWork(serving questions: [CaseMapNodeID], in p: CaseMapProjection) -> [CaseMapNodeID] {
        var out = Set<CaseMapNodeID>()
        for q in questions {
            for l in p.links(of: q) where l.to == q && l.type == .requestsEvidenceFor { out.insert(l.from) }
        }
        return out.sorted()
    }
}

// MARK: - MAP-02 semantic zoom

public nonisolated enum CaseMapZoomDetail: Int, Sendable, Comparable, CaseIterable {
    /// The shape and the kind's outline only.
    case outline
    /// Icon, state symbol and title.
    case compact
    /// Plus the kind and link labels.
    case standard
    /// Plus the recorded state in words, the date at its precision, the amount, how many sources, and the first line of
    /// the wording — the same record, more of it.
    case rich

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    public static func level(_ scale: Double) -> CaseMapZoomDetail {
        scale < 0.3 ? .outline : scale < 0.6 ? .compact : scale < 1.4 ? .standard : .rich
    }
    public var showsLinkLabels: Bool { self >= .standard }

    /// The extra lines a card shows at this level (empty below `.rich`). Reads the node only; changes nothing.
    public static func cardLines(_ n: CaseMapNode, at level: CaseMapZoomDetail) -> [String] {
        guard level == .rich else { return [] }
        var out = ["\(n.status.kind.label): \(n.status.text)"]
        if n.review != .notApplicable { out.append(n.review.label) }
        if let d = n.dateLabel { out.append(d) }
        if let m = n.money { out.append(m.display) }
        out.append(n.sources.isEmpty ? "No cited source" : "\(n.sources.count) cited source(s)")
        if let w = n.wording?.split(separator: "\n").first.map(String.init), !w.isEmpty, w != n.title { out.append(String(w.prefix(120))) }
        if !n.qualifications.isEmpty { out.append("Qualified (\(n.qualifications.count))") }
        return out
    }
}

// MARK: - MAP-11 visual rules

public nonisolated enum CaseMapVisual {
    /// Every link is drawn with the same width, whatever its certainty, review or how many links an item has; only the
    /// person's selection is wider. Thickness never encodes certainty or guilt.
    public static func lineWidth(_ l: CaseMapLink, selected: Bool) -> Double { selected ? 2.5 : 1.2 }
    /// Every card has the same size.
    public static func cardSize(_ n: CaseMapNode) -> (width: Double, height: Double) { (CaseMapLayout.nodeWidth, CaseMapLayout.nodeHeight) }
    /// Dash pattern from the link type only.
    public static func dash(_ t: CaseMapLinkType) -> [Double] { t.stroke == .solid ? [] : t.stroke == .dashed ? [8, 5] : [2, 4] }
}

// MARK: - MAP-04 branch folds

/// What a folded branch holds, so its card can say it (new, blocked, waiting for review).
public nonisolated struct CaseMapFoldSummary: Sendable, Equatable, Hashable {
    public let anchor: CaseMapNodeID
    /// Records folded under this anchor (including those inside inner folds).
    public let held: Int
    /// Records inside inner folds (folded anchors under this one, and what they hold).
    public let inInnerFolds: Int
    public let new: Int
    public let blocked: Int
    public let reviewRequired: Int
    /// "12 folded · 2 new · 1 blocked · 3 waiting for review" — every marker that is not zero.
    public var label: String {
        var parts = ["\(held) folded"]
        if new > 0 { parts.append("\(new) new") }
        if blocked > 0 { parts.append("\(blocked) blocked") }
        if reviewRequired > 0 { parts.append("\(reviewRequired) waiting for review") }
        if inInnerFolds > 0 { parts.append("\(inInnerFolds) in inner folds") }
        return parts.joined(separator: " · ")
    }
}

public nonisolated enum CaseMapFolds {
    /// The records that hang under `anchor`: what was taken from it, results returned to it, work serving it and what was
    /// placed in it — recursively, cycle-safe (each once; the anchor never folds itself).
    public static func descendants(of anchor: CaseMapNodeID, in p: CaseMapProjection) -> [CaseMapNodeID] {
        var seen: Set<CaseMapNodeID> = [anchor]
        var out: [CaseMapNodeID] = []
        var queue = [anchor]
        var head = 0
        while head < queue.count {
            let id = queue[head]; head += 1
            for c in children(of: id, in: p).sorted() where seen.insert(c).inserted {
                out.append(c); queue.append(c)
            }
        }
        return out
    }

    static func children(of id: CaseMapNodeID, in p: CaseMapProjection) -> [CaseMapNodeID] {
        p.links(of: id).compactMap { l in
            switch l.type {
            case .derivedFrom, .receivedInResponseTo, .requestsEvidenceFor: return l.to == id ? l.from : nil
            case .placedIn: return l.from == id ? l.to : nil
            default: return nil
            }
        }.filter { p.node($0) != nil }
    }

    /// Everything held by the given folds (a folded anchor inside another fold stays folded when the outer one opens),
    /// with a summary for each OUTERMOST fold that is not itself held by another.
    public static func apply(_ folded: [CaseMapNodeID], in p: CaseMapProjection, changed: Set<CaseMapNodeID>) -> (held: Set<CaseMapNodeID>, summaries: [CaseMapNodeID: CaseMapFoldSummary]) {
        let anchors = folded.filter { p.node($0) != nil }
        var under: [CaseMapNodeID: [CaseMapNodeID]] = [:]
        for a in anchors { under[a] = descendants(of: a, in: p) }
        var held = Set<CaseMapNodeID>()
        for a in anchors { held.formUnion(under[a] ?? []) }
        let anchorSet = Set(anchors)
        // Deep dive batch 5 — folded anchors that hang under each other (a cycle through derivation or placement) and
        // under no other fold were all held, so the whole branch vanished with no card to unfold it from. One of them —
        // the first in record order — keeps its card and summarises the cycle.
        for a in anchors.sorted() where held.contains(a) {
            let holders = anchors.filter { $0 != a && (under[$0] ?? []).contains(a) }
            let inCycle = holders.allSatisfy { (under[a] ?? []).contains($0) }
            guard inCycle else { continue }
            let cycle = holders + [a]
            if a == cycle.min() { held.remove(a) }
        }
        var summaries: [CaseMapNodeID: CaseMapFoldSummary] = [:]
        for a in anchors where !held.contains(a) {
            let ds = under[a] ?? []
            let inner = Set(ds.filter { anchorSet.contains($0) }.flatMap { [$0] + (under[$0] ?? []) })
            let nodes = ds.compactMap { p.node($0) }
            summaries[a] = CaseMapFoldSummary(anchor: a, held: ds.count, inInnerFolds: inner.count,
                                              new: nodes.filter { changed.contains($0.id) || $0.status.kind == .stale || $0.review == .reopened }.count,
                                              blocked: nodes.filter { $0.workBlocked || $0.status.kind == .failed }.count,
                                              reviewRequired: nodes.filter { $0.review.awaitingReview }.count)
        }
        return (held, summaries)
    }
}

// MARK: - MAP-07 distributions and shared subsets

public nonisolated struct CaseMapBucket: Sendable, Equatable, Hashable, Identifiable {
    public let id: String
    public let label: String
    /// The records in this bucket (identities — every presentation highlights the same ones).
    public let members: [CaseMapNodeID]
    /// For an amount bucket: its currency and total (one currency per bucket; never added across currencies).
    public let currency: String?
    public let total: Decimal?
}

public nonisolated enum CaseMapDistribution {
    public enum DateGrain: String, Sendable, CaseIterable { case year, month, day }

    /// Records with a recorded date, by year/month/day. A record whose date is less precise than the grain is put in its
    /// own "(month only)" or "(year only)" bucket rather than in an invented day; undated records are counted apart.
    /// Deep dive batch 3 — each record is bucketed in the zone its date was recorded in, else `timeZone` (the reader's; a
    /// zone-less chronology day is that zone's midnight) — the same zone its label is shown in. It was always UTC, so east
    /// of UTC a day's entries fell in the bucket of the day before.
    public static func byDate(_ ids: [CaseMapNodeID], in p: CaseMapProjection, grain: DateGrain, timeZone: TimeZone = .current) -> (buckets: [CaseMapBucket], undated: Int) {
        var groups: [String: (label: String, sort: String, ids: [CaseMapNodeID])] = [:]
        var undated = 0
        for id in ids {
            guard let n = p.node(id), let d = n.eventDate else { undated += 1; continue }
            let tz = n.dateTimeZone.flatMap(TimeZone.init(identifier:)) ?? timeZone
            var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
            let c = cal.dateComponents([.year, .month, .day], from: d)
            let y = c.year ?? 0, m = c.month ?? 1, day = c.day ?? 1
            let precision = n.datePrecision ?? .unknown
            let coarse: DateGrain = [.decade, .year].contains(precision) ? .year : [.quarter, .month].contains(precision) ? .month : .day
            let key: String, label: String
            let month = DateFormatter().monthSymbols[max(0, min(11, m - 1))]
            switch (grain, coarse) {
            case (.year, _): key = String(format: "%04d", y); label = "\(y)"
            case (.month, .year): key = String(format: "%04d-00", y); label = "\(y) (year only)"
            case (.month, _): key = String(format: "%04d-%02d", y, m); label = "\(month) \(y)"
            case (.day, .year): key = String(format: "%04d-00-00", y); label = "\(y) (year only)"
            case (.day, .month): key = String(format: "%04d-%02d-00", y, m); label = "\(month) \(y) (month only)"
            case (.day, .day):
                key = String(format: "%04d-%02d-%02d", y, m, day)
                var style = Date.FormatStyle(date: .abbreviated, time: .omitted); style.timeZone = tz
                label = d.formatted(style)
            }
            groups[key, default: (label, key, [])].ids.append(id)
        }
        let buckets = groups.values.sorted { $0.sort < $1.sort }.map { CaseMapBucket(id: "date:" + $0.sort, label: $0.label, members: $0.ids.sorted(), currency: nil, total: nil) }
        return (buckets, undated)
    }

    /// Money movements by amount band, one set of bands PER CURRENCY (decades: under 100, 100–999, …). Every bucket's total
    /// is in its own currency; nothing is converted or added across currencies.
    public static func byAmount(_ ids: [CaseMapNodeID], in p: CaseMapProjection) -> [CaseMapBucket] {
        var groups: [String: (currency: String, band: Int, ids: [CaseMapNodeID], total: Decimal)] = [:]
        for id in ids {
            guard let n = p.node(id), let m = n.money else { continue }
            let band = bandIndex(m.amount)
            let key = "\(m.currency)|\(String(format: "%03d", band))"
            groups[key, default: (m.currency, band, [], 0)].ids.append(id)
            groups[key]?.total += m.amount
        }
        return groups.keys.sorted().compactMap { k in
            guard let g = groups[k] else { return nil }
            let cur = g.currency == FundsMoney.unstated ? "currency not stated" : g.currency
            return CaseMapBucket(id: "amount:" + k, label: "\(cur): " + bandLabel(g.band), members: g.ids.sorted(), currency: g.currency, total: g.total)
        }
    }

    /// The highest band: amounts of 10^18 and more share it (their bounds would not fit an Int).
    static let topBand = 18
    /// Zero and negative amounts (refunds, reversals) have their own band.
    static let nonPositiveBand = -1

    /// Deep dive batch 5 — the band of an amount, from the Decimal itself: `Int(pow(10, b + 1))` trapped at 10^18 and up,
    /// `log10` of an amount past Double's range was infinite, and a negative amount fell in "0–9".
    static func bandIndex(_ amount: Decimal) -> Int {
        guard amount > 0 else { return nonPositiveBand }
        var v = amount
        var b = 0
        while v >= 10, b < topBand { v /= 10; b += 1 }
        return b
    }

    static func band(_ b: Int) -> (low: String, high: String) {
        if b <= nonPositiveBand { return ("0 or less", "") }
        if b >= topBand { return ("1,000,000,000,000,000,000 (10^18) or more", "") }
        var low = 1
        for _ in 0..<b { low *= 10 }
        let high = low * 10 - 1
        return ((b == 0 ? 0 : low).formatted(), high.formatted())
    }

    /// "100–999", "0 or less", "… or more".
    static func bandLabel(_ b: Int) -> String {
        let r = band(b)
        return r.high.isEmpty ? r.low : "\(r.low)–\(r.high)"
    }
}

// MARK: - MAP-10 view explanations

public nonisolated enum CaseMapViewExplanation {
    /// Lines that explain a partial view beyond the counts: material restricted under the access policy, material that
    /// could not be processed, sources that left the case. Empty when nothing needs explaining.
    public static func lines(_ p: CaseMapProjection, result: CaseMapViewResult) -> [String] {
        var restricted = 0, failed = 0, unavailable = 0
        for id in result.shown {
            guard let n = p.node(id) else { continue }
            switch n.status.kind {
            case .restricted: restricted += 1
            case .failed: failed += 1
            case .unavailable: unavailable += 1
            default: break
            }
        }
        for l in p.links where l.status.kind == .restricted && result.links.contains(l.id) { restricted += 1 }
        var out: [String] = []
        if restricted > 0 {
            out.append("Access: \(restricted) item(s) or link(s) rest on sources in this case that the current access policy does not let this view read. They are shown as restricted, not as missing; their words are not shown or exported.")
        }
        if failed > 0 { out.append("Processing: \(failed) item(s) rest on sources that could not be read (damaged, protected or unsupported). Sources ▸ Needs attention says why for each.") }
        if unavailable > 0 { out.append("Unavailable: \(unavailable) item(s) cite sources no longer in this case. They are kept, labelled, and not counted as support.") }
        return out
    }
}
