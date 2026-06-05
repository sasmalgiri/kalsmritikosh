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
    private let eventExtractor: EventExtractor?
    private let embedder: Embedder?

    private let files: FilesRepository
    private let objects: KnowledgeObjectRepository
    private let chunks: ChunksRepository
    private let entities: EntitiesRepository?
    private let events: EventsRepository?
    private let vectors: VectorStore?

    private let invalidationContinuation: AsyncStream<SubjectInvalidation>.Continuation
    public nonisolated let invalidations: AsyncStream<SubjectInvalidation>

    public init(
        loaders: LoaderRegistry = .standard(),
        cleaner: Cleaner = .init(),
        classifier: DocumentClassifier = .init(),
        chunker: Chunker = .init(),
        entityExtractor: EntityExtractor? = nil,
        entityLinker: EntityLinker? = nil,
        eventExtractor: EventExtractor? = nil,
        embedder: Embedder? = nil,
        files: FilesRepository,
        objects: KnowledgeObjectRepository,
        chunks: ChunksRepository,
        entities: EntitiesRepository? = nil,
        events: EventsRepository? = nil,
        vectors: VectorStore? = nil
    ) {
        self.loaders = loaders
        self.cleaner = cleaner
        self.classifier = classifier
        self.chunker = chunker
        self.entityExtractor = entityExtractor
        self.entityLinker = entityLinker
        self.eventExtractor = eventExtractor
        self.embedder = embedder
        self.files = files
        self.objects = objects
        self.chunks = chunks
        self.entities = entities
        self.events = events
        self.vectors = vectors

        var continuation: AsyncStream<SubjectInvalidation>.Continuation!
        let stream = AsyncStream<SubjectInvalidation> { c in continuation = c }
        self.invalidations = stream
        self.invalidationContinuation = continuation
    }

    public func shutdown() {
        invalidationContinuation.finish()
    }

    public func ingest(fileAt url: URL) async throws -> Result {
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
            // Content changed (or hash absent): wipe the prior record so we
            // don't accumulate duplicate rows in the dependent tables.
            try? await files.deleteByID(existing.id)
        }

        var meta = cleaned.metadata
        meta["documentClass"] = AnyCodable(.string(docClass.rawValue))
        let object = KnowledgeObject(
            id: cleaned.id,
            sourceFile: cleaned.sourceFile,
            sourceType: cleaned.sourceType,
            content: cleaned.content,
            metadata: meta,
            entities: cleaned.entities,
            events: cleaned.events,
            relationships: cleaned.relationships,
            summaries: cleaned.summaries,
            confidence: cleaned.confidence,
            createdAt: cleaned.createdAt,
            updatedAt: .init()
        )

        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let modified = (attrs[.modificationDate] as? Date) ?? .init()
        let size = (attrs[.size] as? Int64) ?? 0
        let contentHash: String? = {
            if let value = meta["contentHash"],
               case .string(let s) = value.value { return s }
            return nil
        }()
        let fileRecord = FileRecord(
            url: url,
            sourceType: type,
            sizeBytes: size,
            modifiedAt: modified,
            ingestedAt: .init(),
            contentHash: contentHash
        )

        do {
            try await files.upsert(fileRecord)
            try await objects.insert(object, fileID: fileRecord.id)
        } catch {
            AtlasLog.storage.error("Failed to persist KO for \(url.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
            throw error
        }

        let chunked = chunker.chunk(objectID: object.id, content: object.content)
        try? await chunks.insertBatch(chunked)

        var extractedEntities: [Entity] = []
        var extractedEvents: [Event] = []

        if let entityExtractor, let entities {
            var raw = (try? await entityExtractor.extractEntities(from: object, chunks: chunked)) ?? []
            if let entityLinker { raw = entityLinker.link(raw) }
            try? await entities.insertBatch(raw)
            extractedEntities = raw
        }

        if let eventExtractor, let events {
            let raw = (try? await eventExtractor.extractEvents(
                from: object,
                chunks: chunked,
                entities: extractedEntities
            )) ?? []
            try? await events.insertBatch(raw)
            extractedEvents = raw
        }

        if let embedder, let vectors {
            for chunk in chunked.prefix(20) {
                let v = await embedder.embed(chunk.text)
                try? await vectors.upsert(chunkID: chunk.id, embedding: v)
            }
        }

        let invalidationSubjects = subjects(forEntities: extractedEntities)
        if !invalidationSubjects.isEmpty {
            invalidationContinuation.yield(SubjectInvalidation(
                subjects: invalidationSubjects,
                triggeringObjectID: object.id
            ))
        }

        AtlasLog.ingestion.info("Ingested \(url.lastPathComponent, privacy: .public): \(chunked.count) chunks, \(extractedEntities.count) entities, \(extractedEvents.count) events")

        return Result(
            fileRecord: fileRecord,
            object: object,
            chunkCount: chunked.count,
            entityCount: extractedEntities.count,
            eventCount: extractedEvents.count,
            documentClass: docClass,
            invalidations: invalidationSubjects
        )
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
}
