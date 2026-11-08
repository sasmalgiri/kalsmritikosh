//
//  CaseSourceDependence.swift
//  Kalsmritikosh
//
//  Smart-map S2 / SRC-10 (docs/IME_Full_Smart_Map_Implementation_TODO_2026-11-08.md §05) — every occurrence of a
//  source is shown, and source dependence is never counted as independent corroboration. The case's documents are
//  grouped into evidential ORIGINS by the same independence law retrieval uses (HIST-035 / W-5.4: one message thread,
//  or identical content — LedgerSourceIndependenceKeyProvider): the versions of one document are one origin, and
//  documents sharing an independence key are copies of one origin. Each map item with sources then carries the
//  origins it rests on, the copies of each in the case and the other records citing the same origin ("repeated
//  references"). Several copies of one report remain ONE origin unless something else establishes independence.
//  Deterministic; reads only the projection's own inputs.
//

import Foundation

/// Another record of the case that cites the same evidential origin.
public nonisolated struct CaseMapOccurrence: Hashable, Sendable {
    public let node: CaseMapNodeID
    public let title: String
    /// The record cites a different copy (another document of the same origin), not the same document.
    public let viaCopy: Bool
    /// The record quotes the same words.
    public let sameWords: Bool
}

/// The evidential origins an item's sources come from, the copies in the case and the repeated references.
public nonisolated struct CaseMapSourceDependence: Hashable, Sendable {
    /// One key per distinct evidential origin the item's sources come from.
    public let originKeys: Set<String>
    /// The other documents in the case that are copies of the item's origin(s), with why they are one origin.
    public let copies: [CaseMapSourceRef]
    /// Why the copies are one origin ("the same message thread", "identical content").
    public let basis: String?
    /// Other records citing the same origin(s), at most `CaseSourceDependence.occurrenceLimit` of them.
    public let occurrences: [CaseMapOccurrence]
    /// How many other records cite the same origin(s) in all.
    public let occurrenceTotal: Int

    public var independentOrigins: Int { originKeys.count }

    /// The plain lines an inspector shows.
    public var lines: [String] {
        var out: [String] = []
        out.append(independentOrigins == 1 ? "Rests on one evidential origin." : "Rests on \(independentOrigins) separate evidential origins.")
        if !copies.isEmpty {
            let names = copies.map { $0.documentName ?? "a document" }
            out.append("\(copies.count) other cop\(copies.count == 1 ? "y" : "ies") of the same origin in this case (\(basis ?? "same origin")): "
                       + names.joined(separator: ", ") + ". Copies are not independent corroboration.")
        }
        if occurrenceTotal > 0 {
            out.append("Cited by \(occurrenceTotal) other record\(occurrenceTotal == 1 ? "" : "s") in this case — repeated references to one origin, not further sources.")
        }
        return out
    }
}

