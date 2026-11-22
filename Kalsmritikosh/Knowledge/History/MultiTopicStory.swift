//
//  MultiTopicStory.swift
//  Kalsmritikosh
//
//  Unified path HISTORY-10 (owner 2026-11-22) — not tested yet.
//
//  A story that spans several subjects ("the story of patent 700321 and application 202331019665").
//  Each subject is reconstructed on its own by the one history engine (so every chapter keeps its
//  own evidence, gaps and contradictions), then the chapters are MERGED in date order with each
//  chapter labelled by the subject it belongs to. Nothing is blended: a chapter is never rewritten
//  to mention another subject, and chapters with no date are listed after the dated ones, in their
//  own subject's order. Deterministic.
//

import Foundation

public nonisolated enum MultiTopicStory {

    public struct Topic: Sendable {
        public let label: String
        public let outline: HistoryOutline
        public let narrative: HistoryNarrative
        public init(label: String, outline: HistoryOutline, narrative: HistoryNarrative) {
            self.label = label; self.outline = outline; self.narrative = narrative
        }
    }

    public struct MergedChapter: Sendable, Hashable {
        public let topic: String
        public let title: String
        public let gist: String?
        public let prose: String
        public let start: Date?
        public let itemIDs: [UUID]
    }

    /// Distinct identifier anchors whose value the question names — one per source family (an anchor
    /// and its same-document siblings count once). Two or more means a multi-subject story.
    public static func namedAnchors(in question: String, anchors: [Entity]) -> [Entity] {
        let q = question.lowercased()
        let tokens = Set(q.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 4 && $0.contains(where: \.isNumber) })
        var out: [Entity] = []
        var families: Set<UUID> = []
        for a in anchors.sorted(by: { SubjectResolver.canon($0) < SubjectResolver.canon($1) })
        where tokens.contains(SubjectResolver.canon(a).lowercased()) {
            if families.insert(a.sourceObjectID).inserted { out.append(a) }
        }
        return out
    }

    /// The merged, chronologically ordered chapters, each with its subject's label.
    public static func merge(_ topics: [Topic]) -> [MergedChapter] {
        var dated: [(MergedChapter, Int, Int)] = []
        var undated: [(MergedChapter, Int, Int)] = []
        for (t, topic) in topics.enumerated() {
            let itemStart: [UUID: Date] = Dictionary(
                topic.outline.items.compactMap { item in item.start?.start.map { (item.id, $0) } },
                uniquingKeysWith: { a, _ in a })
            let planByItems: [Set<UUID>: HistoryChapterPlan] = Dictionary(
                topic.outline.chapters.map { (Set($0.itemIDs), $0) }, uniquingKeysWith: { a, _ in a })
            for (c, chapter) in topic.narrative.chapters.enumerated() {
                let planStart = planByItems[Set(chapter.itemIDs)]?.start?.start
                let start = planStart ?? chapter.itemIDs.compactMap { itemStart[$0] }.min()
                let merged = MergedChapter(topic: topic.label, title: chapter.title, gist: chapter.gist,
                                           prose: chapter.prose, start: start, itemIDs: chapter.itemIDs)
                if start != nil { dated.append((merged, t, c)) } else { undated.append((merged, t, c)) }
            }
        }
        dated.sort { l, r in
            if l.0.start != r.0.start { return (l.0.start ?? .distantFuture) < (r.0.start ?? .distantFuture) }
            if l.1 != r.1 { return l.1 < r.1 }
            return l.2 < r.2
        }
        undated.sort { ($0.1, $0.2) < ($1.1, $1.2) }
        return dated.map(\.0) + undated.map(\.0)
    }

    /// Plain-text rendering: one heading per chapter, "‹topic› — ‹chapter›", in merged order.
    public static func render(_ topics: [Topic]) -> String {
        let names = topics.map(\.label)
        var body = "A story across \(names.count) subjects: \(names.joined(separator: "; ")). "
            + "Each chapter below belongs to one subject and is labelled with it; chapters are in date order, "
            + "and chapters without a date come last."
        for chapter in merge(topics) {
            body += "\n\n## \(chapter.topic) — \(chapter.title)\n"
            if let gist = chapter.gist { body += gist + "\n" }
            body += chapter.prose
        }
        return body
    }
}
