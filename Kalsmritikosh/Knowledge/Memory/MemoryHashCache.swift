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

    public init() {}

    public func isWarm() -> Bool { warmed }
    public func count() -> Int { map.count }
    public func stats() -> Stats? { lastStats }

    // MARK: - Warm

    public func warm(memory: MemoryRepository, pageSize: Int = 2_000) async {
        map.removeAll(keepingCapacity: true)
        let started = Date()
        AtlasLog.knowledge.info("MemoryHashCache: warm starting")
        var offset = 0
        var total = 0
        while true {
            let page: [MemoryObject]
            do {
                page = try await memory.listAll(offset: offset, pageSize: pageSize)
            } catch {
                AtlasLog.knowledge.error("MemoryHashCache: enumerate failed — \(String(describing: error), privacy: .public)")
                break
            }
            if page.isEmpty { break }
            for obj in page {
                map[Self.key(kind: obj.subjectKind, identifier: obj.subjectIdentifier)] = obj
            }
            total += page.count
            offset += page.count
            if page.count < pageSize { break }
        }
        let elapsed = Date().timeIntervalSince(started)
        lastStats = Stats(memoriesLoaded: total, warmSeconds: elapsed)
        warmed = true
        AtlasLog.knowledge.info("MemoryHashCache: warmed memories=\(total, privacy: .public) elapsed=\(String(format: "%.2f", elapsed), privacy: .public)s")
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
        map[Self.key(kind: memory.subjectKind, identifier: memory.subjectIdentifier)] = memory
    }

    // MARK: - Internals

    private nonisolated static func key(kind: MemoryObject.SubjectKind, identifier: String) -> String {
        "\(kind.rawValue)|\(identifier)"
    }
}
