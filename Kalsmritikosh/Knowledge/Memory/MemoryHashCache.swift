//
//  MemoryHashCache.swift
//  Kalsmritikosh
//
//  In-memory hashmap fronting the `memory_objects` table for the
//  retrieval pipeline's FIRST layer (Memory). Every question triggers
//  N memory lookups; doing them through SQL B-tree is wasteful when
//  the working set is small enough to fit in RAM.
//
//  Shape:
//
//    [SubjectKey: MemoryObject]   where SubjectKey is "<kind>|<identifier>"
//
//  Lifecycle:
//
//    1. AppState.boot → warm(from: memoryRepo)
//       Pages through memory_objects.listAll(...) and populates the map.
//
//    2. MemoryDistiller writes a new memory → note(_:) patches the cache.
//
//  Durability: SQLite is the source-of-truth. The cache is rebuilt
//  from SQL on every cold start; it is NOT persisted.
//
//  Concurrency: actor isolation, same pattern as InMemoryBondGraph.
//
//  F12 — byte-accounted. The cache tracks an estimate of its resident bytes; when a warm or a
//  patch would take it past `byteBudget`, or the system reports memory pressure, it SHEDS: it
//  empties itself and reports cold, and the Memory layer reads SQL (its existing cold path).
//  It never evicts piecemeal — a partial cache would turn a miss into a false "no memory".
//

import Foundation
import OSLog

public actor MemoryHashCache {

    public struct Stats: Sendable, Equatable {
        public let memoriesLoaded: Int
        public let warmSeconds: Double
    }

    private var map: [String: MemoryObject] = [:]
    private var warmed = false
    private var lastStats: Stats?
    private let byteBudget: Int
    private var estimatedBytes = 0
    private var shedReason: String?
    /// Bumped by every warm and shed; a warm that resumes after a newer one (or a shed) abandons.
    private var generation = 0

    public init(byteBudget: Int = CacheByteBudget.defaultBytes()) { self.byteBudget = max(1, byteBudget) }

    public func isWarm() -> Bool { warmed }
    public func count() -> Int { map.count }
    public func stats() -> Stats? { lastStats }
    /// F12 — the estimated resident bytes, and why the cache last went cold (nil = never shed).
    public func residentBytes() -> Int { estimatedBytes }
    public func lastShedReason() -> String? { shedReason }

    /// F12 — drop everything and report cold; retrieval falls back to SQL. Idempotent.
    public func shed(reason: String) {
        map = [:]
        estimatedBytes = 0
        warmed = false
        shedReason = reason
        generation += 1
        KalsmritikoshLog.knowledge.notice("MemoryHashCache: shed — \(reason, privacy: .public)")
    }

    private func store(_ obj: MemoryObject) {
        let key = Self.key(kind: obj.subjectKind, identifier: obj.subjectIdentifier)
        if let old = map[key] { estimatedBytes -= Self.estimatedBytes(old, key: key) }
        map[key] = obj
        estimatedBytes += Self.estimatedBytes(obj, key: key)
    }

    /// Conservative per-entry estimate: string payloads plus fixed struct/collection overheads.
    nonisolated static func estimatedBytes(_ m: MemoryObject, key: String) -> Int {
        var n = 256 + 2 * key.utf8.count + m.narrative.utf8.count + m.status.utf8.count
        n += 16 * (m.keyEventIDs.count + m.importantRelationshipIDs.count + m.sourceObjectIDs.count)
        for d in m.keyDecisions { n += 96 + d.summary.utf8.count }
        for r in m.risks { n += 96 + r.description.utf8.count + 16 * r.sourceObjectIDs.count }
        return n
    }

    // MARK: - Warm

    public func warm(memory: MemoryRepository, pageSize: Int = 2_000) async {
        map.removeAll(keepingCapacity: true)
        estimatedBytes = 0
        warmed = false
        shedReason = nil
        generation += 1
        let myGeneration = generation
        let started = Date()
        KalsmritikoshLog.knowledge.info("MemoryHashCache: warm starting")
        var offset = 0
        var total = 0
        while true {
            let page: [MemoryObject]
            do {
                page = try await memory.listAll(offset: offset, pageSize: pageSize)
            } catch {
                KalsmritikoshLog.knowledge.error("MemoryHashCache: enumerate failed — \(String(describing: error), privacy: .public)")
                break
            }
            // Reentrancy: a shed or a newer warm ran while this page was fetched.
            guard generation == myGeneration else { return }
            if page.isEmpty { break }
            for obj in page { store(obj) }
            if estimatedBytes > byteBudget {
                shed(reason: "warm exceeded the \(byteBudget)-byte budget after \(total + page.count) memories")
                return
            }
            total += page.count
            offset += page.count
            if page.count < pageSize { break }
        }
        guard generation == myGeneration else { return }
        let elapsed = Date().timeIntervalSince(started)
        lastStats = Stats(memoriesLoaded: total, warmSeconds: elapsed)
        warmed = true
        KalsmritikoshLog.knowledge.info("MemoryHashCache: warmed memories=\(total, privacy: .public) elapsed=\(String(format: "%.2f", elapsed), privacy: .public)s")
    }

    // MARK: - Reads

    /// O(1) lookup for the Memory retrieval layer.
    public func lookup(kind: MemoryObject.SubjectKind, identifier: String) -> MemoryObject? {
        map[Self.key(kind: kind, identifier: identifier)]
    }

    /// All memories for a list of candidate (kind, identifier) pairs.
    /// Returns the matches in insertion order with no duplicates. Used
    /// by HybridRetriever.memoryLayer to batch-resolve entity hints.
    public func lookupMany(_ subjects: [(MemoryObject.SubjectKind, String)]) -> [MemoryObject] {
        var out: [MemoryObject] = []
        var seen = Set<MemoryObject.ID>()
        for (kind, identifier) in subjects {
            if let m = map[Self.key(kind: kind, identifier: identifier)],
               seen.insert(m.id).inserted {
                out.append(m)
            }
        }
        return out
    }

    // MARK: - Writes (incremental updates from MemoryDistiller)

    /// Patch the cache after a MemoryDistiller upsert.
    public func note(_ memory: MemoryObject) {
        guard shedReason == nil else { return }   // shed: SQL is serving; do not regrow piecemeal
        store(memory)
        if estimatedBytes > byteBudget { shed(reason: "grew past the \(byteBudget)-byte budget") }
    }

    // MARK: - Internals

    private nonisolated static func key(kind: MemoryObject.SubjectKind, identifier: String) -> String {
        "\(kind.rawValue)|\(identifier)"
    }
}

/// F12 — the default byte budget for one corpus-wide retrieval cache: 1/64 of physical memory,
/// clamped to 32 MB…512 MB (256 MB on a 16 GB Mac).
public enum CacheByteBudget {
    public nonisolated static func defaultBytes(physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Int {
        let share = Int(min(physicalMemory / 64, UInt64(Int.max)))
        return min(max(share, 32 * 1_048_576), 512 * 1_048_576)
    }
}
