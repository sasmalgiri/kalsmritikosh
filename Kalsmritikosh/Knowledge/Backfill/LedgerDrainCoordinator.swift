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
//                                filename/hostname ghosts). SOFT-EXCLUDE since
//                                the owner ruling of 2026-09-25: entities get
//                                review_status='rejected' and their memory
//                                status='retired', both reversible and logged
//                                in fact_reviews. It no longer deletes rows or
//                                cascades away mentions/aliases.
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
    /// W-4b — anchors whose minting facts no longer exist, removed.
    public var orphanAnchorsSwept = 0
    /// A6 — era-stale facts unreachable by any current document version, removed.
    public var factOrphansSwept = 0
    /// W-5.6 — mislabeled identifier rows whose field was corrected to the
    /// archive-dominant home ("Patent No. ‹application number›" letters).
    public var crossFieldReassigned = 0
    /// W-5.6 — truncated same-field values folded into the dominant value.
    public var prefixCollapsed = 0
    /// P3.3 — facts written by schema induction, counted SEPARATELY from
    /// `factsWritten` so a receipt never blends model-assisted output into the
    /// deterministic total. Zero whenever the module is off, which is the
    /// default.
    public var factsInduced = 0
    /// Documents induction was attempted on this run (successful or not).
    public var inductionAttempted = 0
    /// Why induction did not run at all, when it did not. nil means it ran.
    public var inductionSkipReason: String?
    /// Candidate documents this run did NOT attempt because the per-run budget
    /// ran out. NON-ZERO MEANS THE PASS IS INCOMPLETE — reported rather than
    /// left implicit, because a receipt that shows "12 attempted" and says
    /// nothing else reads as "that was all of them".
    public var inductionSkippedForBudget = 0
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
          facts: sources rewritten \(factsSourcesRewritten) (deleted \(factsDeleted) stale → wrote \(factsWritten)); anchors now \(anchorsAfter) (\(orphanAnchorsSwept) orphan(s) swept, \(crossFieldReassigned) mislabel(s) re-fielded, \(prefixCollapsed) truncation(s) folded)
          induction:               \(inductionAttempted) document(s) attempted → \(factsInduced) field(s)\(inductionSkipReason.map { " [skipped: \($0)]" } ?? "")\(inductionSkippedForBudget > 0 ? " — \(inductionSkippedForBudget) more candidate(s) left for the next pass (budget)" : "")
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
    /// P3.3 — optional schema inducer. nil (the default) leaves every existing
    /// caller's behaviour byte-identical: no extra pass, no model call, no new
    /// table written. Injected only where a capability registry exists.
    private let inducer: InducedSchemaExtractor?
    private let inductionAttempts: InducedSchemaAttemptRepository?
    /// Per-RUN document budget for induction, decremented only when a model
    /// call was actually made. Belongs to the drain rather than to the
    /// extractor because only the drain knows how many documents a pass faces.
    private var inductionBudgetRemaining = 0
    private var alreadyAttempted: Set<UUID> = []
    private var inductionEnabledThisRun = false

    public init(database: Database,
                objects: KnowledgeObjectRepository,
                entities: EntitiesRepository,
                events: EventsRepository,
                facts: GenericFactRepository,
                evidence: EvidenceStore,
                inducer: InducedSchemaExtractor? = nil,
                inductionAttempts: InducedSchemaAttemptRepository? = nil,
                inductionDocumentBudget: Int = 50) {
        self.database = database
        self.objects = objects
        self.entities = entities
        self.events = events
        self.facts = facts
        self.evidence = evidence
        self.inducer = inducer
        self.inductionAttempts = inductionAttempts
        self.inductionBudgetRemaining = inductionDocumentBudget
    }

    /// The one pass. Safe to re-run: era-stamped rows are skipped everywhere.
    public func drain() async throws -> DrainReceipt {
        var receipt = DrainReceipt()
        receipt.chunksCount.before = try await count("chunks")
        receipt.chunksFTSCount.before = try await count("chunks_fts")
        receipt.embeddingsCount.before = try await count("chunk_embeddings")

        // ── P3.3 induction eligibility, decided ONCE per run ────────────────
        //
        // Three things must hold, and each failure is RECORDED rather than
        // silently producing a run with no induction: the module is on, an
        // inducer and attempt ledger were injected, and the attempt ledger is
        // READABLE. The last is the important one — without the marker there is
        // no idempotence, and re-running a non-deterministic writer blind would
        // break the drain's own "second run changes nothing" law. Skipping is
        // the safe direction; guessing is not.
        if inducer == nil || inductionAttempts == nil {
            receipt.inductionSkipReason = "no inducer wired for this drain"
        } else if !KnowledgeModuleFlags.isEnabled(.inducedSchema) {
            receipt.inductionSkipReason = "module off"
        } else if let inductionAttempts {
            alreadyAttempted = await inductionAttempts.attemptedVersionIDs()
            if await inductionAttempts.attemptsReadable {
                inductionEnabledThisRun = true
            } else {
                receipt.inductionSkipReason =
                    "the attempt ledger could not be read, so idempotence could not be guaranteed"
            }
        }

        // ── pass 1: entity retirement (idempotent) ──────────────────────────
        // The receipt has always called this RETIREMENT; as of the owner ruling
        // of 2026-09-25 the implementation matches the word — junk entities are
        // soft-excluded (review_status='rejected') and their memory is marked
        // retired, both reversible and logged in fact_reviews. Nothing deleted.
        let purge = try await gate.purgeGarbage(in: database)
        receipt.entitiesRetired = purge.entitiesRetired
        receipt.memoryObjectsRetired = purge.memoryObjectsRetired

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

        var boilerplateBodies: [(ko: KnowledgeObject.ID, content: String)] = []
        for koID in koIDs {
            guard let ko = (try? await objects.load(id: koID)) ?? nil else { continue }
            try await drainFacts(for: ko, into: &receipt)
            try await drainEvents(for: ko, into: &receipt)
            try await stampDocumentClass(for: ko, into: &receipt)
            if !ko.content.isEmpty { boilerplateBodies.append((ko.id, ko.content)) }
        }

        // I1 (module .boilerplateEmbedSkip) — learn cross-document boilerplate
        // templates from the whole corpus in one batch (repeats appearing in ≥3
        // documents get promoted). Ingest's embed gate then skips chunks that are
        // mostly a known template. Off ⇒ skipped; best-effort (never fails drain).
        if KnowledgeModuleFlags.isEnabled(.boilerplateEmbedSkip) {
            let promoted = (try? await BoilerplateRegistry(database: database)
                .detectAndPromote(bodies: boilerplateBodies)) ?? []
            if !promoted.isEmpty {
                KalsmritikoshLog.knowledge.info("Boilerplate: promoted \(promoted.count, privacy: .public) learned template(s)")
            }
        }

        // ── pass 4: global milestone rebuild, anchored, suspects excluded ───
        receipt.milestonesRebuilt = try await rebuildMilestones(koIDs: koIDs)

        // ── pass 2b (A6): ORPHANED-FACTS SWEEP ───────────────────────────────
        // Any fact STILL era-stale after the per-KO pass is unreachable by
        // the drain's own derivation — its evidence blocks are not part of
        // any document's current version (deleted or re-versioned sources).
        // Derived hygiene, same class as the stale-facts delete inside
        // drainFacts: source rows untouched, the orphan derived row dies.
        try await database.exec("""
        DELETE FROM generic_facts WHERE COALESCE(producer_version, 0) != \(DerivedProducerVersions.facts);
        """, [])
        receipt.factOrphansSwept = try await Int(database.query("SELECT changes();").first?.int(0) ?? 0)

        // ── pass 2c (W-5.6): CROSS-BLOCK COLLISION RESOLUTION ───────────────
        // The within-block resolver (C-10, caged by owner binding gate 4)
        // cannot see a mislabel whose true home lives in a DIFFERENT
        // document — the live ghost: two hearing letters write "Patent No.
        // 202331019665" while 115 sources file that value as the
        // application number. Archive-wide, same spirit as the caged gates:
        // (a) exact value collision across identifier fields; (b) the
        // intruded field holds a better-attested value of its own; (d') the
        // home's attestation dominates (≥3× and ≥10 rows). The mislabeled
        // rows' FIELD is corrected in place and the subject unbound so the
        // 4b sweep retires the ghost anchor — evidence rows never deleted.
        // Idempotent: once corrected, the collision no longer exists.
        let reassignments = try await crossBlockCollisions()
        for r in reassignments {
            try await database.exec("""
            UPDATE generic_facts SET field = ?, subject_id = NULL
            WHERE lower(field) = ? AND value = ?;
            """, [.text(r.home), .text(r.intruded), .text(r.value)])
            receipt.crossFieldReassigned += try await Int(database.query("SELECT changes();").first?.int(0) ?? 0)
        }
        // Same-field truncation fold: a value that is a strict prefix (≥6
        // chars) of a value the SAME field attests ≥5× more (and ≥20 rows)
        // is a broken capture of it, not a second answer — fold it in.
        for f in try await prefixCollapses() {
            try await database.exec("""
            UPDATE generic_facts SET value = ?
            WHERE lower(field) = ? AND value = ?;
            """, [.text(f.dominant), .text(f.field), .text(f.truncated)])
            receipt.prefixCollapsed += try await Int(database.query("SELECT changes();").first?.int(0) ?? 0)
        }

        // ── pass 4b (W-4b): ORPHANED-ANCHOR SWEEP ────────────────────────────
        // An anchor is DERIVED from facts; when a facts refresh stops minting
        // a junk fact (ed202331019665, the mis-fielded patent number), the
        // anchor entity it once bound must die with it — otherwise the About
        // footer lists ghosts forever ("2 patents on file"). Derived hygiene,
        // same class as the stale-facts delete above; source rows untouched.
        try await database.exec("""
        DELETE FROM entities
        WHERE kind = '\(Entity.Kind.identifierAnchor.rawValue)' AND merged_into IS NULL
          AND id NOT IN (SELECT DISTINCT subject_id FROM generic_facts WHERE subject_id IS NOT NULL);
        """, [])
        receipt.orphanAnchorsSwept = try await Int(database.query("SELECT changes();").first?.int(0) ?? 0)

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
        let versionBlocks = try await evidence.blocks(forVersion: versionID)
        // A mailbox thread shares ONE version with every other thread in the
        // file; draining it over the whole version re-derived all 526 messages
        // once per thread. Keep the thread's own messages; a single-document
        // KO has no message indices and keeps every block, as before.
        let own = IngestCoordinator.blocks(for: ko, from: versionBlocks, singleKO: false)
        let blocks = own.isEmpty ? versionBlocks : own
        guard !blocks.isEmpty else { return }
        let blockIDs = blocks.map(\.id)

        // Stale = any fact carried by these blocks not yet at the facts era.
        let existing = try await facts.facts(forBlockIDs: blockIDs)
        let stale = existing.filter { ($0.producerVersion ?? 0) != DerivedProducerVersions.facts }
        guard !stale.isEmpty || existing.isEmpty else { return }   // fully current → skip

        // Repair the thread's evidence links. Before the thread-aware
        // `blocks(for:)`, ingest linked no mailbox block to its thread, so the
        // facts below would cite blocks no KnowledgeObject owns. Idempotent
        // (INSERT OR IGNORE); only a thread KO has `own` blocks.
        if !own.isEmpty {
            try await evidence.linkBlocks(own.map(\.id), toObject: ko.id, at: Date())
        }

        // Same derivation the ingest path performs (subject label = title block
        // or filename stem; skip boilerplate + tiny blocks), then C-10 merge +
        // anchor binding.
        let subjectLabel = FactSubjectPartitioner.documentLabel(blocks: blocks, fileURL: ko.sourceFile)
        // S2-U1 (D-17 Step 4) — class-ordered roots: the KO's stored class
        // puts its own pack first (a certificate meets the patent root before
        // the employment one); nil class keeps the historical order.
        let docClass = try? await objects.documentClass(forID: ko.id)
        // C-4 — same document-level entry point as the ingest path, so a
        // re-derivation recovers the page-break-split labels the original
        // per-block pass could not see.
        // P3.1 — kinded, same as ingest. This is also how universality reaches
        // an ALREADY-INGESTED archive: the drain re-derives facts from the
        // STORED evidence blocks, so turning the open extractor on and draining
        // upgrades the whole ledger without re-reading a single file.
        // Per-message partitions for a mailbox, one partition otherwise — the
        // SAME split the ingest path uses (FactSubjectPartitioner).
        var derived: [GenericFact] = []
        for partition in FactSubjectPartitioner.partitions(blocks: blocks, fallbackLabel: subjectLabel) {
            let substantive = partition.blocks.filter { !$0.kind.isBoilerplate }
            guard !substantive.isEmpty else { continue }
            derived += extractor.extract(
                fromKindedBlocks: substantive
                    .map { (id: $0.id,
                            text: $0.normalizedText.isEmpty ? $0.rawText : $0.normalizedText,
                            kind: $0.kind) },
                subjectLabel: partition.subjectLabel,
                documentClass: docClass ?? nil,
                // The layout-preserving text for label detection: rawText keeps the
                // line breaks that normalization drops, and without them no
                // `Label: value` after the first is recognisable. See
                // DomainFactExtractor.extract(fromKindedBlocks:) for the
                // measurement that found this.
                layoutTextByBlock: Dictionary(
                    substantive.map { ($0.id, $0.rawText) },
                    uniquingKeysWith: { a, _ in a }))
        }
        var merged = DomainFactExtractor.merge(derived)

        // ── P3.3 — INDUCTION, and only where every rule found nothing ────────
        //
        // `existing.isEmpty && merged.isEmpty` is gate 1 of the four in
        // InducedSchemaExtractor's header, evaluated from values already in
        // hand: this document has no facts and the eleven packs plus the open
        // extractor just failed to produce any. There is therefore nothing for
        // a model-assisted pass to perturb, reorder or contradict.
        //
        // It rides inside the same SAVEPOINT below, so an induced write either
        // lands with the rest of this document's facts or not at all.
        var inducedCount = 0
        var inducedAttemptMade = false
        // A candidate that the budget turned away is counted, so the receipt can
        // say the pass was incomplete instead of implying it was exhaustive.
        if inductionEnabledThisRun, existing.isEmpty, merged.isEmpty,
           inducer != nil, inductionAttempts != nil,
           !alreadyAttempted.contains(versionID),
           inductionBudgetRemaining <= 0 {
            receipt.inductionSkippedForBudget += 1
        }
        if inductionEnabledThisRun, existing.isEmpty, merged.isEmpty,
           let inducer, let inductionAttempts,
           !alreadyAttempted.contains(versionID),
           inductionBudgetRemaining > 0 {
            inductionBudgetRemaining -= 1
            alreadyAttempted.insert(versionID)
            inducedAttemptMade = true
            let outcome = await inducer.induce(
                blocks: blocks
                    .filter { !$0.kind.isBoilerplate }
                    .map { (id: $0.id,
                            text: $0.normalizedText.isEmpty ? $0.rawText : $0.normalizedText,
                            kind: $0.kind) },
                subjectLabel: subjectLabel,
                existingFactCount: 0)
            // Counted AFTER the merge, not before: the merge can fold two
            // proposals onto one row, and reporting the pre-merge number would
            // make `factsWritten` go negative on the line below.
            let inducedFacts = DomainFactExtractor.merge(outcome.facts)
            merged += inducedFacts
            inducedCount = inducedFacts.count
            // Recorded whether it succeeded or not — the attempt IS this pass's
            // resume marker (see the v132 migration), so skipping the record on
            // failure would make the pass re-run forever on exactly the
            // documents where the model has already proven unhelpful.
            await inductionAttempts.record(InducedSchemaAttempt(
                sourceVersionID: versionID,
                knowledgeObjectID: ko.id,
                fieldsWritten: inducedCount,
                declineReason: outcome.declined?.explanation,
                rejectedNotFound: outcome.rejected.valueNotFoundInDocument,
                rejectedReserved: outcome.rejected.reservedField,
                rejectedOther: outcome.rejected.total
                    - outcome.rejected.valueNotFoundInDocument
                    - outcome.rejected.reservedField))
        }

        // Anchor binding (3c semantics), sourced to this KO.
        var cache: [String: UUID] = [:]
        merged = try await withBoundAnchors(merged, koID: ko.id, cache: &cache)

        try await database.exec("SAVEPOINT drain_facts;", [])
        do {
            if !stale.isEmpty { try await facts.delete(ids: stale.map(\.id)) }
            // Topic-Ledger U2 — merge by natural key so a re-derived fact shared
            // across documents lands on ONE canonical row, not a duplicate.
            if !merged.isEmpty { try await facts.mergeUpsert(merged) }
            try await database.exec("RELEASE drain_facts;", [])
        } catch {
            try? await database.exec("ROLLBACK TO drain_facts;", [])
            try? await database.exec("RELEASE drain_facts;", [])
            throw error
        }
        receipt.factsSourcesRewritten += 1
        receipt.factsDeleted += stale.count
        // Induced fields are reported on their own line, so `factsWritten`
        // stays a count of deterministically derived facts.
        receipt.factsWritten += merged.count - inducedCount
        receipt.factsInduced += inducedCount
        if inducedAttemptMade { receipt.inductionAttempted += 1 }
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

    // ── pass 2c helpers (W-5.6) — pure decisions over grouped counts ────────

    struct CrossFieldReassignment: Sendable, Equatable {
        let intruded: String   // lower(field) the value must leave
        let home: String       // lower(field) that dominates it
        let value: String
    }
    struct PrefixFold: Sendable, Equatable {
        let field: String      // lower(field)
        let truncated: String
        let dominant: String
    }

    static let identifierFields = ["patentnumber", "applicationnumber", "publicationnumber"]

    private func identifierAttestation() async throws -> [String: [String: Int]] {
        let placeholders = Self.identifierFields.map { "'\($0)'" }.joined(separator: ",")
        let rows = try await database.query("""
        SELECT lower(field), value, COUNT(*) FROM generic_facts
        WHERE lower(field) IN (\(placeholders))
        GROUP BY lower(field), value;
        """, [])
        var out: [String: [String: Int]] = [:]   // field → value → row count
        for row in rows {
            guard let f = row.string(0), let v = row.string(1) else { continue }
            out[f, default: [:]][v] = Int(row.int(2) ?? 0)
        }
        return out
    }

    func crossBlockCollisions() async throws -> [CrossFieldReassignment] {
        let attn = try await identifierAttestation()
        return Self.resolveCrossBlock(attestation: attn)
    }

    /// Pure — CI proves the gates on the live shape. A value leaves field F
    /// for field H only when: it collides (both claim it), H attests it ≥3×
    /// F and ≥10 rows, and F holds a DIFFERENT value attested better than
    /// the intruder (F has its own answer).
    nonisolated static func resolveCrossBlock(attestation: [String: [String: Int]]) -> [CrossFieldReassignment] {
        var out: [CrossFieldReassignment] = []
        for (f, values) in attestation.sorted(by: { $0.key < $1.key }) {
            for (v, fCount) in values.sorted(by: { $0.key < $1.key }) {
                for (h, hValues) in attestation.sorted(by: { $0.key < $1.key }) where h != f {
                    guard let hCount = hValues[v] else { continue }
                    guard hCount >= 10, hCount >= 3 * fCount else { continue }
                    let fBest = values.filter { $0.key != v }.map(\.value).max() ?? 0
                    guard fBest > fCount else { continue }
                    out.append(CrossFieldReassignment(intruded: f, home: h, value: v))
                }
            }
        }
        return out
    }

    func prefixCollapses() async throws -> [PrefixFold] {
        let attn = try await identifierAttestation()
        return Self.resolvePrefixFolds(attestation: attn)
    }

    /// Pure — a same-field value that is a strict prefix (≥6 chars) of a
    /// value attested ≥5× more and ≥20 rows is a broken capture, folded in.
    nonisolated static func resolvePrefixFolds(attestation: [String: [String: Int]]) -> [PrefixFold] {
        var out: [PrefixFold] = []
        for (f, values) in attestation.sorted(by: { $0.key < $1.key }) {
            for (short, sCount) in values.sorted(by: { $0.key < $1.key }) where short.count >= 6 {
                for (long, lCount) in values.sorted(by: { $0.key < $1.key })
                where long != short && long.hasPrefix(short) {
                    guard lCount >= 20, lCount >= 5 * sCount else { continue }
                    out.append(PrefixFold(field: f, truncated: short, dominant: long))
                }
            }
        }
        return out
    }
}
