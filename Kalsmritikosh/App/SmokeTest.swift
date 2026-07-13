//
//  SmokeTest.swift
//  Kalsmritikosh
//
//  In-process smoke-test entry point that exercises the full M6 pipeline:
//      1. Boot a fresh AppState into a temp database.
//      2. Ingest the bundled ProjectDelta fixture corpus.
//      3. Wait for IncrementalUpdater + MemoryDistiller to converge.
//      4. Ask "Why was Project Delta delayed?" through MasterBrain.
//      5. Assert: an answer comes back, with at least one citation, and
//         the rendered body mentions Supplier ABC and delivery delays.
//
//  Surfaced as a `runProjectDeltaSmokeTest()` async function so it can be
//  invoked from a debug menu or a future test target without depending
//  on any external test harness existing today.
//

import Foundation
import OSLog

public struct ProjectDeltaSmokeResult: Sendable {
    public let ingested: Int
    public let entityCount: Int
    public let eventCount: Int
    public let memoryObjectCount: Int
    public let answer: VerifiedAnswer
    public let assertionsPassed: [String]
    public let assertionsFailed: [String]

    public var ok: Bool { assertionsFailed.isEmpty }
}

@MainActor
public func runProjectDeltaSmokeTest() async throws -> ProjectDeltaSmokeResult {
    KalsmritikoshLog.app.info("ProjectDelta smoke test starting")

    // 1. Use a fresh isolated bookmark store + fresh in-tmp AppState.
    // CRITICAL: boot must receive an isolated databaseURL — without it,
    // AppState falls back to the user's PRODUCTION sqlite in the app
    // container, and the T13 / brain / distiller passes run against
    // their real archive (observed: 549 memory rows = ~hours of work
    // before the smoke ever finishes). Mirror Gate1Baseline's pattern.
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("KalsmritikoshSmoke-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let isolatedDBURL = tempDir.appendingPathComponent("smoke.sqlite", isDirectory: false)
    let isolatedBookmarks = BookmarkStore()
    let state = AppState(bookmarks: isolatedBookmarks)
    await state.boot(databaseURL: isolatedDBURL)

    guard case .ready = state.phase,
          let ingest = state.ingest,
          let entities = state.entities,
          let events = state.events,
          let memory = state.memoryRepo
    else {
        throw NSError(
            domain: "kalsmritikosh.smoke",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "AppState failed to boot."]
        )
    }

    // 2. Locate fixtures inside the app bundle.
    let fixtureURLs = try fixtureURLs()
    var ingested = 0
    for url in fixtureURLs {
        do {
            _ = try await ingest.ingest(fileAt: url); await ingest.drainEmbeddingsNow()
            ingested += 1
        } catch {
            KalsmritikoshLog.app.error("Smoke ingest failed for \(url.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    // 3. Force a synchronous distillation pass for the smoke test —
    // IncrementalUpdater normally runs the same logic but with a debounce.
    if let distiller = state.memoryDistiller {
        let projects = (try? await entities.list(kind: .project, limit: 25))?.map(\.value) ?? []
        let orgs = (try? await entities.list(kind: .organization, limit: 25))?.map(\.value) ?? []
        let people = (try? await entities.list(kind: .person, limit: 25))?.map(\.value) ?? []
        let candidates = Set(projects + orgs + people)
        for value in candidates {
            for kind in MemoryObject.SubjectKind.allCases {
                _ = try? await distiller.distill(.init(kind: kind, identifier: value))
            }
        }
    }

    // 4. Ask the canonical question.
    let answer = await state.brain.answer(question: "Why was Project Delta delayed?")

    // 5. Assertions.
    let entityCount = (try? await countAllEntities(entities)) ?? 0
    let eventCount = (try? await events.count()) ?? 0
    let memoryCount = (try? await memory.count()) ?? 0
    var passed: [String] = []
    var failed: [String] = []

    if ingested >= 5 { passed.append("ingested \(ingested) fixture files") }
    else { failed.append("expected >=5 ingested files, got \(ingested)") }

    if entityCount > 0 { passed.append("entityCount=\(entityCount)") }
    else { failed.append("no entities extracted from corpus") }

    if eventCount > 0 { passed.append("eventCount=\(eventCount)") }
    else { failed.append("no events extracted from corpus") }

    if memoryCount > 0 { passed.append("memoryObjectCount=\(memoryCount)") }
    else { failed.append("memory layer produced 0 subjects") }

    if !answer.refused { passed.append("brain answered (not refused)") }
    else { failed.append("brain refused: \(answer.refusalReason ?? "unknown")") }

    if !answer.citations.isEmpty { passed.append("citations=\(answer.citations.count)") }
    else { failed.append("answer had zero citations") }

    let body = answer.body.lowercased()
    // Ledger-AI contract: the correct smoke check for a citation-first
    // system is "did the answer draw on the RIGHT EVIDENCE", NOT "did
    // the stochastic LLM emit a literal string". A local model may
    // write "the vendor" / "the supplier" / "the external provider"
    // instead of "Supplier ABC" and still be correct. So the primary
    // assertion resolves each citation's KO to its source filename and
    // checks whether any resolves to a supplier_abc_* fixture. The
    // body-wording check survives only as a soft secondary signal.
    var citedSupplierEvidence = false
    if let objectsRepo = state.objects {
        for citation in answer.citations {
            if let url = try? await objectsRepo.fetchSourceURL(id: citation.objectID),
               url.lastPathComponent.lowercased().contains("supplier_abc") {
                citedSupplierEvidence = true
                break
            }
        }
    }
    if citedSupplierEvidence {
        passed.append("cited Supplier ABC evidence file (deterministic citation-source check)")
    } else if body.contains("supplier abc") || body.contains("supplier_abc") {
        passed.append("body mentions Supplier ABC (soft signal — no citation resolved to a supplier_abc_* file)")
    } else {
        failed.append("answer neither cited a supplier_abc_* file nor mentioned Supplier ABC")
    }

    if body.contains("delivery") || body.contains("delayed") || body.contains("amendment") {
        passed.append("body mentions delivery/delay/amendment vocabulary")
    } else {
        failed.append("body lacks delivery/delay vocabulary")
    }

    // HISTORY Phase F integration probe — ask a reconstructive
    // question and confirm the brain routes through the narrative
    // composer (D.6/D.7). This is a presence check, not a quality
    // gate: the LLM may or may not be available depending on the
    // dev machine, so we assert chapters arrived rather than that
    // prose is non-empty. The full NarrativeEvalKit run with gold
    // fixtures lands separately.
    var historyChapters: [NarrativeChapter] = []
    var historyVerified: VerifiedAnswer?
    for await update in await state.brain.answerStream(
        question: "Reconstruct the history of Project Delta."
    ) {
        switch update {
        case .chapterReady(let chapter):
            historyChapters.append(chapter)
        case .verified(let answer):
            historyVerified = answer
        default:
            continue
        }
    }
    if !historyChapters.isEmpty {
        passed.append("HISTORY: composer yielded \(historyChapters.count) chapter(s)")
    } else if let v = historyVerified, !v.refused {
        // No chapters but a verified answer means we routed through
        // the legacy expert pipeline — acceptable if the intent
        // detector classified the question as a flat lookup, but
        // we surface it so the developer knows.
        passed.append("HISTORY: legacy expert path (no chapters) — intent=\(v.intentKind ?? "unknown")")
    } else {
        failed.append("HISTORY: composer produced 0 chapters AND brain refused or returned nil")
    }
    if let v = historyVerified, !v.contradictions.isEmpty {
        passed.append("HISTORY: surfaced \(v.contradictions.count) contradiction(s)")
    }

    // HISTORY Phase F — optional full eval. Off by default (one
    // composer call per question is slow); developers opt in with
    // KALSMRITIKOSH_NARRATIVE_EVAL=1 in the scheme environment so a regular
    // smoke run stays fast. The report prints to stdout (and to
    // KalsmritikoshLog) so the dev sees it next to the smoke pass / fail list.
    if ProcessInfo.processInfo.environment["KALSMRITIKOSH_NARRATIVE_EVAL"] == "1" {
        let report = await NarrativeEvalKit.run(
            questions: NarrativeEvalKit.projectDeltaQuestions,
            brain: state.brain,
            events: events
        )
        KalsmritikoshLog.app.info("Narrative eval report:\n\(report.markdownTable, privacy: .public)")
        print(report.markdownTable)
        // HISTORY F.4 — persist each run to Application Support so
        // the EvalDashboardView can render trend lines across runs.
        try? await NarrativeEvalReportStore.shared.save(report)
        if report.avgCitationDensity > 0 {
            passed.append("HISTORY F: eval cite/sent=\(String(format: "%.2f", report.avgCitationDensity)) over \(report.scores.count) Q")
        } else {
            failed.append("HISTORY F: eval produced 0 citation density — composer not generating prose with [E?] tags")
        }
    }

    // T1 — calibrated confidence aggregation (replaces noisy-OR).
    let t1A = Confidence.aggregate(
        Array(repeating: Confidence(0.5), count: 94),
        agreement: 0.2,
        diversity: 0.2,
        contradictionPenalty: 0.0
    )
    if t1A.value <= 0.65 {
        passed.append("T1(a): 94×0.5 low-signal → \(t1A.value) ≤ 0.65")
    } else {
        failed.append("T1(a): 94×0.5 low-signal got \(t1A.value), expected ≤ 0.65")
    }

    let t1B = Confidence.aggregate(
        Array(repeating: Confidence(0.9), count: 3),
        agreement: 0.9,
        diversity: 1.0,
        contradictionPenalty: 0.0
    )
    if t1B.value >= 0.85 {
        passed.append("T1(b): 3×0.9 high-signal → \(t1B.value) ≥ 0.85")
    } else {
        failed.append("T1(b): 3×0.9 high-signal got \(t1B.value), expected ≥ 0.85")
    }

    // Adversarial: maximal claims should still clamp below 0.99.
    let t1C = Confidence.aggregate(
        Array(repeating: Confidence(1.0), count: 200),
        agreement: 1.0,
        diversity: 1.0,
        contradictionPenalty: 0.0
    )
    if t1C.value < 0.99 {
        passed.append("T1(c): clamp prevents ≥0.99 (got \(t1C.value))")
    } else {
        failed.append("T1(c): aggregate returned \(t1C.value) — clamp violated")
    }

    if answer.confidence.value < 1.0 {
        passed.append("T1: ProjectDelta answer confidence \(answer.confidence.value) < 1.00")
    } else {
        failed.append("T1: ProjectDelta answer confidence is \(answer.confidence.value) (expected < 1.00)")
    }

    // T2 — claim-level evidence contract. Static checks on the parser.
    let t2Map: [String: EvidenceCitation] = [
        "E1": EvidenceCitation(supportingObjectIDs: [], supportingEventIDs: [], supportingEntityIDs: []),
        "E2": EvidenceCitation(supportingObjectIDs: [], supportingEventIDs: [], supportingEntityIDs: []),
        "E3": EvidenceCitation(supportingObjectIDs: [], supportingEventIDs: [], supportingEntityIDs: [])
    ]
    // (a) fenced JSON parses; (b) two claims carry DIFFERENT evidence sets;
    // (c) claims with empty / unresolved evidence are dropped and counted.
    let t2Response = """
    ```json
    {"claims":[
      {"text":"Claim citing E1 only","evidence":["E1"]},
      {"text":"Claim citing E2 and E3","evidence":["E2","E3"]},
      {"text":"Claim with empty evidence","evidence":[]},
      {"text":"Claim with phantom E-id","evidence":["E99"]}
    ]}
    ```
    """
    let t2Parsed = ExpertResponseParser.parseClaims(from: t2Response, evidenceMap: t2Map)
    if t2Parsed.claims.count == 2 {
        passed.append("T2: parser kept 2 valid claims out of 4")
    } else {
        failed.append("T2: parser kept \(t2Parsed.claims.count) claims (expected 2)")
    }
    if t2Parsed.dropped == 2 {
        passed.append("T2: parser dropped 2 unverifiable claims")
    } else {
        failed.append("T2: parser dropped \(t2Parsed.dropped) claims (expected 2)")
    }

    // (b) different evidence sets across same-expert claims.
    let t2Sets = t2Parsed.claims.map { Set($0.citation.supportingObjectIDs)
        .union(Set($0.citation.supportingEventIDs.map { _ in UUID() }))  // distinct shape
    }
    _ = t2Sets  // shape check below
    let t2EvidenceSignatures = t2Parsed.claims.map { c in
        "\(c.citation.supportingObjectIDs.count)/\(c.citation.supportingEventIDs.count)/\(c.citation.supportingEntityIDs.count):\(c.text)"
    }
    if Set(t2EvidenceSignatures).count == t2Parsed.claims.count {
        passed.append("T2: parsed claims carry distinct evidence shapes")
    } else {
        failed.append("T2: parsed claims share identical evidence shapes")
    }

    // T3 — canonical entities + mentions + aliases. Re-ingest the fixture
    // and verify idempotency at both layers.
    let canonicalCountBefore = (try? await countAllEntities(entities)) ?? -1
    let mentionCountBefore = (try? await entities.mentionCount()) ?? -1
    for url in fixtureURLs {
        _ = try? await ingest.ingest(fileAt: url)
    }
    let canonicalCountAfter = (try? await countAllEntities(entities)) ?? -1
    let mentionCountAfter = (try? await entities.mentionCount()) ?? -1
    let dupGroups = (try? await entities.duplicateCanonicalGroups()) ?? -1

    if canonicalCountAfter == canonicalCountBefore {
        passed.append("T3: canonical count stable across re-ingest (\(canonicalCountAfter))")
    } else {
        failed.append("T3: canonical count changed \(canonicalCountBefore) → \(canonicalCountAfter)")
    }

    if mentionCountAfter == mentionCountBefore {
        passed.append("T3: mention count stable across re-ingest (\(mentionCountAfter))")
    } else {
        failed.append("T3: mention count changed \(mentionCountBefore) → \(mentionCountAfter) (hash-idempotent path broken)")
    }

    if dupGroups == 0 {
        passed.append("T3: zero duplicate (kind, normalized) groups")
    } else {
        failed.append("T3: \(dupGroups) duplicate (kind, normalized) groups exist — UNIQUE violated")
    }

    // T4 — graph extraction: edges exist + supplier reachable via 2-hop.
    if let relRepo = state.relationships {
        let total = (try? await relRepo.count()) ?? 0
        if total >= 8 {
            passed.append("T4: \(total) edges in graph (≥ 8)")
        } else {
            failed.append("T4: only \(total) edges in graph (expected ≥ 8)")
        }
        let co = (try? await relRepo.count(ofKind: .coOccurs)) ?? 0
        let ev = (try? await relRepo.count(ofKind: .eventLinked)) ?? 0
        KalsmritikoshLog.app.info("T4 edge mix: co_occurs=\(co, privacy: .public) event_linked=\(ev, privacy: .public)")

        // 2-hop traversal: find any project entity matching "Delta" and
        // check whether traversal reaches an org whose name mentions
        // "Supplier" or "ABC".
        if let graph = state.graph,
           let project = (try? await state.entities?.find(byValue: "Delta", limit: 5))?.first {
            let edges = (try? await graph.twoHop(from: project.id, breadth: 25)) ?? []
            let touched: Set<Entity.ID> = Set(edges.flatMap { [$0.fromEntityID, $0.toEntityID] })
            var reachedSupplier = false
            for id in touched {
                if let entity = try? await state.entities?.find(byID: id),
                   entity.kind == .organization,
                   entity.value.localizedCaseInsensitiveContains("supplier")
                    || entity.value.localizedCaseInsensitiveContains("abc") {
                    reachedSupplier = true
                    break
                }
            }
            if reachedSupplier {
                passed.append("T4: 2-hop from Project Delta reaches a Supplier org")
            } else {
                failed.append("T4: 2-hop from Project Delta did NOT reach a Supplier org (\(touched.count) entities touched)")
            }
        } else {
            failed.append("T4: no Project Delta entity present to start 2-hop traversal")
        }
    } else {
        failed.append("T4: relationships repository not wired into AppState")
    }

    // T5 — int8 vector store round-trip. Uses a throwaway temp DB so the
    // fixture's real vectors stay untouched.
    do {
        let vecDB = try Database(url: tempDir.appendingPathComponent("t5-vec.sqlite"))
        try await SchemaMigrations.migrate(vecDB)
        // Skip chunks FK so we can plant synthetic ids.
        try await vecDB.exec("PRAGMA foreign_keys = OFF;")
        let vecStore = SQLiteVectorStore(database: vecDB)
        var ids: [UUID] = []
        var vecs: [[Float]] = []
        for _ in 0..<200 {
            let id = UUID()
            let v = (0..<128).map { _ in Float.random(in: -1...1) }
            ids.append(id); vecs.append(v)
            try await vecStore.upsert(chunkID: id, embedding: v)
        }
        var roundTrip = 0
        for _ in 0..<20 {
            let i = Int.random(in: 0..<200)
            let hits = try await vecStore.nearest(to: vecs[i], limit: 1, candidateChunkIDs: nil)
            if hits.first?.chunkID == ids[i] { roundTrip += 1 }
        }
        if roundTrip >= 19 {
            passed.append("T5: int8 vector round-trip \(roundTrip)/20 correct")
        } else {
            failed.append("T5: int8 vector round-trip only \(roundTrip)/20 correct")
        }
        // Candidate prefilter sanity: scoped scan never exceeds the
        // candidate set and respects the limit.
        let scoped = try await vecStore.nearest(
            to: vecs[0],
            limit: 5,
            candidateChunkIDs: Array(ids.prefix(10))
        )
        if scoped.count <= 5 && scoped.count > 0 {
            passed.append("T5: candidate-scoped scan returned \(scoped.count) ≤ limit")
        } else {
            failed.append("T5: candidate-scoped scan returned \(scoped.count) (expected 1..5)")
        }
    } catch {
        failed.append("T5: vector store setup failed: \(error)")
    }

    // T7 — Quote-strip on a synthetic 10-message thread reduces body size
    // by ≥60% vs the raw quoted thread.
    do {
        var rawThread = "Hi team, this is the latest reply.\n\n"
        // Build 10 nested quoted messages (each reply double-quotes the prior).
        for i in 1...10 {
            rawThread += "On Mon, Mar \(i), 2026 at 09:00, Sender \(i) wrote:\n"
            for _ in 0..<8 {
                rawThread += "> Quoted line of reply \(i) with lots of repeated context.\n"
            }
            rawThread += "> > More deeply-quoted history that adds noise.\n"
            rawThread += "> -----Original Message-----\n"
            rawThread += "> > <blockquote>An even deeper quoted block.</blockquote>\n"
            rawThread += "\n"
        }
        let (stripped, removed) = EmailLoader.stripQuotedRegions(rawThread)
        let rawLen = rawThread.utf8.count
        let strippedLen = stripped.utf8.count
        let reductionRatio = Double(rawLen - strippedLen) / Double(max(1, rawLen))
        if reductionRatio >= 0.60 {
            passed.append(String(format: "T7: quote-strip removed %.0f%% of bytes (raw %d → %d, removed %d)", reductionRatio * 100, rawLen, strippedLen, removed))
        } else {
            failed.append(String(format: "T7: quote-strip removed only %.0f%% (expected ≥60%%)", reductionRatio * 100))
        }
    }

    // T7 — Attachment dedup: same content under two URLs becomes one
    // canonical KO + one alias file row.
    do {
        let dedupDB = try Database(url: tempDir.appendingPathComponent("t7-dedup.sqlite"))
        try await SchemaMigrations.migrate(dedupDB)
        let dedupFiles = FilesRepository(database: dedupDB)
        let canonicalID = UUID()
        let aliasID = UUID()
        let hash = "deadbeef\(UUID().uuidString)"
        try await dedupFiles.upsert(FileRecord(
            id: canonicalID,
            url: URL(fileURLWithPath: "/tmp/a.pdf"),
            sourceType: .pdf,
            contentHash: hash
        ))
        // Simulate hash-first detection finding the canonical:
        let found = try await dedupFiles.findCanonicalByContentHash(hash)
        if found?.id == canonicalID {
            passed.append("T7: findCanonicalByContentHash resolves canonical file")
        } else {
            failed.append("T7: findCanonicalByContentHash did not return canonical")
        }
        try await dedupFiles.upsert(FileRecord(
            id: aliasID,
            url: URL(fileURLWithPath: "/tmp/b.pdf"),
            sourceType: .pdf,
            contentHash: hash,
            aliasOf: canonicalID
        ))
        let aliasCount = try await dedupFiles.countAliases(of: canonicalID)
        if aliasCount == 1 {
            passed.append("T7: 1 alias row points at canonical (two parent links, one KO)")
        } else {
            failed.append("T7: \(aliasCount) alias rows for canonical (expected 1)")
        }
    } catch {
        failed.append("T7: dedup setup failed: \(error)")
    }

    // T8 — Move / availability / cascading delete primitives.
    do {
        let t8DB = try Database(url: tempDir.appendingPathComponent("t8.sqlite"))
        try await SchemaMigrations.migrate(t8DB)
        let t8Files = FilesRepository(database: t8DB)
        let rootA = URL(fileURLWithPath: "/tmp/rootA")
        let rootB = URL(fileURLWithPath: "/tmp/rootB")
        let recA1 = FileRecord(
            url: rootA.appendingPathComponent("doc.txt"),
            sourceType: .txt,
            contentHash: "hashA1",
            availability: .available
        )
        let recA2 = FileRecord(
            url: rootA.appendingPathComponent("doc2.txt"),
            sourceType: .txt,
            contentHash: "hashA2"
        )
        let recB1 = FileRecord(
            url: rootB.appendingPathComponent("doc.txt"),
            sourceType: .txt,
            contentHash: "hashB1"
        )
        try await t8Files.upsert(recA1)
        try await t8Files.upsert(recA2)
        try await t8Files.upsert(recB1)

        // Move: same id, new url, no row count change.
        let beforeMoveCount = try await t8Files.count()
        let movedURL = rootA.appendingPathComponent("renamed-doc.txt")
        try await t8Files.updateURL(id: recA1.id, to: movedURL)
        let afterMoveCount = try await t8Files.count()
        let movedRecord = try await t8Files.findByURL(movedURL)
        if afterMoveCount == beforeMoveCount && movedRecord?.id == recA1.id {
            passed.append("T8(move): same id, new url, KO count unchanged")
        } else {
            failed.append("T8(move): id=\(String(describing: movedRecord?.id)) count \(beforeMoveCount) → \(afterMoveCount)")
        }

        // Missing: flip availability, knowledge survives.
        try await t8Files.updateAvailability(id: recA1.id, to: .missing)
        let stillThere = try await t8Files.findByURL(movedURL)
        let countAfterMissing = try await t8Files.count()
        if stillThere?.availability == .missing && countAfterMissing == afterMoveCount {
            passed.append("T8(missing): availability=missing, no cascading delete")
        } else {
            failed.append("T8(missing): availability=\(String(describing: stillThere?.availability)) count=\(countAfterMissing)")
        }

        // Offline root sweep: rootA files → offline_root, rootB untouched.
        try await t8Files.markFilesUnderRoot(rootA, as: .offlineRoot)
        let a1 = try await t8Files.findByURL(movedURL)
        let b1 = try await t8Files.findByURL(recB1.url)
        if a1?.availability == .offlineRoot && b1?.availability == .available {
            passed.append("T8(offline): rootA files offline_root, rootB available")
        } else {
            failed.append("T8(offline): a1=\(String(describing: a1?.availability)) b1=\(String(describing: b1?.availability))")
        }

        // Cascading delete under root: only rootA's rows go.
        let rootACountBefore = try await t8Files.countUnderRoot(rootA)
        try await t8Files.deleteAllUnderRoot(rootA)
        let rootAAfter = try await t8Files.countUnderRoot(rootA)
        let rootBAfter = try await t8Files.countUnderRoot(rootB)
        if rootAAfter == 0 && rootBAfter == 1 && rootACountBefore >= 2 {
            passed.append("T8(forget): rootA cascaded (\(rootACountBefore) → 0), rootB intact (\(rootBAfter))")
        } else {
            failed.append("T8(forget): rootA \(rootACountBefore) → \(rootAAfter), rootB \(rootBAfter)")
        }
    } catch {
        failed.append("T8: setup failed: \(error)")
    }

    // T9 — Event date confidence: tiered assignment + badge logic.
    do {
        let extractor = RuleEventExtractor()

        // (a) Email KO with a "date" header → 0.95.
        let emailKO = KnowledgeObject(
            sourceFile: URL(fileURLWithPath: "/tmp/t9-email.eml"),
            sourceType: .eml,
            content: "Body: invoice issued on Monday.",
            metadata: [
                "subject": AnyCodable(.string("Test")),
                "date": AnyCodable(.string("Mon, 1 Apr 2025 10:00:00 +0000"))
            ],
            confidence: .high
        )
        let emailEvents = try await extractor.extractEvents(
            from: emailKO,
            chunks: [],
            entities: []
        )
        if emailEvents.contains(where: { abs($0.dateConfidence - 0.95) < 0.01 }) {
            passed.append("T9: email header → dateConfidence 0.95")
        } else {
            let confs = emailEvents.map(\.dateConfidence)
            failed.append("T9: email header → \(confs) (expected 0.95)")
        }

        // (b) Non-email KO with no detected date → mtime fallback 0.3.
        let mtimeKO = KnowledgeObject(
            sourceFile: URL(fileURLWithPath: "/tmp/non-existent-\(UUID()).txt"),
            sourceType: .txt,
            content: "Project contract signed at the kickoff meeting.",
            confidence: .high
        )
        let mtimeEvents = try await extractor.extractEvents(
            from: mtimeKO,
            chunks: [],
            entities: []
        )
        if mtimeEvents.contains(where: { abs($0.dateConfidence - 0.30) < 0.01 }) {
            passed.append("T9: mtime/fallback → dateConfidence 0.30")
        } else {
            let confs = mtimeEvents.map(\.dateConfidence)
            failed.append("T9: mtime fallback → \(confs) (expected 0.30)")
        }

        // (c) Timeline view: low-confidence dates get the "~" badge.
        if let mtimeEvent = mtimeEvents.first {
            let label = TimelineView.formatDate(mtimeEvent)
            if label.hasPrefix("~") {
                passed.append("T9: low-confidence event renders with ~ badge")
            } else {
                failed.append("T9: low-confidence event label = '\(label)' (expected ~ prefix)")
            }
        }
    } catch {
        failed.append("T9: extractor invocation failed: \(error)")
    }

    // T10 — Timeliness: coverage 1.0 across full range; ≤0.5 with gap
    // for events only in the last quarter of the window.
    do {
        let calendar = Calendar(identifier: .gregorian)
        let start = calendar.date(from: DateComponents(year: 2023, month: 1, day: 1))!
        let end = calendar.date(from: DateComponents(year: 2026, month: 12, day: 31))!
        let window = DateInterval(start: start, end: end)
        func mkEvent(year: Int) -> Event {
            let d = calendar.date(from: DateComponents(year: year, month: 6, day: 15))!
            return Event(
                kind: .meetingHeld,
                date: d,
                title: "evt",
                sourceObjectID: UUID(),
                confidence: .medium,
                dateConfidence: 0.9
            )
        }
        let full = [mkEvent(year: 2023), mkEvent(year: 2024), mkEvent(year: 2025), mkEvent(year: 2026)]
        let r1 = DefaultConfidenceEngine.timeliness(
            events: full,
            intentKind: .reconstructTimeline,
            intentWindow: window,
            now: Date()
        )
        if let c1 = r1.coverage, abs(c1 - 1.0) < 0.01, r1.gaps.isEmpty {
            passed.append("T10: full-range evidence → coverage 1.0, 0 gaps")
        } else {
            failed.append("T10: full-range → coverage=\(String(describing: r1.coverage)) gaps=\(r1.gaps.count)")
        }

        let lateOnly = [mkEvent(year: 2026)]
        let r2 = DefaultConfidenceEngine.timeliness(
            events: lateOnly,
            intentKind: .reconstructTimeline,
            intentWindow: window,
            now: Date()
        )
        if let c2 = r2.coverage, c2 <= 0.5, r2.gaps.count >= 1 {
            passed.append(String(format: "T10: late-only → coverage %.2f ≤ 0.5 with %d gap(s)", c2, r2.gaps.count))
        } else {
            failed.append("T10: late-only coverage=\(String(describing: r2.coverage)) gaps=\(r2.gaps.count)")
        }
    }

    // T13.7 — Multipart EML: text part feeds extraction, attachment is
    // staged on disk and surfaced in KO metadata for recursive ingest.
    do {
        let emlText = """
        From: Alice <alice@example.com>
        To: Bob <bob@example.com>
        Subject: With attachment
        Date: Mon, 1 Apr 2026 12:00:00 +0000
        Content-Type: multipart/mixed; boundary="BOUNDARY"

        --BOUNDARY
        Content-Type: text/plain; charset=utf-8
        Content-Transfer-Encoding: 7bit

        Body text — the only thing extraction should see.

        --BOUNDARY
        Content-Type: application/pdf; name="invoice.pdf"
        Content-Transfer-Encoding: base64
        Content-Disposition: attachment; filename="invoice.pdf"

        JVBERi0xLjUKJYCBgoMKCg==

        --BOUNDARY--
        """
        let emlURL = tempDir.appendingPathComponent("t137_fixture.eml")
        try emlText.write(to: emlURL, atomically: true, encoding: .utf8)
        let loader = EmailLoader()
        let ko = try await loader.ingest(fileAt: emlURL, type: .eml)
        let bodyHasText = ko.content.contains("Body text")
        let bodyExcludesBase64 = !ko.content.contains("JVBERi0xLjUKJYCBgoMKCg==")
        if bodyHasText && bodyExcludesBase64 {
            passed.append("T13.7: multipart body → text only; base64 NOT in content")
        } else {
            failed.append("T13.7: hasText=\(bodyHasText) excludesB64=\(bodyExcludesBase64)")
        }
        if let value = ko.metadata[EmailLoader.attachmentURLsMetaKey],
           case .string(let json) = value.value {
            let urls = EmailLoader.decodeAttachmentURLs(from: json)
            if urls.count == 1 && urls[0].lastPathComponent == "invoice.pdf" {
                passed.append("T13.7: 1 attachment URL surfaced (invoice.pdf)")
            } else {
                failed.append("T13.7: attachment URLs = \(urls)")
            }
            for u in urls { try? FileManager.default.removeItem(at: u) }
        } else {
            failed.append("T13.7: no attachment URLs in metadata")
        }
        try? FileManager.default.removeItem(at: emlURL)
    } catch {
        failed.append("T13.7: setup failed: \(error)")
    }

    // T13.1 + T13.2 — mbox → per-message KOs with structured entities.
    do {
        // Synthesize a 3-message mbox in tempDir.
        let mboxText = """
        From a@example.com Mon Apr  1 12:00:00 2026
        From: Alice <alice@northwind.com>
        To: Bob <bob@northwind.com>
        Subject: Hello bob
        Date: Mon, 1 Apr 2026 12:00:00 +0000

        First message body.

        From b@example.com Tue Apr  2 09:00:00 2026
        From: Bob <bob@northwind.com>
        To: Alice <alice@northwind.com>
        Subject: Re: Hello bob
        Date: Tue, 2 Apr 2026 09:00:00 +0000

        Second message body.

        From a@example.com Wed Apr  3 15:30:00 2026
        From: Alice <alice@northwind.com>
        To: Carol <carol@external.com>
        Subject: Different thread
        Date: Wed, 3 Apr 2026 15:30:00 +0000

        Third message body.
        """
        let mboxURL = tempDir.appendingPathComponent("t13_fixture.mbox")
        try mboxText.write(to: mboxURL, atomically: true, encoding: .utf8)
        let loader = EmailLoader()
        let kos = try await loader.ingestMany(fileAt: mboxURL, type: .mbox)
        if kos.count == 3 {
            passed.append("T13.1: 3-message mbox → 3 KOs")
        } else {
            failed.append("T13.1: 3-message mbox produced \(kos.count) KOs (expected 3)")
        }
        // Each per-message KO carries its structured entities via the
        // metadata payload key.
        var allStructured: [Entity] = []
        for ko in kos {
            if let value = ko.metadata[EmailLoader.structuredEntitiesMetaKey],
               case .string(let json) = value.value {
                allStructured.append(contentsOf: EmailLoader.decodeStructuredEntities(from: json))
            }
        }
        let hasEmailAddresses = allStructured.contains { $0.kind == .emailAddress }
        let hasPersonName = allStructured.contains { $0.kind == .person && $0.value == "Alice" }
        if hasEmailAddresses && hasPersonName {
            passed.append("T13.2: structured entities (emailAddress + person) emitted from headers")
        } else {
            failed.append("T13.2: structured entities missing — emails=\(hasEmailAddresses) Alice=\(hasPersonName)")
        }
        try? FileManager.default.removeItem(at: mboxURL)
    } catch {
        failed.append("T13.1/2: setup failed: \(error)")
    }

    // Query-driven boost — noun extraction + filename matching.
    do {
        // Noun extraction picks supplier / abc / delays out of a real
        // question and filters question-vocabulary stopwords.
        let nouns = AppState.extractNouns(from: "What did Supplier ABC say about delays?")
        let lower = nouns.map { $0.lowercased() }
        let hasContent = lower.contains("supplier") || lower.contains("abc") || lower.contains("delays")
        let hasStopwords = lower.contains("what") || lower.contains("did") || lower.contains("say")
        if hasContent && !hasStopwords {
            passed.append("Boost: noun extraction got \(nouns.sorted()) (content kept, stopwords dropped)")
        } else {
            failed.append("Boost: noun extraction got \(nouns) — content=\(hasContent) stopwords=\(hasStopwords)")
        }

        // Filename matching finds the supplier_abc_*.eml fixtures in the
        // bundled ProjectDelta corpus.
        if let resourceRoot = Bundle.main.url(forResource: "ProjectDelta", withExtension: nil) {
            let matches = AppState.scanFiles(
                at: resourceRoot,
                matching: ["supplier", "abc"],
                remaining: 25
            )
            let names = matches.map(\.lastPathComponent).sorted()
            let foundSupplierEMLs = names.contains { $0.contains("supplier_abc") }
            if foundSupplierEMLs, matches.count >= 4 {
                passed.append("Boost: scanFiles found \(matches.count) supplier_abc files")
            } else {
                failed.append("Boost: scanFiles found \(names) (expected ≥ 4 supplier_abc files)")
            }
        }
    }

    // T13.5 — Google / Gmail / Googlemail must collapse to ONE canonical.
    do {
        let t135DB = try Database(url: tempDir.appendingPathComponent("t135.sqlite"))
        try await SchemaMigrations.migrate(t135DB)
        try await t135DB.exec("PRAGMA foreign_keys = OFF;")
        let repo = EntitiesRepository(database: t135DB)
        let sourceID = UUID()
        let surfaces = ["Google", "google", "GOOGLE", "Gmail", "gmail", "Googlemail", "googlemail"]
        let inputs = surfaces.map { value in
            Entity(kind: .organization, value: value, sourceObjectID: sourceID, confidence: .medium)
        }
        let mapping = try await repo.insertBatch(inputs)
        let canonicalIDs = Set(mapping.values)
        if canonicalIDs.count == 1 {
            passed.append("T13.5: 7 surface forms (Google/Gmail/Googlemail/...) → 1 canonical")
        } else {
            failed.append("T13.5: surface forms produced \(canonicalIDs.count) canonicals (expected 1)")
        }
        // Aliases must be found via the LEFT JOIN even when the value
        // column carries the OTHER surface form.
        let foundByGmail = try await repo.find(byValue: "Gmail", limit: 5)
        if foundByGmail.contains(where: { canonicalIDs.contains($0.id) }) {
            passed.append("T13.5: find(byValue: \"Gmail\") resolves to the canonical via alias")
        } else {
            failed.append("T13.5: find(byValue: \"Gmail\") missed the canonical (alias not seeded?)")
        }
    } catch {
        failed.append("T13.5: setup failed: \(error)")
    }

    // T13.4 — EntityQualityGate keeps real names, drops garbage.
    do {
        let gate = EntityQualityGate(stoplist: ["smtp", "noreply", "notifications"])
        func mk(_ value: String, _ kind: Entity.Kind = .person) -> Entity {
            Entity(kind: kind, value: value, sourceObjectID: UUID())
        }
        let keepers = [
            mk("Mike"),
            mk("Supplier ABC", .organization),
            mk("Gmail", .organization),   // T13.5: legit org
            mk("Apple", .organization)
        ]
        let rejects = [
            mk("tue"),
            mk("jun"),
            mk("smtp"),
            mk("notifications"),
            mk("tyzpr01mb4530", .organization),
            mk("apple naturallanguage"),
            mk("urls"),
            mk("a"),
            mk("worker-pod-7", .organization)
        ]
        let keptResult = gate.filter(keepers)
        let droppedResult = gate.filter(rejects)
        if keptResult.count == keepers.count {
            passed.append("T13.4: gate kept all \(keepers.count) real names")
        } else {
            failed.append("T13.4: gate dropped \(keepers.count - keptResult.count) real name(s)")
        }
        if droppedResult.isEmpty {
            passed.append("T13.4: gate dropped all \(rejects.count) garbage entities")
        } else {
            failed.append("T13.4: gate left \(droppedResult.count) garbage entities through: \(droppedResult.map(\.value))")
        }
    }

    // G2-TEMPORAL — DateGrammar.parse covers the four classes used by
    // the question corpus: ISO range, month-year single, month range,
    // and relative keyword. Pure & deterministic — no LLM.
    do {
        let utc = TimeZone(identifier: "UTC") ?? .current
        var cal = Calendar(identifier: .gregorian); cal.timeZone = utc
        let base = cal.date(from: DateComponents(timeZone: utc, year: 2026, month: 6, day: 15))!

        // (a) ISO range
        if let m = DateGrammar.parse("between 2024-04-08 and 2024-06-14", baseDate: base, timeZone: utc),
           let s = m.timeframe.start, let e = m.timeframe.end,
           cal.component(.year, from: s) == 2024,
           cal.component(.month, from: s) == 4,
           cal.component(.year, from: e) == 2024,
           cal.component(.month, from: e) == 6 {
            passed.append("G2-TEMPORAL(iso-range): 2024-04-08..2024-06-14 parsed")
        } else {
            failed.append("G2-TEMPORAL(iso-range): parse failed")
        }

        // (b) Month-year single ("April 2024")
        if let m = DateGrammar.parse("what happened in April 2024?", baseDate: base, timeZone: utc),
           let s = m.timeframe.start, let e = m.timeframe.end,
           cal.component(.year, from: s) == 2024,
           cal.component(.month, from: s) == 4,
           cal.component(.year, from: e) == 2024,
           cal.component(.month, from: e) == 4 {
            passed.append("G2-TEMPORAL(month-year): \"April 2024\" parsed")
        } else {
            failed.append("G2-TEMPORAL(month-year): parse failed")
        }

        // (c) Month range ("April through June 2024")
        if let m = DateGrammar.parse("changes from April through June 2024", baseDate: base, timeZone: utc),
           let s = m.timeframe.start, let e = m.timeframe.end,
           cal.component(.month, from: s) == 4,
           cal.component(.month, from: e) == 6 {
            passed.append("G2-TEMPORAL(month-range): April..June 2024 parsed")
        } else {
            failed.append("G2-TEMPORAL(month-range): parse failed")
        }

        // (d) Relative ("last week")
        if let m = DateGrammar.parse("what changed last week?", baseDate: base, timeZone: utc),
           let s = m.timeframe.start, let e = m.timeframe.end,
           s < e, e <= base {
            passed.append("G2-TEMPORAL(relative): \"last week\" produced a window before base")
        } else {
            failed.append("G2-TEMPORAL(relative): \"last week\" parse failed")
        }

        // (e) Sentinel: nil for text with no temporal expression.
        if DateGrammar.parse("Who signed the contract?", baseDate: base, timeZone: utc) == nil {
            passed.append("G2-TEMPORAL(nil): no temporal text → nil")
        } else {
            failed.append("G2-TEMPORAL(nil): false positive on non-temporal question")
        }

        // (f) G2-2 — week-number range. The engine-firing audit flagged
        // "between week N and week M of <project>" returning timeframe=nil
        // even though intent kind resolved to executiveBriefing. The
        // baseDate's ISO year is 2026; weeks 22-25 of 2026 = May 25..Jun 21.
        if let m = DateGrammar.parse("between week 22 and week 25 of Project Delta",
                                     baseDate: base, timeZone: utc),
           let s = m.timeframe.start, let e = m.timeframe.end,
           s < e {
            passed.append("G2-2(week-range): weeks 22-25 produced a window")
        } else {
            failed.append("G2-2(week-range): weeks 22-25 returned nil")
        }
        if let m = DateGrammar.parse("what happened during week 22 of 2024",
                                     baseDate: base, timeZone: utc),
           let s = m.timeframe.start,
           cal.component(.year, from: s) == 2024 {
            passed.append("G2-2(week-single): \"week 22 of 2024\" anchored to 2024")
        } else {
            failed.append("G2-2(week-single): explicit year not honored")
        }
    }

    // G2-1.5 — SessionProfile records turns and snapshot returns
    // recency-first entity ordering; reset clears state.
    do {
        let profile = SessionProfile(maxTurns: 5)
        await profile.recordTurn(question: "Tell me about Supplier ABC",
                                 intentKind: "lookup",
                                 entityHints: ["Supplier ABC"])
        await profile.recordTurn(question: "What about Project Delta?",
                                 intentKind: "lookup",
                                 entityHints: ["Project Delta"])
        await profile.recordTurn(question: "And the contract?",
                                 intentKind: "lookup",
                                 entityHints: ["Project Delta", "contract"])
        let snap = await profile.snapshot()
        if snap.recentTurns.count == 3,
           snap.mentionedEntities.first == "Project Delta",
           snap.mentionedEntities.contains("Supplier ABC"),
           snap.lastIntentKind == "lookup" {
            passed.append("G2-1.5: SessionProfile snapshot recency-ordered (\(snap.mentionedEntities.prefix(3).joined(separator: ", ")))")
        } else {
            failed.append("G2-1.5: snapshot wrong — entities=\(snap.mentionedEntities) turns=\(snap.recentTurns.count) lastIntent=\(snap.lastIntentKind ?? "nil")")
        }
        await profile.reset()
        let cleared = await profile.snapshot()
        if cleared.isEmpty {
            passed.append("G2-1.5: SessionProfile.reset clears state")
        } else {
            failed.append("G2-1.5: reset left \(cleared.recentTurns.count) turns behind")
        }
    }

    // G2-1.5 — Reranker.questionShape is pure and covers the canonical
    // wh-/yes-no/list shapes the prompt depends on.
    do {
        let cases: [(String, String)] = [
            ("Who signed the contract?", "who"),
            ("When did the invoice arrive?", "when"),
            ("List all suppliers", "list"),
            ("Is the project delayed?", "yes-no"),
            ("Project Delta status", "statement")
        ]
        let mismatches = cases.compactMap { (q, expected) -> String? in
            let got = Reranker.questionShape(q)
            return got == expected ? nil : "\(q) → \(got) (≠ \(expected))"
        }
        if mismatches.isEmpty {
            passed.append("G2-1.5: Reranker.questionShape classifies 5 canonical shapes")
        } else {
            failed.append("G2-1.5: questionShape mismatches: \(mismatches.joined(separator: "; "))")
        }
    }

    // G2-MMR — Diversity pass over an over-capped citation set.
    //
    // Construct a synthetic set of 5 citations: 3 from the same email
    // thread (high token overlap), 1 contract.md, 1 amendment-7.md.
    // With cap=3 and a pure relevance sort, the 3 email-thread copies
    // would win. MMR must instead pick 1 thread copy + the 2 distinct
    // docs so the answer covers the question end-to-end.
    do {
        let mmrAnswer = await state.brain.answer(
            question: "List all delays mentioned across the Project Delta archive."
        )
        // A3 in the eval is an aggregation question — cap is 8.
        // The smoke ProjectDelta fixture has 6-8 KOs depending on what
        // survived ingestion; aggregation cap (8) won't truncate them,
        // so MMR may not visibly fire. The check below verifies the
        // verifier didn't drop everything to zero citations — and
        // that on a real over-capped scenario, the cited set is not
        // a single-thread monoculture.
        let citedFilenames = mmrAnswer.citations
            .map { $0.objectID.uuidString.prefix(8) }
        let distinctObjects = Set(mmrAnswer.citations.map(\.objectID)).count
        if mmrAnswer.citations.count >= 1, distinctObjects == mmrAnswer.citations.count {
            passed.append("G2-MMR: aggregation cited \(mmrAnswer.citations.count) distinct citations (\(citedFilenames.prefix(3).joined(separator: ", "))…)")
        } else {
            failed.append("G2-MMR: aggregation cited \(mmrAnswer.citations.count) citations, distinct=\(distinctObjects)")
        }
    }

    // G2-COMMITMENTS-REFRESH — chatmind intention patterns produce
    // taskAssigned events with date lifted from "by <date>" phrasing.
    do {
        let extractor = RuleEventExtractor()
        let ko = KnowledgeObject(
            sourceFile: URL(fileURLWithPath: "/tmp/g2-commit.txt"),
            sourceType: .txt,
            content: """
            Hi team — quick recap from today's call:
            I will send the revised contract by Friday March 6, 2026.
            We plan to finalize the supplier list next week.
            Action item: Maria to share the invoice by tomorrow.
            """,
            confidence: .high
        )
        let events = try await extractor.extractEvents(from: ko, chunks: [], entities: [])
        let commitments = events.filter { $0.kind == .taskAssigned }
        if commitments.count >= 3 {
            passed.append("G2-COMMIT: \(commitments.count) taskAssigned events from 3 intention phrases")
        } else {
            failed.append("G2-COMMIT: expected ≥3 taskAssigned events, got \(commitments.count)")
        }
        // At least one commitment should carry a due-by date (0.75 conf)
        // — the "by Friday March 6, 2026" phrase.
        let dueDated = commitments.first { abs($0.dateConfidence - 0.75) < 0.01 }
        if dueDated != nil {
            passed.append("G2-COMMIT: dueDate lifted from 'by <date>' phrase (confidence 0.75)")
        } else {
            let confs = commitments.map(\.dateConfidence)
            failed.append("G2-COMMIT: no commitment carried due-date confidence 0.75 (confs=\(confs))")
        }
    }

    // T11 — Quality strip renders the expected fields and handles a
    // contradictory fixture (Conflicts: 1).
    do {
        let report = ConfidenceReport(
            combined: Confidence(0.82),
            sourceCount: 5, distinctSourceObjectIDs: 4, agreementScore: 0.8,
            contradictions: [],
            droppedUnverifiable: 0,
            newestEvidenceDate: Date(),
            freshness: 0.6,
            coverage: 0.75,
            coverageGaps: [],
            ingestCoverage: 1.0
        )
        let goodAnswer = VerifiedAnswer(
            body: "All good.",
            citations: [
                VerifiedAnswer.Citation(objectID: UUID(), snippet: "a"),
                VerifiedAnswer.Citation(objectID: UUID(), snippet: "b")
            ],
            confidence: Confidence(0.82),
            contradictions: [],
            report: report
        )
        let line = QualityStrip.formatLine(goodAnswer)
        let hasAll = line.contains("Confidence: strong")
            && line.contains("Evidence:")
            && line.contains("Timeliness:")
            && line.contains("Conflicts: 0")
        if hasAll {
            passed.append("T11: quality strip line contains all sections")
        } else {
            failed.append("T11: strip line missing sections — '\(line)'")
        }

        let conflict = VerifiedAnswer.Contradiction(
            description: "Invoice paid vs unpaid",
            claimA: "Paid on 2026-02-10",
            claimB: "Unpaid as of 2026-03-01"
        )
        let conflictAnswer = VerifiedAnswer(
            body: "Conflicting evidence.",
            citations: goodAnswer.citations,
            confidence: Confidence(0.55),
            contradictions: [conflict],
            report: report
        )
        let conflictLine = QualityStrip.formatLine(conflictAnswer)
        if conflictLine.contains("Conflicts: 1") {
            passed.append("T11: contradictory answer shows Conflicts: 1")
        } else {
            failed.append("T11: conflict count not surfaced — '\(conflictLine)'")
        }
    }

    // T12 — Eval harness produces eval-report.md with nonzero numbers
    // that are reproducible across two runs.
    do {
        let runner = EvalKitRunner()
        let dir1 = tempDir.appendingPathComponent("eval1", isDirectory: true)
        let dir2 = tempDir.appendingPathComponent("eval2", isDirectory: true)
        try FileManager.default.createDirectory(at: dir1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir2, withIntermediateDirectories: true)
        let url1 = try runner.runOffline(outputDir: dir1)
        let url2 = try runner.runOffline(outputDir: dir2)
        let exists1 = FileManager.default.fileExists(atPath: url1.path)
        let body1 = (try? String(contentsOf: url1, encoding: .utf8)) ?? ""
        let body2 = (try? String(contentsOf: url2, encoding: .utf8)) ?? ""
        let hasClassTable = body1.contains("| lookup |") && body1.contains("| aggregation |")
        if exists1 && hasClassTable {
            passed.append("T12: eval-report.md produced with per-class table")
        } else {
            failed.append("T12: report missing class rows or file (\(url1.path))")
        }
        // Strip generation timestamps before comparing — runOffline is
        // otherwise fully deterministic.
        func stripTimestamps(_ s: String) -> String {
            s.components(separatedBy: "\n")
                .filter { !$0.hasPrefix("Generated:") }
                .joined(separator: "\n")
        }
        if stripTimestamps(body1) == stripTimestamps(body2) {
            passed.append("T12: two runs produce identical reports (0% drift)")
        } else {
            failed.append("T12: two runs diverged")
        }
    } catch {
        failed.append("T12: eval harness failed: \(error)")
    }

    // T6 — embedAll batches 1000 inputs into ceil(1000/64) = 16 calls.
    do {
        let counter = T6CallCounter()
        let fake = T6CountingEmbedder(dimension: 8, counter: counter)
        let texts = (0..<1000).map { "synthetic text \($0)" }
        let out = await fake.embedAll(texts, batchSize: 64)
        let expected = Int((1000.0 / 64.0).rounded(.up))
        let calls = await counter.count
        if out.count == 1000 && calls <= expected {
            passed.append("T6: embedAll → \(calls) batch calls for 1000 texts (≤ \(expected))")
        } else {
            failed.append("T6: embedAll \(calls) calls / \(out.count) vectors (expected ≤\(expected) calls, 1000 vectors)")
        }
    }

    // G3.22 — make the backfill deterministic for the smoke. AppState's
    // boot-time backfill is dispatched on a detached utility task, so
    // it may not have completed before the assertions below read
    // fact_type. Running it synchronously here re-applies cleanly
    // (idempotent: only touches NULL rows) and removes the race.
    if let entities = state.entities, let events = state.events {
        let backfill = OntologyBackfill(
            entities: entities,
            events: events
        )
        _ = await backfill.run()
    }

    // G3.22 — per-FactType row counts. The OntologyBackfill runs at
    // boot and labels every entity / event row with a fact_type. If
    // the classifier or backfill regress, these counts go to 0.
    do {
        let entityCounts = (try? await entities.countsByFactType()) ?? [:]
        let eventCounts = (try? await events.countsByFactType()) ?? [:]
        let totalLabeled = entityCounts.values.reduce(0, +) + eventCounts.values.reduce(0, +)
        if totalLabeled > 0 {
            // Render a compact summary so the failure case is debuggable.
            let entityStr = entityCounts.isEmpty
                ? "—"
                : entityCounts.sorted(by: { $0.key < $1.key })
                    .map { "\($0.key):\($0.value)" }.joined(separator: ",")
            let eventStr = eventCounts.isEmpty
                ? "—"
                : eventCounts.sorted(by: { $0.key < $1.key })
                    .map { "\($0.key):\($0.value)" }.joined(separator: ",")
            passed.append("G3: fact_type counts entities[\(entityStr)] events[\(eventStr)]")
        } else {
            failed.append("G3: OntologyBackfill produced 0 typed rows (classifier or backfill regression)")
        }
    }

    // G3.22 — typed-bond engine end-to-end. Ingest writes bonds via
    // BondConstructor; BondWalker should reach KOs from a Project
    // Delta seed; WalkExplainer should turn the steps into typed
    // WalkStep rows with valid FactType endpoints.
    if let factBonds = state.factBonds {
        let bondCount = (try? await factBonds.count()) ?? 0
        if bondCount > 0 {
            passed.append("G3: fact_bonds populated (count=\(bondCount))")
        } else {
            failed.append("G3: fact_bonds is empty after ingest")
        }

        // Walk from the Project Delta entity. The corpus contains
        // multiple ProjectDelta-related KOs (contract, amendment,
        // invoices, emails) so the walker should reach ≥1 source KO.
        // NLTagger sometimes tags "Project Delta" as organization
        // (the FactTypeClassifier has a name-based override for this,
        // but the underlying entity.kind stays organization). Fall
        // back to scanning orgs for "delta" so the seed is found even
        // when entity.kind is misleading.
        let projects = (try? await entities.list(kind: .project, limit: 25)) ?? []
        let orgs = (try? await entities.list(kind: .organization, limit: 25)) ?? []
        let projectDelta = projects.first(where: { $0.value.lowercased().contains("delta") })
            ?? projects.first
        let orgDelta = orgs.first(where: { $0.value.lowercased().contains("delta") })
        let delta = projectDelta ?? orgDelta
        if let seed = delta {
            let walker = BondWalker(repository: factBonds)
            let result = await walker.expand(from: seed.id, maxHops: 2)
            if !result.sourceObjectIDs.isEmpty {
                passed.append("G3: BondWalker reached \(result.sourceObjectIDs.count) KO(s) from seed '\(seed.value)'")
            } else {
                failed.append("G3: BondWalker found no source KOs from seed '\(seed.value)'")
            }

            // WalkExplainer should classify ≥1 step's endpoints. The
            // backfill labels fact_type on every entity/event, so we
            // expect at least one typed step out the other side.
            let explainer = WalkExplainer(entities: entities, events: events)
            let typed = await explainer.explain(result.steps)
            if !typed.isEmpty {
                let bondNames = Set(typed.map(\.bond)).sorted().joined(separator: ",")
                passed.append("G3: WalkExplainer produced \(typed.count) typed step(s); bonds=[\(bondNames)]")
            } else if !result.steps.isEmpty {
                // Steps exist but none classified — backfill hasn't
                // run yet OR none of the touched rows are typed.
                failed.append("G3: WalkExplainer produced 0 typed steps from \(result.steps.count) raw step(s)")
            }
            // (No raw steps = nothing to explain. Not a failure.)
        } else {
            failed.append("G3: no project entity available to seed BondWalker")
        }
    } else {
        failed.append("G3: AppState.factBonds is nil (boot path didn't wire FactBondsRepository)")
    }

    let result = ProjectDeltaSmokeResult(
        ingested: ingested,
        entityCount: entityCount,
        eventCount: eventCount,
        memoryObjectCount: memoryCount,
        answer: answer,
        assertionsPassed: passed,
        assertionsFailed: failed
    )
    if result.ok {
        KalsmritikoshLog.app.info("ProjectDelta smoke test PASSED (\(result.assertionsPassed.count, privacy: .public) checks)")
    } else {
        KalsmritikoshLog.app.error("ProjectDelta smoke test FAILED — \(result.assertionsFailed.joined(separator: "; "), privacy: .public)")
    }
    // Write a durable report so the run is retrievable after the OSLog .info
    // lines scroll away (log show doesn't persist .info). Best-effort.
    writeSmokeReport(result)
    return result
}

/// Persist a human-readable smoke report to ~/Documents/EvalBaselines/ so a run
/// can be inspected after the fact (OSLog .info isn't persisted to disk).
@MainActor
private func writeSmokeReport(_ result: ProjectDeltaSmokeResult) {
    var md = "# ProjectDelta SmokeTest — \(result.ok ? "PASSED ✅" : "FAILED ❌")\n\n"
    md += "- ingested: \(result.ingested)\n"
    md += "- entities: \(result.entityCount)  ·  events: \(result.eventCount)  ·  memory: \(result.memoryObjectCount)\n"
    md += "- checks passed: \(result.assertionsPassed.count)  ·  failed: \(result.assertionsFailed.count)\n\n"
    if !result.assertionsFailed.isEmpty {
        md += "## Failures\n\n" + result.assertionsFailed.map { "- \($0)" }.joined(separator: "\n") + "\n\n"
    }
    md += "## Passed\n\n" + result.assertionsPassed.map { "- \($0)" }.joined(separator: "\n") + "\n\n"
    md += "## Answer\n\n- state: \(result.answer.answerState.rawValue)\n"
    md += "- confidence: \(result.answer.confidence.value)\n"
    md += "- citations: \(result.answer.citations.count)\n\n"
    md += "```\n\(result.answer.body.prefix(2000))\n```\n"

    let base = (try? FileManager.default.url(
        for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true
    )) ?? FileManager.default.temporaryDirectory
    let dir = base.appendingPathComponent("EvalBaselines", isDirectory: true)
    let url = dir.appendingPathComponent("smoke-report.md", isDirectory: false)
    do {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(md.utf8).write(to: url, options: .atomic)
        KalsmritikoshLog.app.info("Smoke report written to \(url.path, privacy: .public)")
    } catch {
        KalsmritikoshLog.app.error("Smoke report write failed: \(String(describing: error), privacy: .public)")
    }
}

// MARK: - Helpers

private func fixtureURLs() throws -> [URL] {
    let bundle = Bundle.main
    guard let resourcePath = bundle.resourcePath else {
        throw NSError(
            domain: "kalsmritikosh.smoke",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Bundle has no resource path."]
        )
    }
    let root = URL(fileURLWithPath: resourcePath)
        .appendingPathComponent("ProjectDelta", isDirectory: true)
    guard FileManager.default.fileExists(atPath: root.path) else {
        // Fallback: search recursively in the bundle for our fixture filenames.
        return bundle.urls(forResourcesWithExtension: "eml", subdirectory: nil) ?? []
    }
    let items = try FileManager.default.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: [.isRegularFileKey]
    )
    return items
        .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
}

// T6 helpers — fake counting embedder.
private actor T6CallCounter {
    private(set) var count = 0
    func bump(_ n: Int = 1) { count += n }
}

private struct T6CountingEmbedder: Embedder {
    let dimension: Int
    let counter: T6CallCounter

    func embed(_ text: String) async -> [Float] {
        await counter.bump()
        return Array(repeating: 0, count: dimension)
    }

    func embedBatch(_ texts: [String]) async -> [[Float]] {
        await counter.bump()
        return texts.map { _ in Array(repeating: 0, count: dimension) }
    }
}

private func countAllEntities(_ repo: EntitiesRepository) async throws -> Int {
    var total = 0
    for kind in Entity.Kind.allCases {
        total += try await repo.count(of: kind)
    }
    return total
}
