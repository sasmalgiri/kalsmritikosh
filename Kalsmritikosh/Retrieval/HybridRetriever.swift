//
//  HybridRetriever.swift
//  Kalsmritikosh
//
//  Priority-ordered retrieval per the locked architecture:
//      Memory → Timeline → Entity → Metadata → Summary → Graph → Vector
//
//  Each layer is asked in order; if it returns enough confident hits the
//  retriever short-circuits and returns. Vector search is the final
//  fallback — never the entry point. Memory always leads.
//

import Foundation
import OSLog

public actor HybridRetriever: Retriever {
    /// How many vector hits the vector layer asks for. Held as a property
    /// so a future Settings toggle can change it without touching the
    /// retrieval call site. UPDATE_06 Item 2.
    public nonisolated static let defaultVectorLayerLimit = 20

    /// Words IntentDetector sometimes emits as "entity hints" but which
    /// are actually question words / list-shape words. Filtering them
    /// out at `entityLayer` time prevents `entities.find(byValue:)`
    /// from matching arbitrary substrings and polluting the candidate
    /// set with low-signal entities — observed on
    /// "What organizations am I in touch with via patents?" where
    /// `["What"]` swamped the result list with random WhatsApp /
    /// LinkedIn entities and the topic-to-entity fallback couldn't fire.
    private nonisolated static let questionWords: Set<String> = [
        "what", "who", "when", "where", "why", "how", "which",
        "list", "show", "tell", "find", "give",
        "the", "a", "an", "of", "is", "are", "was", "were",
        "do", "did", "does", "have", "had", "has",
        "i", "me", "my", "you", "your", "us", "we", "our", "their"
    ]

    private let memory: MemoryRepository
    private let events: EventsRepository
    private let entities: EntitiesRepository
    private let chunks: ChunksRepository
    private let summaries: SummariesRepository
    private let graph: GraphStore
    private let vectors: VectorStore
    private let embedder: Embedder
    private let vectorLayerLimit: Int
    /// G2-SYNTHETIC-QUESTIONS — optional. When present, the metadata
    /// (FTS) layer also queries the synthetic-questions FTS view and
    /// unions chunk hits derived from synthetic-question matches.
    private let syntheticQuestions: SyntheticQuestionsRepository?
    /// G2-QA-PAIRS — optional. When present, the metadata (FTS) layer
    /// also searches the qa_pairs FTS view; matches hydrate the
    /// answer-side KO's top chunk and append it to the retrieved set.
    private let qaPairs: QAPairsRepository?
    /// In-memory caches for the three SQL-heavy retrieval layers.
    /// When wired AND warm, the layer prefers the cache lookup over
    /// SQL. Each cache exposes isWarm() so the warm-up window stays
    /// safe (SQL fallback).
    private let memoryCache: MemoryHashCache?
    private let entityTrie: EntityTrie?
    private let entityTimeline: EntityTimeline?
    /// G3.17 — optional typed-graph walker. When wired, the graph
    /// layer enriches entity seeds with chunks pulled from KOs
    /// reached via fact_bonds (up to 2 hops). Schema-aware multi-hop
    /// without changing the layer ordering or public API.
    private let bondWalker: BondWalker?
    /// G3.20 — optional explainer that translates raw bond steps
    /// into typed [WalkStep] for the "Why this answer?" UI. Wired
    /// alongside the walker; both nil = bond-walk features disabled.
    private let walkExplainer: WalkExplainer?
    /// G3.17 — how many bond walks per retrieve() call. Capped so a
    /// dense graph doesn't blow up the query budget. 0 = walks
    /// disabled even if a walker is wired.
    private let bondWalkSeedLimit: Int
    /// G3.17 — how many chunks the bond walks contribute.
    private let bondWalkChunkLimit: Int
    /// T18 (§21) — optional. When wired, chunks whose parent KnowledgeObject
    /// is flagged `privileged` are withheld from the final retrieval set —
    /// a privacy post-filter (like PrivacyGate for providers) that leaves the
    /// per-layer algorithms and their ordering untouched. nil, or zero
    /// privileged objects, makes this a strict no-op (eval baseline unchanged).
    private let objects: KnowledgeObjectRepository?
    /// SEM — optional. When wired, after the result is assembled the retriever
    /// looks up the domain-pack GenericFacts derived from the evidence blocks it
    /// surfaced (option A: facts ride the evidence) and attaches the ASSERTABLE
    /// ones to the result. nil, or blocks with no facts, is a strict no-op.
    private let genericFacts: GenericFactRepository?
    /// C2.1 — resolves reliable independence keys for corroboration. nil ⇒ conservative
    /// (unkeyed evidence never corroborates). Called at most once per retrieval.
    private let independenceProvider: SourceIndependenceKeyProvider?

    public init(
        memory: MemoryRepository,
        events: EventsRepository,
        entities: EntitiesRepository,
        chunks: ChunksRepository,
        summaries: SummariesRepository,
        graph: GraphStore,
        vectors: VectorStore,
        embedder: Embedder,
        vectorLayerLimit: Int = HybridRetriever.defaultVectorLayerLimit,
        syntheticQuestions: SyntheticQuestionsRepository? = nil,
        qaPairs: QAPairsRepository? = nil,
        bondWalker: BondWalker? = nil,
        walkExplainer: WalkExplainer? = nil,
        memoryCache: MemoryHashCache? = nil,
        entityTrie: EntityTrie? = nil,
        entityTimeline: EntityTimeline? = nil,
        bondWalkSeedLimit: Int = 3,
        bondWalkChunkLimit: Int = 10,
        objects: KnowledgeObjectRepository? = nil,
        genericFacts: GenericFactRepository? = nil,
        independenceProvider: SourceIndependenceKeyProvider? = nil
    ) {
        self.objects = objects
        self.genericFacts = genericFacts
        self.independenceProvider = independenceProvider
        self.memory = memory
        self.events = events
        self.entities = entities
        self.chunks = chunks
        self.summaries = summaries
        self.graph = graph
        self.vectors = vectors
        self.embedder = embedder
        self.vectorLayerLimit = vectorLayerLimit
        self.syntheticQuestions = syntheticQuestions
        self.qaPairs = qaPairs
        self.bondWalker = bondWalker
        self.walkExplainer = walkExplainer
        self.memoryCache = memoryCache
        self.entityTrie = entityTrie
        self.entityTimeline = entityTimeline
        self.bondWalkSeedLimit = bondWalkSeedLimit
        self.bondWalkChunkLimit = bondWalkChunkLimit
    }

    public func retrieve(
        for intent: UserIntent,
        layers: [RetrievalLayer]
    ) async throws -> RetrievalResult {
        let ordering = layers.isEmpty ? RetrievalLayer.priorityOrder : layers

        var usedLayers: [RetrievalLayer] = []
        var collectedEvents: [Event] = []
        var collectedEntities: [Entity] = []
        var collectedChunks: [RetrievedChunk] = []
        var collectedSummaries: [Summary] = []
        var collectedRelationships: [Relationship] = []
        var collectedMemoryNarratives: [String] = []
        // G3.20 — raw bond steps collected from each seed walk; the
        // WalkExplainer translates them to typed WalkSteps once the
        // graph layer finishes.
        var collectedBondSteps: [BondWalker.WalkResult.Step] = []

        for layer in ordering {
            usedLayers.append(layer)
            switch layer {
            case .memory:
                let memoryHits = try await memoryLayer(intent)
                collectedMemoryNarratives.append(contentsOf: memoryHits.map(\.narrative))
                // Hydrate the events behind the memory hits so downstream
                // experts have grounded evidence. Don't short-circuit
                // entirely — the brain wants both the narrative and the
                // raw events the experts can reason over.
                if !memoryHits.isEmpty {
                    collectedSummaries.append(contentsOf: memoryHits.map(memoryAsSummary))
                    let allEventIDs = memoryHits.flatMap(\.keyEventIDs)
                    if !allEventIDs.isEmpty {
                        let hydrated = try await events.findByIDs(allEventIDs)
                        collectedEvents.append(contentsOf: hydrated)
                    }
                }
            case .timeline:
                // Always let subsequent layers contribute. Even when a
                // healthy event set exists, entity hydration matters for
                // surfacing named subjects in the answer body.
                collectedEvents.append(contentsOf: try await timelineLayer(intent))
            case .entity:
                collectedEntities.append(contentsOf: try await entityLayer(intent))
            case .metadata:
                collectedChunks.append(contentsOf: try await metadataLayer(intent))
            case .summary:
                collectedSummaries.append(contentsOf: try await summaryLayer(intent))
            case .graph:
                if !collectedEntities.isEmpty {
                    let edges = try await graphLayer(seeds: collectedEntities)
                    collectedRelationships.append(contentsOf: edges)
                    // G3.17/G3.18 — typed bond walks, biased by intent.
                    // Reconstruction-shaped questions get more seeds and
                    // hops; flat factual lookups get a tight budget so
                    // the schema-aware layer doesn't tax simple queries.
                    let existingObjectIDs = Set(collectedChunks.map(\.chunk.objectID))
                    let bondOutcome = try await bondLayer(
                        intent: intent,
                        seeds: collectedEntities,
                        excludeObjectIDs: existingObjectIDs
                    )
                    collectedChunks.append(contentsOf: bondOutcome.chunks)
                    collectedBondSteps.append(contentsOf: bondOutcome.steps)
                }
            case .vector:
                // Audit P0 #2/#8 — the dense channel must retrieve INDEPENDENTLY,
                // not be confined to the chunk ids the lexical layers already
                // found. Confining it defeated semantic recall whenever FTS/
                // entity/metadata missed the right passage (measured: lookup
                // retrieval recall 0.07 on the gold set). A full-index scan
                // (ANN-accelerated when the HNSW index is built) surfaces the
                // semantically-nearest chunks regardless of what earlier layers
                // found; results fuse with the rest in `assemble`.
                collectedChunks.append(contentsOf: try await vectorLayer(intent, candidateChunkIDs: nil))
            }
        }

        // RET-009 — question-conditioned AUTHORITY (supersedes the pure density
        // heuristic). Per-KO mention count still selects CANDIDATE documents
        // (preserving recall), but WHICH candidate is authoritative — and the
        // order it promotes in — is now decided by DocumentFitness (role +
        // requested-field match against the compiled QueryPlan), NOT raw mention
        // count. So a résumé outranks a 186×-mention patent email for "where
        // worked", and a LOW-mention receipt image can still win a payment
        // question. Gated on the objects repo being wired AND the question naming
        // a specific source role; otherwise falls back to the prior density
        // behavior so the offline eval baseline is unchanged.
        var authorityKOs: Set<KnowledgeObject.ID> = []
        var authorityRanking: [KnowledgeObject.ID] = []   // best→worst by fitness
        var mentionCounts: [KnowledgeObject.ID: Int] = [:]
        for e in collectedEntities.prefix(4) {
            let rows = (try? await entities.mentions(forEntityID: e.id, limit: 500)) ?? []
            for r in rows { mentionCounts[r.objectID, default: 0] += 1 }
        }
        let densityKOs = Set(mentionCounts.filter { $0.value >= 3 }.map(\.key))

        let plan = QueryPlanCompiler().compile(intent: intent, category: .fact, queryClass: .ordinary)
        let hasSpecificRole = plan.preferredSourceRoles.contains { $0 != .any && $0 != .correspondence }
        if let objects, hasSpecificRole {
            // Candidate set by mention EXISTENCE + the retrieved set — NOT mention
            // count. A person names themselves only once or twice in their own CV
            // (measured: the résumé had 2 subject mentions, < the density floor),
            // so a count-based gate would EXCLUDE the very document that is most
            // authoritative. We therefore consider: (a) documents any subject is
            // mentioned in at all, (b) whatever the retrieval channels surfaced,
            // and (c) the dense KOs — then let fitness decide authority.
            var candidateSet = densityKOs
            for subject in plan.targetSubjects.prefix(3) {
                let hits = (try? await objects.findMentioning(subject, limit: 40)) ?? []
                for h in hits { candidateSet.insert(h.id) }
            }
            // Fill remaining budget from the retrieved chunk set.
            for oid in collectedChunks.map(\.chunk.objectID) where candidateSet.count < 48 {
                candidateSet.insert(oid)
            }
            // Deterministic truncation: a Set's iteration order is randomized
            // per process, so `prefix` would pick an arbitrary 48 at scale and
            // make the authority ranking (and thus the answer) vary run-to-run.
            // Sort by a stable key before capping.
            let candidates = Array(
                candidateSet.sorted { $0.uuidString < $1.uuidString }.prefix(48)
            )
            let scorer = DocumentFitnessScorer()
            var candidateSignals: [DocumentSignals] = []
            for ko in candidates {
                guard let obj = try? await objects.load(id: ko) else { continue }
                let name = obj.sourceFile.lastPathComponent
                let fields = DocumentRoleInference.presentFields(inText: obj.content)
                let roles = DocumentRoleInference.inferRoles(fileName: name, sourceType: obj.sourceType, presentFields: fields)
                let signals = DocumentSignals(
                    objectID: ko, fileName: name, sourceType: obj.sourceType,
                    roleHints: roles, presentFields: fields,
                    subjectMentionCount: mentionCounts[ko] ?? 0,
                    contentSignature: DocumentRoleInference.contentSignature(obj.content))
                candidateSignals.append(signals)
            }
            // RET-008 — collapse near-duplicate copies (e.g. the same résumé re-sent
            // 15×) to one authoritative representative, so duplicates neither crowd
            // the window nor fake corroboration.
            let (ranked, collapsed) = scorer.rankDeduped(plan: plan, candidates: candidateSignals)
            if collapsed > 0 {
                KalsmritikoshLog.storage.notice("RET-008: collapsed \(collapsed, privacy: .public) duplicate doc(s) in authority ranking.")
            }
            authorityRanking = ranked.filter { $0.score > 0 }.map(\.objectID)
            // Inject density candidates PLUS strong role-matchers (adds low-mention
            // authoritative docs like a receipt); ranking demotes pure correspondence.
            // Only deduped representatives are eligible → duplicates aren't injected N×.
            let repIDs = Set(ranked.map(\.objectID))
            authorityKOs = densityKOs.intersection(repIDs).union(densityKOs.subtracting(Set(candidateSignals.map(\.objectID))))
            for f in ranked where f.matchedRole != nil && f.score > 0.5 { authorityKOs.insert(f.objectID) }
        } else {
            authorityKOs = densityKOs   // fallback: prior density-only authority
        }

        if !authorityKOs.isEmpty {
            // RET-004 — inject the chunks of an authoritative doc that actually MATCH the
            // question (by query-term overlap), not just its first N (no prefix-only injection).
            let selector = HierarchicalEvidenceSelector()
            let selTerms = selector.terms(from: plan)
            let present = Set(collectedChunks.map(\.chunk.objectID))
            for ko in authorityKOs where !present.contains(ko) {
                let injected = (try? await chunks.findByObjectID(ko)) ?? []
                let pick = selTerms.isEmpty
                    ? Array(injected.indices.prefix(4))
                    : selector.selectWithinDocument(chunkTexts: injected.map(\.text), terms: selTerms, limit: 4)
                for i in pick where i < injected.count {
                    collectedChunks.append(RetrievedChunk(chunk: injected[i], score: 1.0, viaLayer: .entity))
                }
            }
        }

        // G3.20 — translate raw bond steps into typed [WalkStep] for
        // the "Why this answer?" UI. Skipped when no explainer is
        // wired or no steps were produced.
        let walkSteps: [WalkStep]
        if let explainer = walkExplainer, !collectedBondSteps.isEmpty {
            walkSteps = await explainer.explain(collectedBondSteps)
        } else {
            walkSteps = []
        }

        // HISTORY Phase C.4 — slot-aware boost. Events whose 5W+H
        // slots mention a question entity hint (WHO/WHAT/etc.) bubble
        // up; events with denser slot fills get a tiebreak nudge so
        // narrative-grade events outrank thinly-slotted ones. The
        // boost runs BEFORE the tier sort in `assemble` — rankByTier
        // is stable on input order, so within a tier the slot order
        // is preserved.
        let boostedEvents = await boostEventsBySlots(
            events: collectedEvents,
            hints: intent.entityHints
        )

        // T18/P6.4 (§21) — withhold EVERYTHING sourced from a privileged
        // KnowledgeObject before the result is assembled: chunks, events,
        // entities, and relationships all carry `sourceObjectID`, so all four
        // layers are filtered (was: chunks only). No-op unless something is
        // actually privileged.
        let privileged = await privilegedObjectIDSet()
        let visibleChunks = privileged.isEmpty ? collectedChunks
            : collectedChunks.filter { !privileged.contains($0.chunk.objectID) }
        let visibleEvents = privileged.isEmpty ? boostedEvents
            : boostedEvents.filter { !privileged.contains($0.sourceObjectID) }
        let visibleEntities = privileged.isEmpty ? collectedEntities
            : collectedEntities.filter { !privileged.contains($0.sourceObjectID) }
        let visibleRelationships = privileged.isEmpty ? collectedRelationships
            : collectedRelationships.filter { !privileged.contains($0.sourceObjectID) }
        if !privileged.isEmpty {
            let withheld = (collectedChunks.count - visibleChunks.count)
                + (boostedEvents.count - visibleEvents.count)
                + (collectedEntities.count - visibleEntities.count)
                + (collectedRelationships.count - visibleRelationships.count)
            if withheld > 0 {
                KalsmritikoshLog.storage.notice("Privilege filter: withheld \(withheld, privacy: .public) item(s) across chunks/events/entities/relations (§21).")
            }
        }

        let result = assemble(
            chunks: visibleChunks,
            events: visibleEvents,
            entities: visibleEntities,
            relationships: visibleRelationships,
            summaries: collectedSummaries,
            layers: usedLayers,
            shortCircuit: nil,
            walkSteps: walkSteps,
            authorityKOs: authorityKOs,
            authorityRanking: authorityRanking
        )
        return await attachGenericFacts(to: result)
    }

    /// SEM (option A) — attach the ASSERTABLE domain-pack facts derived from the
    /// evidence blocks in the assembled result. Keyed on the surfaced chunks'
    /// `evidenceBlockID`, so a fact only rides an answer whose evidence actually
    /// backs it. Strict no-op when no repo is wired or no surfaced chunk carries
    /// a block id. Never throws into the retrieval path.
    private func attachGenericFacts(to result: RetrievalResult) async -> RetrievalResult {
        guard let genericFacts else { return result }
        let blockIDs = result.chunks.compactMap { $0.chunk.evidenceBlockID }
        guard !blockIDs.isEmpty else { return result }                 // zero work when no blocks
        let facts = (try? await genericFacts.facts(forBlockIDs: blockIDs)) ?? []
        guard !facts.isEmpty else { return result }                    // zero work when no facts

        // Resolve the distinct objects the facts' blocks actually map to (in-memory, from the
        // retrieved chunks — no repo calls, no invented objects). Then resolve independence
        // keys in ONE batch for exactly that set. Skip the batch when nothing resolves.
        var blockToObject: [UUID: KnowledgeObject.ID] = [:]
        for c in result.chunks where c.chunk.evidenceBlockID != nil {
            let b = c.chunk.evidenceBlockID!
            if blockToObject[b] == nil { blockToObject[b] = c.chunk.objectID }
        }
        let resolvedObjects = Set(facts.flatMap { $0.sourceBlockIDs.compactMap { blockToObject[$0] } })
        var keys: [KnowledgeObject.ID: String] = [:]
        if let independenceProvider, !resolvedObjects.isEmpty {
            keys = (try? await independenceProvider.keys(for: resolvedObjects)) ?? [:]   // one batch call
        }
        let evaluations = ClaimEvaluator.evaluate(facts: facts, chunks: result.chunks, independenceKeys: keys)
        guard !evaluations.isEmpty else { return result }
        // Deprecated compat field: the surfaced facts (any maySurface decision), so a reader
        // can still join field/value with the canonical evaluation by id.
        let surfacedIDs = Set(evaluations.map(\.id))
        let compatFacts = facts.filter { surfacedIDs.contains($0.id) }
        return RetrievalResult(
            chunks: result.chunks, events: result.events, entities: result.entities,
            relationships: result.relationships, summaries: result.summaries,
            layersUsed: result.layersUsed, shortCircuitedAt: result.shortCircuitedAt,
            walkSteps: result.walkSteps, genericFacts: compatFacts, claimEvaluations: evaluations,
            authorityObjectIDs: result.authorityObjectIDs   // must survive the fact-attach rewrap
        )
    }


    /// The set of privileged KnowledgeObject IDs. Guarded so it costs nothing
    /// when no objects repo is wired or nothing is privileged.
    private func privilegedObjectIDSet() async -> Set<KnowledgeObject.ID> {
        guard let objects else { return [] }
        let ids = (try? await objects.privilegedObjectIDs()) ?? []
        return Set(ids)
    }

    /// Re-orders events by 5W+H slot relevance:
    ///   score = (# question hints found in any slot value) * 2
    ///         + slot density (count of populated slots) * 0.5
    /// Ties keep the original order so layered priority is respected.
    /// Returns the input list verbatim when there are no events or no
    /// hints — both the fetch and the rank are pure work to skip then.
    private func boostEventsBySlots(
        events: [Event],
        hints: [String]
    ) async -> [Event] {
        guard !events.isEmpty else { return events }
        let bundles = (try? await self.events.narrativeSlots(forEventIDs: events.map(\.id))) ?? [:]
        guard !bundles.isEmpty else { return events }
        let normalizedHints = hints
            .map { $0.lowercased() }
            .filter { !$0.isEmpty }
        let indexed = events.enumerated().map { (idx, event) -> (Int, Event, Double) in
            let slots = bundles[event.id] ?? .empty
            let score = Self.slotScore(slots: slots, hints: normalizedHints)
            return (idx, event, score)
        }
        let sorted = indexed.sorted { a, b in
            if a.2 != b.2 { return a.2 > b.2 }
            return a.0 < b.0
        }
        return sorted.map(\.1)
    }

    private nonisolated static func slotScore(slots: EventNarrativeSlots, hints: [String]) -> Double {
        if slots.isEmpty { return 0 }
        var hintScore = 0.0
        if !hints.isEmpty {
            for slot in NarrativeSlot.allCases {
                for value in slots.values(for: slot) {
                    let text = value.text.lowercased()
                    for hint in hints where text.contains(hint) {
                        hintScore += 2.0
                        break // one hit per value
                    }
                }
            }
        }
        let density = Double(slots.filledSlotCount) * 0.5
        return hintScore + density
    }

    // MARK: - Layers

    private func memoryLayer(_ intent: UserIntent) async throws -> [MemoryObject] {
        var seen = Set<MemoryObject.ID>()
        var hits: [MemoryObject] = []

        // Subject identifiers worth looking up: scope + each entity hint.
        var candidates: [String] = intent.entityHints
        switch intent.scope {
        case .project(let name), .person(let name), .organization(let name), .folder(let name):
            candidates.append(name)
        case .global:
            break
        }

        // Hot path: hashmap lookups via MemoryHashCache.
        let cacheReady = await memoryCache?.isWarm() ?? false
        if let cache = memoryCache, cacheReady {
            for candidate in Set(candidates) where !candidate.isEmpty {
                for kind in MemoryObject.SubjectKind.allCases {
                    if let current = await cache.lookup(kind: kind, identifier: candidate),
                       seen.insert(current.id).inserted {
                        hits.append(current)
                    }
                }
            }
        } else {
            for candidate in Set(candidates) where !candidate.isEmpty {
                for kind in MemoryObject.SubjectKind.allCases {
                    if let current = try? await memory.current(forSubject: kind, identifier: candidate),
                       seen.insert(current.id).inserted {
                        hits.append(current)
                    }
                }
            }
        }

        // Fall back to full-text-ish search over narratives when no hint
        // matched directly.
        if hits.isEmpty {
            let trimmed = intent.rawQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let searchHits = (try? await memory.search(trimmed, limit: 5)) ?? []
                for hit in searchHits where seen.insert(hit.id).inserted {
                    hits.append(hit)
                }
            }
        }

        return hits
    }

    private func timelineLayer(_ intent: UserIntent) async throws -> [Event] {
        // Hot path: when entity hints + a timeframe both narrow the
        // result, fan out per-entity via the EntityTimeline cache —
        // binary search + memcpy instead of SQL intersection of
        // (entity_id, date BETWEEN). Falls back to the global SQL
        // path when no hint anchors the query.
        let timelineReady = await entityTimeline?.isWarm() ?? false
        let trieReady = await entityTrie?.isWarm() ?? false
        if let timeline = entityTimeline, timelineReady,
           let trie = entityTrie, trieReady,
           !intent.entityHints.isEmpty {
            var seenEventIDs = Set<Event.ID>()
            var collectedIDs: [Event.ID] = []
            for hint in intent.entityHints.prefix(4) {
                let entityIDs = await trie.resolve(hint)
                for entityID in entityIDs {
                    let slots = await timeline.slots(
                        forEntity: entityID,
                        from: intent.timeframe?.start,
                        to: intent.timeframe?.end
                    )
                    for slot in slots where seenEventIDs.insert(slot.eventID).inserted {
                        collectedIDs.append(slot.eventID)
                        if collectedIDs.count >= 200 { break }
                    }
                    if collectedIDs.count >= 200 { break }
                }
                if collectedIDs.count >= 200 { break }
            }
            if !collectedIDs.isEmpty {
                return try await events.findByIDs(collectedIDs)
            }
            // No entity matches — fall through to the SQL timeline path
            // so the brain still gets globally-recent context.
        }
        if let timeframe = intent.timeframe,
           let start = timeframe.start,
           let end = timeframe.end {
            return try await events.between(start: start, end: end, limit: 200)
        }
        if let timeframe = intent.timeframe {
            return try await events.between(
                start: timeframe.start ?? .distantPast,
                end: timeframe.end ?? .distantFuture,
                limit: 200
            )
        }
        return try await events.recent(limit: 100)
    }

    private func entityLayer(_ intent: UserIntent) async throws -> [Entity] {
        var results: [Entity] = []
        var seen = Set<Entity.ID>()
        let trieReady = await entityTrie?.isWarm() ?? false
        // Real-data debug (2026-06-25): IntentDetector was emitting
        // question-words ("What", "Who", "When") as entity hints, and
        // `entities.find(byValue: "What")` LIKE-matched 15+ unrelated
        // entities containing the substring "what" — polluting the
        // candidate set and bypassing the downstream topic-to-entity
        // logic. Drop the question-words at this layer so the topic
        // step can actually fire when no real entity name appears
        // in the question.
        let cleanHints = intent.entityHints.filter { hint in
            let h = hint.lowercased()
            return !Self.questionWords.contains(h) && h.count >= 2
        }
        for hint in cleanHints.prefix(6) {
            // Hot path: Trie resolves the hint in O(|hint|) to a set
            // of candidate ids, then a single `WHERE id IN (...)` SQL
            // hydrates them. Replaces `LIKE '%hint%'` full scan.
            if let trie = entityTrie, trieReady {
                let candidateIDs = Array(await trie.resolve(hint))
                if !candidateIDs.isEmpty {
                    let hydrated = (try? await entities.findByIDs(candidateIDs, limit: 15)) ?? []
                    for entity in hydrated where seen.insert(entity.id).inserted {
                        results.append(entity)
                    }
                    continue
                }
            }
            // Fallback: SQL LIKE scan.
            let rows = try await entities.find(byValue: hint, limit: 15)
            for entity in rows where seen.insert(entity.id).inserted {
                results.append(entity)
            }
        }
        // Topic-to-entity retrieval: regardless of hint count, when the
        // question text has searchable nouns, also pull entities
        // co-occurring with those nouns in the corpus. We PREPEND
        // these so they outrank the generic top-up entities the next
        // block adds.
        //
        // Why unconditional (was `results.count < 3`): for questions
        // like "What organizations am I in touch with via patents?",
        // even after we filter out question-words from hints, the
        // hint loop produces nothing (no entity named "patents"), so
        // the old < 3 guard relied on luck. Always running this step
        // ensures topic-relevant entities (Khurana / IIPRD / BiswajitSarkar)
        // appear at the front of the candidate list. Capped at 15 so
        // it doesn't drown out a targeted-entity query that DID match.
        // FTS5's MATCH rejects raw question text with punctuation /
        // question marks. Extract content words (≥3 chars, filter
        // question-words/stopwords) and OR-join them so FTS5 treats it
        // as a multi-keyword query.
        let topicTokens = intent.rawQuestion
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 && !Self.questionWords.contains($0.lowercased()) }
        let ftsQuery = topicTokens.joined(separator: " OR ")
        if !ftsQuery.isEmpty,
           let ftsHits = try? await chunks.searchFTS(ftsQuery, limit: 25) {
            let koIDs = Array(Set(ftsHits.map(\.objectID))).prefix(20)
            if !koIDs.isEmpty {
                let topicEntities = (try? await entities.findInObjects(
                    Array(koIDs),
                    limit: 15
                )) ?? []
                // Prepend so they outrank the alphabetical top-up below.
                var topicResults: [Entity] = []
                for (entity, _) in topicEntities where seen.insert(entity.id).inserted {
                    topicResults.append(entity)
                }
                results = topicResults + results
            }
        }

        // P5.1 / §11.3 — remove generic entity pollution. The global top-up
        // below floods the candidate set with up to ~48 globally-common
        // entities regardless of the question, which drowns targeted queries.
        // Now that the topic-relevant FTS block above surfaces query-specific
        // entities unconditionally, the global fallback only fires when the
        // query is genuinely sparse (< 3 topic/hint entities found) or is an
        // explicitly broad/global browse. Targeted queries that matched keep a
        // clean, on-topic candidate set.
        let isBroadQuery = intent.scope == .global
        if results.count < 3 || isBroadQuery {
            let topUpKinds: [Entity.Kind] = [.emailAddress, .organization, .person, .vendor, .client, .project]
            for kind in topUpKinds {
                let rows = try await entities.list(kind: kind, limit: 8)
                for row in rows where seen.insert(row.id).inserted {
                    if let real = try await entities.find(byID: row.id) {
                        results.append(real)
                    }
                }
            }
        }
        return results
    }

    private func metadataLayer(_ intent: UserIntent) async throws -> [RetrievedChunk] {
        let q = intent.rawQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        let hits = try await chunks.searchFTS(q, limit: 25)
        var collected: [RetrievedChunk] = hits.enumerated().map { idx, chunk in
            RetrievedChunk(
                chunk: chunk,
                score: 1.0 / Double(idx + 1),
                viaLayer: .metadata
            )
        }

        // G2-SYNTHETIC-QUESTIONS — also search the synthetic-questions
        // FTS view; for each match, hydrate the underlying chunk and
        // merge into the result set. De-dupe by chunkID — if the same
        // chunk was hit by chunk-text FTS AND by a synthetic question,
        // we keep the higher score (synthetic-question matches signal
        // question-shaped relevance, which chatmind validated as the
        // strongest single retrieval lift).
        if let synthRepo = syntheticQuestions {
            let synthHits = (try? await synthRepo.search(q, limit: 25)) ?? []
            if !synthHits.isEmpty {
                let existingChunkIDs = Set(collected.map(\.chunk.id))
                // Hydrate chunks for synthetic-question hits not already
                // present in the chunk-text path.
                let missingChunkIDs = synthHits
                    .map(\.chunkID)
                    .filter { !existingChunkIDs.contains($0) }
                let hydrated = (try? await chunks.findByIDs(missingChunkIDs)) ?? []
                let hydratedByID: [Chunk.ID: Chunk] = Dictionary(
                    uniqueKeysWithValues: hydrated.map { ($0.id, $0) }
                )
                for hit in synthHits {
                    if let chunk = hydratedByID[hit.chunkID] {
                        collected.append(RetrievedChunk(
                            chunk: chunk,
                            score: hit.score,
                            viaLayer: .metadata
                        ))
                    }
                }
            }
        }

        // G2-QA-PAIRS — search the qa_pairs FTS view. For each pair the
        // user question matches, hydrate the FIRST chunk of the answer
        // KO (small enough that taking the head of its chunk set is a
        // decent stand-in for "the answer text"). Append as metadata-
        // layer hits so the verifier can merge with chunk-text + synthq
        // hits.
        if let qaRepo = qaPairs {
            let qaHits = (try? await qaRepo.search(q, limit: 15)) ?? []
            if !qaHits.isEmpty {
                let existingObjectIDs = Set(collected.map(\.chunk.objectID))
                let novelHits = qaHits.filter {
                    !existingObjectIDs.contains($0.answerObjectID)
                }
                for hit in novelHits {
                    if let chunk = try? await chunks.firstChunk(forObjectID: hit.answerObjectID) {
                        collected.append(RetrievedChunk(
                            chunk: chunk,
                            score: hit.score,
                            viaLayer: .metadata
                        ))
                    }
                }
            }
        }

        return collected
    }

    private func summaryLayer(_ intent: UserIntent) async throws -> [Summary] {
        try await summaries.listByLevel(.knowledgeBase, limit: 3)
    }

    private func graphLayer(seeds: [Entity]) async throws -> [Relationship] {
        var out: [Relationship] = []
        for seed in seeds.prefix(3) {
            out.append(contentsOf: try await graph.neighbors(of: seed.id, limit: 25))
        }
        return out
    }

    /// G3.17/G3.18/G3.20 — typed bond walk, intent-biased. For each
    /// seed entity, BFS over fact_bonds up to a per-intent hop budget,
    /// collect the source KO ids of the traversed bonds, and hydrate
    /// the first chunk per KO as retrieval evidence (`viaLayer:
    /// .graph`). Returns both chunks (for the retrieval set) and raw
    /// bond steps (for the WalkExplainer / "Why this answer?" UI).
    /// KOs that already appeared in earlier layers are skipped so we
    /// don't duplicate citations.
    private struct BondLayerOutcome {
        let chunks: [RetrievedChunk]
        let steps: [BondWalker.WalkResult.Step]
    }

    private func bondLayer(
        intent: UserIntent,
        seeds: [Entity],
        excludeObjectIDs: Set<KnowledgeObject.ID>
    ) async throws -> BondLayerOutcome {
        guard let walker = bondWalker, bondWalkSeedLimit > 0 else {
            return BondLayerOutcome(chunks: [], steps: [])
        }
        let budget = bondWalkBudget(for: intent)
        guard budget.seeds > 0, budget.chunks > 0 else {
            return BondLayerOutcome(chunks: [], steps: [])
        }
        var aggregatedKOIDs: [KnowledgeObject.ID] = []
        var seenKOIDs: Set<KnowledgeObject.ID> = excludeObjectIDs
        var allSteps: [BondWalker.WalkResult.Step] = []
        for seed in seeds.prefix(budget.seeds) {
            let result = await walker.expand(from: seed.id, maxHops: budget.hops)
            allSteps.append(contentsOf: result.steps)
            for koID in result.sourceObjectIDs {
                guard !seenKOIDs.contains(koID) else { continue }
                seenKOIDs.insert(koID)
                aggregatedKOIDs.append(koID)
                if aggregatedKOIDs.count >= budget.chunks { break }
            }
            if aggregatedKOIDs.count >= budget.chunks { break }
        }
        guard !aggregatedKOIDs.isEmpty else {
            return BondLayerOutcome(chunks: [], steps: allSteps)
        }
        let scoreFloor = bondChunkScore(for: intent)
        var out: [RetrievedChunk] = []
        for koID in aggregatedKOIDs {
            if let chunk = try? await chunks.firstChunk(forObjectID: koID) {
                out.append(RetrievedChunk(
                    chunk: chunk,
                    // G3.19 — score floor is intent-biased. Multi-hop
                    // questions promote bond chunks above most vector
                    // hits since the bond graph IS the answer path;
                    // lookups demote them so a direct semantic match
                    // still wins.
                    score: scoreFloor,
                    viaLayer: .graph
                ))
            }
        }
        return BondLayerOutcome(chunks: out, steps: allSteps)
    }

    /// G3.19 — pick the bond-chunk score floor based on intent. The
    /// values are kept inside a narrow band so MMR diversity (G2-MMR)
    /// can still reshuffle them; this is the BASELINE score, not the
    /// final ranking.
    private func bondChunkScore(for intent: UserIntent) -> Double {
        switch intent.kind {
        case .reconstructProject,
             .reconstructRelationship,
             .reconstructTimeline,
             .executiveBriefing:
            // Multi-hop / reconstruction — the bond graph is what the
            // question hinges on. Above most vector fallbacks.
            return 0.65
        case .riskDetection, .missingInformation:
            return 0.55
        case .factualLookup, .semanticSearch, .unknown:
            // Direct factual matches usually outrank a graph walk for
            // simple lookups; keep bond chunks visible but below.
            return 0.45
        }
    }

    /// G3.18 — pick (seeds × hops × chunkLimit) for bond walks based
    /// on the question's intent kind. Reconstruction-shaped questions
    /// (project / relationship / timeline) explore wider; flat factual
    /// lookups stay narrow so we don't pay the bond-walk cost on a
    /// "what is X" query that the entity layer already answers.
    private func bondWalkBudget(for intent: UserIntent) -> (seeds: Int, hops: Int, chunks: Int) {
        switch intent.kind {
        case .reconstructProject,
             .reconstructRelationship,
             .reconstructTimeline,
             .executiveBriefing:
            // Multi-hop questions — the bond graph is the whole point.
            return (
                seeds: max(bondWalkSeedLimit, 5),
                hops: 2,
                chunks: max(bondWalkChunkLimit, 15)
            )
        case .riskDetection, .missingInformation:
            // Want broad context but not exhaustive — sit between the
            // reconstruction tier and the cheap lookup tier.
            return (
                seeds: bondWalkSeedLimit,
                hops: 2,
                chunks: bondWalkChunkLimit
            )
        case .factualLookup, .semanticSearch, .unknown:
            // Cheap path: a single short hop off the top seed. Saves
            // ~ N×perHopLimit SQL queries on every direct-lookup query.
            return (
                seeds: min(bondWalkSeedLimit, 2),
                hops: 1,
                chunks: min(bondWalkChunkLimit, 5)
            )
        }
    }

    private func vectorLayer(
        _ intent: UserIntent,
        candidateChunkIDs: [Chunk.ID]? = nil
    ) async throws -> [RetrievedChunk] {
        let query = await embedder.embed(intent.rawQuestion)
        // Empty = no embedding produced (T15). Treat the vector layer as
        // unavailable for this query and fall through to the structured
        // layers — do NOT search with a zero/empty query (which would
        // return noise). .vector is last in priority, so this is a no-op.
        guard !query.isEmpty else {
            KalsmritikoshLog.storage.notice("Vector layer skipped: no query embedding produced; using structured layers only.")
            return []
        }
        let hits = try await vectors.nearest(
            to: query,
            limit: vectorLayerLimit,
            candidateChunkIDs: candidateChunkIDs
        )
        let hydrated = try await chunks.findByIDs(hits.map(\.chunkID))
        let byID = Dictionary(uniqueKeysWithValues: hydrated.map { ($0.id, $0) })
        return hits.compactMap { hit in
            guard let chunk = byID[hit.chunkID] else { return nil }
            return RetrievedChunk(chunk: chunk, score: hit.score, viaLayer: .vector)
        }
    }

    // MARK: - Helpers

    private func memoryAsSummary(_ memory: MemoryObject) -> Summary {
        Summary(
            level: .knowledgeBase,
            length: .executive,
            scope: .knowledgeBase,
            body: memory.narrative,
            modelID: "memory.distilled",
            confidence: memory.confidence
        )
    }

    private func assemble(
        chunks: [RetrievedChunk],
        events: [Event],
        entities: [Entity],
        relationships: [Relationship] = [],
        summaries: [Summary],
        layers: [RetrievalLayer],
        shortCircuit: RetrievalLayer?,
        walkSteps: [WalkStep] = [],
        authorityKOs: Set<KnowledgeObject.ID> = [],
        authorityRanking: [KnowledgeObject.ID] = []
    ) -> RetrievalResult {
        // HISTORY Phase A.4 — tier-aware re-ranking.
        // Entities are sorted by (-tier.defaultWeight, originalIndex)
        // so T1 leads, T2 follows, T3 trails — unless the user has
        // toggled `showT3InResults` off, in which case T3 entities
        // are filtered out entirely. Preserve-not-filter rule
        // honored: T3 rows STAY ON DISK; only the result surface
        // is affected.
        //
        // Events get the same treatment because EventExtractor
        // (Phase A.5) will tag them; today every event is still T2
        // by default which is a no-op until A.5 lands.
        let showT3 = UserDefaults.standard.object(forKey: "kalsmritikosh.history.showT3InResults") as? Bool ?? false
        let rankedEntities = Self.rankByTier(entities, includeT3: showT3)
        let rankedEvents   = Self.rankByTier(events,   includeT3: showT3, keyPath: \.qualityTier)

        // UPDATE_07 — near-duplicate collapse + per-source diversity. Email
        // reply-chains produce dozens of near-identical quoted chunks that
        // embed to nearly the same vector and flood the top-K, burying the one
        // authoritative document (a grant certificate, a contract) under copies
        // of a subject line. Collapse chunks with the same normalized-text
        // signature and cap how many any single source contributes, preserving
        // the existing priority order (FTS/metadata chunks already precede
        // vector chunks). Preserve-not-delete: rows stay on disk; only this
        // result window is de-duplicated.
        // Audit P0 #4/#9 — fuse the channels by Reciprocal Rank Fusion BEFORE
        // diversifying. Previously the final order was just the layer-append
        // order (metadata → graph → vector LAST), so the semantically-correct
        // vector hits landed at the bottom of the window and the experts saw
        // them last (measured: recall@3 ~0.07 while recall@all ~0.98 — the right
        // evidence was retrieved but buried). RRF ranks each chunk by its rank
        // WITHIN each channel that found it, rewarding cross-channel agreement,
        // on one comparable scale instead of mixing 1/FTS-rank vs cosine vs the
        // fixed graph score. diversify() then preserves this relevance order.
        let fused = Self.rrfRank(chunks)
        // RET-009 — stable-promote authoritative-document chunks to the front of
        // the fused window. When a fitness ranking is present, authority chunks
        // are ordered by their document's FITNESS (role+field match) so the most
        // authoritative doc leads; otherwise (density fallback) they keep fused
        // order. Pure reorder (no add/drop); diversify still caps per-source.
        let prioritized: [RetrievedChunk]
        if authorityKOs.isEmpty {
            prioritized = fused
        } else if authorityRanking.isEmpty {
            prioritized = fused.filter { authorityKOs.contains($0.chunk.objectID) }
                + fused.filter { !authorityKOs.contains($0.chunk.objectID) }
        } else {
            let rankIndex = Dictionary(
                authorityRanking.enumerated().map { ($0.element, $0.offset) },
                uniquingKeysWith: { a, _ in a })
            let authorityChunks = fused.enumerated()
                .filter { authorityKOs.contains($0.element.chunk.objectID) }
                .sorted {
                    let a = rankIndex[$0.element.chunk.objectID] ?? Int.max
                    let b = rankIndex[$1.element.chunk.objectID] ?? Int.max
                    return a != b ? a < b : $0.offset < $1.offset
                }
                .map(\.element)
            let rest = fused.filter { !authorityKOs.contains($0.chunk.objectID) }
            prioritized = authorityChunks + rest
        }
        let diverseChunks = Self.diversify(prioritized)

        // UPDATE_07 — the same hygiene for events: the timeline/reconstruction
        // path was drowning in email noise (empty-title events, internal
        // "Archived entry —" version markers, delivery-failure / processing-error
        // notifications, and dozens of duplicate-title emails), which pushed the
        // authoritative dated facts out of the answer window. Filter that noise
        // from the surfaced set (rows stay on disk).
        let cleanedEvents = Self.cleanEvents(rankedEvents)

        return RetrievalResult(
            chunks: diverseChunks,
            events: cleanedEvents,
            entities: rankedEntities,
            relationships: relationships,
            summaries: summaries,
            layersUsed: layers,
            shortCircuitedAt: shortCircuit,
            walkSteps: walkSteps,
            authorityObjectIDs: authorityRanking.isEmpty
                ? authorityKOs.sorted { $0.uuidString < $1.uuidString }
                : authorityRanking
        )
    }

    /// UPDATE_07 — collapse near-duplicate chunk texts and cap how many chunks
    /// any single source document contributes, preserving input (priority)
    /// order. Kills the email reply-chain flood (dozens of quoted near-identical
    /// chunks) that buries authoritative single-source documents. Deterministic.
    /// Reciprocal Rank Fusion across retrieval channels (audit P0 #4/#9). Each
    /// chunk is scored by Σ 1/(k + rank) over every channel (viaLayer) that
    /// surfaced it, where `rank` is its 1-based position within that channel
    /// sorted by the channel's own score. This puts FTS's 1/rank, the dense
    /// channel's cosine, and the graph's fixed score on ONE comparable scale and
    /// rewards chunks that more than one independent channel agrees on.
    /// De-duplicated by chunk id (keeping the highest-scoring channel's
    /// representative); stable and deterministic. k=60 is the standard constant.
    nonisolated static func rrfRank(_ chunks: [RetrievedChunk], k: Double = 60) -> [RetrievedChunk] {
        guard !chunks.isEmpty else { return [] }
        var byLayer: [RetrievalLayer: [RetrievedChunk]] = [:]
        for c in chunks { byLayer[c.viaLayer, default: []].append(c) }
        var rrf: [Chunk.ID: Double] = [:]
        var best: [Chunk.ID: RetrievedChunk] = [:]
        var firstIndex: [Chunk.ID: Int] = [:]
        for (i, c) in chunks.enumerated() where firstIndex[c.chunk.id] == nil { firstIndex[c.chunk.id] = i }
        for (_, group) in byLayer {
            for (rank, c) in group.sorted(by: { $0.score > $1.score }).enumerated() {
                rrf[c.chunk.id, default: 0] += 1.0 / (k + Double(rank + 1))
                if let cur = best[c.chunk.id] {
                    if c.score > cur.score { best[c.chunk.id] = c }
                } else {
                    best[c.chunk.id] = c
                }
            }
        }
        return best.values.sorted { a, b in
            let ra = rrf[a.chunk.id] ?? 0, rb = rrf[b.chunk.id] ?? 0
            if ra != rb { return ra > rb }
            if a.score != b.score { return a.score > b.score }
            return (firstIndex[a.chunk.id] ?? 0) < (firstIndex[b.chunk.id] ?? 0)
        }
    }

    nonisolated static func diversify(_ chunks: [RetrievedChunk], maxPerSource: Int = 4) -> [RetrievedChunk] {
        var seenText = Set<String>()
        var perSource: [KnowledgeObject.ID: Int] = [:]
        var out: [RetrievedChunk] = []
        out.reserveCapacity(chunks.count)
        for rc in chunks {
            let sig = chunkSignature(rc.chunk.text)
            if !sig.isEmpty {
                guard seenText.insert(sig).inserted else { continue }   // near-duplicate text
            }
            let n = perSource[rc.chunk.objectID, default: 0]
            guard n < maxPerSource else { continue }                    // one source can't dominate
            perSource[rc.chunk.objectID] = n + 1
            out.append(rc)
        }
        return out
    }

    /// System-notification / non-substantive email subjects that are never a
    /// real ledger event. Conservative — only unambiguous machine noise.
    private nonisolated static let eventNoisePatterns: [String] = [
        "processing error", "delivery status notification", "mail delivery",
        "undeliverable", "out of office", "automatic reply", "read receipt",
        "failure notice", "returned mail"
    ]

    /// Filter obvious noise from the events a retrieval surfaces and collapse
    /// duplicate-title events. Preserve-not-delete: on-disk rows are untouched;
    /// this only cleans the answer/timeline window. Deterministic.
    nonisolated static func cleanEvents(_ events: [Event]) -> [Event] {
        var seen = Set<String>()
        var out: [Event] = []
        out.reserveCapacity(events.count)
        for e in events {
            let title = e.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if title.isEmpty { continue }                               // empty-title noise
            let lower = title.lowercased()
            if lower.hasPrefix("archived entry") { continue }           // internal version marker
            if eventNoisePatterns.contains(where: { lower.contains($0) }) { continue }
            let sig = String(lower.prefix(60))
            guard seen.insert(sig).inserted else { continue }           // duplicate-title collapse
            out.append(e)
        }
        return out
    }

    /// Normalized-text fingerprint for near-duplicate detection: lowercased,
    /// letters/digits/space only, whitespace-collapsed, first ~160 chars — long
    /// enough to separate genuinely different passages, short enough that quoted
    /// reply-chains with the same header collapse together.
    nonisolated static func chunkSignature(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        var lastSpace = false
        for s in text.lowercased().unicodeScalars {
            let isAlnum = (s.value >= 97 && s.value <= 122) || (s.value >= 48 && s.value <= 57)
            if isAlnum {
                scalars.append(s); lastSpace = false
            } else if !lastSpace {
                scalars.append(" "); lastSpace = true
            }
            if scalars.count >= 160 { break }
        }
        return String(scalars).trimmingCharacters(in: .whitespaces)
    }

    /// Stable tier-aware sort. Items with higher
    /// `tier.defaultWeight` come first; original order is preserved
    /// within a tier. T3 items are dropped when `includeT3== false`.
    private nonisolated static func rankByTier(
        _ entities: [Entity],
        includeT3: Bool
    ) -> [Entity] {
        let filtered = includeT3 ? entities : entities.filter { $0.qualityTier != .t3 }
        let indexed = filtered.enumerated().map { ($0.offset, $0.element) }
        return indexed.sorted { a, b in
            let wa = a.1.qualityTier.defaultWeight
            let wb = b.1.qualityTier.defaultWeight
            if wa != wb { return wa > wb }
            return a.0 < b.0
        }.map(\.1)
    }

    private nonisolated static func rankByTier(
        _ events: [Event],
        includeT3: Bool,
        keyPath: KeyPath<Event, QualityTier>
    ) -> [Event] {
        let filtered = includeT3 ? events : events.filter { $0[keyPath: keyPath] != .t3 }
        let indexed = filtered.enumerated().map { ($0.offset, $0.element) }
        return indexed.sorted { a, b in
            let wa = a.1[keyPath: keyPath].defaultWeight
            let wb = b.1[keyPath: keyPath].defaultWeight
            if wa != wb { return wa > wb }
            return a.0 < b.0
        }.map(\.1)
    }
}

extension RetrievalLayer {
    /// The locked priority order. Memory leads; vector is intentionally last.
    public nonisolated static let priorityOrder: [RetrievalLayer] = [
        .memory, .timeline, .entity, .metadata, .summary, .graph, .vector
    ]
}
