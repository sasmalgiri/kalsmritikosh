//
//  ConfidencePropagator.swift
//  Kalsmritikosh
//
//  Phase J.8 — Vol 17 §A8 (Core Historical Intelligence Algorithms).
//  Walks Evidence → Event → Causal Link when an event is corrected
//  or re-derived, so the recomputed confidence reaches every
//  downstream link instead of stranding on the original row.
//
//  Today this layer ships:
//
//      propagate(forEvent: Event.ID, in: [Event])
//          → recompute confidence of every non-superseded causal
//            link with the given event as source OR target. Uses the
//            same scoring function the CausalDiscoverer applies on
//            initial emission so the values stay comparable.
//
//  When the new score differs from the existing link's confidence by
//  more than `minDelta`, we supersede the old row with a fresh one
//  carrying source=.heuristic (or the link's existing source) +
//  the updated confidence. User-asserted links (source=.user) are
//  NEVER auto-recomputed — the user's call wins.
//
//  Narrative/chapter confidence isn't recomputed here. Chapters
//  rebuild on the next composition pass; this propagator focuses on
//  the link layer where the algebra is well-defined.
//
//  Quality-or-nothing: returns nil + a debug log when the event id
//  isn't found in the supplied event list. No fabricated scores.
//

import Foundation
import OSLog

public actor ConfidencePropagator {
    private let links: EventLinksRepository
    private let events: EventsRepository
    private let database: Database

    /// Minimum confidence delta (absolute) before the propagator
    /// supersedes a link. Filters out churn for tiny floating-point
    /// drift between runs (re-running discover() on identical
    /// inputs can shift a score by 1e-15 due to FP order-of-ops).
    public static let minDelta: Double = 0.02

    /// Same gap cap CausalDiscoverer uses. Kept in sync manually for
    /// now; future refactor can factor both into a shared CausalConfig.
    public static let maxGapDays: Int = 120

    public init(
        links: EventLinksRepository,
        events: EventsRepository,
        database: Database
    ) {
        self.links = links
        self.events = events
        self.database = database
    }

    /// Recompute confidence on every non-superseded causal link
    /// touching `eventID`. Pass the candidate event set the brain
    /// already has on hand so the propagator doesn't re-query for
    /// rows the caller just loaded.
    /// Returns the number of links that were superseded.
    @discardableResult
    public func propagate(
        forEvent eventID: Event.ID,
        in candidates: [Event] = []
    ) async -> Int {
        // Find the touched event. If the caller supplied a candidate
        // list (typically the current retrieval set), search there
        // first; fall back to a DB fetch.
        let touched: Event
        if let match = candidates.first(where: { $0.id == eventID }) {
            touched = match
        } else if let fetched = (try? await events.findByIDs([eventID]))?.first {
            touched = fetched
        } else {
            AtlasLog.knowledge.info("ConfidencePropagator: event \(eventID.uuidString.prefix(8), privacy: .public) not found; skipping")
            return 0
        }

        // Hydrate entityIDs for `touched` from the event_entities
        // join table — the canonical decode leaves entityIDs empty
        // (same pattern CausalDiscoverer uses).
        let hydratedTouched = await Self.hydrateEntities(
            event: touched, database: database
        )

        // Pull every non-superseded link mentioning `eventID`.
        let touchingLinks: [CausalLink]
        do {
            let outgoing = try await links.outgoing(from: eventID)
            let incoming = try await links.incoming(to: eventID)
            touchingLinks = outgoing + incoming
        } catch {
            AtlasLog.knowledge.error("ConfidencePropagator: link fetch failed — \(String(describing: error), privacy: .public)")
            return 0
        }
        guard !touchingLinks.isEmpty else { return 0 }

        // Fetch every other endpoint event in one batch.
        let otherIDs: [Event.ID] = touchingLinks.flatMap { link -> [Event.ID] in
            var ids: [Event.ID] = []
            if link.sourceEventID != eventID { ids.append(link.sourceEventID) }
            if link.targetEventID != eventID { ids.append(link.targetEventID) }
            return ids
        }
        let uniqueOthers = Array(Set(otherIDs))
        let otherEvents: [Event] = (try? await events.findByIDs(uniqueOthers)) ?? []
        var otherByID: [Event.ID: Event] = [:]
        for ev in otherEvents {
            otherByID[ev.id] = await Self.hydrateEntities(event: ev, database: database)
        }

        let calendar = Calendar.current
        var supersededCount = 0
        for link in touchingLinks {
            // User-asserted links are immutable from the propagator's
            // perspective — only the user can change them.
            if link.source == .user { continue }
            let source: Event
            let target: Event
            if link.sourceEventID == eventID {
                source = hydratedTouched
                guard let t = otherByID[link.targetEventID] else { continue }
                target = t
            } else {
                guard let s = otherByID[link.sourceEventID] else { continue }
                source = s
                target = hydratedTouched
            }
            let gapDays = calendar.dateComponents([.day], from: source.date, to: target.date).day ?? 0
            // Re-run the same score the discoverer used at emission.
            // No body-text snippet here; that requires a KO fetch
            // and the propagator runs synchronously against the
            // already-loaded link set — title+summary is sufficient
            // for the rebound estimate.
            let score = CausalDiscoverer.score(
                a: source, b: target,
                bBodyText: nil,
                gapDays: gapDays,
                maxGapDays: Self.maxGapDays
            )
            let newConfidence = min(1.0, score.value)
            guard abs(newConfidence - link.confidence) >= Self.minDelta else { continue }
            let updated = CausalLink(
                sourceEventID: link.sourceEventID,
                targetEventID: link.targetEventID,
                relation: link.relation,
                confidence: newConfidence,
                evidenceObjectIDs: link.evidenceObjectIDs,
                allen: link.allen,
                source: link.source,
                reason: link.reason.map { "\($0) (recomputed)" } ?? "recomputed",
                createdAt: Date(),
                supersededBy: nil
            )
            do {
                try await links.supersede(oldLinkID: link.id, with: updated)
                supersededCount += 1
            } catch {
                AtlasLog.knowledge.error("ConfidencePropagator: supersede failed for \(link.id.uuidString.prefix(8), privacy: .public) — \(String(describing: error), privacy: .public)")
            }
        }
        AtlasLog.knowledge.info("ConfidencePropagator: recomputed \(supersededCount, privacy: .public) link(s) around event \(eventID.uuidString.prefix(8), privacy: .public)")
        return supersededCount
    }

    /// Pull entityIDs from the event_entities join table — the
    /// canonical Event decode leaves them empty, so the propagator
    /// has to re-hydrate before scoring (otherwise the entity-overlap
    /// signal in score() always reads 0).
    private static func hydrateEntities(event: Event, database: Database) async -> Event {
        guard event.entityIDs.isEmpty else { return event }
        let rows = (try? await database.query("""
        SELECT entity_id FROM event_entities WHERE event_id = ?;
        """, [.uuid(event.id)])) ?? []
        let ids = rows.compactMap { $0.uuid(0) }
        guard !ids.isEmpty else { return event }
        return Event(
            id: event.id, kind: event.kind, date: event.date, endDate: event.endDate,
            title: event.title, summary: event.summary,
            entityIDs: ids,
            sourceObjectID: event.sourceObjectID, sourceRange: event.sourceRange,
            confidence: event.confidence, dateConfidence: event.dateConfidence,
            attributes: event.attributes, qualityTier: event.qualityTier,
            datePrecision: event.datePrecision
        )
    }
}
