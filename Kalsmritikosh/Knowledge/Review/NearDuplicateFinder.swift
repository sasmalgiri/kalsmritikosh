//
//  NearDuplicateFinder.swift
//  Kalsmritikosh
//
//  W2-4 — near-duplicates across documents (method as in mailin's
//  NearDuplicatesEngine, native implementation):
//    1. candidates: documents sharing a MinHash LSH band bucket (16 bands × 4 rows
//       over word 5-shingles) — bands only choose what to compare;
//    2. verification: exact Jaccard similarity of the shingle sets ≥ threshold;
//    3. groups: verified pairs joined by union–find; a group's score is its
//       weakest verified link.
//  Pure and deterministic (fixed hash seeds). Groups are linked, never merged or deleted.
//

import Foundation

public nonisolated struct NearDuplicateGroup: Sendable, Equatable {
    public let members: [UUID]
    public let weakestSimilarity: Double
}

public nonisolated enum NearDuplicateFinder {
    static let bands = 16, rows = 4

    static func fnv(_ s: Substring, seed: UInt64) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325 ^ seed
        for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return h
    }

    public static func shingles(_ text: String, size: Int = 5) -> Set<UInt64> {
        let words = text.lowercased().split { !$0.isLetter && !$0.isNumber }
        guard words.count >= size else { return words.isEmpty ? [] : [fnv(words.joined(separator: " ")[...], seed: 0)] }
        var out = Set<UInt64>()
        for i in 0...(words.count - size) { out.insert(fnv(words[i..<(i + size)].joined(separator: " ")[...], seed: 0)) }
        return out
    }

    static func signature(_ sh: Set<UInt64>) -> [UInt64] {
        (0..<(bands * rows)).map { k in
            let seed = UInt64(k + 1) &* 0x9E3779B97F4A7C15
            return sh.map { ($0 ^ seed) &* 0xff51afd7ed558ccd }.min() ?? UInt64.max
        }
    }

    public static func jaccard(_ a: Set<UInt64>, _ b: Set<UInt64>) -> Double {
        guard !a.isEmpty || !b.isEmpty else { return 0 }
        return Double(a.intersection(b).count) / Double(a.union(b).count)
    }

    public static func find(documents: [(id: UUID, text: String)], threshold: Double = 0.8) -> [NearDuplicateGroup] {
        let sh = documents.map { (id: $0.id, set: shingles($0.text)) }.filter { $0.set.count >= 3 }
        var buckets: [String: [Int]] = [:]
        for (i, d) in sh.enumerated() {
            let sig = signature(d.set)
            for b in 0..<bands {
                let key = "\(b):" + sig[(b * rows)..<((b + 1) * rows)].map(String.init).joined(separator: ",")
                buckets[key, default: []].append(i)
            }
        }
        var parent = Array(0..<sh.count)
        func root(_ x: Int) -> Int { var r = x; while parent[r] != r { r = parent[r] }; return r }
        var weakest: [Int: Double] = [:]
        var checked = Set<Int>()
        for members in buckets.values where members.count > 1 {
            for a in 0..<members.count { for b in (a + 1)..<members.count {
                let i = members[a], j = members[b]
                let key = min(i, j) * sh.count + max(i, j)
                guard checked.insert(key).inserted else { continue }
                let sim = jaccard(sh[i].set, sh[j].set)
                guard sim >= threshold else { continue }
                let ri = root(i), rj = root(j)
                let w = min(sim, weakest[ri] ?? 1, weakest[rj] ?? 1)
                if ri != rj { parent[max(ri, rj)] = min(ri, rj) }
                weakest[min(ri, rj)] = w
            }}
        }
        var groups: [Int: [UUID]] = [:]
        for i in 0..<sh.count { groups[root(i), default: []].append(sh[i].id) }
        return groups.filter { $0.value.count > 1 }.map {
            NearDuplicateGroup(members: $0.value.sorted { $0.uuidString < $1.uuidString }, weakestSimilarity: weakest[$0.key] ?? threshold)
        }.sorted { $0.members.count > $1.members.count }
    }
}
