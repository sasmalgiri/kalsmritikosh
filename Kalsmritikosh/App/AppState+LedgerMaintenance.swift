//
//  AppState+LedgerMaintenance.swift
//  Kalsmritikosh
//
//  Topic-Ledger U3 (owner rule 1) — the owner-invoked one-time cleanup that
//  collapses an already-inflated fact ledger to one canonical row per distinct
//  fact and drops extraction junk. Safe and idempotent: facts are derived
//  projections, so rewriting them never touches primary evidence.
//

import Foundation
import os

extension AppState {
    /// Collapse duplicate facts + drop junk in the live ledger. Returns
    /// (before, after) row counts, or nil if the repository isn't ready.
    @discardableResult
    public func cleanUpLedger() async -> (before: Int, after: Int)? {
        guard let genericFacts else { return nil }
        do {
            let result = try await genericFacts.dedupExisting()
            KalsmritikoshLog.app.info("Ledger cleanup: \(result.before, privacy: .public) → \(result.after, privacy: .public) facts")
            return result
        } catch {
            KalsmritikoshLog.app.error("Ledger cleanup failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Topic-Ledger U5 — build deterministic TOPICS from the (deduped) ledger:
    /// group facts by subject, attach that subject's dated events, and roll each
    /// up into one MemoryObject via TopicSpineBuilder (no model). Returns the
    /// number of topics written, or nil if repositories aren't ready. Owner-
    /// invoked; safe (memory objects are derived, re-buildable).
    @discardableResult
    public func buildTopics() async -> Int? {
        guard let genericFacts, let memoryRepo else { return nil }
        // Gather all canonical facts, grouped by subject label.
        var factsBySubject: [String: [GenericFact]] = [:]
        var offset = 0
        while true {
            let page = (try? await genericFacts.all(offset: offset, pageSize: 1_000)) ?? []
            if page.isEmpty { break }
            for f in page { factsBySubject[f.subjectLabel, default: []].append(f) }
            offset += page.count
            if page.count < 1_000 { break }
        }
        guard !factsBySubject.isEmpty else { return 0 }

        let allEvents = (try? await events?.recent(limit: 2_000)) ?? []
        let now = Date()

        // U6/C3 — when a reasoning model is available (e.g. Apple Intelligence on),
        // smooth each deterministic spine into prose; the polisher REJECTS any
        // rewrite that drops/adds a number or name, so facts are never changed.
        // No model → the closure returns nil → the spine stands unchanged.
        let caps = capabilities
        let polisher = TopicProsePolisher(reason: { spine in
            guard let caps else { return nil }
            let spec = CapabilitySpec.reasoning(contextTokens: 2_000, purpose: "topic.polish")
            guard let provider = try? await caps.resolve(spec), await provider.isAvailable() else { return nil }
            let prompt = """
            Rewrite the following notes as 2–4 clear sentences of connected prose. \
            Do NOT add, remove, or change any name, number, date, amount, or fact — only add \
            connecting words and grammar. Keep it faithful and concise.

            Notes:
            \(spine)
            """
            return try? await provider.generate(
                prompt: prompt, options: GenerationOptions(maxTokens: 300, temperature: 0.2))
        })

        var built = 0
        for (subject, facts) in factsBySubject {
            // Best-effort event attachment: events whose title/summary names the subject.
            let subjectEvents = allEvents.filter {
                $0.title.localizedCaseInsensitiveContains(subject)
                || ($0.summary?.localizedCaseInsensitiveContains(subject) ?? false)
            }
            let spineTopic = TopicSpineBuilder.build(
                subjectIdentifier: subject, facts: facts, events: subjectEvents, now: now)
            let polished = await polisher.polish(spine: spineTopic.narrative)
            let topic: MemoryObject = (polished == spineTopic.narrative) ? spineTopic : MemoryObject(
                id: spineTopic.id, subjectKind: spineTopic.subjectKind,
                subjectIdentifier: spineTopic.subjectIdentifier,
                keyEventIDs: spineTopic.keyEventIDs, narrative: polished,
                sourceObjectIDs: spineTopic.sourceObjectIDs, confidence: spineTopic.confidence,
                createdAt: spineTopic.createdAt, updatedAt: spineTopic.updatedAt)
            if (try? await memoryRepo.upsert(topic)) != nil { built += 1 }
        }
        KalsmritikoshLog.app.info("Topic build: \(built, privacy: .public) topics from \(factsBySubject.count, privacy: .public) subjects")
        return built
    }
}
