//
//  IngestCoordinator.swift
//  Kalsmritikosh
//
//  Single entry-point for turning a file on disk into persisted rows.
//  Steps: detect type → load → clean → classify → chunk → extract
//  entities + events + relationships → embed chunks → write everything →
//  emit a SubjectInvalidation so the MemoryDistiller can update only the
//  affected subjects.
//

import Foundation
import OSLog
import CryptoKit


public actor IngestCoordinator {
    /// Thrown when a file is intentionally NOT ingested (not a failure). Callers
    /// treat it as "processed, skipped" so it doesn't count as an error.
    public enum IngestSkipped: Error, Sendable { case mediaDeferred }

    public struct Result: Sendable {
        public let fileRecord: FileRecord
        public let object: KnowledgeObject
        public let chunkCount: Int
        public let entityCount: Int
        public let eventCount: Int
        public let documentClass: DocumentClass
        public let invalidations: [SubjectInvalidation.Subject]
    }

    private let loaders: LoaderRegistry
    private let cleaner: Cleaner
    private let classifier: DocumentClassifier
    private let chunker: Chunker
    private let entityExtractor: EntityExtractor?
    private let entityLinker: EntityLinker?
    private let entityQualityGate: EntityQualityGate?
    private let eventExtractor: EventExtractor?
    /// HISTORY Phase C.2 — produces 5W+H slots per event for the
    /// Phase D narrative composer. Nil = events still get inserted
    /// but `narrative_slots_json` stays as the column default '{}'.
    private let narrativeSlotExtractor: NarrativeSlotExtractor?
    private let relationshipExtractor: Tier1RelationshipExtractor?
    private let embedder: Embedder?

    private let files: FilesRepository
    private let objects: KnowledgeObjectRepository
    private let chunks: ChunksRepository
    private let entities: EntitiesRepository?
    private let events: EventsRepository?
    private let relationships: RelationshipsRepository?
    private let vectors: VectorStore?
    /// G2-SYNTHETIC-QUESTIONS — optional repository; when wired, the
    /// ingest pipeline generates and writes hypothetical questions for
    /// each chunk so the retriever can match question-shaped queries
    /// against question-shaped projections of the corpus.
    ///
    /// Generation runs OUT-OF-BAND via `synthQueue` so re-ingest of a
    /// 42K-chunk archive completes in minutes instead of hours. The
    /// queue is allowed to drain on its own schedule; the ingest path
    /// returns once KO + chunks + entities + events + bonds are
    /// persisted. Falls back to inline generation when the queue
    /// isn't wired (smoke tests, the eval harness).
    private let syntheticQuestions: SyntheticQuestionsRepository?
    private let syntheticQuestionGenerator: any SyntheticQuestionGenerator
    private let synthQueue: SyntheticQuestionQueue?
    /// A2 — when both are wired, a real ingest ALSO persists the canonical
    /// structural evidence layer (typed EvidenceBlocks + source version +
    /// document profile) additively, alongside the legacy KnowledgeObject path.
    /// nil = structural layer not populated (no regression to the KO path).
    private let evidenceStore: EvidenceStore?
    private let structuralRegistry: StructuralParserRegistry?
    /// A5.1 — when wired, structural blocks yield directly-observed Assertions
    /// (the claim–evidence ledger between EvidenceBlocks and typed rows). nil =
    /// assertion ledger not populated from ingest (no regression).
    private let assertions: AssertionsRepository?
    /// SEM — when wired, the domain packs run over each substantive block's text
    /// and persist evidence-linked GenericFacts (derived projections carrying the
    /// exact block ids they came from). nil = domain facts not derived from ingest.
    private let genericFacts: GenericFactRepository?
    private let domainFactExtractor = DomainFactExtractor()
    /// EV-005 — optional managed-evidence vault. When wired AND the managedEvidenceMode
    /// flag is on, each real ingest also copies the source bytes into the content-addressed
    /// vault so the exact version can be reopened later. nil, or flag off, = reference mode
    /// (no copy) — the default, unchanged behavior.
    private let evidenceVault: EvidenceVault?
    /// ING-006 — when wired, the background embedding drain yields to interactive queries
    /// via this gate (checked between batches). nil = no priority gating (drain runs freely).
    private let priorityGate: QueryPriorityGate?
    /// PA-PROD B3 — when wired, a successful real ingest fires an incremental Claim projection
    /// for the committed source (its affected subjects → Claims, plus derived-membership refresh
    /// for the workspaces that hold it). The SAME actor instance as the boot backfill, so the
    /// two never scan concurrently. Fire-and-forget + failure-isolated: never fails the ingest.
    /// nil = no incremental projection (the boot backfill still covers everything).
    private let claimProjection: ClaimProjectionBackfill?
    /// A2 §7.3/§7.7 — durable per-file ingest outcome (best-effort). nil = not
    /// recorded (behaviour otherwise unchanged).
    private let ingestAttempts: IngestAttemptsRepository?
    /// A2 §7.6 — parent→child source provenance (email→attachment, …). nil =
    /// relations not recorded.
    private let sourceRelations: SourceRelationsRepository?
    /// G2-QA-PAIRS — optional. When wired AND the loader produced ≥2
    /// KOs per file (e.g. an mbox), the QA-pair extractor runs after
    /// the per-KO loop and persists summarised pairs for retrieval.
    private let qaPairs: QAPairsRepository?
    private let qaPairExtractor: any QAPairExtractor
    /// G3.12 — typed-bond construction. When wired, every KO's
    /// per-context bonds (sent_by, discusses, affiliated_with, …)
    /// are upserted into `fact_bonds` after the entity/event/
    /// relationship write block. Nil = phase-3 bonds disabled
    /// (older boot paths, smoke tests).
    private let bondConstructor: BondConstructor?
    /// G2-3 — per-chunk contextual retrieval. When wired, produces a
    /// one-sentence prefix for each chunk that describes the chunk's
    /// role in the parent document. Prepended ONLY at embed time so
    /// the stored chunk.text + FTS rows are untouched. Nil = chunks
    /// embed without per-chunk context (heuristic doc-context still
    /// applies).
    private let contextPrefixGenerator: (any ContextPrefixGenerator)?
    /// Phase J.13 — live observability. Bumped at each pipeline
    /// stage so the Live tab's workflow strip shows real counts.
    /// Optional — when nil the bumps are no-ops and ingest behaves
    /// exactly as before.
    private let pipelineMetrics: PipelineMetrics?
    /// T18 — optional chain-of-custody ledger. nil = custody logging off.
    private let custody: CustodyRepository?

    private let invalidationContinuation: AsyncStream<SubjectInvalidation>.Continuation
    public nonisolated let invalidations: AsyncStream<SubjectInvalidation>

    public init(
        loaders: LoaderRegistry,
        cleaner: Cleaner = .init(),
        classifier: DocumentClassifier = .init(),
        chunker: Chunker = .init(),
        entityExtractor: EntityExtractor? = nil,
        entityLinker: EntityLinker? = nil,
        entityQualityGate: EntityQualityGate? = nil,
        eventExtractor: EventExtractor? = nil,
        narrativeSlotExtractor: NarrativeSlotExtractor? = nil,
        relationshipExtractor: Tier1RelationshipExtractor? = nil,
        embedder: Embedder? = nil,
        files: FilesRepository,
        objects: KnowledgeObjectRepository,
        chunks: ChunksRepository,
        entities: EntitiesRepository? = nil,
        events: EventsRepository? = nil,
        relationships: RelationshipsRepository? = nil,
        vectors: VectorStore? = nil,
        syntheticQuestions: SyntheticQuestionsRepository? = nil,
        syntheticQuestionGenerator: (any SyntheticQuestionGenerator)? = nil,
        synthQueue: SyntheticQuestionQueue? = nil,
        qaPairs: QAPairsRepository? = nil,
        qaPairExtractor: (any QAPairExtractor)? = nil,
        bondConstructor: BondConstructor? = nil,
        contextPrefixGenerator: (any ContextPrefixGenerator)? = nil,
        pipelineMetrics: PipelineMetrics? = nil,
        custody: CustodyRepository? = nil,
        evidenceStore: EvidenceStore? = nil,
        structuralRegistry: StructuralParserRegistry? = nil,
        assertions: AssertionsRepository? = nil,
        ingestAttempts: IngestAttemptsRepository? = nil,
        sourceRelations: SourceRelationsRepository? = nil,
        genericFacts: GenericFactRepository? = nil,
        evidenceVault: EvidenceVault? = nil,
        priorityGate: QueryPriorityGate? = nil,
        claimProjection: ClaimProjectionBackfill? = nil
    ) {
        self.evidenceStore = evidenceStore
        self.structuralRegistry = structuralRegistry
        self.assertions = assertions
        self.genericFacts = genericFacts
        self.evidenceVault = evidenceVault
        self.priorityGate = priorityGate
        self.claimProjection = claimProjection
        self.ingestAttempts = ingestAttempts
        self.sourceRelations = sourceRelations
        self.custody = custody
        self.loaders = loaders
        self.cleaner = cleaner
        self.classifier = classifier
        self.chunker = chunker
        self.entityExtractor = entityExtractor
        self.entityLinker = entityLinker
        self.entityQualityGate = entityQualityGate
        self.eventExtractor = eventExtractor
        self.narrativeSlotExtractor = narrativeSlotExtractor
        self.relationshipExtractor = relationshipExtractor
        self.embedder = embedder
        self.files = files
        self.objects = objects
        self.chunks = chunks
        self.entities = entities
        self.events = events
        self.relationships = relationships
        self.vectors = vectors
        self.syntheticQuestions = syntheticQuestions
        self.syntheticQuestionGenerator = syntheticQuestionGenerator
            ?? HeuristicSyntheticQuestionGenerator()
        self.synthQueue = synthQueue
        self.qaPairs = qaPairs
        self.qaPairExtractor = qaPairExtractor ?? EmailThreadQAPairExtractor()
        self.bondConstructor = bondConstructor
        self.contextPrefixGenerator = contextPrefixGenerator
        self.pipelineMetrics = pipelineMetrics

        var continuation: AsyncStream<SubjectInvalidation>.Continuation!
        let stream = AsyncStream<SubjectInvalidation> { c in continuation = c }
        self.invalidations = stream
        self.invalidationContinuation = continuation
    }

    // PERF.1 — background embedding backfill. Started lazily on first ingest
    // (avoids actor-init self-capture), cancelled on shutdown.
    private var embeddingDrainStarted = false
    private var embeddingDrainTask: Task<Void, Never>?
    /// Pause/Stop hooks for the live ingest controls. `drainPaused` idles the
    /// background embedding loop between batches (Resume clears it).
    private var drainPaused = false

    public func shutdown() {
        embeddingDrainTask?.cancel()
        invalidationContinuation.finish()
    }

    /// Pause (true) / resume (false) the background embedding drain. Wired to the
    /// live-panel Pause/Resume controls via AppState.
    public func setDrainPaused(_ paused: Bool) { drainPaused = paused }

    /// Stop the embedding drain entirely (the Stop control). Cancels the task and
    /// clears the started flag so a later ingest restarts it from the pending set.
    public func stopEmbeddingDrain() {
        embeddingDrainTask?.cancel()
        embeddingDrainStarted = false
        drainPaused = false
    }

    /// PERF.1 — start the resumable background embedding drain WITHOUT needing a
    /// new ingest. Called once at boot so chunks left unembedded by a PRIOR
    /// session (the app was quit before the drain finished) are completed on the
    /// next launch. Without this, the drain only ever started from `ingest()`,
    /// so a launch with no new files left the pending set stranded forever.
    public func startBackgroundEmbeddingDrain() {
        ensureEmbeddingDrain()
    }

    /// Kick the resumable background embedding drain once. Idempotent.
    private func ensureEmbeddingDrain() {
        guard !embeddingDrainStarted else { return }
        embeddingDrainStarted = true
        // P9.1 — run at background QoS so active interactive queries get CPU
        // priority over the embedding backfill (plus the per-batch yield below).
        embeddingDrainTask = Task(priority: .background) { [weak self] in await self?.embeddingDrainLoop() }
    }

    /// PERF.1 — continuously embed chunks that still lack a vector, in batches,
    /// at low priority. Resumable by construction (the pending set is queried
    /// each pass), so it survives restarts and never loses vectors. Yields
    /// between batches so active user queries take priority.
    private func embeddingDrainLoop() async {
        guard let embedder, let vectors else { return }   // no embedder → nothing to do
        // Chunks the embedder returned EMPTY for this session (e.g. binary /
        // mojibake / non-text content that NLEmbedding's word model has no
        // vocabulary for, or zero-length chunks). They can never be vectorized
        // by the current embedder, so re-embedding them every pass just
        // hot-loops forever. Skip them for the rest of the session; a fresh
        // launch (or a better embedder) retries from scratch — nothing is lost,
        // and these chunks stay fully searchable via FTS + structure.
        var unembeddable = Set<Chunk.ID>()
        let modelID = vectors.embeddingModelID   // v54 — embed the ACTIVE model's gap
        while !Task.isCancelled {
            // Live Pause — idle between batches until resumed (or cancelled).
            while drainPaused && !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            if Task.isCancelled { break }
            // ING-006 — yield to any in-flight interactive query before the next batch.
            await priorityGate?.awaitClearance()
            if Task.isCancelled { break }
            let fetched = (try? await chunks.findChunksMissingVector(limit: 256, modelID: modelID)) ?? []
            let batch = fetched.filter { !unembeddable.contains($0.id) }
            if batch.isEmpty {
                // Fully drained, or everything still missing is known-unembeddable.
                // Idle; a later ingest adds new rows this pass will pick up.
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                continue
            }
            let texts: [String] = batch.map { c in
                if let p = c.contextPrefix, !p.isEmpty { return "\(p)\n---\n\(c.text)" }
                return c.text
            }
            let embStart = Date()
            let vectorsList = await embedder.embedAll(texts, batchSize: 64)
            await pipelineMetrics?.record(.embedded, seconds: Date().timeIntervalSince(embStart))
            var embedded = 0
            for (i, c) in batch.enumerated() where i < vectorsList.count {
                if vectorsList[i].isEmpty {
                    unembeddable.insert(c.id)   // don't retry this one this session
                    continue                     // never persist a zero vector
                }
                try? await vectors.upsert(chunkID: c.id, embedding: vectorsList[i])
                embedded += 1
            }
            await pipelineMetrics?.bump(.embedded, by: embedded)
            try? await Task.sleep(nanoseconds: embedded == 0 ? 2_000_000_000 : 200_000_000)
        }
    }

    /// PERF.1 — synchronously embed all currently-pending chunks (no sleeps,
    /// stops when nothing progresses). Eval + smoke harnesses call this right
    /// after ingesting a fixture so vector search is ready before they measure;
    /// production relies on the background drain instead. Safe to call anytime.
    public func drainEmbeddingsNow() async {
        guard let embedder, let vectors else { return }
        let modelID = vectors.embeddingModelID   // v54 — embed the ACTIVE model's gap
        while !Task.isCancelled {
            let batch = (try? await chunks.findChunksMissingVector(limit: 256, modelID: modelID)) ?? []
            if batch.isEmpty { break }
            let texts: [String] = batch.map { c in
                if let p = c.contextPrefix, !p.isEmpty { return "\(p)\n---\n\(c.text)" }
                return c.text
            }
            let vecs = await embedder.embedAll(texts, batchSize: 64)
            var progressed = false
            for (i, c) in batch.enumerated() where i < vecs.count {
                if vecs[i].isEmpty { continue }
                try? await vectors.upsert(chunkID: c.id, embedding: vecs[i])
                progressed = true
            }
            if !progressed { break }   // embedder can't produce vectors → stop
        }
    }

    public func ingest(fileAt url: URL) async throws -> Result {
        // A2 / A5.3 — the structural layer is parsed ONCE inside ingestCore
        // (past the skip/alias/move early returns), so the same ParsedDocument
        // feeds event extraction AND is persisted with consistent block IDs.
        // A2 §7.3/§7.7 — record the outcome durably so failures/skips are
        // visible and re-tryable (best-effort; never affects the ingest).
        ensureEmbeddingDrain()   // PERF.1 — vectors deepen in the background
        // Audio/video are a DEFERRED format — skip transcription entirely. It's
        // slow and hang-prone (a .3gp email attachment froze the whole ingest at
        // 0% CPU), and these are typically personal media, not evidence. Recorded
        // as deferred (never a "failure"); this is the single chokepoint so it
        // also covers media attachments extracted from mbox/zip. Re-enable later
        // by transcribing on demand. Applies to direct files AND attachments.
        var detected = SourceType.detect(from: url)
        // Content-based fallback: an attachment with no/unknown extension (e.g. a
        // bare-hash filename) whose bytes are a real JPEG/PNG/PDF/… was falling to
        // TextLoader and getting refused as binary. Sniff magic bytes and re-route.
        if detected == .unknown,
           let head = try? Data(contentsOf: url, options: .mappedIfSafe),
           let sniffed = SourceType.sniffMagicBytes(head) {
            detected = sniffed
        }
        if detected.category == .audio || detected.category == .video {
            await ingestAttempts?.record(url: url, status: .unchanged, stage: "media-deferred",
                                         detail: "audio/video not transcribed (deferred format)")
            throw IngestSkipped.mediaDeferred
        }
        // v54 resume — durable in-progress marker. If the app is killed mid-
        // ingest, this row stays the latest for the URL and boot's
        // resumeIncompleteIngests() re-runs it. Superseded moments later by the
        // terminal outcome below.
        await ingestAttempts?.record(url: url, status: .started, stage: "ingest")
        do {
            let result = try await ingestCore(fileAt: url)
            await ingestAttempts?.record(
                url: url,
                status: result.chunkCount > 0 ? .queryable : .unchanged,
                contentHash: result.fileRecord.contentHash
            )
            // PA-PROD B3 — a real ingest (new chunks committed) refreshes this source's
            // Claims + derived workspace membership. Skips/aliases/moves (chunkCount == 0)
            // change no content, so they don't fire. Fire-and-forget on the shared projection
            // actor — never blocks or fails the ingest; the actor coalesces + isolates errors.
            if result.chunkCount > 0, let claimProjection {
                let fileID = result.fileRecord.id
                Task(priority: .utility) { await claimProjection.projectSource(fileID: fileID, at: Date()) }
            }
            await writeCostProfileFile()   // PERF.0 — durable stage-cost profile
            return result
        } catch {
            await ingestAttempts?.record(url: url, status: .failed, stage: "ingest",
                                         detail: String(describing: error).prefix(500).description)
            throw error
        }
    }

    /// Phase 2 recovery — outcome of re-ingesting legacy files that failed
    /// before the real OLE2 parsers landed.
    public struct LegacyRecovery: Sendable {
        public let attempted: Int    // failed .doc/.xls still readable in place
        public let recovered: Int    // re-ingested and now queryable
        public let missing: Int      // no longer readable (e.g. extracted email/zip attachments)
    }

    /// Re-ingest the .doc/.xls files whose last attempt failed (they were
    /// dropped when the legacy loaders were text-sweep stubs). Idempotent +
    /// per-document atomic. Files that no longer exist in place — chiefly email/
    /// zip attachments staged in a since-cleared temp dir — are counted `missing`
    /// and recovered instead by re-ingesting their parent container.
    @discardableResult
    public func reingestFailedLegacy() async -> LegacyRecovery {
        guard let ingestAttempts else { return LegacyRecovery(attempted: 0, recovered: 0, missing: 0) }
        let urls = await ingestAttempts.failedURLs(matchingExtensions: ["doc", "xls"])
        var attempted = 0, recovered = 0, missing = 0
        for url in urls {
            guard FileManager.default.isReadableFile(atPath: url.path) else { missing += 1; continue }
            attempted += 1
            do {
                let r = try await ingest(fileAt: url)
                if r.chunkCount > 0 { recovered += 1 }
            } catch { /* ingest() recorded .failed */ }
        }
        KalsmritikoshLog.ingestion.info("Legacy recovery: attempted \(attempted, privacy: .public), recovered \(recovered, privacy: .public), missing \(missing, privacy: .public)")
        return LegacyRecovery(attempted: attempted, recovered: recovered, missing: missing)
    }

    /// v54 resume/recovery — re-ingest any file whose last recorded attempt is
    /// still `.started`, i.e. an ingest interrupted by a crash or quit. Safe to
    /// call at boot: re-ingest is idempotent (unchanged files skip via
    /// content-hash) and the per-document atomic commit guarantees no partial KO
    /// was left behind to duplicate. Best-effort per file; a file that's no
    /// longer readable in place is recorded failed and skipped. Returns the
    /// number of files actually re-ingested.
    @discardableResult
    public func resumeIncompleteIngests() async -> Int {
        guard let ingestAttempts else { return 0 }
        let urls = await ingestAttempts.interruptedURLs()
        guard !urls.isEmpty else { return 0 }
        KalsmritikoshLog.ingestion.info("Resuming \(urls.count, privacy: .public) interrupted ingest(s)")
        var resumed = 0
        for url in urls {
            guard FileManager.default.isReadableFile(atPath: url.path) else {
                await ingestAttempts.record(url: url, status: .failed, stage: "resume",
                                            detail: "file no longer readable at resume")
                continue
            }
            do { _ = try await ingest(fileAt: url); resumed += 1 }
            catch { /* ingest() already recorded .failed */ }
        }
        return resumed
    }

    /// v54 MBOX lineage — the structural blocks that belong to ONE
    /// KnowledgeObject. For a single-KO file that's the whole document. For a
    /// multi-KO file (mbox → one KO per message) it's the blocks the parser
    /// stamped with the same `messageIndex` the loader put on the KO, so a
    /// message's chunks/events/entities link only to that message's blocks. If
    /// the two splitters disagree (no match), returns [] and the caller falls
    /// back to content chunking — degrade, never cross-link.
    private nonisolated static func blocks(
        for ko: KnowledgeObject, from all: [EvidenceBlock], singleKO: Bool
    ) -> [EvidenceBlock] {
        if singleKO { return all }
        guard case .int(let idx)? = ko.metadata["messageIndex"]?.value else { return [] }
        return all.filter {
            if case .int(let bi)? = $0.attributes["messageIndex"]?.value { return bi == idx }
            return false
        }
    }

    /// The result of parsing a file's structural document once, before both
    /// extraction (which links events to blocks) and persistence.
    private struct StructuralParse: Sendable {
        let doc: ParsedDocument
        let parserName: String
        let parserVersion: String
        let sizeBytes: Int64
        let startedAt: Date
    }

    /// Parse the format's structural document a single time. Returns nil when no
    /// parser handles the type or the bytes can't be read. No persistence — that
    /// is `persistStructuralDoc`, so the SAME doc can also feed extraction.
    /// PERF.0 — write the running per-stage cost profile to a file we can read
    /// after a run (unified-log .info isn't retrievable). Overwrites each time
    /// with the latest cumulative snapshot. Best-effort; never affects ingest.
    private func writeCostProfileFile() async {
        guard let pipelineMetrics else { return }
        let profile = await pipelineMetrics.costProfile()
        guard let dir = try? FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ) else { return }
        let reportDir = dir.appendingPathComponent("EvalBaselines", isDirectory: true)
        try? FileManager.default.createDirectory(at: reportDir, withIntermediateDirectories: true)
        let url = reportDir.appendingPathComponent("ingest-cost.txt")
        try? "cumulative stage cost (highest first):\n\(profile)\n".data(using: .utf8)?
            .write(to: url, options: .atomic)
    }

    private func parseStructuralOnce(url: URL, type: SourceType, fileID: UUID) async -> StructuralParse? {
        guard let structuralRegistry, evidenceStore != nil,
              let parser = structuralRegistry.parser(for: type),
              let data = try? Data(contentsOf: url) else { return nil }
        let started = Date()
        guard let doc = try? await parser.parse(
            data: data, filename: url.lastPathComponent, type: type,
            logicalSourceID: fileID, sourceVersionID: UUID()
        ) else { return nil }
        // PERF.0 — structural parse includes image OCR; time it so we can see
        // whether OCR/parse is the real cost centre (measure, don't guess).
        await pipelineMetrics?.record(.parse, seconds: Date().timeIntervalSince(started))
        return StructuralParse(
            doc: doc, parserName: parser.parserName, parserVersion: parser.parserVersion,
            sizeBytes: Int64(data.count), startedAt: started
        )
    }

    /// Persist an already-parsed structural document (typed EvidenceBlocks +
    /// source version + document profile) and derive directly-observed
    /// assertions from it. Best-effort: never fails the ingest.
    private func persistStructuralDoc(_ parse: StructuralParse, url: URL, store: EvidenceStore) async {
        do {
            try await store.persist(
                parse.doc, parser: parse.parserName, parserVersion: parse.parserVersion,
                sizeBytes: parse.sizeBytes, originalURL: url.absoluteString,
                makeCurrent: true, startedAt: parse.startedAt
            )
            KalsmritikoshLog.ingestion.info("Structural: \(parse.doc.blocks.count, privacy: .public) block(s) for \(url.lastPathComponent, privacy: .private)")
            // A5.1 — derive directly-observed assertions from the typed blocks.
            if let assertions {
                await deriveAssertions(from: parse.doc, sourceVersionID: parse.doc.sourceVersionID,
                                       extractorVersion: parse.parserVersion, into: assertions)
            }
            // SEM — derive domain-pack GenericFacts from the same blocks (additive;
            // never fails the ingest). Facts carry their block ids for drill-back.
            if let genericFacts {
                await deriveGenericFacts(from: parse.doc, url: url, into: genericFacts)
            }
        } catch {
            KalsmritikoshLog.ingestion.error("Structural persist failed for \(url.lastPathComponent, privacy: .private): \(String(describing: error), privacy: .public)")
        }
    }

    /// A5.1 — turn high-signal typed EvidenceBlocks into directly-observed
    /// Assertions, each carrying the exact block it came from, its verbatim
    /// quote, and the source version that asserted it. Email header fields and
    /// document titles are facts the block IS (not inferences), so they land as
    /// `.directlyObserved`. This populates the claim–evidence ledger from
    /// structure; richer subject/predicate/object derivation is A5.3. Best-
    /// effort: a failure here never fails the ingest.
    private func deriveAssertions(
        from doc: ParsedDocument, sourceVersionID: UUID,
        extractorVersion: String, into assertions: AssertionsRepository
    ) async {
        let statementExtractor = StatementExtractor()
        for block in doc.blocks {
            switch block.kind {
            case .emailHeader:
                guard let field = block.locator.emailHeaderField, !field.isEmpty else { continue }
                await insertObserved(block, predicate: "email_\(field)", sourceVersionID: sourceVersionID,
                                     extractorVersion: extractorVersion, into: assertions)
            case .documentTitle:
                await insertObserved(block, predicate: "document_title", sourceVersionID: sourceVersionID,
                                     extractorVersion: extractorVersion, into: assertions)
            case .paragraph, .emailBody, .slideBody, .quote:
                // A5 extraction — attributed statements become SOURCE-asserted
                // assertions (who claimed what), never directly-observed.
                for s in statementExtractor.statements(in: block.rawText) {
                    let assertion = Assertion(
                        subjectKind: .claim,
                        subjectID: sourceVersionID,
                        predicate: "statement_\(s.verb)",
                        object: .literal("\(s.speaker): \(s.claim)"),
                        confidence: block.extractionConfidence * 0.8,
                        evidenceBlockIDs: [block.id],
                        directQuote: "\(s.speaker) \(s.verb) \(s.claim)",
                        assertingSourceID: sourceVersionID,
                        provenance: .sourceAsserted,
                        extractorVersion: extractorVersion,
                        agent: "system.statements"
                    )
                    do { try await assertions.insert(assertion) }
                    catch { KalsmritikoshLog.ingestion.error("Assertion insert failed: \(String(describing: error), privacy: .public)") }
                }
            default:
                continue
            }
        }
    }

    /// Insert a directly-observed assertion for a header/title block (A5.1).
    private func insertObserved(
        _ block: EvidenceBlock, predicate: String, sourceVersionID: UUID,
        extractorVersion: String, into assertions: AssertionsRepository
    ) async {
        let value = block.normalizedText.isEmpty ? block.rawText : block.normalizedText
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let assertion = Assertion(
            subjectKind: .claim, subjectID: sourceVersionID, predicate: predicate,
            object: .literal(value), confidence: block.extractionConfidence,
            evidenceBlockIDs: [block.id], directQuote: block.rawText,
            assertingSourceID: sourceVersionID, provenance: .directlyObserved,
            extractorVersion: extractorVersion, agent: "system.structural"
        )
        do { try await assertions.insert(assertion) }
        catch { KalsmritikoshLog.ingestion.error("Assertion insert failed: \(String(describing: error), privacy: .public)") }
    }

    /// SEM — run the domain packs over each substantive block's text and persist
    /// the evidence-linked GenericFacts they produce. Facts are derived projections:
    /// each carries the exact block id it came from so it always drills back to
    /// evidence. The subject label is the document's title (or filename stem) so a
    /// document's facts group together. Best-effort — never fails the ingest.
    private func deriveGenericFacts(
        from doc: ParsedDocument, url: URL, into repo: GenericFactRepository
    ) async {
        let subjectLabel: String = {
            if let title = doc.blocks.first(where: { $0.kind == .documentTitle }) {
                let t = title.normalizedText.isEmpty ? title.rawText : title.normalizedText
                let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return String(trimmed.prefix(120)) }
            }
            return url.deletingPathExtension().lastPathComponent
        }()
        var derived: [GenericFact] = []
        for block in doc.blocks {
            guard !block.kind.isBoilerplate else { continue }
            let text = block.normalizedText.isEmpty ? block.rawText : block.normalizedText
            guard text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 8 else { continue }
            derived += domainFactExtractor.extract(fromText: text, subjectLabel: subjectLabel, blockID: block.id)
        }
        guard !derived.isEmpty else { return }
        do {
            try await repo.upsert(DomainFactExtractor.merge(derived))
            KalsmritikoshLog.ingestion.info("Domain facts: \(derived.count, privacy: .public) fact(s) for \(url.lastPathComponent, privacy: .private)")
        } catch {
            KalsmritikoshLog.ingestion.error("Domain-fact persist failed for \(url.lastPathComponent, privacy: .private): \(String(describing: error), privacy: .public)")
        }
    }

    private func ingestCore(fileAt url: URL) async throws -> Result {
        await pipelineMetrics?.bump(.discovered)
        var type = SourceType.detect(from: url)
        // Content-based fallback for extensionless / unknown files (e.g. an email
        // attachment named as a bare hash) — sniff magic bytes so a real image /
        // PDF / zip routes to the right parser instead of falling to TextLoader.
        if type == .unknown,
           let head = try? Data(contentsOf: url, options: .mappedIfSafe),
           let sniffed = SourceType.sniffMagicBytes(head) {
            type = sniffed
        }

        // ZIP archives expand recursively. We still emit a manifest KO for
        // the archive itself (via the ArchiveLoader.ingest path below) so
        // the file is tracked; then we walk the entries through the
        // standard pipeline. Cycle/depth defense: only one expansion
        // level — nested ZIPs become metadata-only KOs after the first.
        // A2 §7.6 — child file ids from a ZIP expansion, recorded as
        // archive→member relations once this archive's own file row exists.
        var expandedMemberIDs: [UUID] = []
        if type == .zip {
            if let (root, files) = try? ArchiveLoader.expandZIP(at: url) {
                KalsmritikoshLog.ingestion.info("Expanded ZIP \(url.lastPathComponent, privacy: .private) → \(files.count, privacy: .public) entries")
                defer { try? FileManager.default.removeItem(at: root) }
                for entry in files {
                    // Avoid recursive expansion of nested zips — they
                    // get the metadata-only manifest path below.
                    if SourceType.detect(from: entry) == .zip {
                        continue
                    }
                    do {
                        let member = try await self.ingest(fileAt: entry)
                        expandedMemberIDs.append(member.fileRecord.id)
                    } catch {
                        KalsmritikoshLog.ingestion.error("Nested-entry ingest failed for \(entry.lastPathComponent, privacy: .private): \(String(describing: error), privacy: .public)")
                    }
                }
            }
        }

        let loader = loaders.loader(for: type)
        let raw: KnowledgeObject
        do {
            raw = try await loader.ingest(fileAt: url, type: type)
        } catch {
            KalsmritikoshLog.ingestion.error("Loader failed for \(url.lastPathComponent, privacy: .private): \(String(describing: error), privacy: .public)")
            throw error
        }
        // Decode embedded encoded blobs (base64/hex/quoted-printable/percent)
        // into readable, searchable text — non-destructively appended. Runs after
        // the Cleaner so the idempotency hash stays tied to the original content.
        let cleaned = ContentDecoder().decode(cleaner.clean(raw))
        let docClass = classifier.classify(cleaned)

        // Idempotency: if this URL was already ingested and the cleaned
        // content hash matches, skip everything. Otherwise delete the
        // stale row (cascades through KO + chunks + entities + events +
        // relationships) and re-ingest below.
        let newHash: String? = {
            if let value = cleaned.metadata["contentHash"],
               case .string(let s) = value.value { return s }
            return nil
        }()
        if let existing = try? await files.findByURL(url) {
            if let newHash, existing.contentHash == newHash {
                KalsmritikoshLog.ingestion.info("Skipping unchanged file \(url.lastPathComponent, privacy: .private)")
                // T18 — re-ingest with a matching hash confirms custody.
                try? await custody?.record(CustodyEvent(
                    fileID: existing.id, kind: .hashVerified,
                    detail: url.lastPathComponent, hash: newHash))
                return Result(
                    fileRecord: existing,
                    object: cleaned,
                    chunkCount: 0,
                    entityCount: 0,
                    eventCount: 0,
                    documentClass: docClass,
                    invalidations: []
                )
            }
            // T18 — the bytes at a known URL changed: record a mismatch
            // (surfaced as a tamper signal) BEFORE wiping the stale row.
            try? await custody?.record(CustodyEvent(
                fileID: existing.id, kind: .hashMismatch,
                detail: "content at \(url.lastPathComponent) changed since last ingest",
                hash: newHash))
            // PI.1 — content changed: PRESERVE the prior version before the
            // active rows are refreshed (never silently delete extracted data).
            // Archive the old file record + its KO content into the history
            // tables, THEN refresh the active rows. If preservation fails we do
            // NOT delete — better a rare duplicate row than lost extraction.
            do {
                try await files.archiveVersionBeforeSupersede(existing, supersededBy: nil)
                try await files.deleteByID(existing.id)
            } catch {
                KalsmritikoshLog.ingestion.error("Version preserve/supersede failed for \(url.lastPathComponent, privacy: .private): \(String(describing: error), privacy: .public) — keeping prior rows, not deleting")
            }
        }

        // T8 — Move detection. If findByURL missed but a canonical with
        // this exact hash exists, treat it as a move: point that file row
        // at the new url instead of re-ingesting. No new KO is created.
        if let newHash,
           let canonical = try? await files.findCanonicalByContentHash(newHash),
           canonical.url != url {
            // The canonical bytes used to be at canonical.url — if that
            // url no longer points at the file (i.e. we got here because
            // findByURL on the new url returned nil and findByURL on the
            // old url would also return our row), treat it as a move:
            // update url on the canonical and reset availability.
            let canonicalStillAtOldURL = FileManager.default.fileExists(atPath: canonical.url.path)
            if !canonicalStillAtOldURL {
                try? await files.updateURL(id: canonical.id, to: url)
                KalsmritikoshLog.ingestion.info("Move detected for \(url.lastPathComponent, privacy: .private) (was at \(canonical.url.lastPathComponent, privacy: .private))")
                let updated = FileRecord(
                    id: canonical.id,
                    url: url,
                    sourceType: canonical.sourceType,
                    sizeBytes: canonical.sizeBytes,
                    modifiedAt: canonical.modifiedAt,
                    ingestedAt: canonical.ingestedAt,
                    contentHash: canonical.contentHash,
                    aliasOf: canonical.aliasOf,
                    availability: .available
                )
                return Result(
                    fileRecord: updated,
                    object: cleaned,
                    chunkCount: 0,
                    entityCount: 0,
                    eventCount: 0,
                    documentClass: docClass,
                    invalidations: []
                )
            }
        }

        // T7 — Hash-first dedup. A different URL with the same contentHash
        // becomes an alias row pointing at the canonical file; no new KO
        // is created and downstream extraction is skipped. "The same PDF
        // attached to two emails yields one parsed KO with two parent links."
        if let newHash,
           let canonical = try? await files.findCanonicalByContentHash(newHash) {
            let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
            let modified = (attrs[.modificationDate] as? Date) ?? .init()
            let size = (attrs[.size] as? Int64) ?? 0
            let aliasRecord = FileRecord(
                url: url,
                sourceType: type,
                sizeBytes: size,
                modifiedAt: modified,
                ingestedAt: .init(),
                contentHash: newHash,
                aliasOf: canonical.id
            )
            try? await files.upsert(aliasRecord)
            KalsmritikoshLog.ingestion.info("Aliased \(url.lastPathComponent, privacy: .private) → canonical \(canonical.id, privacy: .public)")
            return Result(
                fileRecord: aliasRecord,
                object: cleaned,
                chunkCount: 0,
                entityCount: 0,
                eventCount: 0,
                documentClass: docClass,
                invalidations: []
            )
        }

        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let modified = (attrs[.modificationDate] as? Date) ?? .init()
        let size = (attrs[.size] as? Int64) ?? 0
        let contentHashForFile: String? = {
            if let value = cleaned.metadata["contentHash"],
               case .string(let s) = value.value { return s }
            return nil
        }()
        let fileRecord = FileRecord(
            url: url,
            sourceType: type,
            sizeBytes: size,
            modifiedAt: modified,
            ingestedAt: .init(),
            contentHash: contentHashForFile
        )
        do {
            try await files.upsert(fileRecord)
        } catch {
            KalsmritikoshLog.storage.error("Failed to upsert file row for \(url.lastPathComponent, privacy: .private): \(String(describing: error), privacy: .public)")
            throw error
        }
        // EV-005 — managed evidence mode: copy the source bytes into the content-addressed
        // vault so this exact version stays reopenable even if the original is later moved/
        // replaced. Opt-in (default reference mode) + best-effort; never fails the ingest.
        if let evidenceVault, FeatureFlags.managedEvidenceModeValue() {
            do { _ = try await evidenceVault.store(contentsOf: url) }
            catch { KalsmritikoshLog.ingestion.error("Evidence vault copy failed for \(url.lastPathComponent, privacy: .private): \(String(describing: error), privacy: .public)") }
        }
        // A2 §7.6 — now the archive's file row exists, link its members.
        for memberID in expandedMemberIDs {
            await sourceRelations?.record(parent: fileRecord.id, child: memberID, relation: .archiveMember)
        }
        // T18 — first acquisition of this file: open its chain of custody.
        try? await custody?.record(CustodyEvent(
            fileID: fileRecord.id, kind: .acquired, detail: url.lastPathComponent))
        if let h = contentHashForFile {
            try? await custody?.record(CustodyEvent(
                fileID: fileRecord.id, kind: .hashComputed,
                detail: url.lastPathComponent, hash: h))
        }

        // T13.1 — one OR MORE KnowledgeObjects per file. mbox produces
        // one KO per message; other formats wrap their single ingest()
        // result in a one-element array via the protocol default.
        let perFileKOs: [KnowledgeObject]
        do {
            perFileKOs = try await loader.ingestMany(fileAt: url, type: type)
        } catch {
            KalsmritikoshLog.ingestion.error("ingestMany failed for \(url.lastPathComponent, privacy: .private): \(String(describing: error), privacy: .public)")
            throw error
        }
        guard !perFileKOs.isEmpty else {
            return Result(
                fileRecord: fileRecord,
                object: cleaned,
                chunkCount: 0,
                entityCount: 0,
                eventCount: 0,
                documentClass: docClass,
                invalidations: []
            )
        }

        // A5.3 / A2 parse-once — parse the structural document a SINGLE time
        // here (past all the skip/alias/move early returns, so only real
        // ingests reach it). The same ParsedDocument feeds event extraction
        // (so events link to specific source blocks) AND is persisted below.
        // v54 MBOX lineage — a multi-KO (mbox) file's blocks all live in one
        // ParsedDocument stamped per-message with messageIndex; each message-KO
        // now receives ITS OWN blocks (matched by messageIndex) so its chunks/
        // events/entities link to that message's blocks, never cross-linking.
        let structural = await parseStructuralOnce(url: url, type: type, fileID: fileRecord.id)
        let allBlocks = structural?.doc.blocks ?? []
        let singleKO = perFileKOs.count == 1

        var totalChunks = 0
        var totalEntities = 0
        var totalEvents = 0
        var allInvalidations: [SubjectInvalidation.Subject] = []
        var lastObject: KnowledgeObject = perFileKOs[0]
        // PA-PROD B6 — collect each KnowledgeObject's OWN structural blocks so canonical Claim
        // evidence can resolve a real object id. For a multi-KO source (mbox) each message KO gets
        // only its message's blocks (Self.blocks matches by messageIndex — never cross-linked).
        var blockOwnership: [(ko: KnowledgeObject.ID, blockIDs: [EvidenceBlock.ID])] = []

        for rawKO in perFileKOs {
            do {
                let koBlocks = Self.blocks(for: rawKO, from: allBlocks, singleKO: singleKO)
                let processed = try await processKnowledgeObject(
                    rawKO,
                    fileID: fileRecord.id,
                    documentClass: docClass,
                    blocks: koBlocks
                )
                totalChunks += processed.chunkCount
                totalEntities += processed.entityCount
                totalEvents += processed.eventCount
                allInvalidations.append(contentsOf: processed.invalidations)
                lastObject = processed.object
                if !koBlocks.isEmpty { blockOwnership.append((rawKO.id, koBlocks.map(\.id))) }

                // T13.7 — if this KO staged any attachments, ingest them
                // recursively as their own files. T7's hash-first dedup
                // catches the same attachment recurring across many
                // emails and folds it into a single canonical KO with
                // alias file rows.
                if let value = processed.object.metadata[EmailLoader.attachmentURLsMetaKey],
                   case .string(let json) = value.value {
                    // DETERMINISM FIX (reproducibility):
                    // Sort attachments by content hash before recursing
                    // so the T7 "first-wins" canonical selection is
                    // stable across runs. Without this, when two emails
                    // carry the same PDF, which one becomes the canonical
                    // depended on actor scheduling — varying KO + chunk
                    // counts by 5-25% across fresh re-ingests.
                    let attachmentURLs = EmailLoader.decodeAttachmentURLs(from: json)
                    let ordered: [URL] = attachmentURLs.sorted { lhs, rhs in
                        let lh = (try? Data(contentsOf: lhs, options: [.mappedIfSafe])).map { Self.sha256Hex($0) } ?? lhs.path
                        let rh = (try? Data(contentsOf: rhs, options: [.mappedIfSafe])).map { Self.sha256Hex($0) } ?? rhs.path
                        if lh == rh { return lhs.path < rhs.path }
                        return lh < rh
                    }
                    for attachmentURL in ordered {
                        do {
                            let attachmentResult = try await ingest(fileAt: attachmentURL)
                            // A2 §7.6 — record email → attachment provenance, even
                            // when dedup folds the attachment into a canonical copy.
                            await sourceRelations?.record(
                                parent: fileRecord.id, child: attachmentResult.fileRecord.id,
                                relation: .attachment
                            )
                            totalChunks += attachmentResult.chunkCount
                            totalEntities += attachmentResult.entityCount
                            totalEvents += attachmentResult.eventCount
                            allInvalidations.append(contentsOf: attachmentResult.invalidations)
                        } catch {
                            KalsmritikoshLog.ingestion.error("Attachment ingest failed for \(attachmentURL.lastPathComponent, privacy: .private): \(String(describing: error), privacy: .public)")
                        }
                    }
                }
            } catch {
                KalsmritikoshLog.ingestion.error("Per-KO processing failed for \(url.lastPathComponent, privacy: .private) (message \(rawKO.id.uuidString.prefix(8), privacy: .public)): \(String(describing: error), privacy: .public)")
                // Console echo so dev / smoke runs can see the cause
                // without subscribing to OSLog; quiet enough not to
                // spam a healthy ingest.
                print("PerKO drop \(rawKO.id.uuidString.prefix(8)): \(String(describing: error).prefix(200))")
            }
        }

        // G2-QA-PAIRS — once every KO from this file is processed, run
        // the thread-pair extractor over the batch. mbox files produce
        // one KO per message; the extractor finds adjacent question →
        // answer turns and persists summaries via QAPairsRepository.
        // Single-KO files (.eml singleton, .pdf, .md, ...) emit nothing.
        if let qaRepo = qaPairs, perFileKOs.count >= 2 {
            let pairs = await qaPairExtractor.extract(from: perFileKOs)
            if !pairs.isEmpty {
                let rows = pairs.map { p in
                    QAPairsRepository.Row(
                        questionText: p.questionText,
                        answerText: p.answerText,
                        questionObjectID: p.questionObjectID,
                        answerObjectID: p.answerObjectID,
                        confidence: p.confidence,
                        producedBy: qaPairExtractor.id
                    )
                }
                do {
                    try await qaRepo.insertBatch(rows)
                    KalsmritikoshLog.ingestion.info("QA-pairs: persisted \(rows.count, privacy: .public) pair(s) from \(url.lastPathComponent, privacy: .private)")
                } catch {
                    KalsmritikoshLog.ingestion.error("QA-pairs write failed for \(url.lastPathComponent, privacy: .private): \(String(describing: error), privacy: .public)")
                }
            }
        }

        KalsmritikoshLog.ingestion.info("Ingested \(url.lastPathComponent, privacy: .private): \(perFileKOs.count) KO(s), \(totalChunks) chunks, \(totalEntities) entities, \(totalEvents) events")

        // A5.3 / A2 — persist the already-parsed structural document (blocks +
        // source version + document profile) and derive directly-observed
        // assertions from it. Same doc that fed event extraction, so the block
        // IDs referenced by events resolve here. Gated on a real ingest.
        if let structural, let evidenceStore, totalChunks > 0 {
            await persistStructuralDoc(structural, url: url, store: evidenceStore)
            // PA-PROD B6 — now the structural EvidenceBlocks AND the KnowledgeObjects both exist,
            // record block→object ownership (before incremental Claim projection is scheduled in
            // `ingest`). Best-effort: a failure here never fails the ingest.
            for link in blockOwnership {
                do { try await evidenceStore.linkBlocks(link.blockIDs, toObject: link.ko, at: Date()) }
                catch { KalsmritikoshLog.ingestion.error("Block→object ownership link failed for \(link.ko.uuidString.prefix(8), privacy: .public): \(String(describing: error), privacy: .public)") }
            }
        }

        return Result(
            fileRecord: fileRecord,
            object: lastObject,
            chunkCount: totalChunks,
            entityCount: totalEntities,
            eventCount: totalEvents,
            documentClass: docClass,
            invalidations: allInvalidations
        )
    }

    private struct ProcessedKO: Sendable {
        let object: KnowledgeObject
        let chunkCount: Int
        let entityCount: Int
        let eventCount: Int
        let invalidations: [SubjectInvalidation.Subject]
    }

    /// Runs the per-KO half of the pipeline (chunk → entity merge → events
    /// → relationships → embeddings → invalidations). Called once per KO
    /// produced by `loader.ingestMany`, so an mbox file fans out through
    /// here once per message.
    private func processKnowledgeObject(
        _ rawObject: KnowledgeObject,
        fileID: UUID,
        documentClass docClass: DocumentClass,
        blocks: [EvidenceBlock] = []
    ) async throws -> ProcessedKO {
        var meta = rawObject.metadata
        meta["documentClass"] = AnyCodable(.string(docClass.rawValue))
        // G2-ENVIRONMENTS — let the format-specific environment lift
        // structural facts BEFORE generic entity / event extraction
        // runs. EmailDocumentEnvironment is the only one wired today;
        // future PDFDocumentEnvironment / SpreadsheetDocumentEnvironment
        // plug in the same way. Additive only — no fields are removed.
        for env in Self.documentEnvironments where env.recognizes(rawObject) {
            let extra = await env.extractStructuralMetadata(from: rawObject)
            for (k, v) in extra {
                meta[k] = v
            }
        }
        let object = KnowledgeObject(
            id: rawObject.id,
            sourceFile: rawObject.sourceFile,
            sourceType: rawObject.sourceType,
            content: rawObject.content,
            metadata: meta,
            entities: rawObject.entities,
            events: rawObject.events,
            relationships: rawObject.relationships,
            summaries: rawObject.summaries,
            confidence: rawObject.confidence,
            createdAt: rawObject.createdAt,
            updatedAt: .init()
        )

        do {
            try await objects.insert(object, fileID: fileID)
            await pipelineMetrics?.bump(.loaded)
        } catch {
            KalsmritikoshLog.storage.error("KO insert failed for \(rawObject.id.uuidString.prefix(8), privacy: .public): \(String(describing: error), privacy: .public)")
            throw error
        }

        // v54 evidence-first chunking (audit P0 #1/#2) — when the structural
        // parser produced typed EvidenceBlocks for this KO, derive chunks
        // (retrieval units) directly from them with exact block lineage; each
        // chunk records its evidence_block_id + block_kind. Fall back to the
        // flattened KO.content for formats with no structural parser (and, until
        // Phase1 step 4, for multi-KO mbox messages, which arrive with blocks=[]).
        var chunked = blocks.isEmpty
            ? chunker.chunk(objectID: object.id, content: object.content)
            : chunker.chunk(objectID: object.id, blocks: blocks)
        // Stage 1 ingest quality gate ("do not embed everything") — mark
        // non-substantive chunks (blank, tiny fragment, bare page number, lone
        // nav token) as NOT admitted to the vector index. They are still stored
        // and stay FTS-/citation-searchable; only embedding skips them. Verified
        // on the real corpus at <0.5% incidence on genuine content. Block-derived
        // chunks additionally exclude boilerplate kinds (page furniture, email
        // signature/disclaimer) from embedding — down-ranked, never dropped.
        chunked = chunked.map { c in
            let isBoilerplate = c.blockKind
                .flatMap(EvidenceBlockKind.init(rawValue:))?.isBoilerplate ?? false
            let admit = !isBoilerplate && ChunkAdmissionGate.evaluate(c.text).admitted
            return c.withAdmitEmbedding(admit)
        }
        // G2-3 — populate per-chunk context_prefix BEFORE persisting +
        // embedding so the embed pass and the persisted row carry the
        // same prefix. Skipped when chunks.count < 2 (single-chunk
        // small docs already are their own context) or when no
        // generator is wired.
        if let gen = contextPrefixGenerator, chunked.count >= 2 {
            // Sequential — Ollama serializes inference internally, so a
            // parallel TaskGroup only stacks per-chunk timeouts on top
            // of each other (the 4th queued chunk waits for 3 chunks
            // worth of inference, blowing past its own timeout budget).
            // Running one at a time gives each chunk the FULL provider
            // bandwidth and the FULL configured timeout.
            //
            // Brain-carries-meaning forward: after each successful
            // LLM call we fold the produced prefix into a running
            // context that REPLACES the doc opening for the next
            // chunk. The brain's prompt for chunk N therefore sees
            // "what was understood about chunks 0..N-1" instead of
            // re-reading the raw opening every time. This shortens
            // each prompt over time AND helps the model produce a
            // more cohesive prefix because it knows what's already
            // been said.
            let filename = object.sourceFile.lastPathComponent
            let total = chunked.count
            let runningContextCap = 1_500
            var runningContext = String(object.content.prefix(runningContextCap))
            var withPrefix: [Chunk] = []
            withPrefix.reserveCapacity(chunked.count)
            for c in chunked {
                let req = ContextPrefixRequest(
                    chunkText: c.text,
                    chunkOrdinal: c.ordinal,
                    totalChunks: total,
                    filename: filename,
                    documentOpening: runningContext
                )
                let result = await gen.prefix(for: req)
                withPrefix.append(c.withContextPrefix(result?.text, source: result?.source))
                // Fold the successful prefix into a running summary
                // capped at `runningContextCap`. Keeps the prompt
                // bounded while preserving the most recent N
                // section summaries — the local context that
                // matters most for chunk N+1.
                if let prefix = result?.text, !prefix.isEmpty {
                    let updated = "Sections so far: \(prefix)\n" + runningContext
                    runningContext = String(updated.prefix(runningContextCap))
                }
            }
            chunked = withPrefix
        }
        // v54 per-document atomicity — the core evidence commit (this KO + its
        // chunks) is all-or-nothing. If chunk persistence fails, delete the KO so
        // no partial document survives (the FK cascade drops any rows already
        // written, incl. chunk_embeddings). Scoped to this koID, so it's safe
        // under concurrent ingest fan-out — no shared transaction, no actor
        // reentrancy hazard. The per-file loop records the file's attempt failed;
        // re-ingest is idempotent via content-hash. (Derived enrichment below —
        // entities/events/relationships — stays best-effort and re-derivable, so
        // it is intentionally NOT part of the atomic core.)
        do {
            try await chunks.insertBatch(chunked)
        } catch {
            KalsmritikoshLog.storage.error("chunk insert failed for \(object.id.uuidString.prefix(8), privacy: .public) — rolling back KO: \(String(describing: error), privacy: .public)")
            try? await objects.deleteByID(object.id)
            throw error
        }
        await pipelineMetrics?.bump(.chunked, by: chunked.count)

        // G2-SYNTHETIC-QUESTIONS — generate hypothetical questions per
        // chunk and persist them so the retriever can match question-
        // shaped queries against question-shaped projections.
        //
        // Off the ingest path: when `synthQueue` is wired, enqueue the
        // work as a deferred job and return immediately. The queue
        // drains in a long-running background Task. This is the path
        // the app uses — without it a 42K-chunk re-ingest blocked at
        // 99% CPU for hours generating questions inline.
        //
        // Inline path retained as a fallback for the smoke + eval
        // harnesses that boot AppState without the queue.
        if let synthQueue {
            await synthQueue.enqueue(.init(
                objectID: object.id,
                chunks: chunked,
                documentContext: Self.documentContext(for: object)
            ))
        } else if let synthRepo = syntheticQuestions {
            // Inline path — Smoke / eval harnesses that boot AppState
            // without the queue land here. Large-content KOs (a
            // 67-message thread, a 50-page PDF) routinely produce
            // 100+ chunks each; running the generator over every
            // chunk inline stalls the per-KO pipeline for minutes
            // per KO, which then silently swallows ~80% of a 236-KO
            // batch via the per-KO catch at line 351.
            //
            // Cap inline generation at `maxInlineSynthChunksPerKO`
            // chunks. The remaining chunks just don't get synth-Q
            // rows for this run — they'll be filled by the queue
            // when the production app re-ingests with synthQueue
            // wired. Eval still gets representative coverage.
            let maxInlineSynthChunksPerKO = 24
            let chunksToProcess = chunked.prefix(maxInlineSynthChunksPerKO)
            if chunked.count > maxInlineSynthChunksPerKO {
                KalsmritikoshLog.ingestion.info(
                    "inline synth-Q capped: \(chunked.count, privacy: .public) chunks → \(maxInlineSynthChunksPerKO, privacy: .public) for KO \(object.id.uuidString.prefix(8), privacy: .public)"
                )
            }
            let docContext = Self.documentContext(for: object)
            var rows: [SyntheticQuestionsRepository.Row] = []
            for chunk in chunksToProcess {
                let questions = await syntheticQuestionGenerator.generate(
                    for: chunk,
                    documentContext: docContext,
                    topK: 4
                )
                for q in questions {
                    rows.append(SyntheticQuestionsRepository.Row(
                        chunkID: chunk.id,
                        objectID: object.id,
                        text: q.text,
                        confidence: q.confidence,
                        producedBy: syntheticQuestionGenerator.id
                    ))
                }
            }
            if !rows.isEmpty {
                do {
                    try await synthRepo.insertBatch(rows)
                } catch {
                    KalsmritikoshLog.ingestion.error("Synthetic-questions write failed for \(object.id.uuidString.prefix(8), privacy: .public): \(String(describing: error), privacy: .public)")
                }
            }
        }

        var extractedEntities: [Entity] = []
        var extractedEvents: [Event] = []
        var canonicalMapping: [Entity.ID: Entity.ID] = [:]

        if let entityExtractor, let entities {
            // T13.2 — seed with loader-provided structured entities
            // (From/To/Cc/Date) BEFORE running NER over the content. NER
            // augments; loader entities are already high-confidence.
            var raw: [Entity] = []
            // HISTORY Phase A — annotate every entity with its
            // quality_tier at extraction time. Structured-header
            // entities short-circuit to T1; NER entities run through
            // the shape rules and land in T2 (real proper noun) or
            // T3 (noise — hostname, weekday token, base64-ish, etc.).
            if let value = object.metadata[EmailLoader.structuredEntitiesMetaKey],
               case .string(let json) = value.value {
                let structured = EmailLoader.decodeStructuredEntities(from: json)
                raw.append(contentsOf: structured.map { entity in
                    annotate(entity, source: .structuredHeader)
                })
            }
            let nerExtracted = (try? await entityExtractor.extractEntities(from: object, chunks: chunked, blocks: blocks)) ?? []
            raw.append(contentsOf: nerExtracted.map { entity in
                annotate(entity, source: .ner)
            })
            // Deterministic input order so EntityLinker's
            // first-wins canonical resolution is reproducible.
            // Without this, the merge winner for a (kind,
            // normalized) collision depends on actor scheduling
            // around when each chunk's NER pass returned its
            // entities — varying canonical entity counts by
            // ~10-15% across fresh re-ingests despite identical
            // mention counts.
            raw.sort { lhs, rhs in
                if lhs.kind != rhs.kind { return lhs.kind.rawValue < rhs.kind.rawValue }
                let lhn = lhs.normalizedValue ?? lhs.value
                let rhn = rhs.normalizedValue ?? rhs.value
                if lhn != rhn { return lhn < rhn }
                if lhs.value != rhs.value { return lhs.value < rhs.value }
                return lhs.id.uuidString < rhs.id.uuidString
            }
            if let entityLinker { raw = entityLinker.link(raw) }
            // T13.4 — drop garbage (weekdays / mail keywords / hostnames /
            // app-internal identifiers) before storage.
            if let entityQualityGate {
                raw = entityQualityGate.filter(raw)
            }
            canonicalMapping = (try? await entities.insertBatch(raw)) ?? [:]
            extractedEntities = raw
            await pipelineMetrics?.bump(.entities, by: raw.count)
            await writeDomainAliases(forEntities: raw, in: entities, sourceObjectID: object.id)
        }

        if let eventExtractor, let events {
            let rawEvents = (try? await eventExtractor.extractEvents(
                from: object,
                chunks: chunked,
                entities: extractedEntities,
                blocks: blocks
            )) ?? []
            // Legal/patent MILESTONE events — the "story spine" the generic
            // extractor misses (filed / hearing / objection / granted). Dated,
            // high-trust, from official-document boilerplate. Deterministic.
            let milestoneEvents = PatentLegalEventExtractor.extract(
                text: object.content,
                sourceObjectID: object.id,
                entityIDs: extractedEntities.map(\.id)
            )
            let remapped = (rawEvents + milestoneEvents).map { event in
                remapEventToCanonical(event, mapping: canonicalMapping)
            }
            try? await events.insertBatch(remapped)
            await pipelineMetrics?.bump(.events, by: remapped.count)
            extractedEvents = remapped
        }

        // Computed once and reused by both the entity-entity relationship
        // extractor (legacy untyped edges) and the typed BondConstructor
        // (G3.10/12). For email KOs both rely on the same canonical
        // sender/recipient ids; computing the participants twice would
        // do redundant alias lookups.
        let resolvedParticipants = await emailParticipants(
            for: object,
            extractedEntities: extractedEntities,
            mapping: canonicalMapping
        )

        // HISTORY Phase C.2 — populate 5W+H slots for each event so
        // the Phase D narrative composer can render chapters from
        // structured slot prose instead of bullet titles. Runs after
        // participant resolution (above) so email WHO slots get the
        // canonical sender + recipient ids attached. Failure here
        // leaves narrative_slots_json at the column default '{}' —
        // the column is not load-bearing for retrieval.
        if let narrativeSlotExtractor, let events, !extractedEvents.isEmpty {
            let participantsBridge: NarrativeSlotEmailParticipants? = resolvedParticipants.map {
                NarrativeSlotEmailParticipants(
                    senderID: $0.senderID,
                    recipientIDs: $0.recipientIDs
                )
            }
            for event in extractedEvents {
                let slots = await narrativeSlotExtractor.extract(
                    event: event,
                    object: object,
                    entities: extractedEntities,
                    canonicalMapping: canonicalMapping,
                    emailParticipants: participantsBridge
                )
                if !slots.isEmpty {
                    try? await events.setNarrativeSlots(slots, forEventID: event.id)
                }
            }
        }

        if let relationshipExtractor, let relationships {
            let canonicalIDs = extractedEntities.compactMap { canonicalMapping[$0.id] }
            let edges = relationshipExtractor.extract(
                objectID: object.id,
                canonicalEntityIDs: canonicalIDs,
                events: extractedEvents,
                emailParticipants: resolvedParticipants
            )
            let upserts: [RelationshipsRepository.EdgeUpsert] = edges.map { edge in
                let (from, to) = orderEdge(kind: edge.kind, from: edge.from, to: edge.to)
                return RelationshipsRepository.EdgeUpsert(
                    kind: edge.kind,
                    from: from,
                    to: to,
                    viaEventID: edge.viaEventID
                )
            }
            try? await relationships.upsertEdges(upserts, sourceObjectID: object.id)
        }

        // G3.12 — typed bonds. Runs after the entity-entity edge write
        // so the canonical mapping is settled and the events table has
        // any newly inserted ids. Failure is non-fatal: bonds are an
        // ADDITIONAL graph signal; the legacy `relationships` table is
        // what existing retrieval still reads.
        if let bondConstructor {
            let context = BondConstructor.Context(
                objectID: object.id,
                entities: extractedEntities,
                events: extractedEvents,
                canonicalMapping: canonicalMapping,
                emailParticipants: resolvedParticipants
            )
            _ = await bondConstructor.construct(context)
        }

        // PERF.1 — embeddings are NO LONGER generated on the blocking ingest
        // path. The chunks were persisted above, so FTS + structured retrieval
        // are queryable immediately; the vectors deepen in the background
        // (enrichment-ladder Tier 2). `embeddingDrainLoop()` finds chunks that
        // still lack a vector and embeds them in batches. This can't lose
        // vectors — a chunk with no vector is always re-found on the next drain,
        // even after a restart — and it lets a large ingest become searchable
        // without waiting on thousands of embeddings.

        let invalidationSubjects = subjects(forEntities: extractedEntities)
        if !invalidationSubjects.isEmpty {
            invalidationContinuation.yield(SubjectInvalidation(
                subjects: invalidationSubjects,
                triggeringObjectID: object.id
            ))
        }

        return ProcessedKO(
            object: object,
            chunkCount: chunked.count,
            entityCount: extractedEntities.count,
            eventCount: extractedEvents.count,
            invalidations: invalidationSubjects
        )
    }

    /// Replace an event's entityIDs with canonical ids. Unmapped ids
    /// pass through unchanged (defensive — should never happen because
    /// the event's entity references come from the same batch).
    private func remapEventToCanonical(_ event: Event, mapping: [Entity.ID: Entity.ID]) -> Event {
        Event(
            id: event.id,
            kind: event.kind,
            date: event.date,
            endDate: event.endDate,
            title: event.title,
            summary: event.summary,
            entityIDs: event.entityIDs.map { mapping[$0] ?? $0 },
            sourceObjectID: event.sourceObjectID,
            sourceRange: event.sourceRange,
            confidence: event.confidence,
            // BUG FIX: previously this remap dropped dateConfidence / qualityTier
            // / datePrecision / status, so every event fell back to the Event
            // defaults (0.5 / .t2 / .inferred). That collapsed the whole
            // evidentiary-status spread — an email-header event that the
            // extractor correctly marked 0.95 / T1 / observed was silently
            // reset, and EventStatus.derive then classified ALL events as
            // "derived" (Findings tabs went flat). Carry the trust signals
            // through the canonicalization.
            dateConfidence: event.dateConfidence,
            attributes: event.attributes,
            qualityTier: event.qualityTier,
            datePrecision: event.datePrecision,
            status: event.status
        )
    }

    /// Canonicalize edge direction for undirected edge kinds so
    /// (a,b) and (b,a) hit the same UNIQUE row.
    private func orderEdge(
        kind: Relationship.Kind,
        from: Entity.ID,
        to: Entity.ID
    ) -> (Entity.ID, Entity.ID) {
        let undirected: Set<Relationship.Kind> = [.coOccurs, .eventLinked]
        guard undirected.contains(kind) else { return (from, to) }
        return from.uuidString <= to.uuidString ? (from, to) : (to, from)
    }

    /// For email KOs, derive sender + recipient canonical entity ids from
    /// the EmailLoader-populated "from" / "to" / "cc" headers and resolve
    /// the sender's domain to an org canonical via the alias table.
    private func emailParticipants(
        for object: KnowledgeObject,
        extractedEntities: [Entity],
        mapping: [Entity.ID: Entity.ID]
    ) async -> Tier1RelationshipExtractor.EmailParticipants? {
        guard let entities,
              [SourceType.eml, .appleMail, .mbox].contains(object.sourceType) else {
            return nil
        }
        let fromHeader = headerValue(object.metadata, "from")
        let toHeader = headerValue(object.metadata, "to")
        let ccHeader = headerValue(object.metadata, "cc")
        guard let senderAddr = firstEmailAddress(in: fromHeader) else { return nil }
        let recipientAddrs = Set(
            emailAddresses(in: toHeader) + emailAddresses(in: ccHeader)
        ).filter { $0 != senderAddr }
        guard let senderID = canonicalEmailAddressID(
            address: senderAddr,
            extractedEntities: extractedEntities,
            mapping: mapping
        ) else { return nil }
        let recipientIDs: [Entity.ID] = recipientAddrs.compactMap { addr in
            canonicalEmailAddressID(
                address: addr,
                extractedEntities: extractedEntities,
                mapping: mapping
            )
        }
        var orgID: Entity.ID? = nil
        if let at = senderAddr.firstIndex(of: "@") {
            let domain = String(senderAddr[senderAddr.index(after: at)...]).lowercased()
            orgID = try? await entities.find(byValue: domain, limit: 1).first?.id
        }
        return Tier1RelationshipExtractor.EmailParticipants(
            senderID: senderID,
            recipientIDs: recipientIDs,
            senderDomainOrgID: orgID
        )
    }

    private func headerValue(_ meta: [String: AnyCodable], _ key: String) -> String {
        guard let v = meta[key], case .string(let s) = v.value else { return "" }
        return s
    }

    private func firstEmailAddress(in header: String) -> String? {
        emailAddresses(in: header).first
    }

    private func emailAddresses(in header: String) -> [String] {
        guard !header.isEmpty else { return [] }
        // Match e.g. "Name <addr@example.com>" or "addr@example.com" separated by , or ;.
        let pattern = "[A-Za-z0-9._%+\\-]+@[A-Za-z0-9.\\-]+\\.[A-Za-z]{2,}"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = header as NSString
        let matches = re.matches(in: header, range: NSRange(location: 0, length: ns.length))
        return matches.map { ns.substring(with: $0.range).lowercased() }
    }

    /// Resolves an email-address string to a canonical entity id by
    /// finding the matching emailAddress entity in this batch and
    /// looking up its canonical id in `mapping`.
    private func canonicalEmailAddressID(
        address: String,
        extractedEntities: [Entity],
        mapping: [Entity.ID: Entity.ID]
    ) -> Entity.ID? {
        let target = address.lowercased()
        let match = extractedEntities.first(where: { e in
            e.kind == .emailAddress &&
                (e.normalizedValue?.lowercased() == target ||
                 e.value.lowercased() == target)
        })
        guard let raw = match?.id else { return nil }
        return mapping[raw]
    }

    /// For each email-address entity, derive an org label from its
    /// domain and write a canonical org + alias row for the domain stem.
    /// Idempotent — re-ingest of an unchanged file no-ops on the alias
    /// table thanks to UNIQUE(entity_id, alias_normalized).
    private func writeDomainAliases(
        forEntities entities: [Entity],
        in repo: EntitiesRepository,
        sourceObjectID: KnowledgeObject.ID
    ) async {
        for entity in entities where entity.kind == .emailAddress {
            let addr = entity.normalizedValue ?? entity.value
            guard let at = addr.firstIndex(of: "@") else { continue }
            let domain = String(addr[addr.index(after: at)...])
            guard let head = domain.split(separator: ".").first.map(String.init),
                  !head.isEmpty else { continue }
            let label = head
                .split(separator: "-")
                .map { token -> String in
                    let s = String(token)
                    if s.count <= 4 && s.allSatisfy(\.isLetter) {
                        return s.uppercased()
                    }
                    return s.prefix(1).uppercased() + s.dropFirst().lowercased()
                }
                .joined(separator: " ")
            guard label.count > 2 else { continue }
            do {
                let orgID = try await repo.upsertCanonicalOrganization(
                    label: label,
                    sourceObjectID: sourceObjectID
                )
                try await repo.addAlias(
                    entityID: orgID,
                    aliasNormalized: domain.lowercased(),
                    source: "email-domain"
                )
            } catch {
                KalsmritikoshLog.ingestion.error("Domain alias write failed for \(domain, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// G2-ENVIRONMENTS — registered DocumentEnvironment adapters,
    /// applied in order. The first one(s) that `recognizes(_:)` the
    /// raw object run; outputs merge into KO metadata. Pure additive
    /// at this point — no chunker overrides or extraction-hint usage
    /// is wired here yet (those land per-format in follow-on commits).
    private static let documentEnvironments: [any DocumentEnvironment] = [
        EmailDocumentEnvironment(),
        PDFDocumentEnvironment(),
        SpreadsheetDocumentEnvironment(),
        VideoDocumentEnvironment()
    ]

    /// G2-3 — Build a short doc-level context blurb prepended to each
    /// chunk at embedding time. Pure: derives from KO metadata + first
    /// content line + filename. Capped to keep the prefix from
    /// drowning the chunk text itself in the embedding pool.
    ///
    /// Inputs (in order of value):
    /// 1. Email Subject (loader writes it as metadata["subject"]).
    /// 2. Source filename (often carries the answer, e.g. invoice-432.eml).
    /// 3. First non-empty content line (typical title / H1 / opener).
    ///
    /// Result is "" when no context can be derived — caller falls back
    /// to the chunk text alone, preserving pre-G2-3 behavior.
    /// Lower-case hex SHA-256 over `data`. Used to compute a stable
    /// canonical-sort key for attachment-recursion ordering so the
    /// T7 "first-wins" dedup decision is reproducible across runs.
    static func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func documentContext(for object: KnowledgeObject) -> String {
        var parts: [String] = []

        if let value = object.metadata["subject"],
           case .string(let subject) = value.value {
            let trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                parts.append("Subject: \(String(trimmed.prefix(160)))")
            }
        }

        let filename = object.sourceFile.lastPathComponent
        if !filename.isEmpty {
            parts.append("File: \(filename)")
        }

        let firstLine = object.content
            .split(separator: "\n", maxSplits: 5, omittingEmptySubsequences: true)
            .first
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        if !firstLine.isEmpty, firstLine.count <= 240, !parts.contains(where: { $0.hasSuffix(firstLine) }) {
            parts.append("Opening: \(String(firstLine.prefix(200)))")
        }

        return parts.joined(separator: " | ")
    }

    private func subjects(forEntities entities: [Entity]) -> [SubjectInvalidation.Subject] {
        var out: [SubjectInvalidation.Subject] = []
        var seen = Set<String>()

        for entity in entities {
            let identifier = entity.normalizedValue ?? entity.value
            guard !identifier.isEmpty else { continue }
            let kind: MemoryObject.SubjectKind?
            switch entity.kind {
            case .person: kind = .person
            case .organization, .vendor, .client: kind = .organization
            case .project: kind = .project
            case .deliverable: kind = .deliverable
            default: kind = nil
            }
            if let kind {
                let key = "\(kind.rawValue)|\(identifier)"
                if seen.insert(key).inserted {
                    out.append(.init(kind: kind, identifier: identifier))
                }
            }
        }

        // Fallback: when NLTagger misses person/org names (very common
        // in short emails) mine email-address entities for their domain
        // and treat each domain stem as an organization invalidation so
        // the MemoryDistiller still fires for this subject.
        for entity in entities where entity.kind == .emailAddress {
            let addr = entity.normalizedValue ?? entity.value
            guard let at = addr.firstIndex(of: "@") else { continue }
            let domain = String(addr[addr.index(after: at)...])
            guard let head = domain.split(separator: ".").first.map(String.init),
                  !head.isEmpty else { continue }
            let label = head
                .split(separator: "-")
                .map { token -> String in
                    let s = String(token)
                    if s.count <= 4 && s.allSatisfy(\.isLetter) {
                        return s.uppercased()
                    }
                    return s.prefix(1).uppercased() + s.dropFirst().lowercased()
                }
                .joined(separator: " ")
            guard label.count > 2 else { continue }
            let key = "organization|\(label)"
            if seen.insert(key).inserted {
                out.append(.init(kind: .organization, identifier: label))
            }
        }

        return out
    }

    /// HISTORY Phase A — rebuild an Entity with its quality_tier
    /// computed from value + kind + source. Pure value transform;
    /// the original Entity is immutable, so we produce a fresh
    /// instance with the same fields plus the tier.
    private nonisolated func annotate(
        _ entity: Entity,
        source: QualityTierClassifier.Source
    ) -> Entity {
        let tier = QualityTierClassifier.tier(
            value: entity.value,
            kind: entity.kind,
            source: source
        )
        return Entity(
            id: entity.id,
            kind: entity.kind,
            value: entity.value,
            normalizedValue: entity.normalizedValue,
            sourceObjectID: entity.sourceObjectID,
            sourceRange: entity.sourceRange,
            confidence: entity.confidence,
            attributes: entity.attributes,
            qualityTier: tier
        )
    }
}
