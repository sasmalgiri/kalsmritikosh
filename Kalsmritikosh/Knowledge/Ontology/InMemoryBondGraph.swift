//
//  InMemoryBondGraph.swift
//  Kalsmritikosh
//
//  Custom in-memory data structure for the G3 typed-bond graph.
//  Conventional SQL is wrong for graph BFS — every hop becomes a new
//  round-trip. We trade ~100-200MB of RAM for O(1) adjacency lookups,
//  turning multi-hop walks from ~50-200 SQL queries into pointer-chasing
//  in a Swift dictionary.
//
//  Shape:
//
//    fact_id (UUID)  →  [outgoing Bond]
//    fact_id (UUID)  →  [incoming Bond]
//    fact_id (UUID)  →  FactType (entities + events combined)
//
//  Lifecycle:
//
//    1. AppState.boot → warm(from: factBonds, entities, events)
//       Reads every fact_bonds row + every classified fact_type into
//       the maps. Done once at boot. ~1-3s for a 100k-fact corpus.
//
//    2. BondConstructor writes a new bond → noteBond(_:) patches the
//       cache so next walk sees the update without a re-warm.
//
//    3. OntologyBackfill sets fact_type → noteFactType(_:type:) patches
//       the type index.
//
//  Durability: SQLite stays the source-of-truth. This cache is rebuilt
//  from SQL on every cold start; it is NOT persisted. Crash safety is
//  the SQLite WAL, not the cache.
//
//  Concurrency: actor isolation. All read/write paths go through the
//  actor's serial execution queue. Reads are O(1), writes are
//  amortised O(1) (Swift Dictionary append).
//

import Foundation
import OSLog

