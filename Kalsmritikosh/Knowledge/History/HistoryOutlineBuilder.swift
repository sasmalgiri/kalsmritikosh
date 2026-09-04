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

public nonisolated struct HistoryOutlineBuilder: Sendable {
    /// UTC gregorian calendar so year grouping is stable across locales/timezones.
    private static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
    }()

    /// P4-U2 (H-2) — the chapter that holds ambiguously-placed items. A fixed
    /// title so the gap engine and the placement twin can find it.
    public static let unplacedChapterTitle = "Unplaced evidence"
    public static let undatedChapterTitle = "Undated material"
    /// P4-U4 (SR-6) — rejected items are EXCLUDED from the story but kept
    /// VISIBLE in their own final chapter, never silently dropped.
    public static let reviewedOutChapterTitle = "Reviewed out"

    public init() {}

    public func build(material: HistoryMaterial, items: [HistoryItem],
                      corpusSnapshotID: UUID? = nil,
                      sourceContext: StorySourceContext = .empty) -> HistoryOutline {
        // P4-U4 (SR-6) — the review gate first: rejected items leave the
        // story here and reappear only in the visible "Reviewed out" chapter.
        let rejected = items.filter { $0.reviewStatus == .rejected }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        let live = items.filter { $0.reviewStatus != .rejected }

        // Partition dated vs undated (undated = no concrete start date).
        // P4-U4 (SR-5) — on the same date, a USER-CORRECTED item outranks the
        // machine's reading (total order: date, corrected-first, id).
        let dated = live.filter { $0.start?.start != nil }
            .sorted { a, b in
                let da = a.start!.start!, db = b.start!.start!
                if da != db { return da < db }
                let ca = a.reviewStatus == .corrected, cb = b.reviewStatus == .corrected
                if ca != cb { return ca }
                return a.id.uuidString < b.id.uuidString
            }
        let undated = live.filter { $0.start?.start == nil }
            .sorted { $0.id.uuidString < $1.id.uuidString }

        // P4-U2 — PLACEMENT under the H-laws (structure-first). Each dated
        // item lands in exactly ONE bucket (H-1 use-once, by construction):
        //   H-3 a whole-file beat when its evidence includes a certificate-
        //       class document (that document's record is never split),
        //   H-5 its email episode when its evidence threads to exactly one,
        //   H-2 UNPLACED when it ties equally to several episodes — listed
        //       for review, never guessed into one,
        //   otherwise the original year bucket.
        // An empty context sends everything down the year path — the
        // pre-P4 outline, unchanged.
        struct Episode { var display: String; var subtitle: String?; var items: [HistoryItem] = [] }
        var episodes: [String: Episode] = [:]
        var episodeOrder: [String] = []      // insertion-stable; final order is by date below
        var yearItems: [HistoryItem] = []
        var unplaced: [HistoryItem] = []

        func place(into key: String, display: String, subtitle: String?, _ item: HistoryItem) {
            if episodes[key] == nil {
                episodes[key] = Episode(display: display, subtitle: subtitle)
                episodeOrder.append(key)
            }
            episodes[key]?.items.append(item)
        }

        for item in dated {
            let objects = item.evidence.map(\.objectID)
            // H-3 — the whole-file beat wins first (deterministic pick on ties).
            let certObjects = objects
                .filter { StorySourceContext.wholeFileClasses.contains(sourceContext.documentClassByObject[$0] ?? "") }
                .sorted { $0.uuidString < $1.uuidString }
            if let cert = certObjects.first {
                let key = "doc:\(cert.uuidString)"
                place(into: key,
                      display: sourceContext.episodeDisplayByKey[key] ?? "Official record",
                      subtitle: "A single official document's record, kept whole",
                      item)
                continue
            }
            // H-5 — the email episode, when the evidence threads to one.
            let keys = objects.compactMap { sourceContext.episodeKeyByObject[$0] }
            if keys.isEmpty { yearItems.append(item); continue }
            var counts: [String: Int] = [:]
            keys.forEach { counts[$0, default: 0] += 1 }
            let top = counts.values.max() ?? 0
            let winners = counts.filter { $0.value == top }.keys.sorted()
            if winners.count == 1, let key = winners.first {
                place(into: key,
                      display: sourceContext.episodeDisplayByKey[key] ?? key,
                      subtitle: "One thread of correspondence, kept together",
                      item)
            } else {
                unplaced.append(item)        // H-2 — never guessed
            }
        }

        // Year chapters over the remaining items (the original law, verbatim).
        struct PlannedChapter { let earliest: Date?; let title: String; let subtitle: String?
                                let start: TemporalValue?; let end: TemporalValue?; let itemIDs: [UUID] }
        var planned: [PlannedChapter] = []
        var currentYear: Int? = nil
        var bucket: [HistoryItem] = []
        func flush() {
            guard !bucket.isEmpty, let year = currentYear else { return }
            planned.append(PlannedChapter(
                earliest: bucket.first?.start?.start, title: String(year), subtitle: nil,
                start: bucket.first?.start, end: bucket.last?.end ?? bucket.last?.start,
                itemIDs: bucket.map(\.id)))
            bucket = []
        }
        for item in yearItems {
            let year = Self.calendar.component(.year, from: item.start!.start!)
            if currentYear == nil { currentYear = year }
            if year != currentYear { flush(); currentYear = year }
            bucket.append(item)
        }
        flush()

        // Episode chapters (items already chronological — `dated` order held).
        for key in episodeOrder {
            guard let ep = episodes[key] else { continue }
            planned.append(PlannedChapter(
                earliest: ep.items.first?.start?.start, title: ep.display, subtitle: ep.subtitle,
                start: ep.items.first?.start, end: ep.items.last?.end ?? ep.items.last?.start,
                itemIDs: ep.items.map(\.id)))
        }

        // All structural chapters in one chronology (total order: date, title).
        planned.sort { a, b in
            switch (a.earliest, b.earliest) {
            case let (da?, db?): return da != db ? da < db : a.title < b.title
            case (nil, _?):      return false
            case (_?, nil):      return true
            case (nil, nil):     return a.title < b.title
            }
        }

        var chapters: [HistoryChapterPlan] = []
        var ordinal = 0
        for p in planned {
            chapters.append(HistoryChapterPlan(
                ordinal: ordinal, title: p.title, subtitle: p.subtitle,
                start: p.start, end: p.end, itemIDs: p.itemIDs))
            ordinal += 1
        }

        if !undated.isEmpty {
            chapters.append(HistoryChapterPlan(
                ordinal: ordinal, title: Self.undatedChapterTitle,
                subtitle: "Items whose sources do not establish a date",
                itemIDs: undated.map(\.id)))
            ordinal += 1
        }
        if !unplaced.isEmpty {
            chapters.append(HistoryChapterPlan(
                ordinal: ordinal, title: Self.unplacedChapterTitle,
                subtitle: "Items whose sources tie equally to more than one episode — placement needs review",
                itemIDs: unplaced.map(\.id)))
            ordinal += 1
        }
        if !rejected.isEmpty {
            chapters.append(HistoryChapterPlan(
                ordinal: ordinal, title: Self.reviewedOutChapterTitle,
                subtitle: "Excluded by your review — kept visible, never silently dropped",
                itemIDs: rejected.map(\.id)))
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

        // Keep the full item list in a stable order: chronological, undated,
        // then the reviewed-out tail (visible, never silently dropped).
        return HistoryOutline(
            subject: material.subject, corpusSnapshotID: corpusSnapshotID,
            items: dated + undated + rejected, chapters: chapters, actors: actors,
            relationships: material.relationships, coverage: coverage)
    }
}
