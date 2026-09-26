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

    /// Story-reviewer loop (module .storyReviewerLoop) — record a user's
    /// approve/correct/reject verdict on one reconstructed history beat. The
    /// outline builder already honours the status on the next render (rejected
    /// beats drop, corrected beats lead). No-op when the module is off or the
    /// history repo isn't ready. Returns true when the verdict was written.
    @discardableResult
    public func reviewStoryItem(_ itemID: UUID, _ status: HistoryReviewStatus) async -> Bool {
        guard KnowledgeModuleFlags.isEnabled(.storyReviewerLoop),
              let historyArtifacts else { return false }
        do {
            try await historyArtifacts.setItemReviewStatus(status, forItemID: itemID)
            KalsmritikoshLog.app.info("Story review: item \(itemID.uuidString.prefix(8), privacy: .public) → \(status.rawValue, privacy: .public)")
            return true
        } catch {
            KalsmritikoshLog.app.error("Story review write failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }
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

    /// Owner Q (2026-09-21) — topics are a WHOLE-ARCHIVE derived layer, so they
    /// must be (re)built ONCE the corpus is fully in, not per-file or mid-ingest
    /// (a mid-ingest pass stamps a partial, document-shaped set). The bulk
    /// (re)ingest paths call this at CLEAN completion: collapse duplicate facts,
    /// then rebuild the minimized + AI-resolved topic set. Gated by `.autoTopics`
    /// (same switch the idle pass honours); deterministic core, AI polish only
    /// when a model is available. No-op when the module is off.
    public func autoBuildTopicsAfterIngest() async {
        guard KnowledgeModuleFlags.isEnabled(.autoTopics) else { return }
        // When AI is allowed, WARM the on-device model before the batch. This runs
        // the instant ingest completes, when the Neural Engine may still be cold or
        // contended by the just-finished pass; the first real polish/subject-
        // resolution call could otherwise throw once and silently fall back to a raw
        // spine (every topic then reads deterministic). A tiny warm generate + short
        // retry primes the model so the batch reliably gets AI. Best-effort: if it
        // never warms, we proceed and buildTopics falls back safely as before.
        if FeatureFlags.aiRegimeValue().allowsAI, let caps = capabilities {
            for _ in 0..<3 {
                let spec = CapabilitySpec.reasoning(contextTokens: 256, purpose: "topic.warmup")
                if let provider = try? await caps.resolve(spec), await provider.isAvailable(),
                   (try? await provider.generate(
                        prompt: "Reply with the word: ready",
                        options: GenerationOptions(maxTokens: 4, temperature: 0))) != nil {
                    break
                }
                try? await Task.sleep(nanoseconds: 1_200_000_000)
            }
        }
        _ = await cleanUpLedger()
        if let n = await buildTopics() {
            KalsmritikoshLog.app.info("Post-ingest topic build: \(n, privacy: .public) topics on the full ledger")
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

        // Subject spine (module .subjectSpine) — the trunk of the tree: anchors
        // reach every document that names them, anchors of one matter join one
        // family, and each document is resolved to the family it is about. A
        // fact then groups under that real-world subject instead of its file
        // name. Unresolved facts keep their own label (the old behaviour).
        var spine: SubjectSpine.Resolution?
        var blockOwners: [UUID: [UUID]] = [:]
        if KnowledgeModuleFlags.isEnabled(.subjectSpine), let database {
            let builder = SubjectSpine(database: database)
            do {
                spine = try await builder.run().0
                blockOwners = try await builder.blockOwners()
            } catch {
                KalsmritikoshLog.app.error("Subject spine failed; topics fall back to per-document subjects: \(String(describing: error), privacy: .public)")
            }
        }
        func sourceObjects(of fact: GenericFact) -> [UUID] {
            var seen = Set<UUID>()
            return fact.sourceBlockIDs.flatMap { blockOwners[$0] ?? [] }.filter { seen.insert($0).inserted }
        }

        // Gather all canonical facts, grouped by (resolved) subject label.
        var factsBySubject: [String: [GenericFact]] = [:]
        var offset = 0
        while true {
            let page = (try? await genericFacts.all(offset: offset, pageSize: 1_000)) ?? []
            if page.isEmpty { break }
            for f in page {
                let key = spine?.subjectLabel(anchorID: f.subjectID, currentLabel: f.subjectLabel,
                                              objectIDs: sourceObjects(of: f)) ?? f.subjectLabel
                factsBySubject[key, default: []].append(f)
            }
            offset += page.count
            if page.count < 1_000 { break }
        }
        guard !factsBySubject.isEmpty else { return 0 }
        // Family label → every document resolved to that family, so a matter's
        // topic carries the events and sources of documents that hold no fact.
        var familyObjects: [String: Set<UUID>] = [:]
        if let spine {
            for (root, objects) in spine.objectsOfFamily {
                if let label = spine.label[root] { familyObjects[label, default: []].formUnion(objects) }
            }
        }

        // M2 (module .aiSubjectResolution) — before minimizing, let the on-device
        // model group labels that name the SAME real-world subject (e.g. several
        // copies of one résumé) into ONE canonical subject, so document-shaped
        // topics become real-world-subject topics. Each merge passes a shared-
        // evidence-term guard (no blind merges); facts only move. Off / no model ⇒
        // skipped. Runs BEFORE minimization so the deduped facts feed the merged subject.
        if KnowledgeModuleFlags.isEnabled(.aiSubjectResolution), let caps = capabilities {
            let clusterer = AISubjectClusterer(reason: { prompt in
                let spec = CapabilitySpec.reasoning(contextTokens: 2_000, purpose: "topic.subjectResolution")
                guard let provider = try? await caps.resolve(spec),
                      await provider.isAvailable() else { return nil }
                return try? await provider.generate(
                    prompt: prompt, options: GenerationOptions(maxTokens: 400, temperature: 0.1))
            })
            // Evidence-resolved matters are not offered to the model: their
            // membership is decided by documents naming the identifier, and a
            // model grouping (non-deterministic) folded extra subjects into the
            // patent on one run and not the next.
            let matterLabels = Set(spine?.label.values.map { $0 } ?? [])
            let input = factsBySubject
                .filter { !matterLabels.contains($0.key) }
                .map { TopicConsolidator.SubjectFacts(subject: $0.key, facts: $0.value) }
            let canonical = await clusterer.canonicalize(input)
            if canonical.contains(where: { $0.key != $0.value }) {
                var merged: [String: [GenericFact]] = [:]
                for (label, facts) in factsBySubject {
                    merged[canonical[label] ?? label, default: []].append(contentsOf: facts)
                }
                let before = factsBySubject.count
                factsBySubject = merged
                KalsmritikoshLog.app.info("AI subject resolution: \(before, privacy: .public) → \(merged.count, privacy: .public) subjects")
            }
        }

        // Topic minimization (owner rule, 2026-09-19) — a subject with too little
        // evidence is NOT a real topic. Fold each thin subject into its closest
        // substantive subject so we end up with a few rich, evidence-backed topics
        // instead of hundreds of context-free ones. Deterministic; facts only move,
        // never change. Gated by the .topicMinimization module switch.
        if KnowledgeModuleFlags.isEnabled(.topicMinimization) {
            // Spine-resolved matters are closed: evidence decided their members.
            let matters = Set(spine?.label.values.map { $0 } ?? []).intersection(factsBySubject.keys)
            let consolidated = TopicConsolidator.consolidate(
                factsBySubject.map { TopicConsolidator.SubjectFacts(subject: $0.key, facts: $0.value) },
                closed: matters)
            factsBySubject = Dictionary(
                consolidated.map { ($0.subject, $0.facts) }, uniquingKeysWith: { a, _ in a })
            KalsmritikoshLog.app.info("Topic minimization: \(consolidated.count, privacy: .public) topics kept")
        }

        let allEvents = (try? await events?.recent(limit: 2_000)) ?? []
        let now = Date()

        // U6/C3 — when a reasoning model is available (e.g. Apple Intelligence on),
        // smooth each deterministic spine into prose; the polisher REJECTS any
        // rewrite that drops/adds a number or name, so facts are never changed.
        // No model → the closure returns nil → the spine stands unchanged.
        // M3 (module .topicProsePolish, default on) — gate the AI prose polish.
        let polishEnabled = KnowledgeModuleFlags.isEnabled(.topicProsePolish)
        let caps = capabilities
        let polisher = TopicProsePolisher(reason: { spine in
            guard polishEnabled, let caps else { return nil }
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
        var polishedCount = 0
        var builtSubjects: Set<String> = []
        var eventsByObject: [UUID: [Event]] = [:]
        for (subject, facts) in factsBySubject {
            // The subject's documents: where its facts were read from, plus (for
            // a resolved matter) every document the spine placed in its family.
            var objects: [UUID] = []
            var seenObjects = Set<UUID>()
            for id in facts.flatMap(sourceObjects(of:)) + (familyObjects[subject] ?? []).sorted(by: { $0.uuidString < $1.uuidString })
                where seenObjects.insert(id).inserted { objects.append(id) }
            // Events: those whose title/summary names the subject, plus every
            // event read from one of the subject's documents.
            var subjectEvents = allEvents.filter {
                $0.title.localizedCaseInsensitiveContains(subject)
                || ($0.summary?.localizedCaseInsensitiveContains(subject) ?? false)
            }
            if spine != nil, let events {
                var seenEvents = Set(subjectEvents.map(\.id))
                // A matter's timeline comes from the documents ABOUT it; a report
                // that merely lists its number cites it as a fact but must not
                // pour its own events into the matter's history.
                let eventSources = familyObjects[subject].map { family in
                    objects.filter { family.contains($0) }
                } ?? objects
                for oid in eventSources {
                    if eventsByObject[oid] == nil {
                        eventsByObject[oid] = (try? await events.findBySourceObject(oid)) ?? []
                    }
                    for e in eventsByObject[oid] ?? [] where seenEvents.insert(e.id).inserted {
                        subjectEvents.append(e)
                    }
                }
            }
            let spineTopic = TopicSpineBuilder.build(
                subjectIdentifier: subject, facts: facts, events: subjectEvents,
                factSourceObjectIDs: objects, now: now)
            let polished = await polisher.polish(spine: spineTopic.narrative)
            let didPolish = (polished != spineTopic.narrative)
            if didPolish { polishedCount += 1 }
            let topic: MemoryObject = didPolish ? MemoryObject(
                id: spineTopic.id, subjectKind: spineTopic.subjectKind,
                subjectIdentifier: spineTopic.subjectIdentifier,
                keyEventIDs: spineTopic.keyEventIDs, narrative: polished,
                sourceObjectIDs: spineTopic.sourceObjectIDs, confidence: spineTopic.confidence,
                createdAt: spineTopic.createdAt, updatedAt: spineTopic.updatedAt) : spineTopic
            if (try? await memoryRepo.upsert(topic)) != nil { built += 1 }
            builtSubjects.insert(spineTopic.subjectIdentifier)
        }
        // REPLACE, not append: drop topic rows from earlier builds whose subject
        // isn't in this build (stale document-shaped labels, superseded merges).
        // Scoped to subject_kind='topic', so distilled memories are untouched. This
        // is what makes a rebuild under a new AI regime actually clear the old set
        // instead of accumulating (the live 92→143 growth was this missing step).
        if let removed = try? await memoryRepo.deleteTopicsNotIn(subjectIdentifiers: builtSubjects), removed > 0 {
            KalsmritikoshLog.app.info("Topic build: pruned \(removed, privacy: .public) stale topic(s)")
        }
        lastTopicBuild = (built, polishedCount)
        KalsmritikoshLog.app.info("Topic build: \(built, privacy: .public) topics, \(polishedCount, privacy: .public) AI-polished, from \(factsBySubject.count, privacy: .public) subjects")
        return built
    }

    /// M4 — an objective read of topic-layer quality: total topics, how many are
    /// still document-shaped vs real-world subjects, and how many the AI polished.
    /// Lets the owner see whether AI subject resolution + prose actually improved
    /// the DB. nil when the memory repo isn't ready.
    public func topicScoreboard() async -> TopicScoreboard? {
        guard let memoryRepo else { return nil }
        let topics = (try? await memoryRepo.listAll()) ?? []
        return TopicScoreboard.from(
            identifiers: topics.map(\.subjectIdentifier),
            aiPolished: lastTopicBuild?.polished ?? 0)
    }

    /// L2 (module `.summariesAtIdle`) — build a deterministic extractive summary
    /// of the archive on the idle pass and persist it to `summaries`. Uses the
    /// HeuristicSummarizer (no LLM), so it respects the minimum-LLM contract.
    /// Returns the number of summaries written, or nil if repositories aren't ready.
    @discardableResult
    public func buildSummaries() async -> Int? {
        guard let objects, let summariesRepo else { return nil }
        let summarizer = HeuristicSummarizer(objectsRepo: objects, summariesRepo: summariesRepo)
        do {
            _ = try await summarizer.summarize(
                scope: .knowledgeBase, level: .knowledgeBase, length: .executive)
            KalsmritikoshLog.app.info("Summary build: knowledge-base summary refreshed")
            return 1
        } catch {
            KalsmritikoshLog.app.error("Summary build failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// L3 (module `.historyAtIdle`) — reconstruct and persist per-subject history
    /// for the top entities on the idle pass, filling history_artifacts/chapters/
    /// items. Deterministic (the engine is LLM-free). Reuses persistStoryFromAsk,
    /// which dedups on an unchanged ledger, so repeated passes are cheap and
    /// idempotent. Capped + cancellation-checked so it never dominates idle time.
    /// Returns the number of histories persisted, or nil if repositories aren't ready.
    @discardableResult
    public func buildHistories(limit: Int = 10) async -> Int? {
        guard let entities, let engine = historyEngine, historyArtifacts != nil else { return nil }
        var anchors = (try? await entities.allAnchors(limit: 500)) ?? []
        guard !anchors.isEmpty else { return 0 }
        // Subject spine — ONE history per real-world matter, most-documented
        // first. Without it the first `limit` anchor rows were taken in storage
        // order, so one patent got four histories (application number, patent
        // number under two field names, a truncated copy) while matters beyond
        // the tenth row got none.
        if KnowledgeModuleFlags.isEnabled(.subjectSpine), let database,
           let resolution = try? await SubjectSpine(database: database).run().0 {
            let reachRows = (try? await database.query("""
            SELECT entity_id, COUNT(DISTINCT source_object_id) FROM entity_mentions
            WHERE kind = 'identifierAnchor' GROUP BY entity_id;
            """, [])) ?? []
            var reach: [UUID: Int] = [:]
            for r in reachRows { if let id = r.uuid(0) { reach[id] = Int(r.int(1) ?? 0) } }
            func grade(_ e: Entity) -> Bool { SubjectSpine.subjectGradeFields.contains(SubjectResolver.fieldID(of: e)) }
            // The field a history engine reads best first: an Indian patent's
            // application number is its lifelong identifier (the same value
            // under "patent" produced 2 history items; under "application", 32).
            let fieldPreference = ["applicationnumber", "casenumber", "contractnumber", "registrationnumber", "patentnumber"]
            func pref(_ e: Entity) -> Int { fieldPreference.firstIndex(of: SubjectResolver.fieldID(of: e)) ?? fieldPreference.count }
            var primary: [UUID: Entity] = [:]    // family root → its most-reached anchor
            for a in anchors {
                let root = resolution.familyOf[a.id] ?? a.id
                if let cur = primary[root] {
                    let (ra, rc) = (reach[a.id] ?? 0, reach[cur.id] ?? 0)
                    let better = ra != rc ? ra > rc
                        : (pref(a) != pref(cur) ? pref(a) < pref(cur) : a.id.uuidString < cur.id.uuidString)
                    if better { primary[root] = a }
                } else {
                    primary[root] = a
                }
            }
            func familyReach(_ root: UUID) -> Int { resolution.objectsOfFamily[root]?.count ?? (reach[primary[root]?.id ?? root] ?? 0) }
            let ordered = primary.sorted { l, r in
                let (fl, fr) = (familyReach(l.key), familyReach(r.key))
                return fl != fr ? fl > fr : l.value.id.uuidString < r.value.id.uuidString
            }.map(\.value)
            // Matters first, then the people and organisations the archive is
            // most about (named in ≥ 3 documents), then attribute identifiers
            // (accounts, tax ids) — which used to take every slot.
            let peopleRows = (try? await database.query("""
            SELECT e.id FROM entities e JOIN entity_mentions m ON m.entity_id = e.id
            WHERE e.kind IN ('person', 'organization') AND e.quality_tier IN ('T1', 'T2')
              AND e.merged_into IS NULL AND COALESCE(e.review_status, '') <> 'retired'
            GROUP BY e.id HAVING COUNT(DISTINCT m.source_object_id) >= 3
            ORDER BY COUNT(DISTINCT m.source_object_id) DESC, e.id LIMIT ?;
            """, [.integer(Int64(limit * 4))])) ?? []
            // A full name only: single words ("Hindi", "Ltd", "Chennai", "Sasmal")
            // are mis-typed entities, and their histories came back empty.
            let people = ((try? await entities.findByIDs(peopleRows.compactMap { $0.uuid(0) })) ?? [])
                .filter { e in
                    let words = e.value.split(whereSeparator: { !$0.isLetter && $0 != "." })
                        .filter { $0.filter(\.isLetter).count >= 2 }
                    return words.count >= 2
                }
            let peopleOrder = Dictionary(uniqueKeysWithValues: peopleRows.enumerated().compactMap { i, r in r.uuid(0).map { ($0, i) } })
            anchors = ordered.filter(grade)
                + people.sorted { (peopleOrder[$0.id] ?? 0) < (peopleOrder[$1.id] ?? 0) }
                + ordered.filter { !grade($0) }
        }
        var built = 0
        for entity in anchors.prefix(limit) {
            if Task.isCancelled { break }
            let subject = HistorySubject.forEntity(entity)
            var result: HistoryReconstructionResult?
            for await update in engine.reconstruct(subject: subject, request: HistoryRequest()) {
                if case .verified(let r) = update { result = r }
            }
            guard let result else { continue }
            let narrative = HistoryNarrativeRenderer().render(outline: result.outline)
            if await persistStoryFromAsk(
                result, narrative: narrative, anchorKey: entity.id.uuidString) != nil {
                built += 1
            }
        }
        KalsmritikoshLog.app.info("History build: \(built, privacy: .public) subject histories persisted")
        return built
    }
}