public actor InMemoryBondGraph {

    public struct Stats: Sendable, Equatable {
        public let bondsLoaded: Int
        public let factsTyped: Int
        public let outgoingBuckets: Int
        public let incomingBuckets: Int
        public let warmSeconds: Double
    }

    // MARK: - State

    /// fact_id → outgoing bonds. Each bond.fromID == key.
    private var outgoingMap: [UUID: [FactBondsRepository.Bond]] = [:]
    /// fact_id → incoming bonds. Each bond.toID == key.
    private var incomingMap: [UUID: [FactBondsRepository.Bond]] = [:]
    /// fact_id → FactType. Combines entity AND event classifications
    /// into a single lookup the WalkExplainer can hit without N
    /// SQL round-trips.
    private var factTypeMap: [UUID: FactType] = [:]
    /// Set so a duplicate `noteBond` (same id) doesn't double-append.
    private var seenBondIDs: Set<UUID> = []

    private var lastStats: Stats?
    /// false until warm() finishes. Callers check this before
    /// preferring the cache over SQL so the warm-up window doesn't
    /// silently return empty walks. The flag stays true forever once
    /// set — incremental `noteBond` patches don't flip it back.
    private var warmed = false

    public init() {}

    public func isWarm() -> Bool { warmed }

    // MARK: - Warm-up

    /// Page through every fact_bonds row + classified fact_type and
    /// build the in-memory adjacency. Idempotent — calling twice
    /// clears the cache and rebuilds. Logs progress per page so a
    /// 1M-bond corpus can be observed via `log show`.
    public func warm(
        bonds: FactBondsRepository,
        entities: EntitiesRepository,
        events: EventsRepository,
        pageSize: Int = 5_000
    ) async {
        outgoingMap.removeAll(keepingCapacity: true)
        incomingMap.removeAll(keepingCapacity: true)
        factTypeMap.removeAll(keepingCapacity: true)
        seenBondIDs.removeAll(keepingCapacity: true)

        let started = Date()
        AtlasLog.knowledge.info("InMemoryBondGraph: warm starting")

        // 1. Bonds — paged enumeration.
        var bondOffset = 0
        var totalBonds = 0
        while true {
            let page: [FactBondsRepository.Bond]
            do {
                page = try await bonds.listAll(offset: bondOffset, pageSize: pageSize)
            } catch {
                AtlasLog.knowledge.error("InMemoryBondGraph: bond enumerate failed at offset \(bondOffset, privacy: .public) — \(String(describing: error), privacy: .public)")
                break
            }
            if page.isEmpty { break }
            for bond in page { ingestBond(bond) }
            totalBonds += page.count
            bondOffset += page.count
            if page.count < pageSize { break }
        }

        // 2. fact_type — entities then events. Run in parallel to halve
        //    cold-start wall-clock for large archives.
        async let entityTypes = paged(entities: entities, pageSize: pageSize)
        async let eventTypes = paged(events: events, pageSize: pageSize)
        let entityList = await entityTypes
        let eventList = await eventTypes
        var totalTyped = 0
        for (id, raw) in entityList {
            if let type = FactType(rawValue: raw) {
                factTypeMap[id] = type
                totalTyped += 1
            }
        }
        for (id, raw) in eventList {
            if let type = FactType(rawValue: raw) {
                factTypeMap[id] = type
                totalTyped += 1
            }
        }

        let elapsed = Date().timeIntervalSince(started)
        lastStats = Stats(
            bondsLoaded: totalBonds,
            factsTyped: totalTyped,
            outgoingBuckets: outgoingMap.count,
            incomingBuckets: incomingMap.count,
            warmSeconds: elapsed
        )
        warmed = true
        AtlasLog.knowledge.info("InMemoryBondGraph: warmed bonds=\(totalBonds, privacy: .public) typed=\(totalTyped, privacy: .public) outBuckets=\(self.outgoingMap.count, privacy: .public) inBuckets=\(self.incomingMap.count, privacy: .public) elapsed=\(String(format: "%.2f", elapsed), privacy: .public)s")
    }

    private func paged(entities: EntitiesRepository, pageSize: Int) async -> [(UUID, String)] {
        var out: [(UUID, String)] = []
        var offset = 0
        while true {
            let page: [(UUID, String)]
            do {
                page = try await entities.allFactTypes(offset: offset, pageSize: pageSize)
            } catch {
                break
            }
            if page.isEmpty { break }
            out.append(contentsOf: page)
            offset += page.count
            if page.count < pageSize { break }
        }
        return out
    }

    private func paged(events: EventsRepository, pageSize: Int) async -> [(UUID, String)] {
        var out: [(UUID, String)] = []
        var offset = 0
        while true {
            let page: [(UUID, String)]
            do {
                page = try await events.allFactTypes(offset: offset, pageSize: pageSize)
            } catch {
                break
            }
            if page.isEmpty { break }
            out.append(contentsOf: page)
            offset += page.count
            if page.count < pageSize { break }
        }
        return out
    }

    // MARK: - Reads (hot path for BondWalker + WalkExplainer)

    /// Outgoing bonds from `factID`. O(1) hashmap lookup + optional
    /// in-memory filter. Replaces a SQL `SELECT ... WHERE from_fact_id = ?`
    /// per hop.
    public func outgoing(from factID: UUID, bondNames: Set<String> = []) -> [FactBondsRepository.Bond] {
        guard let raw = outgoingMap[factID] else { return [] }
        if bondNames.isEmpty { return raw }
        return raw.filter { bondNames.contains($0.bondName) }
    }

    public func incoming(to factID: UUID, bondNames: Set<String> = []) -> [FactBondsRepository.Bond] {
        guard let raw = incomingMap[factID] else { return [] }
        if bondNames.isEmpty { return raw }
        return raw.filter { bondNames.contains($0.bondName) }
    }

    /// FactType of `factID` if classified. Replaces a SQL `SELECT
    /// fact_type FROM entities/events WHERE id = ?` per step in the
    /// WalkExplainer.
    public func factType(for factID: UUID) -> FactType? {
        factTypeMap[factID]
    }

    public func count() -> Int { seenBondIDs.count }
    public func stats() -> Stats? { lastStats }

    // MARK: - Writes (patched on each new bond / classification)

    /// Add a single bond to the cache without re-warming. Called by
    /// BondConstructor + BondBackfill after every successful upsert.
    /// Idempotent — same bond.id won't be added twice.
    public func noteBond(_ bond: FactBondsRepository.Bond) {
        ingestBond(bond)
    }

    /// Update the fact_type index after OntologyBackfill labels a row.
    public func noteFactType(_ id: UUID, type: FactType) {
        factTypeMap[id] = type
    }

    // MARK: - Internals

    private func ingestBond(_ bond: FactBondsRepository.Bond) {
        guard seenBondIDs.insert(bond.id).inserted else { return }
        outgoingMap[bond.fromID, default: []].append(bond)
        incomingMap[bond.toID, default: []].append(bond)
    }
}
