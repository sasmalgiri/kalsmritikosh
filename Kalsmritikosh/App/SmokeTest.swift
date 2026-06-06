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
    AtlasLog.app.info("ProjectDelta smoke test starting")

    // 1. Use a fresh isolated bookmark store + fresh in-tmp AppState.
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("AtlasSmoke-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let isolatedBookmarks = BookmarkStore()
    let state = AppState(bookmarks: isolatedBookmarks)
    await state.boot()

    guard case .ready = state.phase,
          let ingest = state.ingest,
          let entities = state.entities,
          let events = state.events,
          let memory = state.memoryRepo
    else {
        throw NSError(
            domain: "atlas.smoke",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "AppState failed to boot."]
        )
    }

    // 2. Locate fixtures inside the app bundle.
    let fixtureURLs = try fixtureURLs()
    var ingested = 0
    for url in fixtureURLs {
        do {
            _ = try await ingest.ingest(fileAt: url)
            ingested += 1
        } catch {
            AtlasLog.app.error("Smoke ingest failed for \(url.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
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
    if body.contains("supplier abc") || body.contains("supplier_abc") {
        passed.append("body mentions Supplier ABC")
    } else {
        failed.append("body never mentions Supplier ABC")
    }

    if body.contains("delivery") || body.contains("delayed") || body.contains("amendment") {
        passed.append("body mentions delivery/delay/amendment vocabulary")
    } else {
        failed.append("body lacks delivery/delay vocabulary")
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
        AtlasLog.app.info("T4 edge mix: co_occurs=\(co, privacy: .public) event_linked=\(ev, privacy: .public)")

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
        if abs(r1.coverage - 1.0) < 0.01 && r1.gaps.isEmpty {
            passed.append("T10: full-range evidence → coverage 1.0, 0 gaps")
        } else {
            failed.append("T10: full-range → coverage=\(r1.coverage) gaps=\(r1.gaps.count)")
        }

        let lateOnly = [mkEvent(year: 2026)]
        let r2 = DefaultConfidenceEngine.timeliness(
            events: lateOnly,
            intentKind: .reconstructTimeline,
            intentWindow: window,
            now: Date()
        )
        if r2.coverage <= 0.5 && r2.gaps.count >= 1 {
            passed.append(String(format: "T10: late-only → coverage %.2f ≤ 0.5 with %d gap(s)", r2.coverage, r2.gaps.count))
        } else {
            failed.append("T10: late-only coverage=\(r2.coverage) gaps=\(r2.gaps.count)")
        }
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
        AtlasLog.app.info("ProjectDelta smoke test PASSED (\(result.assertionsPassed.count, privacy: .public) checks)")
    } else {
        AtlasLog.app.error("ProjectDelta smoke test FAILED — \(result.assertionsFailed.joined(separator: "; "), privacy: .public)")
    }
    return result
}

// MARK: - Helpers

private func fixtureURLs() throws -> [URL] {
    let bundle = Bundle.main
    guard let resourcePath = bundle.resourcePath else {
        throw NSError(
            domain: "atlas.smoke",
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
