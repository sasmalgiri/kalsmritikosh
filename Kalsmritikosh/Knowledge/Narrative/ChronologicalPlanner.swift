//
//  ChronologicalPlanner.swift
//  Kalsmritikosh
//
//  HISTORY Phase D.2 — turns a flat event list into chapter
//  boundaries. A "chapter" is a contiguous time window whose events
//  share a topic or are tight enough on the timeline that splitting
//  would create stub chapters.
//
//  Strategy (deterministic; runs without an LLM):
//   1. Sort events chronologically.
//   2. Walk pairs: open a new chapter when EITHER
//        - the gap to the next event > 45 days (configurable), OR
//        - the next event's primary topic community ≠ the current
//          chapter's topic community
//      Otherwise: the next event joins the current chapter.
//   3. Cap chapters at 12 events — beyond that, force a split at
//      the next gap-of-any-size so the LLM doesn't see a wall.
//   4. Drop chapters with < 2 events when the overall plan has
//      ≥ 4 candidate chapters (avoids stubby "April 2023: 1 event"
//      sections). Below that threshold, keep singletons.
//
//  Topic anchoring: when the entity_communities table from Phase B
//  is populated, we look up each event's participating canonical
//  entity IDs and pick the most-common community as the chapter's
//  topic. The Phase D.3 LLM uses this as a paragraph anchor; the
//  Phase E UI shows it as a subtitle.
//

import Foundation

