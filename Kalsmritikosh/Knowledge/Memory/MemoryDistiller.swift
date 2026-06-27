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
    ///
    /// IMPORTANT: this fast-skips obvious-noise subject identifiers
    /// (length<3, header-fragment shapes) so a 9000+ subject backlog
    /// doesn't burn an hour distilling base64 fragments that nobody
    /// will query. The underlying entity row + its mentions REMAIN —
    /// only the memory_object summary is skipped. User-directed
    /// distillation (e.g. a future "promote this subject" action)
    /// bypasses this guard.
    @discardableResult
    public func distill(_ subject: Subject, triggeredBy: KnowledgeObject.ID? = nil) async throws -> MemoryObject? {
        if Self.isLowSignalSubject(subject.identifier) {
            return nil
        }
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

        // HISTORY Phase A.7 — memory inherits the BEST (highest-trust)
        // tier across the subject's contributing events. 'T1' < 'T2' <
        // 'T3' lexicographically, so MIN gives T1 if any event is T1.
        // Fall back to T2 (the schema default) when no events match.
        let memoryTier: QualityTier = {
            let eventTiers = recentEvents.map(\.qualityTier)
            guard let best = eventTiers.min(by: { $0.rawValue < $1.rawValue }) else {
                return prior?.qualityTier ?? .t2
            }
            // If we also have a prior, keep whichever is better.
            if let priorTier = prior?.qualityTier, priorTier.rawValue < best.rawValue {
                return priorTier
            }
            return best
        }()

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
            updatedAt: Date(),
            qualityTier: memoryTier
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

    /// Conservative cheap check — returns true for subject identifiers
    /// that are almost certainly header artifacts (DKIM / ARC IDs,
    /// base64 fragments, 2-char initials). Distillation is skipped for
    /// these but the entity rows themselves are not touched, honoring
    /// the "preserve all data" directive — the user can search them via
    /// FTS or surface them via a future "promote" action.
    nonisolated static func isLowSignalSubject(_ identifier: String) -> Bool {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return true }
        let isSingleWord = !trimmed.contains(" ")
        // Single-word, NOT all-caps, no vowels — clear noise. The
        // all-caps exemption preserves real acronyms (BMW, NHL, NFL).
        // No upper-bound on length: a long string of consonants is
        // even more clearly noise ("aetnfnkzqotrtcqbk"). Real words
        // and short titles always include a vowel within 6 chars.
        if isSingleWord,
           trimmed.allSatisfy({ $0.isLetter }),
           trimmed != trimmed.uppercased(),
           !trimmed.lowercased().contains(where: { "aeiouy".contains($0) }) {
            return true
        }
        // Mid-cap base64 noise: ≥3 uppercase letters AFTER position 0
        // in a single token — "AeTnFNkZQOTRtCqBk", "rMsPWt". Real
        // camelCase names (iPhone, MacBook, JavaScript) have at most
        // 1 mid-cap.
        if isSingleWord, trimmed.count >= 5,
           trimmed != trimmed.uppercased() {
            let midUpper = trimmed.dropFirst().filter(\.isUppercase).count
            if midUpper >= 3 { return true }
        }
        // Long-string low-vowel-ratio noise. "aetnfnkzqotrtcqbk" has
        // vowels but at 18% (real words run 30-45%). Only fires on
        // pure-alpha lowercase tokens length ≥ 10 so we don't catch
        // common short words.
        if isSingleWord, trimmed.count >= 10,
           trimmed == trimmed.lowercased(),
           trimmed.allSatisfy({ $0.isLetter }) {
            let vowels = trimmed.filter { "aeiouy".contains($0) }.count
            let ratio = Double(vowels) / Double(trimmed.count)
            if ratio < 0.25 { return true }
        }
        return false
    }
}
