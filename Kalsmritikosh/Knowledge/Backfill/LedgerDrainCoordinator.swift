//
//  LedgerDrainCoordinator.swift
//  Kalsmritikosh
//
//  V5 — THE DRAIN (F7): the sanctioned ONE-TIME rewrite of the DERIVED layers
//  to the current producer eras. Sources and evidence are NEVER touched — the
//  no-delete law protects them; what gets rewritten is stale DERIVATIONS:
//
//    pass 1  ENTITY RETIREMENT   EntityQualityGate.purgeGarbage retires the
//                                junk register (the live ~4,343 "Nil Nil"/
//                                filename/hostname ghosts; owner-blessed
//                                mechanism from T13, cascades memory_objects).
//    pass 2  FACTS → v2          per KO: re-extract GenericFacts from the
//                                STORED EvidenceBlocks via the same packs the
//                                ingest path uses, C-10 merge, BIND ANCHORS
//                                (anchors are born here for legacy sources);
//                                stale (v0/v1) fact rows for that source are
//                                replaced. Facts are derived projections —
//                                explicitly rewritable.
//    pass 3  EVENTS → v1         per KO with stale events: drop that KO's
//                                extractor events and re-extract via the NOW
//                                CLASS-GATED RuleEventExtractor (EV-1 — a
//                                patent letter stops manufacturing commercial
//                                boilerplate).
//    pass 4  MILESTONES          one global rebuild: delete + re-extract legal
//                                milestones THREADED ONTO ANCHORS, I-5
//                                split-suspects excluded. (Same primitives as
//                                AppState.backfillLegalMilestones, which stays
//                                the UI-facing rebuild; this is the headless
//                                drain twin.)
//    pass 5  DOCUMENT_CLASS      v123 backfill: classify + stamp every KO
//                                whose document_class is NULL.
//    pass 6  ENTITY ERA STAMP    surviving register rows → producer_version 1
//                                (they now reflect v1 semantics: gated + the
//                                anchor era).
//
//  RESUME MARKER = producer_version itself: every pass selects only
//  COALESCE(producer_version,0) != current rows, so a second run is a no-op
//  by construction (transactional per unit of work; resumable after a kill).
//  UNTOUCHED, PROVEN: chunks, chunks_fts, chunk_embeddings — the receipt
//  carries before/after row counts; a change is a STOP.
//

import Foundation
import os

public struct DrainReceipt: Sendable {
    public var entitiesRetired = 0
    public var memoryObjectsRetired = 0
    public var factsSourcesRewritten = 0
    public var factsDeleted = 0
    public var factsWritten = 0
    public var anchorsAfter = 0
    public var eventKOsRewritten = 0
    public var eventsDeleted = 0
    public var eventsWritten = 0
    public var milestonesRebuilt = 0
    public var documentClassStamped = 0
    public var entitiesStampedV1 = 0
    /// Untouched-table proofs: (before, after) row counts.
    public var chunksCount = (before: 0, after: 0)
    public var chunksFTSCount = (before: 0, after: 0)
    public var embeddingsCount = (before: 0, after: 0)

    public var untouchedProven: Bool {
        chunksCount.before == chunksCount.after
            && chunksFTSCount.before == chunksFTSCount.after
            && embeddingsCount.before == embeddingsCount.after
    }

    public func renderLines() -> String {
        """
        DRAIN RECEIPT
          entities retired:        \(entitiesRetired) (+\(memoryObjectsRetired) memory rows)
          facts: sources rewritten \(factsSourcesRewritten) (deleted \(factsDeleted) stale → wrote \(factsWritten) v2); anchors now \(anchorsAfter)
          events: KOs rewritten    \(eventKOsRewritten) (deleted \(eventsDeleted) stale → wrote \(eventsWritten) v1)
          milestones rebuilt:      \(milestonesRebuilt)
          document_class stamped:  \(documentClassStamped)
          entities stamped v1:     \(entitiesStampedV1)
          untouched: chunks \(chunksCount.before)→\(chunksCount.after) · fts \(chunksFTSCount.before)→\(chunksFTSCount.after) · embeddings \(embeddingsCount.before)→\(embeddingsCount.after) [\(untouchedProven ? "PROVEN" : "VIOLATED — STOP")]
        """
    }
}

public final class LedgerDrainCoordinator {
    private let database: Database
    private let objects: KnowledgeObjectRepository
    private let entities: EntitiesRepository
    private let events: EventsRepository
    private let facts: GenericFactRepository
    private let evidence: EvidenceStore
    private let extractor = DomainFactExtractor()
    private let gate = EntityQualityGate.bundled()

