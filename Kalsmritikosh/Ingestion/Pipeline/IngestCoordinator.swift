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
    private let relationshipExtractor: Tier1RelationshipExtractor?
    private let embedder: Embedder?

    private let files: FilesRepository
    private let objects: KnowledgeObjectRepository
    private let chunks: ChunksRepository
    private let entities: EntitiesRepository?
    private let events: EventsRepository?
    private let relationships: RelationshipsRepository?
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
        relationshipExtractor: Tier1RelationshipExtractor? = nil,
        embedder: Embedder? = nil,
        files: FilesRepository,
        objects: KnowledgeObjectRepository,
        chunks: ChunksRepository,
        entities: EntitiesRepository? = nil,
        events: EventsRepository? = nil,
        relationships: RelationshipsRepository? = nil,
        vectors: VectorStore? = nil
    ) {
        self.loaders = loaders
        self.cleaner = cleaner
        self.classifier = classifier
        self.chunker = chunker
        self.entityExtractor = entityExtractor
        self.entityLinker = entityLinker
        self.eventExtractor = eventExtractor
        self.relationshipExtractor = relationshipExtractor
        self.embedder = embedder
        self.files = files
        self.objects = objects
        self.chunks = chunks
        self.entities = entities
        self.events = events
        self.relationships = relationships
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
        var canonicalMapping: [Entity.ID: Entity.ID] = [:]

        if let entityExtractor, let entities {
            var raw = (try? await entityExtractor.extractEntities(from: object, chunks: chunked)) ?? []
            if let entityLinker { raw = entityLinker.link(raw) }
            canonicalMapping = (try? await entities.insertBatch(raw)) ?? [:]
            extractedEntities = raw
            // Port the render-time email-domain mining into ingest so an
            // alias row exists for every domain we see, mapped onto its
            // org canonical. Render still labels too — aliases also feed
            // future lookups.
            await writeDomainAliases(forEntities: raw, in: entities, sourceObjectID: object.id)
        }

        if let eventExtractor, let events {
            let rawEvents = (try? await eventExtractor.extractEvents(
                from: object,
                chunks: chunked,
                entities: extractedEntities
            )) ?? []
            // Remap event.entityIDs to canonical ids before persisting so
            // event_entities rows reference the real canonical rows.
            let remapped = rawEvents.map { event in
                remapEventToCanonical(event, mapping: canonicalMapping)
            }
            try? await events.insertBatch(remapped)
            extractedEvents = remapped
        }

        // T4 — Tier 1 graph extraction. Co-occurrence + event-linked
        // edges across canonical entities, plus typed email edges when
        // sender/recipients can be resolved.
        if let relationshipExtractor, let relationships {
            let canonicalIDs = extractedEntities.compactMap { canonicalMapping[$0.id] }
            let participants = await emailParticipants(
                for: object,
                extractedEntities: extractedEntities,
                mapping: canonicalMapping
            )
            let edges = relationshipExtractor.extract(
                objectID: object.id,
                canonicalEntityIDs: canonicalIDs,
                events: extractedEvents,
                emailParticipants: participants
            )
            for edge in edges {
                let (from, to) = orderEdge(kind: edge.kind, from: edge.from, to: edge.to)
                try? await relationships.upsertEdge(
                    kind: edge.kind,
                    from: from,
                    to: to,
                    sourceObjectID: object.id,
                    viaEventID: edge.viaEventID
                )
            }
        }

        if let embedder, let vectors {
            // T6 — batch embedding. embedAll chunks the list into
            // batchSize-sized calls so we never round-trip per chunk.
            let texts = chunked.map(\.text)
            let vectorsList = await embedder.embedAll(texts, batchSize: 64)
            for (i, chunk) in chunked.enumerated() where i < vectorsList.count {
                try? await vectors.upsert(chunkID: chunk.id, embedding: vectorsList[i])
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
