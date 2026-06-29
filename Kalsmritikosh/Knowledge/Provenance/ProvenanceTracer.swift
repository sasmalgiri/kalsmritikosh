//
//  ProvenanceTracer.swift
//  Kalsmritikosh
//
//  Phase J.5 — Vol 17 §A9 (Core Historical Intelligence Algorithms).
//  A single unified `trace(claimID:)` entry point that walks the
//  ledger backwards from a citation to the full evidence chain:
//
//      file → KnowledgeObject → chunks
//                            ↓
//                       entity mentions → canonical entities
//                            ↓
//                       events → causal links (verified + hypothetical)
//
//  The pieces exist as per-table reads on individual repos; this
//  tracer stitches them so the UI's future "trace this claim" panel
//  and the audit appendix in the InvestigationReportBuilder can both
//  call one method instead of chaining six queries each.
//
//  Quality-or-nothing: every section in the result either has the
//  real rows or is empty. No placeholders, no inferred entries.
//

import Foundation

public struct Provenance: Sendable {
    public let object: KnowledgeObject?
    public let sourceURL: URL?
    public let chunks: [Chunk]
    public let entities: [Entity]
    public let events: [Event]
    public let causalLinks: [CausalLink]
    public let hypotheticalLinks: [HypotheticalCausalLink]

    public nonisolated init(
        object: KnowledgeObject? = nil,
        sourceURL: URL? = nil,
        chunks: [Chunk] = [],
        entities: [Entity] = [],
        events: [Event] = [],
        causalLinks: [CausalLink] = [],
        hypotheticalLinks: [HypotheticalCausalLink] = []
    ) {
        self.object = object
        self.sourceURL = sourceURL
        self.chunks = chunks
        self.entities = entities
        self.events = events
        self.causalLinks = causalLinks
        self.hypotheticalLinks = hypotheticalLinks
    }
}

public actor ProvenanceTracer {
    private let objects: KnowledgeObjectRepository
    private let chunks: ChunksRepository
    private let entities: EntitiesRepository
    private let events: EventsRepository
    private let links: EventLinksRepository?

    public init(
        objects: KnowledgeObjectRepository,
        chunks: ChunksRepository,
        entities: EntitiesRepository,
        events: EventsRepository,
        links: EventLinksRepository? = nil
    ) {
        self.objects = objects
        self.chunks = chunks
        self.entities = entities
        self.events = events
        self.links = links
    }

    /// Walk every layer backwards from a citation's source KO id.
    /// Each subtree is loaded in parallel — the call's wall-clock
    /// cost is dominated by the slowest single SELECT, not the sum.
    public func trace(claimID: KnowledgeObject.ID) async -> Provenance {
        async let objectTask: KnowledgeObject? = {
            try? await self.objects.load(id: claimID)
        }()
        async let urlTask: URL? = {
            try? await self.objects.fetchSourceURL(id: claimID)
        }()
        async let chunkTask: [Chunk] = {
            (try? await self.chunks.findByObjectID(claimID)) ?? []
        }()
        async let entityTask: [Entity] = {
            (try? await self.entities.findByMentionSource(claimID)) ?? []
        }()
        async let eventTask: [Event] = {
            (try? await self.events.findBySourceObject(claimID)) ?? []
        }()

        let (object, url, chunks, entities, events) = await (
            objectTask, urlTask, chunkTask, entityTask, eventTask
        )

        // Pull causal links (verified + hypothetical) that touch any
        // of the events extracted from this KO. Empty list when no
        // events were found.
        var verifiedLinks: [CausalLink] = []
        var hypotheticalLinks: [HypotheticalCausalLink] = []
        if let links, !events.isEmpty {
            let eventIDs = events.map(\.id)
            verifiedLinks = (try? await links.links(in: eventIDs)) ?? []
            hypotheticalLinks = (try? await links.hypotheticals(in: eventIDs)) ?? []
        }

        return Provenance(
            object: object,
            sourceURL: url,
            chunks: chunks,
            entities: entities,
            events: events,
            causalLinks: verifiedLinks,
            hypotheticalLinks: hypotheticalLinks
        )
    }
}