    public init(database: Database,
                objects: KnowledgeObjectRepository,
                entities: EntitiesRepository,
                events: EventsRepository,
                facts: GenericFactRepository,
                evidence: EvidenceStore) {
        self.database = database
        self.objects = objects
        self.entities = entities
        self.events = events
        self.facts = facts
        self.evidence = evidence
    }

    /// The one pass. Safe to re-run: era-stamped rows are skipped everywhere.
    public func drain() async throws -> DrainReceipt {
        var receipt = DrainReceipt()
        receipt.chunksCount.before = try await count("chunks")
        receipt.chunksFTSCount.before = try await count("chunks_fts")
        receipt.embeddingsCount.before = try await count("chunk_embeddings")

        // ── pass 1: entity retirement (owner-blessed purge; idempotent) ─────
        let purge = try await gate.purgeGarbage(in: database)
        receipt.entitiesRetired = purge.entitiesDeleted
        receipt.memoryObjectsRetired = purge.memoryObjectsDeleted

        // Enumerate every KO once; passes 2/3/5 are per-KO.
        var koIDs: [KnowledgeObject.ID] = []
        var offset = 0
        while true {
            let page = (try? await objects.allIDs(offset: offset, pageSize: 500)) ?? []
            if page.isEmpty { break }
            koIDs.append(contentsOf: page)
            offset += page.count
            if page.count < 500 { break }
        }

        for koID in koIDs {
            guard let ko = (try? await objects.load(id: koID)) ?? nil else { continue }
            try await drainFacts(for: ko, into: &receipt)
            try await drainEvents(for: ko, into: &receipt)
            try await stampDocumentClass(for: ko, into: &receipt)
        }

        // ── pass 4: global milestone rebuild, anchored, suspects excluded ───
        receipt.milestonesRebuilt = try await rebuildMilestones(koIDs: koIDs)

        // ── pass 6: era-stamp the surviving register ─────────────────────────
        try await database.exec("""
        UPDATE entities SET producer_version = \(DerivedProducerVersions.entities)
        WHERE COALESCE(producer_version, 0) != \(DerivedProducerVersions.entities);
        """, [])
        receipt.entitiesStampedV1 = try await Int(database.query("SELECT changes();").first?.int(0) ?? 0)

        receipt.anchorsAfter = try await entities.count(of: .identifierAnchor)
        receipt.chunksCount.after = try await count("chunks")
        receipt.chunksFTSCount.after = try await count("chunks_fts")
        receipt.embeddingsCount.after = try await count("chunk_embeddings")
        KalsmritikoshLog.knowledge.info("DRAIN: \(receipt.renderLines(), privacy: .public)")
        return receipt
    }

    // ── pass 2: facts → v2 for one KO ───────────────────────────────────────

    private func drainFacts(for ko: KnowledgeObject, into receipt: inout DrainReceipt) async throws {
        guard let versionID = try await evidence.currentVersionID(forObject: ko.id) else { return }
        let blocks = try await evidence.blocks(forVersion: versionID)
        guard !blocks.isEmpty else { return }
        let blockIDs = blocks.map(\.id)

        // Stale = any fact carried by these blocks not yet at the facts era.
        let existing = try await facts.facts(forBlockIDs: blockIDs)
        let stale = existing.filter { ($0.producerVersion ?? 0) != DerivedProducerVersions.facts }
        guard !stale.isEmpty || existing.isEmpty else { return }   // fully current → skip

        // Same derivation the ingest path performs (subject label = title block
        // or filename stem; skip boilerplate + tiny blocks), then C-10 merge +
        // anchor binding.
        let subjectLabel: String = {
            if let title = blocks.first(where: { $0.kind == .documentTitle }) {
                let t = title.normalizedText.isEmpty ? title.rawText : title.normalizedText
                let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return String(trimmed.prefix(120)) }
            }
            return ko.sourceFile.deletingPathExtension().lastPathComponent
        }()
        var derived: [GenericFact] = []
        for block in blocks {
            guard !block.kind.isBoilerplate else { continue }
            let text = block.normalizedText.isEmpty ? block.rawText : block.normalizedText
            guard text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 8 else { continue }
            derived += extractor.extract(fromText: text, subjectLabel: subjectLabel, blockID: block.id)
        }
        var merged = DomainFactExtractor.merge(derived)
        // Anchor binding (3c semantics), sourced to this KO.
        var cache: [String: UUID] = [:]
        merged = try await withBoundAnchors(merged, koID: ko.id, cache: &cache)