public nonisolated enum CaseSourceDependence {
    /// The most occurrences kept per item (the total is always counted).
    public static let occurrenceLimit = 25

    /// Each version's origin key: the versions of one logical source are one origin, and logical sources sharing an
    /// independence key are joined into one origin (union of both relations).
    static func origins(_ documents: [CaseMapDocument]) -> (forVersion: [UUID: String], basis: [String: String], members: [String: [CaseMapDocument]]) {
        var parent: [String: String] = [:]
        func find(_ x: String) -> String {
            var r = x
            while let p = parent[r], p != r { r = p }
            var c = x
            while let p = parent[c], p != r { parent[c] = r; c = p }
            return r
        }
        func union(_ a: String, _ b: String) {
            let ra = find(a), rb = find(b)
            guard ra != rb else { return }
            if ra < rb { parent[rb] = ra } else { parent[ra] = rb }
        }
        for d in documents {
            let l = "logical:" + d.logicalSourceID.uuidString.lowercased()
            if parent[l] == nil { parent[l] = l }
            if let k = d.independenceKey?.trimmingCharacters(in: .whitespacesAndNewlines), !k.isEmpty {
                let kk = "key:" + k
                if parent[kk] == nil { parent[kk] = kk }
                union(l, kk)
            }
        }
        var forVersion: [UUID: String] = [:]
        var members: [String: [CaseMapDocument]] = [:]
        var keysByOrigin: [String: Set<String>] = [:]
        for d in documents {
            let o = find("logical:" + d.logicalSourceID.uuidString.lowercased())
            forVersion[d.sourceVersionID] = o
            members[o, default: []].append(d)
            if let k = d.independenceKey, !k.isEmpty { keysByOrigin[o, default: []].insert(k) }
        }
        var basis: [String: String] = [:]
        for (o, keys) in keysByOrigin {
            let thread = keys.contains { $0.hasPrefix("thread:") }, content = keys.contains { $0.hasPrefix("content:") || $0.hasPrefix("hash:") }
            basis[o] = thread && content ? "the same message thread and identical content" : thread ? "the same message thread (forwards and replies)" : "identical content"
        }
        return (forVersion, basis, members)
    }

    /// Annotate every item with sources: its origins, the copies of them in the case, and the other records citing them.
    public static func annotate(_ nodes: inout [CaseMapNodeID: CaseMapNode], documents: [CaseMapDocument]) {
        guard !documents.isEmpty else { return }
        let o = origins(documents)
        // Each item's origins and the logical documents it cites.
        var originsOf: [CaseMapNodeID: Set<String>] = [:]
        var citedLogical: [CaseMapNodeID: Set<UUID>] = [:]
        var quotesOf: [CaseMapNodeID: Set<String>] = [:]
        var byOrigin: [String: [CaseMapNodeID]] = [:]
        let logicalOf = Dictionary(documents.map { ($0.sourceVersionID, $0.logicalSourceID) }, uniquingKeysWith: { a, _ in a })
        for (id, n) in nodes {
            var set = Set<String>()
            for s in n.sources {
                guard let v = s.sourceVersionID, let origin = o.forVersion[v] else { continue }
                set.insert(origin)
                if let l = logicalOf[v] { citedLogical[id, default: []].insert(l) }
                if let q = s.quote, !q.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { quotesOf[id, default: []].insert(StudioEvidenceResolver.norm(q)) }
            }
            guard !set.isEmpty else { continue }
            originsOf[id] = set
            for origin in set { byOrigin[origin, default: []].append(id) }
        }
        for key in byOrigin.keys { byOrigin[key]?.sort() }
        for (id, set) in originsOf {
            guard var node = nodes[id] else { continue }
            let own = citedLogical[id] ?? []
            // Copies: documents of the same origin(s) other than the ones the item cites (one per logical source).
            var copies: [CaseMapSourceRef] = []
            var seenLogical = own
            for origin in set.sorted() {
                for d in (o.members[origin] ?? []).sorted(by: { ($0.isCurrent ? 0 : 1, $0.sourceVersionID.uuidString) < ($1.isCurrent ? 0 : 1, $1.sourceVersionID.uuidString) })
                where seenLogical.insert(d.logicalSourceID).inserted {
                    copies.append(CaseMapSourceRef(sourceVersionID: d.sourceVersionID, objectID: d.objectID, documentName: d.name, quote: nil))
                }
            }
            // A document item lists the records citing it; any other item, the other records citing its origin(s).
            var others: [CaseMapNodeID] = []
            var seen = Set<CaseMapNodeID>([id])
            for origin in set.sorted() {
                for other in byOrigin[origin] ?? [] where other.kind != .document && seen.insert(other).inserted { others.append(other) }
            }
            let mine = quotesOf[id] ?? []
            let occurrences: [CaseMapOccurrence] = others.prefix(occurrenceLimit).compactMap { other in
                guard let on = nodes[other] else { return nil }
                let theirLogical = citedLogical[other] ?? []
                return CaseMapOccurrence(node: other, title: on.title, viaCopy: !own.isEmpty && theirLogical.isDisjoint(with: own),
                                         sameWords: !mine.isEmpty && !(quotesOf[other] ?? []).isDisjoint(with: mine))
            }
            let basis = set.sorted().compactMap { o.basis[$0] }.first
            node.dependence = CaseMapSourceDependence(originKeys: set, copies: copies, basis: copies.isEmpty ? nil : basis,
                                                      occurrences: occurrences, occurrenceTotal: others.count)
            nodes[id] = node
        }
    }
}

extension CaseMapProjection {
    /// SRC-10 — how many separate evidential origins the given items rest on together (copies of one report, and
    /// repeated references to it, count once). Items with no sources in the case contribute none.
    public nonisolated func independentOrigins(of ids: [CaseMapNodeID]) -> Int {
        var keys = Set<String>()
        for id in ids { keys.formUnion(node(id)?.dependence?.originKeys ?? []) }
        return keys.count
    }
}
