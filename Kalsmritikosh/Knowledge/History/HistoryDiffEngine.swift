//
//  HistoryDiffEngine.swift
//  Kalsmritikosh
//
//  INN-200 (Universal History program, Phase 13). Evidence Time Machine: compare two
//  reconstructions (e.g. before/after new evidence arrived) and explain what changed
//  — new items, retracted items, changed items, new gaps, resolved gaps. Items are
//  matched by a stable (kind, title) key (content-hash ids change when facts change,
//  so id equality alone can't detect an in-place change). Deterministic, LLM-free.
//

import Foundation

public struct ItemChange: Sendable, Hashable {
    public let before: HistoryItem
    public let after: HistoryItem
    public let changes: [String]   // human-readable field-level deltas
}

public struct HistoryDiff: Sendable, Hashable {
    public let newItems: [HistoryItem]
    public let retractedItems: [HistoryItem]
    public let changedItems: [ItemChange]
    public let newGaps: [HistoryGap]
    public let resolvedGaps: [HistoryGap]
    public var isEmpty: Bool {
        newItems.isEmpty && retractedItems.isEmpty && changedItems.isEmpty && newGaps.isEmpty && resolvedGaps.isEmpty
    }
}

public struct HistoryDiffEngine: Sendable {
    public init() {}

    public func diff(old: HistoryOutline, new: HistoryOutline) -> HistoryDiff {
        let oldByKey = Dictionary(old.items.map { (Self.key($0), $0) }, uniquingKeysWith: { a, _ in a })
        let newByKey = Dictionary(new.items.map { (Self.key($0), $0) }, uniquingKeysWith: { a, _ in a })

        let newItems = new.items.filter { oldByKey[Self.key($0)] == nil }
            .sorted { $0.title < $1.title }
        let retracted = old.items.filter { newByKey[Self.key($0)] == nil }
            .sorted { $0.title < $1.title }

        var changed: [ItemChange] = []
        for (k, o) in oldByKey {
            guard let n = newByKey[k] else { continue }
            let deltas = Self.deltas(from: o, to: n)
            if !deltas.isEmpty { changed.append(ItemChange(before: o, after: n, changes: deltas)) }
        }
        changed.sort { $0.after.title < $1.after.title }

        let oldGapKeys = Set(old.gaps.map(Self.gapKey))
        let newGapKeys = Set(new.gaps.map(Self.gapKey))
        let newGaps = new.gaps.filter { !oldGapKeys.contains(Self.gapKey($0)) }
            .sorted { $0.description < $1.description }
        let resolvedGaps = old.gaps.filter { !newGapKeys.contains(Self.gapKey($0)) }
            .sorted { $0.description < $1.description }

        return HistoryDiff(newItems: newItems, retractedItems: retracted, changedItems: changed,
                           newGaps: newGaps, resolvedGaps: resolvedGaps)
    }

    static func key(_ i: HistoryItem) -> String { "\(i.kind.rawValue)|\(i.title.lowercased())" }
    static func gapKey(_ g: HistoryGap) -> String { "\(g.kind.rawValue)|\(g.description.lowercased())" }

    static func deltas(from o: HistoryItem, to n: HistoryItem) -> [String] {
        var d: [String] = []
        if o.evidenceStatus != n.evidenceStatus { d.append("status \(o.evidenceStatus.rawValue)→\(n.evidenceStatus.rawValue)") }
        if o.start?.start != n.start?.start { d.append("start date changed") }
        if o.end?.end != n.end?.end { d.append("end date changed") }
        if o.confidence != n.confidence { d.append("confidence \(String(format: "%.2f", o.confidence))→\(String(format: "%.2f", n.confidence))") }
        if o.evidence.count != n.evidence.count { d.append("evidence \(o.evidence.count)→\(n.evidence.count) source(s)") }
        return d
    }
}