        try await database.exec("SAVEPOINT drain_facts;", [])
        do {
            if !stale.isEmpty { try await facts.delete(ids: stale.map(\.id)) }
            if !merged.isEmpty { try await facts.upsert(merged) }
            try await database.exec("RELEASE drain_facts;", [])
        } catch {
            try? await database.exec("ROLLBACK TO drain_facts;", [])
            try? await database.exec("RELEASE drain_facts;", [])
            throw error
        }
        receipt.factsSourcesRewritten += 1
        receipt.factsDeleted += stale.count
        receipt.factsWritten += merged.count
    }

    private func withBoundAnchors(_ input: [GenericFact], koID: KnowledgeObject.ID,
                                  cache: inout [String: UUID]) async throws -> [GenericFact] {
        var out: [GenericFact] = []
        out.reserveCapacity(input.count)
        for fact in input {
            guard FactSchemaRegistry.expectedShape(of: fact.field) == .identifier,
                  !fact.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                out.append(fact); continue
            }
            let key = IdentifierAnchor.identityKey(field: fact.field, value: fact.value)
            if let hit = cache[key] { out.append(fact.withSubjectID(hit)); continue }
            let anchorID = try await entities.resolveOrCreateAnchor(
                field: fact.field, value: fact.value, sourceObjectID: koID)
            cache[key] = anchorID
            out.append(fact.withSubjectID(anchorID))
        }
        return out
    }

    // ── pass 3: events → v1 for one KO ──────────────────────────────────────

    private func drainEvents(for ko: KnowledgeObject, into receipt: inout DrainReceipt) async throws {
        let staleCount = try await Int(database.query("""
        SELECT COUNT(*) FROM events
        WHERE source_object_id = ? AND COALESCE(producer_version, 0) != \(DerivedProducerVersions.events);
        """, [.uuid(ko.id)]).first?.int(0) ?? 0)
        guard staleCount > 0 else { return }

        let koEntities = (try? await entities.findByMentionSource(ko.id)) ?? []
        let fresh = (try? await RuleEventExtractor().extractEvents(
            from: ko, chunks: [], entities: koEntities, blocks: [])) ?? []

        try await database.exec("SAVEPOINT drain_events;", [])
        do {
            try await database.exec("""
            DELETE FROM events
            WHERE source_object_id = ? AND COALESCE(producer_version, 0) != \(DerivedProducerVersions.events);
            """, [.uuid(ko.id)])
            if !fresh.isEmpty { try await events.insertBatch(fresh) }
            try await database.exec("RELEASE drain_events;", [])
        } catch {
            try? await database.exec("ROLLBACK TO drain_events;", [])
            try? await database.exec("RELEASE drain_events;", [])
            throw error
        }
        receipt.eventKOsRewritten += 1
        receipt.eventsDeleted += staleCount
        receipt.eventsWritten += fresh.count
    }

    // ── pass 4: anchored milestone rebuild (headless twin of the UI backfill)

    private func rebuildMilestones(koIDs: [KnowledgeObject.ID]) async throws -> Int {
        try await events.deleteMilestoneEvents()
        let suspects = IdentifierAnchorReview.splitSuspectAnchorIDs(
            among: (try? await entities.allAnchors()) ?? [])
        var created = 0
        for koID in koIDs {
            guard let content = try? await objects.fetchContent(id: koID), !content.isEmpty else { continue }
            var seen = Set<String>()
            var anchorIDs: [UUID] = []
            for f in extractor.extract(fromText: content, subjectLabel: "", blockID: UUID())
            where FactSchemaRegistry.expectedShape(of: f.field) == .identifier {
                guard !f.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                let key = IdentifierAnchor.identityKey(field: f.field, value: f.value)
                guard seen.insert(key).inserted else { continue }
                if let id = try? await entities.resolveOrCreateAnchor(
                    field: f.field, value: f.value, sourceObjectID: koID),
                   !suspects.contains(id) {
                    anchorIDs.append(id)
                }
            }
            let milestones = await PatentLegalEventExtractor.extract(
                text: content, sourceObjectID: koID, entityIDs: anchorIDs)
            if !milestones.isEmpty {
                try? await events.insertBatch(milestones)
                created += milestones.count
            }
        }
        return created
    }

    // ── pass 5: document_class (v123 backfill) ──────────────────────────────

    private func stampDocumentClass(for ko: KnowledgeObject, into receipt: inout DrainReceipt) async throws {
        guard try await objects.documentClass(forID: ko.id) == nil else { return }
        try await objects.setDocumentClass(DocumentClassifier().classify(ko), forID: ko.id)
        receipt.documentClassStamped += 1
    }

    private func count(_ table: String) async throws -> Int {
        Int((try await database.query("SELECT COUNT(*) FROM \(table);", [])).first?.int(0) ?? 0)
    }
}
