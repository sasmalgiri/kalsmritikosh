//
//  UndatedOrder.swift
//  Kalsmritikosh
//
//  Unified path TIME-11 (owner 2026-11-22) — not tested yet.
//
//  Orders UNDATED events by evidence, without ever inventing a date. Three kinds of evidence, in
//  this order of strength:
//    1. an explicit reference in the event's own words ("after the meeting", "before the audit",
//       "following the inspection") that names another event — dated or not;
//    2. thread / document order: two events cited from the same source read in the order the
//       source tells them (the position of the cited passage in the document or mail thread);
//    3. source-version order: an event cited from an earlier version of a source comes before one
//       cited only from a later version of the same source.
//  Events with none of these stay "not placed" and are listed apart — never slotted by guesswork.
//  The result is a sequence ("order only (no date)"), never a date: nothing here returns or stores one.
//
//  Pure, deterministic, offline.
//

import Foundation

public nonisolated enum UndatedOrder {

    /// Where an event's citation sits in its source: which source, which version (by when that
    /// version was recorded — a property of the COPY, not of the event), and which passage.
    public struct DocumentKey: Sendable, Hashable {
        public let sourceID: UUID
        public let versionRecordedAt: Double?
        public let position: Int?
        public init(sourceID: UUID, versionRecordedAt: Double?, position: Int?) {
            self.sourceID = sourceID; self.versionRecordedAt = versionRecordedAt; self.position = position
        }
    }

    public struct Item: Sendable, Hashable {
        public let id: String
        public let text: String
        public let documentKey: DocumentKey?
        public init(id: String, text: String, documentKey: DocumentKey?) {
            self.id = id; self.text = text; self.documentKey = documentKey
        }
    }

    /// A dated event an undated one may refer to ("after the hearing").
    public struct Anchor: Sendable, Hashable {
        public let id: String
        public let text: String
        public let date: Date
        public init(id: String, text: String, date: Date) { self.id = id; self.text = text; self.date = date }
    }

    public struct Placement: Sendable, Hashable, Identifiable {
        public let id: String
        /// 1-based position in the order-only sequence.
        public let rank: Int
        /// Why it sits here, in plain words (each reason names its evidence).
        public let reasons: [String]
        /// A dated event this one is stated to come after / before, when its words say so.
        public let afterAnchor: String?
        public let beforeAnchor: String?
    }

    public struct Result: Sendable {
        public let placed: [Placement]
        /// Undated events with no order evidence at all.
        public let notPlaced: [String]
        public static let label = "order only (no date)"
    }

    static let afterWords = ["after", "following", "since", "subsequent to", "once"]
    static let beforeWords = ["before", "prior to", "ahead of", "until", "preceding"]
    static let stopwords: Set<String> = ["the", "a", "an", "this", "that", "his", "her", "their", "our", "its",
                                         "of", "to", "and", "was", "were", "had", "has", "with", "for", "on", "in"]

    /// The words an explicit reference points at: "after the site meeting with X" → ["site", "meeting"].
    static func references(in text: String) -> [(after: Bool, words: [String])] {
        let lower = text.lowercased()
        var out: [(Bool, [String])] = []
        for (isAfter, words) in [(true, afterWords), (false, beforeWords)] {
            for w in words {
                var start = lower.startIndex
                while let r = lower.range(of: w + " ", range: start..<lower.endIndex) {
                    start = r.upperBound
                    // Whole word only.
                    if r.lowerBound > lower.startIndex, lower[lower.index(before: r.lowerBound)].isLetter { continue }
                    let tail = lower[r.upperBound...].prefix(60)
                    let tokens = tail.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                        .map(String.init).prefix(5)
                    let content = tokens.filter { !stopwords.contains($0) && $0.count >= 4 }.prefix(2)
                    if !content.isEmpty { out.append((isAfter, Array(content))) }
                }
            }
        }
        return out.map { (after: $0.0, words: $0.1) }
    }

    static func mentions(_ text: String, _ words: [String]) -> Bool {
        let lower = text.lowercased()
        return words.allSatisfy { lower.contains($0) }
    }

    public static func order(undated: [Item], dated: [Anchor]) -> Result {
        guard !undated.isEmpty else { return Result(placed: [], notPlaced: []) }
        let ids = undated.map(\.id)
        var edges: [String: Set<String>] = [:]          // a → b : a comes before b
        var reasons: [String: [String]] = [:]
        var afterAnchor: [String: String] = [:]
        var beforeAnchor: [String: String] = [:]
        var evidenced: Set<String> = []

        func addEdge(_ a: String, _ b: String, _ why: String, on item: String) {
            guard a != b else { return }
            edges[a, default: []].insert(b)
            reasons[item, default: []].append(why)
            evidenced.insert(a); evidenced.insert(b)
        }

        // 1. Explicit references.
        for item in undated {
            for ref in references(in: item.text) {
                // Another undated event it names.
                for other in undated where other.id != item.id && mentions(other.text, ref.words) {
                    let snippet = String(other.text.prefix(50))
                    if ref.after { addEdge(other.id, item.id, "its words say it came after “\(snippet)”", on: item.id) }
                    else { addEdge(item.id, other.id, "its words say it came before “\(snippet)”", on: item.id) }
                }
                // A dated event it names: say so, without taking the date.
                if let anchor = dated.first(where: { mentions($0.text, ref.words) }) {
                    let snippet = String(anchor.text.prefix(50))
                    if ref.after { afterAnchor[item.id] = snippet } else { beforeAnchor[item.id] = snippet }
                    reasons[item.id, default: []].append(ref.after
                        ? "its words say it came after the dated event “\(snippet)” (no date of its own)"
                        : "its words say it came before the dated event “\(snippet)” (no date of its own)")
                    evidenced.insert(item.id)
                }
            }
        }

        // 2 + 3. Same source: passage order within one version, then version order.
        let bySource = Dictionary(grouping: undated.filter { $0.documentKey != nil }, by: { $0.documentKey!.sourceID })
        for (_, group) in bySource where group.count > 1 {
            let sorted = group.sorted { l, r in
                let a = l.documentKey!, b = r.documentKey!
                if a.versionRecordedAt != b.versionRecordedAt { return (a.versionRecordedAt ?? 0) < (b.versionRecordedAt ?? 0) }
                return (a.position ?? Int.max) < (b.position ?? Int.max)
            }
            for (a, b) in zip(sorted, sorted.dropFirst()) {
                let ka = a.documentKey!, kb = b.documentKey!
                if ka.versionRecordedAt != kb.versionRecordedAt, ka.versionRecordedAt != nil, kb.versionRecordedAt != nil {
                    addEdge(a.id, b.id, "cited from a later version of the same source", on: b.id)
                } else if ka.position != nil, kb.position != nil, ka.position != kb.position {
                    addEdge(a.id, b.id, "told after the previous event in the same document or thread", on: b.id)
                }
            }
        }

        // Stable topological order (Kahn), ties broken by the input order; a cycle (contradictory
        // evidence) is broken at the earliest input item and said.
        var indegree: [String: Int] = Dictionary(uniqueKeysWithValues: ids.map { ($0, 0) })
        for (_, outs) in edges { for b in outs { indegree[b, default: 0] += 1 } }
        let inputIndex = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        var ready = ids.filter { indegree[$0] == 0 && evidenced.contains($0) }
        var sequence: [String] = []
        var remaining = Set(ids.filter { evidenced.contains($0) })
        while !remaining.isEmpty {
            if ready.isEmpty, let breakAt = remaining.min(by: { inputIndex[$0, default: 0] < inputIndex[$1, default: 0] }) {
                reasons[breakAt, default: []].append("its evidence conflicts with another event's — the order here is not settled")
                ready = [breakAt]
            }
            ready.sort { inputIndex[$0, default: 0] < inputIndex[$1, default: 0] }
            let next = ready.removeFirst()
            guard remaining.remove(next) != nil else { continue }
            sequence.append(next)
            for b in edges[next] ?? [] where remaining.contains(b) {
                indegree[b, default: 1] -= 1
                if indegree[b] == 0 { ready.append(b) }
            }
        }
        let placed = sequence.enumerated().map { i, id in
            Placement(id: id, rank: i + 1, reasons: reasons[id] ?? ["placed relative to the events around it"],
                      afterAnchor: afterAnchor[id], beforeAnchor: beforeAnchor[id])
        }
        return Result(placed: placed, notPlaced: ids.filter { !evidenced.contains($0) })
    }
}
