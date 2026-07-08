//
//  EntityTimeline.swift
//  Kalsmritikosh
//
//  Per-entity sorted-by-date Event array. The retrieval pipeline's
//  Timeline layer answers questions like "what happened with
//  Project Delta between April and June?" — that's a date range
//  AND an entity filter. SQL does the intersection at query time;
//  this cache pre-computes per-entity timelines so range queries
//  are binary-search + memcpy.
//
//  Shape:
//
//    [Entity.ID: [TimelineSlot]]    where TimelineSlot = (date, eventID, kind)
//
//  Each per-entity array is sorted ASCENDING by date. Range queries
//  bisect both ends in O(log N).
//
//  Lifecycle:
//
//    1. AppState.boot → warm(events:)
//       Pages through events.allWithParticipants and inserts each event
//       into every participant's sorted array.
//
//    2. New events from ingest → note(_:) inserts into the right slot
//       (binary-search insertion keeps the array sorted).
//
//  Durability: SQLite is the source-of-truth. Cache is non-persistent.
//

import Foundation
import OSLog

public actor EntityTimeline {

    public struct Slot: Sendable, Hashable {
        public let date: Date
        public let eventID: Event.ID
        public let kind: Event.Kind
    }

    public struct Stats: Sendable, Equatable {
        public let eventsLoaded: Int
        public let entityBuckets: Int
        public let warmSeconds: Double
    }

    private var byEntity: [Entity.ID: [Slot]] = [:]
    private var warmed = false
    private var lastStats: Stats?

    public init() {}

    public func isWarm() -> Bool { warmed }
    public func count() -> Int { byEntity.values.reduce(0) { $0 + $1.count } }
    public func entityCount() -> Int { byEntity.count }
    public func stats() -> Stats? { lastStats }

    // MARK: - Warm

    public func warm(events: EventsRepository, pageSize: Int = 2_000) async {
        byEntity.removeAll(keepingCapacity: true)
        let started = Date()
        KalsmritikoshLog.knowledge.info("EntityTimeline: warm starting")
        var offset = 0
        var total = 0
        while true {
            let page: [(Event, [Entity.ID])]
            do {
                page = try await events.allWithParticipants(offset: offset, pageSize: pageSize)
            } catch {
                KalsmritikoshLog.knowledge.error("EntityTimeline: enumerate failed — \(String(describing: error), privacy: .public)")
                break
            }
            if page.isEmpty { break }
            for (event, entityIDs) in page {
                let slot = Slot(date: event.date, eventID: event.id, kind: event.kind)
                for entityID in entityIDs {
                    byEntity[entityID, default: []].append(slot)
                }
                total += 1
            }
            offset += page.count
            if page.count < pageSize { break }
        }
        // Sort every bucket so range queries can bisect.
        for (key, slots) in byEntity {
            byEntity[key] = slots.sorted { $0.date < $1.date }
        }
        let elapsed = Date().timeIntervalSince(started)
        lastStats = Stats(eventsLoaded: total, entityBuckets: byEntity.count, warmSeconds: elapsed)
        warmed = true
        KalsmritikoshLog.knowledge.info("EntityTimeline: warmed events=\(total, privacy: .public) buckets=\(self.byEntity.count, privacy: .public) elapsed=\(String(format: "%.2f", elapsed), privacy: .public)s")
    }

    // MARK: - Reads

    /// All slots for an entity, optionally filtered to a date range.
    /// Binary-search the lower + upper bounds; memcpy the slice.
    public func slots(
        forEntity id: Entity.ID,
        from: Date? = nil,
        to: Date? = nil
    ) -> [Slot] {
        guard let all = byEntity[id], !all.isEmpty else { return [] }
        if from == nil && to == nil { return all }
        let lower = from.map { lowerBound(all, $0) } ?? 0
        let upper = to.map { upperBound(all, $0) } ?? all.count
        guard upper > lower else { return [] }
        return Array(all[lower..<upper])
    }

    public func eventIDs(
        forEntity id: Entity.ID,
        from: Date? = nil,
        to: Date? = nil
    ) -> [Event.ID] {
        slots(forEntity: id, from: from, to: to).map(\.eventID)
    }

    // MARK: - Writes

    /// Patch the timeline after a new event is ingested.
    public func note(event: Event, participants: [Entity.ID]) {
        let slot = Slot(date: event.date, eventID: event.id, kind: event.kind)
        for entityID in participants {
            var bucket = byEntity[entityID] ?? []
            let insertAt = lowerBound(bucket, slot.date)
            bucket.insert(slot, at: insertAt)
            byEntity[entityID] = bucket
        }
    }

    // MARK: - Binary search

    /// First index whose date >= `needle`.
    private nonisolated func lowerBound(_ arr: [Slot], _ needle: Date) -> Int {
        var lo = 0
        var hi = arr.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if arr[mid].date < needle { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// First index whose date > `needle`.
    private nonisolated func upperBound(_ arr: [Slot], _ needle: Date) -> Int {
        var lo = 0
        var hi = arr.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if arr[mid].date <= needle { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
}
