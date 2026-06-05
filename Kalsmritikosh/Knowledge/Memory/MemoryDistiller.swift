//
//  MemoryDistiller.swift
//  Kalsmritikosh
//
//  Walks subjects (project / organization / person / …), gathers their
//  recent events + summaries + relationships, and asks the capability
//  registry for a reasoning model that can produce a structured
//  MemoryObject. Writes the new version through MemoryRepository and
//  appends a MemoryChange row when the snapshot mutates.
//
//  Triggered by IncrementalUpdater on new ingest events and by the
//  nightly CompressionScheduler. Always operates over the set of
//  invalidated subjects, never the whole corpus.
//

import Foundation

public actor MemoryDistiller {
    private let memory: MemoryRepository
    private let events: EventsRepository
    private let entities: EntitiesRepository
    private let capabilities: CapabilityRegistry
    private let knowledgeObjects: KnowledgeObjectRepository?

    public init(
        memory: MemoryRepository,
        events: EventsRepository,
        entities: EntitiesRepository,
        capabilities: CapabilityRegistry,
        knowledgeObjects: KnowledgeObjectRepository? = nil
    ) {
        self.memory = memory
        self.events = events
        self.entities = entities
        self.capabilities = capabilities
        self.knowledgeObjects = knowledgeObjects
    }

    public struct Subject: Sendable, Hashable {
        public let kind: MemoryObject.SubjectKind
        public let identifier: String
        public init(kind: MemoryObject.SubjectKind, identifier: String) {
            self.kind = kind
            self.identifier = identifier
        }
    }

    /// Distill (or refresh) the MemoryObject for the given subject.
    /// Returns the resulting MemoryObject, or `nil` if no evidence exists.
    @discardableResult
    public func distill(_ subject: Subject, triggeredBy: KnowledgeObject.ID? = nil) async throws -> MemoryObject? {
        let allRecent = try await events.recent(limit: 200)
        var sourceMatches: Set<KnowledgeObject.ID> = []
        if let kos = knowledgeObjects {
            let mentions = (try? await kos.findMentioning(subject.identifier, limit: 50)) ?? []
            sourceMatches = Set(mentions.map(\.id))
        }
        let recentEvents = allRecent.filter { event in
            event.title.localizedCaseInsensitiveContains(subject.identifier)
            || (event.summary?.localizedCaseInsensitiveContains(subject.identifier) ?? false)
            || sourceMatches.contains(event.sourceObjectID)
        }
        let entityMatches = try await entities.search(value: subject.identifier, limit: 20)

        // M6.5 will swap this stitched narrative for a real LLM call via
        // CapabilitySpec.reasoning(...). The contract stays the same: the
        // distiller asks for capabilities, not for a specific model.
        let narrative = try await synthesizeNarrative(
            subject: subject,
            events: recentEvents,
            entityMatches: entityMatches
        )

        let prior = try await memory.current(forSubject: subject.kind, identifier: subject.identifier)
        let nextVersion = (prior?.version ?? 0) + 1

        let next = MemoryObject(
            id: prior?.id ?? UUID(),
            subjectKind: subject.kind,
            subjectIdentifier: subject.identifier,
            keyDecisions: prior?.keyDecisions ?? [],
            keyEventIDs: recentEvents.map(\.id),
            importantRelationshipIDs: prior?.importantRelationshipIDs ?? [],
            risks: prior?.risks ?? [],
            status: prior?.status ?? "active",
            narrative: narrative,
            sourceObjectIDs: Array(Set(recentEvents.map(\.sourceObjectID))),
            confidence: aggregateConfidence(events: recentEvents),
            version: nextVersion,
            createdAt: prior?.createdAt ?? Date(),
            updatedAt: Date()
        )

        guard !recentEvents.isEmpty || prior != nil else { return nil }

        // Idempotency: skip the upsert + change-log write entirely when
        // the new distillation is materially equivalent to the prior
        // (same event set, same status, same narrative). Without this
        // guard a repeated distill bloats memory_changes with no-op rows.
        if let prior, isMaterialMatch(prior: prior, candidate: next) {
            return prior
        }

        try await memory.upsert(next)
        if let prior {
            try await memory.recordChange(diff(prior: prior, new: next, triggeredBy: triggeredBy))
        }
        return next
    }

    private func isMaterialMatch(prior: MemoryObject, candidate: MemoryObject) -> Bool {
        Set(prior.keyEventIDs) == Set(candidate.keyEventIDs)
            && prior.status == candidate.status
            && prior.narrative == candidate.narrative
    }

    /// Convenience: derive subjects directly from extracted entities so
    /// IncrementalUpdater can hand the distiller a list of names without
    /// caring about subject kinds.
    public func distillSubjects(forEntities entityValues: [String]) async throws -> [MemoryObject] {
        var out: [MemoryObject] = []
        for value in Set(entityValues) {
            for kind in MemoryObject.SubjectKind.allCases {
                if let memory = try await distill(.init(kind: kind, identifier: value)) {
                    out.append(memory)
                }
            }
        }
        return out
    }

    // MARK: - Narrative synthesis

    private func synthesizeNarrative(
        subject: Subject,
        events: [Event],
        entityMatches: [EntitySummaryRow]
    ) async throws -> String {
        let spec = CapabilitySpec.summarization(
            contextTokens: 4_000,
            purpose: "memory.distill.\(subject.kind.rawValue)"
        )
        if let provider = try? await capabilities.resolve(spec),
           await provider.isAvailable() {
            let prompt = buildPrompt(subject: subject, events: events)
            do {
                return try await provider.generate(
                    prompt: prompt,
                    options: GenerationOptions(maxTokens: 400, temperature: 0.2)
                )
            } catch {
                // Fall through to heuristic narrative below.
            }
        }
        return heuristicNarrative(subject: subject, events: events, entityMatches: entityMatches)
    }

    private func buildPrompt(subject: Subject, events: [Event]) -> String {
        let timeline = events.prefix(40).map { event in
            "- \(event.date.formatted(date: .abbreviated, time: .omitted)): \(event.title)"
        }.joined(separator: "\n")
        return """
        Subject: \(subject.kind.rawValue) "\(subject.identifier)".
        Summarize the current state in 2-3 short paragraphs, calling out:
        - key decisions,
        - active risks,
        - status (active / completed / blocked / unknown).
        Cite source events by date only. Use the evidence below.

        Evidence:
        \(timeline)
        """
    }

    private func heuristicNarrative(
        subject: Subject,
        events: [Event],
        entityMatches: [EntitySummaryRow]
    ) -> String {
        let signal = events.isEmpty
            ? "No events directly mention \(subject.identifier) yet."
            : "Atlas has \(events.count) events referencing \(subject.identifier)."
        let mentions = entityMatches.prefix(6).map(\.value).joined(separator: ", ")
        return mentions.isEmpty
            ? signal
            : "\(signal) Mentioned alongside: \(mentions)."
    }

    private func aggregateConfidence(events: [Event]) -> Confidence {
        guard !events.isEmpty else { return .low }
        let total = events.map(\.confidence).reduce(Confidence.zero) { $0.combined(with: $1) }
        return total
    }

    private func diff(
        prior: MemoryObject,
        new: MemoryObject,
        triggeredBy: KnowledgeObject.ID?
    ) -> MemoryChange {
        let addedEventIDs = Array(Set(new.keyEventIDs).subtracting(prior.keyEventIDs))
        let statusChange: MemoryChange.Delta.StatusChange? =
            prior.status != new.status
            ? .init(from: prior.status, to: new.status)
            : nil
        return MemoryChange(
            memoryObjectID: new.id,
            subjectKind: new.subjectKind,
            subjectIdentifier: new.subjectIdentifier,
            priorVersion: prior.version,
            newVersion: new.version,
            delta: .init(
                addedEventIDs: addedEventIDs,
                statusChanged: statusChange,
                narrativeRewrite: prior.narrative != new.narrative
            ),
            triggeringObjectID: triggeredBy
        )
    }
}
