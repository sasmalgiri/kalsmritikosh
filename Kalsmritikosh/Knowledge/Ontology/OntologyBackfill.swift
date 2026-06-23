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
        public var entitySlotsWritten = 0
        public var eventSlotsWritten = 0
        public var slotWritesRejected = 0
    }

    private let entities: EntitiesRepository
    private let events: EventsRepository
    private let classifier: FactTypeClassifier
    private let slotExtractor: SlotExtractor
    private let validator: OntologyValidator
    private let encoder = JSONEncoder()
    private let minConfidence: Double

    public init(
        entities: EntitiesRepository,
        events: EventsRepository,
        classifier: FactTypeClassifier = FactTypeClassifier(),
        slotExtractor: SlotExtractor = SlotExtractor(),
        validator: OntologyValidator = OntologyValidator(),
        minConfidence: Double = 0.5
    ) {
        self.entities = entities
        self.events = events
        self.classifier = classifier
        self.slotExtractor = slotExtractor
        self.validator = validator
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
                    if await writeEntitySlots(entity: entity, factType: result.type) {
                        stats.entitySlotsWritten += 1
                    } else {
                        stats.slotWritesRejected += 1
                    }
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
                    if await writeEventSlots(event: event, factType: result.type) {
                        stats.eventSlotsWritten += 1
                    } else {
                        stats.slotWritesRejected += 1
                    }
                } catch {
                    AtlasLog.knowledge.error("OntologyBackfill: setFactType failed for event \(event.id.uuidString.prefix(8), privacy: .public): \(String(describing: error), privacy: .public)")
                    stats.eventsSkipped += 1
                }
            } else {
                stats.eventsSkipped += 1
            }
        }

        AtlasLog.knowledge.info("OntologyBackfill: entities classified=\(stats.entitiesClassified, privacy: .public) (slots=\(stats.entitySlotsWritten, privacy: .public)) skipped=\(stats.entitiesSkipped, privacy: .public); events classified=\(stats.eventsClassified, privacy: .public) (slots=\(stats.eventSlotsWritten, privacy: .public)) skipped=\(stats.eventsSkipped, privacy: .public); slot rejects=\(stats.slotWritesRejected, privacy: .public)")
        return stats
    }

    // MARK: - Slot-write helpers (G3.13 + G3.15)

    /// Derive slots, validate via OntologyValidator, and persist if not
    /// `.reject`. Returns true when a row was written, false otherwise.
    /// `.lowQuality` writes proceed — the data still goes in; the UI
    /// can render a warning per the validator contract.
    private func writeEntitySlots(entity: Entity, factType: FactType) async -> Bool {
        let slots = slotExtractor.extract(entity: entity, factType: factType)
        guard !slots.isEmpty else { return false }
        let verdict = validator.validate(type: factType, slots: slots)
        if case .reject(let reasons) = verdict {
            AtlasLog.knowledge.debug("OntologyBackfill: rejected entity \(entity.id.uuidString.prefix(8), privacy: .public) slots — \(reasons.joined(separator: "; "), privacy: .public)")
            return false
        }
        guard let json = encodeSlots(slots) else { return false }
        do {
            try await entities.setSlotValues(json, forEntityID: entity.id)
            return true
        } catch {
            AtlasLog.knowledge.error("OntologyBackfill: setSlotValues failed for entity \(entity.id.uuidString.prefix(8), privacy: .public): \(String(describing: error), privacy: .public)")
            return false
        }
    }

    private func writeEventSlots(event: Event, factType: FactType) async -> Bool {
        let slots = slotExtractor.extract(event: event, factType: factType)
        guard !slots.isEmpty else { return false }
        let verdict = validator.validate(type: factType, slots: slots)
        if case .reject(let reasons) = verdict {
            AtlasLog.knowledge.debug("OntologyBackfill: rejected event \(event.id.uuidString.prefix(8), privacy: .public) slots — \(reasons.joined(separator: "; "), privacy: .public)")
            return false
        }
        guard let json = encodeSlots(slots) else { return false }
        do {
            try await events.setSlotValues(json, forEventID: event.id)
            return true
        } catch {
            AtlasLog.knowledge.error("OntologyBackfill: setSlotValues failed for event \(event.id.uuidString.prefix(8), privacy: .public): \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// Encode `[String: AnySendable]` as JSON via AnyCodable wrappers.
    private func encodeSlots(_ slots: [String: AnyCodable.AnySendable]) -> String? {
        let wrapped = slots.mapValues { AnyCodable($0) }
        guard let data = try? encoder.encode(wrapped),
              let s = String(data: data, encoding: .utf8) else {
            return nil
        }
        return s
    }
}
