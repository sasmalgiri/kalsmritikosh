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
    /// G3.14 — optional LLM-assisted slot filler. When wired, the
    /// backfill runs it for rows where the rule-based SlotExtractor
    /// didn't produce a `.ok` verdict, fetching the source KO content
    /// to give the model a context window. nil = LLM step disabled.
    private let llmSlotExtractor: LLMSlotExtractor?
    private let knowledgeObjects: KnowledgeObjectRepository?

    public init(
        entities: EntitiesRepository,
        events: EventsRepository,
        classifier: FactTypeClassifier = FactTypeClassifier(),
        slotExtractor: SlotExtractor = SlotExtractor(),
        validator: OntologyValidator = OntologyValidator(),
        llmSlotExtractor: LLMSlotExtractor? = nil,
        knowledgeObjects: KnowledgeObjectRepository? = nil,
        minConfidence: Double = 0.5
    ) {
        self.entities = entities
        self.events = events
        self.classifier = classifier
        self.slotExtractor = slotExtractor
        self.validator = validator
        self.llmSlotExtractor = llmSlotExtractor
        self.knowledgeObjects = knowledgeObjects
        self.minConfidence = minConfidence
    }

    /// Run the backfill. Returns counts so callers can log/report.
    /// Loops in `batchSize` chunks until no NULL rows remain — earlier
    /// revisions processed exactly one batch which left larger archives
    /// at ~30-40% classified (caught by DataHealthCheck 2026-06-24:
    /// 674 of 1699 entities typed). Cycle ceiling prevents an infinite
    /// loop if a row's classifier returns nil but the listUnlabeled
    /// query still surfaces it next round.
    public func run(batchSize: Int = 500) async -> Stats {
        var stats = Stats()
        let maxCycles = 200

        // Entities first — many bond rules join through canonical
        // entity ids, so labeling those early lets event classifiers
        // skip work later.
        var entityCycles = 0
        while entityCycles < maxCycles {
            entityCycles += 1
            let unlabeled = (try? await entities.listUnlabeledFactTypes(limit: batchSize)) ?? []
            if unlabeled.isEmpty { break }
            var progressedThisCycle = 0
            for entity in unlabeled {
                if let result = classifier.classify(entity: entity),
                   result.confidence >= minConfidence {
                    do {
                        try await entities.setFactType(
                            result.type.rawValue,
                            forEntityID: entity.id
                        )
                        stats.entitiesClassified += 1
                        progressedThisCycle += 1
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
                    // The classifier doesn't recognise this entity (e.g.
                    // .date / .monetaryAmount / .location). Write a
                    // sentinel `_unclassified` so the next page query
                    // doesn't keep surfacing it — otherwise the loop
                    // would never terminate on corpora with many
                    // unrecognised kinds.
                    try? await entities.setFactType(
                        "_unclassified",
                        forEntityID: entity.id
                    )
                    stats.entitiesSkipped += 1
                }
            }
            if progressedThisCycle == 0 && stats.entitiesSkipped == unlabeled.count {
                // All-skips cycle but rows were marked _unclassified —
                // next page query won't return the same set, but
                // defensively bail if it does.
                if unlabeled.count < batchSize { break }
            }
        }

        var eventCycles = 0
        while eventCycles < maxCycles {
            eventCycles += 1
            let unlabeled = (try? await events.listUnlabeledFactTypes(limit: batchSize)) ?? []
            if unlabeled.isEmpty { break }
            var progressedThisCycle = 0
            for event in unlabeled {
                if let result = classifier.classify(event: event),
                   result.confidence >= minConfidence {
                    do {
                        try await events.setFactType(
                            result.type.rawValue,
                            forEventID: event.id
                        )
                        stats.eventsClassified += 1
                        progressedThisCycle += 1
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
                    try? await events.setFactType(
                        "_unclassified",
                        forEventID: event.id
                    )
                    stats.eventsSkipped += 1
                }
            }
            if progressedThisCycle == 0 && stats.eventsSkipped == unlabeled.count {
                if unlabeled.count < batchSize { break }
            }
        }

        AtlasLog.knowledge.info("OntologyBackfill: entities classified=\(stats.entitiesClassified, privacy: .public) (slots=\(stats.entitySlotsWritten, privacy: .public)) skipped=\(stats.entitiesSkipped, privacy: .public) cycles=\(entityCycles, privacy: .public); events classified=\(stats.eventsClassified, privacy: .public) (slots=\(stats.eventSlotsWritten, privacy: .public)) skipped=\(stats.eventsSkipped, privacy: .public) cycles=\(eventCycles, privacy: .public); slot rejects=\(stats.slotWritesRejected, privacy: .public)")
        return stats
    }

    // MARK: - Slot-write helpers (G3.13 + G3.15)

    /// Derive slots, validate via OntologyValidator, and persist if not
    /// `.reject`. Returns true when a row was written, false otherwise.
    /// `.lowQuality` writes proceed — the data still goes in; the UI
    /// can render a warning per the validator contract.
    ///
    /// G3.14 — when an LLM extractor is wired AND the rule-based
    /// verdict is `.reject`, fetch the source KO content and ask the
    /// model to fill the missing slots. If the second verdict is
    /// `.ok`/`.lowQuality`, persist; otherwise drop the row.
    private func writeEntitySlots(entity: Entity, factType: FactType) async -> Bool {
        var slots = slotExtractor.extract(entity: entity, factType: factType)
        guard !slots.isEmpty else { return false }
        var verdict = validator.validate(type: factType, slots: slots)
        if case .reject = verdict {
            slots = await llmFill(
                entity: entity,
                factType: factType,
                existing: slots,
                sourceObjectID: entity.sourceObjectID
            )
            verdict = validator.validate(type: factType, slots: slots)
        }
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
        var slots = slotExtractor.extract(event: event, factType: factType)
        guard !slots.isEmpty else { return false }
        var verdict = validator.validate(type: factType, slots: slots)
        if case .reject = verdict {
            slots = await llmFill(
                event: event,
                factType: factType,
                existing: slots,
                sourceObjectID: event.sourceObjectID
            )
            verdict = validator.validate(type: factType, slots: slots)
        }
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

    /// G3.14 — call the LLM slot extractor with the source KO content.
    /// No-op when no extractor/KO repo is wired or the content fetch
    /// fails. Returns the (possibly merged) slot map.
    private func llmFill(
        entity: Entity,
        factType: FactType,
        existing: [String: AnyCodable.AnySendable],
        sourceObjectID: KnowledgeObject.ID
    ) async -> [String: AnyCodable.AnySendable] {
        // try? on a throwing String? returns String?? — flatten in one shot.
        guard let llm = llmSlotExtractor,
              let kos = knowledgeObjects,
              let text = (try? await kos.fetchContent(id: sourceObjectID)) ?? nil else {
            return existing
        }
        return await llm.fillMissing(
            entity: entity,
            factType: factType,
            existing: existing,
            sourceText: text
        )
    }

    private func llmFill(
        event: Event,
        factType: FactType,
        existing: [String: AnyCodable.AnySendable],
        sourceObjectID: KnowledgeObject.ID
    ) async -> [String: AnyCodable.AnySendable] {
        // try? on a throwing String? returns String?? — flatten in one shot.
        guard let llm = llmSlotExtractor,
              let kos = knowledgeObjects,
              let text = (try? await kos.fetchContent(id: sourceObjectID)) ?? nil else {
            return existing
        }
        return await llm.fillMissing(
            event: event,
            factType: factType,
            existing: existing,
            sourceText: text
        )
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
