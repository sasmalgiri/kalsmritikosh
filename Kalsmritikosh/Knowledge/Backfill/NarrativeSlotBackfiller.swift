//
//  NarrativeSlotBackfiller.swift
//  Kalsmritikosh
//
//  HISTORY Phase C follow-on — without this, every event ingested
//  before schema v21 landed is forever stuck at `narrative_slots_json
//  = '{}'`. The Phase D composer then can't produce prose for them
//  because the 5W+H slots are empty.
//
//  Strategy:
//    1. Page through `events WHERE narrative_slots_json = '{}'`.
//    2. For each: load the source KO, the participating canonical
//       entities, and run `RuleNarrativeSlotExtractor` — exactly the
//       same code path the ingest pipeline runs forward-only.
//    3. Persist via `EventsRepository.setNarrativeSlots`.
//
//  Idempotent: any event whose slot bundle isn't `.empty` is filtered
//  out at the SQL layer, so a re-run only touches stragglers.
//
//  Bounded: `batchSize` rows per pass + a configurable interval keep
//  the backfill from monopolizing the DB on a million-event archive.
//
//  Quality-or-nothing: if the extractor returns `.empty` for an event
//  (no metadata, no entities), the column stays as the default '{}'.
//  The next pass will retry; nothing is fabricated.
//

import Foundation
import OSLog

public actor NarrativeSlotBackfiller: BackgroundService {
    public let id = "atlas.narrativeSlots.backfill"

    private let database: Database
    private let events: EventsRepository
    private let objects: KnowledgeObjectRepository
    private let entities: EntitiesRepository
    private let extractor: NarrativeSlotExtractor
    private let intervalSeconds: TimeInterval
    private let batchSize: Int
    private var runTask: Task<Void, Never>?

    public init(
        database: Database,
        events: EventsRepository,
        objects: KnowledgeObjectRepository,
        entities: EntitiesRepository,
        extractor: NarrativeSlotExtractor = RuleNarrativeSlotExtractor(),
        intervalSeconds: TimeInterval = 6 * 3_600, // 4× per day
        batchSize: Int = 200
    ) {
        self.database = database
        self.events = events
        self.objects = objects
        self.entities = entities
        self.extractor = extractor
        self.intervalSeconds = intervalSeconds
        self.batchSize = batchSize
    }

    public func start() async {
        guard runTask == nil else { return }
        AtlasLog.knowledge.info("NarrativeSlotBackfiller: starting (interval=\(self.intervalSeconds, privacy: .public)s, batch=\(self.batchSize, privacy: .public))")
        runTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.runOnce()
                let ns = await UInt64(self.intervalSeconds * 1_000_000_000)
                try? await Task.sleep(nanoseconds: ns)
            }
        }
    }

    public func stop() async {
        runTask?.cancel()
        runTask = nil
    }

    /// One backfill pass. Returns the number of events whose
    /// slot bundle was actually written (non-empty result). Events
    /// whose source KO is gone are skipped, NOT counted as failures
    /// — they may be intentional deletions.
    @discardableResult
    public func runOnce() async -> Int {
        let candidates: [Event]
        do {
            candidates = try await events.listEventsMissingNarrativeSlots(limit: batchSize)
        } catch {
            AtlasLog.knowledge.error("NarrativeSlotBackfiller: list failed — \(String(describing: error), privacy: .public)")
            return 0
        }
        guard !candidates.isEmpty else { return 0 }

        var written = 0
        for event in candidates {
            // Load the source KO. Missing = KO was deleted out from
            // under the event row; skip silently.
            let object: KnowledgeObject
            do {
                guard let loaded = try await objects.load(id: event.sourceObjectID) else {
                    continue
                }
                object = loaded
            } catch {
                continue
            }

            // Load the event's participating canonical entities.
            // Identity mapping is correct for backfill: the entities
            // table already holds canonical ids; the ingest-time
            // mention→canonical map isn't reproducible after the fact.
            let participating: [Entity]
            do {
                participating = try await entities.findByIDs(event.entityIDs, limit: event.entityIDs.count + 1)
            } catch {
                continue
            }
            let identityMapping = Dictionary(
                uniqueKeysWithValues: participating.map { ($0.id, $0.id) }
            )

            let slots = await extractor.extract(
                event: event,
                object: object,
                entities: participating,
                canonicalMapping: identityMapping,
                emailParticipants: nil // header-driven path inside extractor still fires from metadata
            )
            if slots.isEmpty {
                continue
            }
            do {
                try await events.setNarrativeSlots(slots, forEventID: event.id)
                written += 1
            } catch {
                AtlasLog.knowledge.error("NarrativeSlotBackfiller: write failed for \(event.id.uuidString.prefix(8), privacy: .public) — \(String(describing: error), privacy: .public)")
            }
        }
        AtlasLog.knowledge.info("NarrativeSlotBackfiller: filled slots for \(written, privacy: .public) of \(candidates.count, privacy: .public) events")
        return written
    }
}
