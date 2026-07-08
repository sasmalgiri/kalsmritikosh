//
//  EntityTrie.swift
//  Kalsmritikosh
//
//  Purpose-built data structure for entity hint resolution. The
//  retrieval pipeline's Entity layer extracts capitalised noun
//  phrases ("Project Delta", "Supplier ABC") from the question and
//  needs to map them to canonical entity ids fast. SQL `LIKE
//  '%query%'` is a full scan; this Trie does prefix lookup in
//  O(|prefix|) per query.
//
//  Shape (compact + practical):
//
//    1. A standard character Trie keyed by lowercased token. Each
//       terminal node carries the set of UUIDs whose value or
//       normalized starts with that prefix.
//
//    2. A separate `tokenIndex: [String: Set<UUID>]` for whole-token
//       lookup ("delta" → all entities with a "delta" token in
//       their value). This is what handles partial-word queries
//       like "the delta project".
//
//    3. A fuzzy fallback using simple bag-of-words + edit distance on
//       each candidate token (capped at editDistanceMax). Good enough
//       for typo tolerance without a full BK-tree.
//
//  Memory: ~3-5x the entity name corpus size. For 100k entities
//  averaging 20 chars: ~10-20MB. Fine.
//

import Foundation
import OSLog

public actor EntityTrie {

    public struct Stats: Sendable, Equatable {
        public let entitiesLoaded: Int
        public let trieNodes: Int
        public let warmSeconds: Double
    }

    private final class Node {
        var children: [Character: Node] = [:]
        var ids: Set<UUID> = []
    }

    private var root = Node()
    private var tokenIndex: [String: Set<UUID>] = [:]
    private var allTokens: Set<String> = []  // for fuzzy candidate selection
    private var warmed = false
    private var lastStats: Stats?
    private var loadedNodes = 0

    public init() {}

    public func isWarm() -> Bool { warmed }
    public func stats() -> Stats? { lastStats }

    // MARK: - Warm

    public func warm(entities: EntitiesRepository, pageSize: Int = 5_000) async {
        root = Node()
        tokenIndex.removeAll(keepingCapacity: true)
        allTokens.removeAll(keepingCapacity: true)
        loadedNodes = 0
        let started = Date()
        KalsmritikoshLog.knowledge.info("EntityTrie: warm starting")
        var offset = 0
        var total = 0
        while true {
            let page: [(UUID, String, String?)]
            do {
                page = try await entities.allValues(offset: offset, pageSize: pageSize)
            } catch {
                KalsmritikoshLog.knowledge.error("EntityTrie: enumerate failed — \(String(describing: error), privacy: .public)")
                break
            }
            if page.isEmpty { break }
            for (id, value, normalized) in page {
                index(id: id, source: value)
                if let n = normalized { index(id: id, source: n) }
                total += 1
            }
            offset += page.count
            if page.count < pageSize { break }
        }
        let elapsed = Date().timeIntervalSince(started)
        lastStats = Stats(entitiesLoaded: total, trieNodes: loadedNodes, warmSeconds: elapsed)
        warmed = true
        KalsmritikoshLog.knowledge.info("EntityTrie: warmed entities=\(total, privacy: .public) tokens=\(self.allTokens.count, privacy: .public) elapsed=\(String(format: "%.2f", elapsed), privacy: .public)s")
    }

    // MARK: - Reads

    /// Whole-token match — "delta" returns every entity whose name
    /// contains a "delta" token. Used by the Entity retrieval layer
    /// to convert hint words into canonical ids.
    public func match(token: String) -> Set<UUID> {
        tokenIndex[token.lowercased()] ?? []
    }

    /// Prefix lookup — "del" returns every entity whose name starts
    /// with a token beginning with "del". O(|prefix|) descent + the
    /// terminal node's accumulated ids.
    public func prefix(_ prefix: String) -> Set<UUID> {
        let chars = Array(prefix.lowercased())
        var cursor = root
        for c in chars {
            guard let next = cursor.children[c] else { return [] }
            cursor = next
        }
        return cursor.ids
    }

    /// Fuzzy match — checks the question's tokens against the cache's
    /// known tokens with edit-distance up to `maxDistance`. Used when
    /// the user types a typo ("Suppleir ABC" → "Supplier ABC").
    public func fuzzy(token: String, maxDistance: Int = 1) -> Set<UUID> {
        let target = token.lowercased()
        // First exact match (cheap fallback).
        if let exact = tokenIndex[target] { return exact }
        var hits: Set<UUID> = []
        for candidate in allTokens where abs(candidate.count - target.count) <= maxDistance {
            if editDistance(candidate, target, cap: maxDistance) <= maxDistance,
               let ids = tokenIndex[candidate] {
                hits.formUnion(ids)
            }
        }
        return hits
    }

    /// Resolve a free-text hint to a single set of candidate ids,
    /// trying exact-token → prefix → fuzzy in order. Tightened so a
    /// hint like "Project Delta" matches even when only one of its
    /// tokens is in the index.
    public func resolve(_ hint: String) -> Set<UUID> {
        let tokens = tokenize(hint)
        guard !tokens.isEmpty else { return [] }
        // 1. Exact-token intersection — entities that contain ALL hint tokens.
        var intersect: Set<UUID>? = nil
        for token in tokens {
            let hits = tokenIndex[token] ?? []
            if intersect == nil {
                intersect = hits
            } else {
                intersect = intersect?.intersection(hits)
            }
            if intersect?.isEmpty == true { break }
        }
        if let intersect, !intersect.isEmpty { return intersect }
        // 2. Prefix on the longest token — handles partial completion.
        let longest = tokens.max(by: { $0.count < $1.count }) ?? ""
        let pfx = prefix(longest)
        if !pfx.isEmpty { return pfx }
        // 3. Fuzzy on every token — typo tolerance.
        var fuzzyHits: Set<UUID> = []
        for token in tokens where token.count >= 3 {
            fuzzyHits.formUnion(fuzzy(token: token, maxDistance: 1))
        }
        return fuzzyHits
    }

    // MARK: - Writes (incremental)

    public func note(id: UUID, value: String, normalized: String? = nil) {
        index(id: id, source: value)
        if let n = normalized { index(id: id, source: n) }
    }

    // MARK: - Internals

    private func index(id: UUID, source: String) {
        let tokens = tokenize(source)
        for token in tokens {
            // Whole-token map
            tokenIndex[token, default: []].insert(id)
            allTokens.insert(token)
            // Prefix Trie — descend, leaving the id at EVERY node so
            // any prefix length returns it.
            var cursor = root
            for c in token {
                if let next = cursor.children[c] {
                    cursor = next
                } else {
                    let new = Node()
                    cursor.children[c] = new
                    cursor = new
                    loadedNodes += 1
                }
                cursor.ids.insert(id)
            }
        }
    }

    private nonisolated func tokenize(_ value: String) -> [String] {
        let lowered = value.lowercased()
        let separators = CharacterSet.alphanumerics.inverted
        return lowered
            .components(separatedBy: separators)
            .filter { $0.count >= 2 }
    }

    /// Capped Levenshtein. Returns `cap + 1` once exceeded so the
    /// caller's threshold check is cheap.
    private nonisolated func editDistance(_ a: String, _ b: String, cap: Int) -> Int {
        let aChars = Array(a)
        let bChars = Array(b)
        if abs(aChars.count - bChars.count) > cap { return cap + 1 }
        var prev = Array(0...bChars.count)
        var curr = Array(repeating: 0, count: bChars.count + 1)
        for i in 1...aChars.count {
            curr[0] = i
            var rowMin = i
            for j in 1...bChars.count {
                let costSubst = prev[j - 1] + (aChars[i - 1] == bChars[j - 1] ? 0 : 1)
                let costInsert = curr[j - 1] + 1
                let costDelete = prev[j] + 1
                curr[j] = min(costSubst, min(costInsert, costDelete))
                rowMin = min(rowMin, curr[j])
            }
            if rowMin > cap { return cap + 1 }
            swap(&prev, &curr)
        }
        return prev[bChars.count]
    }
}
