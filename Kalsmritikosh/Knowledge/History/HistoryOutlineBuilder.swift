//
//  HistoryOutlineBuilder.swift
//  Kalsmritikosh
//
//  HIST-051 (Universal History program, Phase 5). Assembles collected material +
//  projected history items into the COMPLETE deterministic outline: items sorted
//  chronologically, grouped into chapters by period, undated material kept in its
//  own chapter (never placed at a guessed position), coverage computed. Fully
//  deterministic (same input → same outline) and LLM-free.
//

import Foundation

public struct HistoryOutlineBuilder: Sendable {
    /// UTC gregorian calendar so year grouping is stable across locales/timezones.
    private static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
    }()

    public init() {}

    public func build(material: HistoryMaterial, items: [HistoryItem], corpusSnapshotID: UUID? = nil) -> HistoryOutline {
        // Partition dated vs undated (undated = no concrete start date).
        let dated = items.filter { $0.start?.start != nil }
            .sorted { a, b in
                let da = a.start!.start!, db = b.start!.start!
                return da != db ? da < db : a.id.uuidString < b.id.uuidString
            }
        let undated = items.filter { $0.start?.start == nil }
            .sorted { $0.id.uuidString < $1.id.uuidString }

        // Chapter per calendar year (deterministic period boundaries).
        var chapters: [HistoryChapterPlan] = []
        var ordinal = 0
        var currentYear: Int? = nil
        var bucket: [HistoryItem] = []
        func flush() {
            guard !bucket.isEmpty, let year = currentYear else { return }
            let starts = bucket.compactMap { $0.start?.start }
            chapters.append(HistoryChapterPlan(
                ordinal: ordinal, title: String(year),
                start: bucket.first?.start, end: bucket.last?.end ?? bucket.last?.start,
                itemIDs: bucket.map(\.id)))
            ordinal += 1
            bucket = []
            _ = starts
        }
        for item in dated {
            let year = Self.calendar.component(.year, from: item.start!.start!)
            if currentYear == nil { currentYear = year }
            if year != currentYear { flush(); currentYear = year }
            bucket.append(item)
        }
        flush()

        if !undated.isEmpty {
            chapters.append(HistoryChapterPlan(
                ordinal: ordinal, title: "Undated material",
                subtitle: "Items whose sources do not establish a date",
                itemIDs: undated.map(\.id)))
        }

        // Actors: item actors ∪ first-degree neighbours ∪ the subject itself.
        var actorSet = Set<Entity.ID>()
        items.forEach { actorSet.formUnion($0.actors) }
        actorSet.formUnion(material.firstDegreeEntityIDs)
        if let sid = material.subject.canonicalEntityID { actorSet.insert(sid) }
        let actors = actorSet.sorted { $0.uuidString < $1.uuidString }

        let starts = dated.compactMap { $0.start?.start }
        let coverage = HistoryCoverage(
            totalItems: items.count, datedItems: dated.count, undatedItems: undated.count,
            earliest: starts.first, latest: dated.compactMap { $0.end?.end ?? $0.start?.start }.max(),
            evidenceObjectCount: material.evidenceObjectIDs.count,
            assertionCount: material.assertions.count, genericFactCount: material.genericFacts.count,
            eventCount: material.events.count)

        // Keep the full item list in a stable order: chronological then undated.
        return HistoryOutline(
            subject: material.subject, corpusSnapshotID: corpusSnapshotID,
            items: dated + undated, chapters: chapters, actors: actors,
            relationships: material.relationships, coverage: coverage)
    }
}
