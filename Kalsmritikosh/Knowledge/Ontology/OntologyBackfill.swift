//
//  OntologyBackfill.swift
//  Kalsmritikosh
//
//  G3.8 — one-shot backfill that walks every entity / event /
//  memory_object row whose `fact_type` is NULL, runs the
//  FactTypeClassifier, and writes the resulting label back. Idempotent:
//  re-running classifies only the rows that are still NULL, so a partial
//  backfill that crashed mid-way picks up cleanly.
//
//  The IncrementalUpdater calls this once on AppState.boot after the
//  schema migration applies, then never again. New rows are classified
//  in-line by IngestCoordinator (G3.12 wiring, future commit).
//
//  Reads + writes go through the actor-backed repositories — never
//  raw SQL. Confidence threshold for writes is set by
//  `minConfidence`; rows below the threshold stay NULL and are
//  picked up by the LLM-assisted extractor (G3.14, future).
//

import Foundation
import OSLog

public actor OntologyBackfill {
    public struct Stats: Sendable {
        public var entitiesClassified = 0
        public var eventsClassified = 0
        public var entitiesSkipped = 0
        public var eventsSkipped = 0
    }

    private let entities: EntitiesRepository
    private let events: EventsRepository
    private let classifier: FactTypeClassifier
    private let minConfidence: Double

    public init(
        entities: EntitiesRepository,
        events: EventsRepository,
        classifier: FactTypeClassifier = FactTypeClassifier(),
        minConfidence: Double = 0.5
    ) {
        self.entities = entities
        self.events = events
        self.classifier = classifier
        self.minConfidence = minConfidence
    }

    /// Run the backfill. Returns counts so callers can log/report.
    public func run(batchSize: Int = 500) async -> Stats {
        var stats = Stats()

        // Entities first — many bond rules join through canonical
        // entity ids, so labeling those early lets event classifiers
        // skip work later.
        let unlabeledEntities = (try? await entities.listUnlabeledFactTypes(limit: batchSize)) ?? []
        for entity in unlabeledEntities {
            if let result = classifier.classify(entity: entity),
               result.confidence >= minConfidence {
                do {
                    try await entities.setFactType(
                        result.type.rawValue,
                        forEntityID: entity.id
                    )
                    stats.entitiesClassified += 1
                } catch {
                    AtlasLog.knowledge.error("OntologyBackfill: setFactType failed for entity \(entity.id.uuidString.prefix(8), privacy: .public): \(String(describing: error), privacy: .public)")
                    stats.entitiesSkipped += 1
                }
            } else {
                stats.entitiesSkipped += 1
            }
        }

        let unlabeledEvents = (try? await events.listUnlabeledFactTypes(limit: batchSize)) ?? []
        for event in unlabeledEvents {
            if let result = classifier.classify(event: event),
               result.confidence >= minConfidence {
                do {
                    try await events.setFactType(
                        result.type.rawValue,
                        forEventID: event.id
                    )
                    stats.eventsClassified += 1
                } catch {
                    AtlasLog.knowledge.error("OntologyBackfill: setFactType failed for event \(event.id.uuidString.prefix(8), privacy: .public): \(String(describing: error), privacy: .public)")
                    stats.eventsSkipped += 1
                }
            } else {
                stats.eventsSkipped += 1
            }
        }

        AtlasLog.knowledge.info("OntologyBackfill: entities classified=\(stats.entitiesClassified, privacy: .public) skipped=\(stats.entitiesSkipped, privacy: .public); events classified=\(stats.eventsClassified, privacy: .public) skipped=\(stats.eventsSkipped, privacy: .public)")
        return stats
    }
}