public actor ChronologicalPlanner {
    private let database: Database
    /// Open a new chapter when the gap to the next event exceeds this
    /// (in days). 45 days is the empirical sweet spot — small enough
    /// to split distinct project phases, large enough that a vacation
    /// or holiday gap doesn't fracture a single thread.
    private let gapDaysThreshold: Int
    /// Hard cap so a single chapter never blows past the LLM's input
    /// budget. The composer re-runs over chapter contents at
    /// ~150 tokens per event; 12 events ≈ 1800 tokens of context.
    private let maxEventsPerChapter: Int
    /// Minimum events to keep a chapter when the plan has plenty of
    /// other chapters. Below this floor the events get folded into
    /// the previous chapter.
    private let minEventsPerChapter: Int

    public init(
        database: Database,
        gapDaysThreshold: Int = 45,
        maxEventsPerChapter: Int = 12,
        minEventsPerChapter: Int = 2
    ) {
        self.database = database
        self.gapDaysThreshold = gapDaysThreshold
        self.maxEventsPerChapter = maxEventsPerChapter
        self.minEventsPerChapter = minEventsPerChapter
    }

    /// One planned chapter — events + the chosen topic community.
    /// The composer (D.3) hydrates this into a NarrativeChapter by
    /// generating prose and attaching citations.
    public struct PlannedChapter: Sendable {
        public let events: [Event]
        public let topicCommunityID: UUID?
        public let topicTitle: String?
        public let timeframeStart: Date
        public let timeframeEnd: Date
    }

    /// Build the chapter plan for an event list. The list is sorted
    /// in-place by date ascending; gaps + topic shifts drive the
    /// breaks. Returns [] for empty input.
    public func plan(events: [Event]) async -> [PlannedChapter] {
        guard !events.isEmpty else { return [] }
        let sorted = events.sorted { $0.date < $1.date }

        // Pre-fetch each event's primary topic community ID.
        let topicByEvent = await topicCommunityMap(for: sorted)

        // Walk and split.
        var raw: [[Event]] = []
        var currentChapter: [Event] = [sorted[0]]
        for i in 1..<sorted.count {
            let prev = sorted[i - 1]
            let cur = sorted[i]
            let gapDays = Calendar.current.dateComponents([.day], from: prev.date, to: cur.date).day ?? 0
            let topicChanged = (topicByEvent[prev.id] != topicByEvent[cur.id])
            let overCap = currentChapter.count >= maxEventsPerChapter
            if gapDays > gapDaysThreshold || topicChanged || overCap {
                raw.append(currentChapter)
                currentChapter = [cur]
            } else {
                currentChapter.append(cur)
            }
        }
        raw.append(currentChapter)

        // Coalesce stubby chapters when the plan has plenty.
        let coalesced = coalesceStubs(raw)

        // Hydrate each chapter with its chosen topic.
        var out: [PlannedChapter] = []
        for chapter in coalesced where !chapter.isEmpty {
            let topicID = dominantTopic(in: chapter, topicByEvent: topicByEvent)
            let topicTitle: String?
            if let topicID {
                topicTitle = await communityTitle(communityID: topicID)
            } else {
                topicTitle = nil
            }
            out.append(
                PlannedChapter(
                    events: chapter,
                    topicCommunityID: topicID,
                    topicTitle: topicTitle,
                    timeframeStart: chapter.first!.date,
                    timeframeEnd: chapter.last!.date
                )
            )
        }
        return out
    }

    /// Coalesce stub chapters when the plan has > minEventsPerChapter
    /// chapters total. Stubs are folded into the previous chapter.
    private func coalesceStubs(_ chapters: [[Event]]) -> [[Event]] {
        guard chapters.count > minEventsPerChapter else { return chapters }
        var out: [[Event]] = []
        for chapter in chapters {
            if chapter.count < minEventsPerChapter, var last = out.popLast() {
                last.append(contentsOf: chapter)
                out.append(last)
            } else {
                out.append(chapter)
            }
        }
        return out
    }

    /// Pick the most-frequent topic community among the chapter's
    /// events. Ties break in favour of the FIRST event's topic so
    /// chapter ordering stays deterministic.
    private func dominantTopic(
        in chapter: [Event],
        topicByEvent: [Event.ID: UUID]
    ) -> UUID? {
        var counts: [UUID: Int] = [:]
        for event in chapter {
            guard let topic = topicByEvent[event.id] else { continue }
            counts[topic, default: 0] += 1
        }
        guard !counts.isEmpty else { return nil }
        let max = counts.values.max() ?? 0
        let candidates = counts.filter { $0.value == max }.map(\.key)
        // Tie-break: pick the topic of the earliest event whose
        // topic is in the candidate set. Keeps planner deterministic.
        for event in chapter {
            if let topic = topicByEvent[event.id], candidates.contains(topic) {
                return topic
            }
        }
        return candidates.first
    }

    /// For each event, look up the canonical entity ids participating
    /// in the event, then find the community each entity belongs to,
    /// and pick the community with the highest member count among the
    /// event's participants. Returns [event.id : community.id].
    private func topicCommunityMap(for events: [Event]) async -> [Event.ID: UUID] {
        guard !events.isEmpty else { return [:] }
        var out: [Event.ID: UUID] = [:]
        for event in events {
            guard !event.entityIDs.isEmpty else { continue }
            let entityList = event.entityIDs.map { "'\($0.uuidString)'" }.joined(separator: ",")
            // entityList is built from UUIDs we own — no injection risk.
            let query = """
            SELECT ec.community_id, COUNT(*) AS hits
            FROM entity_communities ec
            WHERE ec.entity_id IN (\(entityList))
              AND ec.level = 0
            GROUP BY ec.community_id
            ORDER BY hits DESC, ec.community_id ASC
            LIMIT 1;
            """
            do {
                let rows = try await database.query(query, [])
                if let row = rows.first, let id = row.uuid(0) {
                    out[event.id] = id
                }
            } catch {
                // Topic anchoring is best-effort; the planner still
                // produces gap-based chapters when topics are missing.
                continue
            }
        }
        return out
    }

    private func communityTitle(communityID: UUID) async -> String? {
        let rows = try? await database.query(
            "SELECT title FROM community_summaries WHERE community_id = ? AND level = 0 LIMIT 1;",
            [.uuid(communityID)]
        )
        return rows?.first?.string(0)
    }
}
