//
//  BondBackfill.swift
//  Kalsmritikosh
//
//  Iterates every KO already in the ledger and runs BondConstructor
//  against its existing entities + events. This is the "rebuild the
//  bond graph for a corpus you already ingested" pass — needed once
//  after the v13 migration shipped the `fact_bonds` table to populate
//  bonds for the user's production archive without forcing a full
//  re-ingest.
//
//  BondConstructor's UNIQUE INDEX on (bond_name, from_fact_id, to_fact_id)
//  makes this idempotent: re-running over a KO that already has bonds
//  bumps the weight + appends the source KO id to the evidence list,
//  no duplicate rows.
//
//  Limitation: the per-KO ingest path also derives email participants
//  from the EmailLoader's structured headers. Those are NOT persisted
//  in the database, so the backfill can't recover the
//  affiliated_with / sent_by / received_by / issued_by bonds that
//  required them. Every OTHER bond category (discusses, signed_by,
//  attended_by, made_by, invoice_for, issued_to, delivers_for,
//  delivered_by, party_a, party_b, amends, about) is recoverable from
//  the persisted event.entityIDs.
//

import Foundation
import OSLog

public actor BondBackfill {
    public struct Stats: Sendable {
        public var knowledgeObjects = 0
        public var bondsWritten = 0
        public var skipped = 0
        public var failed = 0
    }

    private let knowledgeObjects: KnowledgeObjectRepository
    private let entities: EntitiesRepository
    private let events: EventsRepository
    private let constructor: BondConstructor
    private let pageSize: Int

    public init(
        knowledgeObjects: KnowledgeObjectRepository,
        entities: EntitiesRepository,
        events: EventsRepository,
        constructor: BondConstructor,
        pageSize: Int = 200
    ) {
        self.knowledgeObjects = knowledgeObjects
        self.entities = entities
        self.events = events
        self.constructor = constructor
        self.pageSize = pageSize
    }

    /// Walk every KO in the ledger and emit bonds. Returns total
    /// counts. Safe to re-run — UNIQUE INDEX dedupes.
    public func run() async -> Stats {
        var stats = Stats()
        var offset = 0
        let started = Date()
        KalsmritikoshLog.knowledge.info("BondBackfill: starting run")
        while true {
            let page: [KnowledgeObject.ID]
            do {
                page = try await knowledgeObjects.allIDs(offset: offset, pageSize: pageSize)
            } catch {
                KalsmritikoshLog.knowledge.error("BondBackfill: enumerate failed at offset \(offset, privacy: .public) — \(String(describing: error), privacy: .public)")
                stats.failed += 1
                break
            }
            if page.isEmpty { break }
            for koID in page {
                stats.knowledgeObjects += 1
                let context = await buildContext(for: koID)
                if context.entities.isEmpty && context.events.isEmpty {
                    stats.skipped += 1
                    continue
                }
                let count = await constructor.construct(context)
                stats.bondsWritten += count
            }
            offset += page.count
            if page.count < pageSize { break }
        }
        let elapsed = Date().timeIntervalSince(started)
        KalsmritikoshLog.knowledge.info("BondBackfill: complete — KOs=\(stats.knowledgeObjects, privacy: .public) bondsWritten=\(stats.bondsWritten, privacy: .public) skipped=\(stats.skipped, privacy: .public) failed=\(stats.failed, privacy: .public) elapsed=\(String(format: "%.1f", elapsed), privacy: .public)s")
        return stats
    }

    // MARK: - Internals

    /// Build a BondConstructor.Context from rows already in the
    /// ledger. Identity canonical mapping (rows are already canonical
    /// at this point) and no email participants (those aren't
    /// persisted — see file header note).
    private func buildContext(for koID: KnowledgeObject.ID) async -> BondConstructor.Context {
        let ents = (try? await entities.findByMentionSource(koID)) ?? []
        let evs = (try? await events.findBySourceObject(koID)) ?? []
        var mapping: [Entity.ID: Entity.ID] = [:]
        for entity in ents {
            mapping[entity.id] = entity.id
        }
        return BondConstructor.Context(
            objectID: koID,
            entities: ents,
            events: evs,
            canonicalMapping: mapping,
            emailParticipants: nil
        )
    }
}
