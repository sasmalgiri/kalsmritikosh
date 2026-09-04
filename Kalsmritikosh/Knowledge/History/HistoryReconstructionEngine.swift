//
//  HistoryReconstructionEngine.swift
//  Kalsmritikosh
//
//  HIST-050 (Universal History program, Phase 7). The ONE orchestration service the
//  whole program consolidates behind. It streams: resolve subject → collect material
//  (ID-scoped) → project temporal claims + history items → build deterministic
//  outline → reconcile (contradictions + gaps) → verified result. Fully
//  deterministic and LLM-free; the optional prose layer plugs in at Phase 8. A
//  subject that cannot resolve to a canonical entity FAILS explicitly — it never
//  silently falls back to global archive activity (trust rule 3).
//

import Foundation

public actor HistoryReconstructionEngine: HistoryReconstructing {
    public nonisolated static let version = "history-engine-1"

    private let resolver: HistorySubjectResolver
    private let collector: HistoryMaterialCollector
    private let projector: TemporalEventProjector
    private let outlineBuilder: HistoryOutlineBuilder
    private let reconciler: HistoryReconciliationEngine
    /// Resolves GenericFact block ids to their owning KnowledgeObject so GenericFact-only
    /// history items carry exact citations (S0.5). Optional so the engine still builds
    /// when no evidence store is available; production always injects one.
    private let blockResolver: EvidenceBlockResolving?
    /// P4-U2 — resolves the material's source objects to their episode keys +
    /// document classes so chapters assemble under the H-laws. Optional: nil
    /// (or an empty context) reproduces the original year-bucket outline.
    private let storyContext: (@Sendable ([KnowledgeObject.ID]) async -> StorySourceContext)?
    private let clock: @Sendable () -> Date

    public init(
        entities: EntitiesRepository,
        events: EventsRepository,
        assertions: AssertionsRepository,
        genericFacts: GenericFactRepository,
        relationships: RelationshipsRepository,
        blockResolver: EvidenceBlockResolving? = nil,
        storyContext: (@Sendable ([KnowledgeObject.ID]) async -> StorySourceContext)? = nil,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.resolver = HistorySubjectResolver(entities: entities)
        self.collector = HistoryMaterialCollector(
            events: events, assertions: assertions, genericFacts: genericFacts, relationships: relationships)
        self.projector = TemporalEventProjector(now: clock())
        self.outlineBuilder = HistoryOutlineBuilder()
        self.reconciler = HistoryReconciliationEngine()
        self.blockResolver = blockResolver
        self.storyContext = storyContext
        self.clock = clock
    }

    public nonisolated func reconstruct(subject: HistorySubject, request: HistoryRequest) -> AsyncStream<HistoryUpdate> {
        AsyncStream { continuation in
            Task { await self.run(subject: subject, request: request, yield: { continuation.yield($0) }); continuation.finish() }
        }
    }

    private func run(subject: HistorySubject, request: HistoryRequest, yield: @Sendable (HistoryUpdate) -> Void) async {
        yield(.resolvingSubject)
        guard let entityID = subject.entityID else {
            yield(.failed(reason: "Only entity-scoped subjects are supported today; topic/folder/corpus history is deferred. No global fallback."))
            return
        }
        guard let resolved = (try? await resolver.resolve(entityID: entityID)) ?? nil else {
            yield(.failed(reason: "Subject \(entityID.uuidString) could not be resolved to a canonical entity."))
            return
        }

        let material: HistoryMaterial
        do { material = try await collector.collect(for: resolved) }
        catch { yield(.failed(reason: "Material collection failed: \(error)")); return }
        yield(.collecting(itemsSoFar: material.totalItems))

        let claims = projector.projectClaims(from: material)
        // Resolve every block the claims cite back to its owning KnowledgeObject so
        // GenericFact-only items get exact objectID+blockID citations (S0.5). Best-effort:
        // a resolution failure leaves object-backed items intact and never fails the run.
        var blockResolution: [EvidenceBlock.ID: ResolvedEvidenceReference] = [:]
        if let blockResolver {
            let blockIDs = Array(Set(claims.flatMap { $0.sourceBlockIDs }))
            if !blockIDs.isEmpty, let resolved = try? await blockResolver.resolveEvidenceBlocks(blockIDs) {
                blockResolution = Dictionary(resolved.map { ($0.blockID, $0) }, uniquingKeysWith: { a, _ in a })
            }
        }
        let items0 = projector.projectItems(from: material, claims: claims, blockResolution: blockResolution)
        let items = request.includeUndated ? items0 : items0.filter { !$0.isUndated }
        yield(.temporalising(claims: claims.count))

        yield(.reconciling)
        // P4-U2 — the H-law source context (episodes + document classes);
        // empty when no provider is wired, which keeps the original outline.
        let context = await storyContext?(material.evidenceObjectIDs) ?? .empty
        let base = outlineBuilder.build(material: material, items: items,
                                        corpusSnapshotID: request.corpusSnapshotID,
                                        sourceContext: context)
        let outline = reconciler.reconcile(outline: base, material: material, independenceKeys: request.independenceKeys)
        yield(.outlineReady(outline))

        // Deterministic chapter stream (prose left to Phase 8; never a RAG substitute).
        for chapter in outline.chapters { yield(.chapterReady(chapter)) }

        yield(.verified(HistoryReconstructionResult(
            subject: resolved, outline: outline, claims: claims,
            engineVersion: Self.version, generatedAt: clock())))
    }
}
