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
        custody: CustodyRepository? = nil
    ) {
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

    public func shutdown() {
        invalidationContinuation.finish()
    }

    public func ingest(fileAt url: URL) async throws -> Result {
        await pipelineMetrics?.bump(.discovered)
        let type = SourceType.detect(from: url)

        // ZIP archives expand recursively. We still emit a manifest KO for
        // the archive itself (via the ArchiveLoader.ingest path below) so
        // the file is tracked; then we walk the entries through the
        // standard pipeline. Cycle/depth defense: only one expansion
        // level — nested ZIPs become metadata-only KOs after the first.
        if type == .zip {
            if let (root, files) = try? ArchiveLoader.expandZIP(at: url) {
                AtlasLog.ingestion.info("Expanded ZIP \(url.lastPathComponent, privacy: .public) → \(files.count, privacy: .public) entries")
                defer { try? FileManager.default.removeItem(at: root) }
                for entry in files {
                    // Avoid recursive expansion of nested zips — they
                    // get the metadata-only manifest path below.
                    if SourceType.detect(from: entry) == .zip {
                        continue
                    }
                    do { _ = try await self.ingest(fileAt: entry) }
                    catch {
                        AtlasLog.ingestion.error("Nested-entry ingest failed for \(entry.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
                    }
                }
            }
        }

        let loader = loaders.loader(for: type)
        let raw: KnowledgeObject
        do {
            raw = try await loader.ingest(fileAt: url, type: type)
        } catch {
            AtlasLog.ingestion.error("Loader failed for \(url.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
            throw error
        }
        let cleaned = cleaner.clean(raw)
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
                AtlasLog.ingestion.info("Skipping unchanged file \(url.lastPathComponent, privacy: .public)")
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
            // Content changed (or hash absent): wipe the prior record so we
            // don't accumulate duplicate rows in the dependent tables.
            try? await files.deleteByID(existing.id)
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
                AtlasLog.ingestion.info("Move detected for \(url.lastPathComponent, privacy: .public) (was at \(canonical.url.lastPathComponent, privacy: .public))")
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
            AtlasLog.ingestion.info("Aliased \(url.lastPathComponent, privacy: .public) → canonical \(canonical.id, privacy: .public)")
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
            AtlasLog.storage.error("Failed to upsert file row for \(url.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
            throw error
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
            AtlasLog.ingestion.error("ingestMany failed for \(url.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
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

        var totalChunks = 0
        var totalEntities = 0
        var totalEvents = 0
        var allInvalidations: [SubjectInvalidation.Subject] = []
        var lastObject: KnowledgeObject = perFileKOs[0]

        for rawKO in perFileKOs {
            do {
                let processed = try await processKnowledgeObject(
                    rawKO,
                    fileID: fileRecord.id,
                    documentClass: docClass
                )
                totalChunks += processed.chunkCount
                totalEntities += processed.entityCount
                totalEvents += processed.eventCount
                allInvalidations.append(contentsOf: processed.invalidations)
                lastObject = processed.object

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
                            totalChunks += attachmentResult.chunkCount
                            totalEntities += attachmentResult.entityCount
                            totalEvents += attachmentResult.eventCount
                            allInvalidations.append(contentsOf: attachmentResult.invalidations)
                        } catch {
                            AtlasLog.ingestion.error("Attachment ingest failed for \(attachmentURL.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
                        }
                    }
                }
            } catch {
                AtlasLog.ingestion.error("Per-KO processing failed for \(url.lastPathComponent, privacy: .public) (message \(rawKO.id.uuidString.prefix(8), privacy: .public)): \(String(describing: error), privacy: .public)")
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
                    AtlasLog.ingestion.info("QA-pairs: persisted \(rows.count, privacy: .public) pair(s) from \(url.lastPathComponent, privacy: .public)")
                } catch {
                    AtlasLog.ingestion.error("QA-pairs write failed for \(url.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
                }
            }
        }

        AtlasLog.ingestion.info("Ingested \(url.lastPathComponent, privacy: .public): \(perFileKOs.count) KO(s), \(totalChunks) chunks, \(totalEntities) entities, \(totalEvents) events")

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
        documentClass docClass: DocumentClass
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
            AtlasLog.storage.error("KO insert failed for \(rawObject.id.uuidString.prefix(8), privacy: .public): \(String(describing: error), privacy: .public)")
            throw error
        }

        var chunked = chunker.chunk(objectID: object.id, content: object.content)
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
        try? await chunks.insertBatch(chunked)
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
                AtlasLog.ingestion.info(
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
                    AtlasLog.ingestion.error("Synthetic-questions write failed for \(object.id.uuidString.prefix(8), privacy: .public): \(String(describing: error), privacy: .public)")
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
            let nerExtracted = (try? await entityExtractor.extractEntities(from: object, chunks: chunked)) ?? []
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
                entities: extractedEntities
            )) ?? []
            let remapped = rawEvents.map { event in
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

        if let embedder, let vectors {
            // G2-3 contextual retrieval — Anthropic-style chunk-context
            // prefix. We prepend a short doc-level blurb (filename +
            // first line + email subject when present) to each chunk
            // BEFORE embedding. The stored `chunk.text` is unchanged —
            // FTS rows, citation snippets, range maps, and the chunker
            // contract all keep their existing shape. Only the vector
            // changes, and that re-anchors small chunks against the
            // larger semantically-similar neighbors they previously
            // lost to (e.g. contract.md vs invoice-432.eml on
            // "delivery date" similarity, per UPDATE_09 Item 1).
            let docContext = Self.documentContext(for: object)
            // G2-3 — per-chunk context wins over the per-document
            // heuristic when present. Per-chunk prefixes contain
            // section-specific context the heuristic can't ("This
            // section lists Project Delta's amendment terms"), which
            // is what widens the vector-similarity gap between an
            // on-target chunk and its off-topic neighbors.
            let texts: [String] = chunked.map { chunk in
                if let prefix = chunk.contextPrefix, !prefix.isEmpty {
                    return "\(prefix)\n---\n\(chunk.text)"
                }
                if !docContext.isEmpty {
                    return "\(docContext)\n---\n\(chunk.text)"
                }
                return chunk.text
            }
            let vectorsList = await embedder.embedAll(texts, batchSize: 64)
            var embeddedCount = 0
            var skippedCount = 0
            for (i, chunk) in chunked.enumerated() where i < vectorsList.count {
                // Empty = "no embedding produced" (T15). NEVER persist a
                // zero/empty vector — skip and leave the chunk without a
                // vector so it re-embeds later, rather than poisoning search.
                if vectorsList[i].isEmpty {
                    skippedCount += 1
                    continue
                }
                try? await vectors.upsert(chunkID: chunk.id, embedding: vectorsList[i])
                embeddedCount += 1
            }
            await pipelineMetrics?.bump(.embedded, by: embeddedCount)
            if skippedCount > 0 {
                AtlasLog.ingestion.error("Ingest \(object.id, privacy: .public): \(skippedCount, privacy: .public) chunk(s) left WITHOUT embeddings (embedder unavailable) — vector search skips them until re-embedded. No zero vectors written.")
            }
        }

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
            attributes: event.attributes
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
                AtlasLog.ingestion.error("Domain alias write failed for \(domain, privacy: .public): \(String(describing: error), privacy: .public)")
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
