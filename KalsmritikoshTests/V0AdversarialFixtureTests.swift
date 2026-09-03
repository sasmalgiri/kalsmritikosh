//
//  V0AdversarialFixtureTests.swift
//  KalsmritikoshTests
//
//  V0 (Stage 1, unit 1.1) — the program's first deliberate failures: the
//  NoiseFixtureGenerator's adversarial classes run against CURRENT
//  extraction, and each promise gap is recorded as an executable red.
//
//  Red discipline: known defects are wrapped in `withKnownIssue`, so the
//  suite is CI-green TODAY and FAILS THE DAY THE FIX LANDS — forcing the
//  wrapper's removal, which is the red→green flip, in the fixing commit
//  (V2 extractor correctness, V3 entity gate/anchors, unit 1.8 causal
//  bounding, V6/NF not-found contract, Train 3 C-4 cross-block assembly).
//
//  Binding #1: rungs 1 / 1n / 2 have fixture-twins here, so batched live
//  witnesses are confirmation, never first detection.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("V0 — adversarial fixtures (reds recorded)", .serialized)
@MainActor
struct V0AdversarialFixtureTests {

    static let gen = NoiseFixtureGenerator()

    // MARK: - Extraction-level reds (REAL write path: facts as stored by ingest)
    //
    // First V0 run's lesson (recorded): DomainFactExtractor on a whole
    // document yields nothing — production extracts per evidence BLOCK.
    // These reds therefore assert against the rig's generic_facts table,
    // the actual write path.

    /// Field names are matched shape-insensitively (lowercased, spaces
    /// stripped): the stored spelling differs from the model's camelCase —
    /// first V0 runs matched zero rows on 'patentNumber' while the answers
    /// displayed stored patent facts. The raw field inventory is printed so
    /// the red output stays self-describing.
    private func storedValues(_ rig: FixtureRig, field: String) async throws -> [String] {
        let rows = try await rig.db.query("SELECT field, value FROM generic_facts", [])
        let all = rows.compactMap { r -> (String, String)? in
            guard let f = r.string(0), let v = r.string(1) else { return nil }
            return (f, v)
        }
        print("V0 fact inventory: \(all.map(\.0).sorted())")
        let want = field.lowercased().replacingOccurrences(of: " ", with: "")
        return all.filter { $0.0.lowercased().replacingOccurrences(of: " ", with: "") == want }.map(\.1)
    }

    @Test("GREEN C-1: 3+ label spellings collapse to ONE stored value (V2 capture groups + merge)")
    func labelVariantsCollapse() async throws {
        let rig = try await FixtureRig.make(document: Self.gen.noisyGrantLetter, name: "grant-letter.md")
        defer { try? FileManager.default.removeItem(at: rig.dir) }
        let values = try await storedValues(rig, field: "patentNumber")
        print("V0→GREEN labelVariants: stored patentNumber values = \(values)")
        #expect(!values.isEmpty, "ingest stored no patentNumber facts at all")
        // V2: six label spellings of 700321 → one bare atom; the cross-field
        // mislabel (an application number under "Patent No.") is reassigned to
        // its true field. One patent, one spelling.
        #expect(Set(values).count == 1, "spellings stored as \(Set(values).count) distinct values")
    }

    @Test("GREEN C-1: stored identifier value carries NO alphabetic label token; mislabel bait stays out of patentNumber")
    func storedValueShapeAndMislabel() async throws {
        let rig = try await FixtureRig.make(document: Self.gen.noisyGrantLetter, name: "grant-letter.md")
        defer { try? FileManager.default.removeItem(at: rig.dir) }
        let values = try await storedValues(rig, field: "patentNumber")
        print("V0→GREEN shape/mislabel: patentNumber values = \(values)")
        #expect(!values.isEmpty)
        // Date bait must already be rejected at write time (rc12) — hard green.
        #expect(!values.contains { $0.contains("22/03/2023") }, "a slash-date was stored as a patent number")
        // V2 capture groups store the bare atom — no label token fused in.
        #expect(!values.contains { $0.lowercased().contains("patent") },
                "label token stored in value")
        // V2 write-time cross-field resolution reassigns the mislabeled
        // application number to its true field — it never lands under patentNumber.
        #expect(!values.contains { $0.contains(Self.gen.applicationNumber) },
                "mislabeled application number stored under patentNumber")
    }

    @Test("RED (deferred): OCR digit substitution recovers no value today — recorded verbatim")
    func ocrSubstitution() async throws {
        let rig = try await FixtureRig.make(document: Self.gen.ocrGrantLetter, name: "scan.md")
        defer { try? FileManager.default.removeItem(at: rig.dir) }
        let values = try await storedValues(rig, field: "patentNumber")
        print("V0 RED ocr: stored patentNumber values = \(values)")
        withKnownIssue("OCR-substituted values are not recovered/flagged; generator class recorded (post-V2 normalizer scope)") {
            #expect(values.contains { $0.contains("7OO321") || $0.filter(\.isNumber).contains("700321") },
                    "no patentNumber fact recovered from the OCR page")
        }
    }

    @Test("RED (deferred to Train 3 C-4): page break splits label from value — no fact today")
    func pageBreakSplit() async throws {
        let rig = try await FixtureRig.make(document: Self.gen.pageBreakSplitLetter, name: "split.md")
        defer { try? FileManager.default.removeItem(at: rig.dir) }
        let values = try await storedValues(rig, field: "patentNumber")
        print("V0 RED pageBreak: stored patentNumber values = \(values)")
        withKnownIssue("C-4 cross-block assembly is Train 3; this fixture stays red until then") {
            #expect(values.contains { $0.contains("700321") }, "label/value split across the page break yields no fact")
        }
    }

    @Test("GREEN C-1: quoted reply + table + prose restatements collapse to one normalized value")
    func quotedReplyAndTable() async throws {
        let rig = try await FixtureRig.make(document: Self.gen.quotedReplyWithTable, name: "reply.md")
        defer { try? FileManager.default.removeItem(at: rig.dir) }
        let values = try await storedValues(rig, field: "patentNumber")
        print("V0→GREEN quotedReply: stored patentNumber values = \(values)")
        #expect(!values.isEmpty, "no patentNumber fact from the reply/table document")
        // V2: spacing/format variants ("Patent  No.   700321" vs "Patent No. 700321")
        // normalize to the same atom and merge to one value.
        #expect(Set(values).count == 1, "restatements stored as \(Set(values).count) distinct values")
    }

    // MARK: - Entity-noise red (full rig — V3's gate)

    @Test("V3/E-1 GREEN: entity noise gated at every door; the register keeps clean names + legitimate email-address entities")
    func entityNoiseGate() async throws {
        // The live noise ("Nil Nil", ", Shabana Khan", "File Processing Bot",
        // emails-as-person) enters through email header → participant/structured
        // entity promotion. With the rig now entities-wired (V3 3d recalibration),
        // the promoted entities pass through the SAME quality gate the NER path
        // does — gate-then-fold at every write door.
        let rig = try await FixtureRig.make(document: Self.gen.entityNoiseEmail, name: "noise.eml")
        defer { try? FileManager.default.removeItem(at: rig.dir) }
        let rows = try await rig.db.query("SELECT value, kind FROM entities", [])
        let named: [(value: String, kind: String)] = rows.compactMap {
            guard let v = $0.string(0), let k = $0.string(1) else { return nil }
            return (v, k)
        }
        // KIND-AWARE junk (the "@" clause was a shape-proxy for a kind-defect):
        // an address is junk only when worn by a PERSON/org, never as its own
        // emailAddress-kind entity. ", Shabana Khan" is NORMALIZED to "Shabana
        // Khan" (kept, no leading comma); "Nil Nil"/"File Processing Bot" are
        // gated; filename subjects never become person entities.
        let nounKinds: Set<String> = ["person", "organization", "vendor", "client"]
        let junk = named.filter { row in
            let t = row.value.trimmingCharacters(in: .whitespaces)
            let emailAsPerson = nounKinds.contains(row.kind) && t.contains("@")
            return t.lowercased() == "nil nil" || t.hasPrefix(",") || emailAsPerson
                || t.lowercased().contains(".pdf") || t.lowercased().contains("file processing bot")
        }
        print("V3 GREEN entityNoise: register = \(named)")
        #expect(!named.isEmpty, "rig persisted no entities — the entities wiring regressed")
        #expect(junk.isEmpty, "noise entities survived the gate: \(junk)")

        // COMPLEMENT (option-B tripwire): the register AFFIRMATIVELY contains the
        // senders' emailAddress entities. If a future change drops emailAddress
        // persistence (to satisfy the old "@" wording), this REDS instead of
        // passing silently — the tail can no longer wag the dog.
        let emailEntities = named.filter { $0.kind == "emailAddress" }
        #expect(!emailEntities.isEmpty, "emailAddress entities missing — the register no longer affirms the correct rows")
        #expect(emailEntities.contains { $0.value.contains("@") }, "emailAddress entity lost its address")
    }

    // MARK: - Rung fixture-twins (binding #1)

    @Test("GREEN rung-1 twin: noisy letter answers the slot question cleanly — the false conflict is gone")
    func rung1Twin() async throws {
        // Binding #1's discovery, now closed: the rc12 cross-field mislabel
        // drop was query-time and needed dominance, so a single-source mislabel
        // slipped through as a false conflict carrying the application number.
        // V2 kills it at the SOURCE — capture groups store the bare atom and the
        // write-time cross-field resolver reassigns the mislabeled application
        // number to its true field before it can conflict with the patent.
        let rig = try await FixtureRig.make(document: Self.gen.noisyGrantLetter, name: "grant-letter.md")
        defer { try? FileManager.default.removeItem(at: rig.dir) }
        let a = try await rig.answer("what is the granted patent number")
        print("V0→GREEN rung-1 twin: refused=\(a.refused) conf=\(a.confidence.value) text=\(a.answerText ?? "nil")")
        #expect(!a.refused)
        #expect(a.answerText?.contains("700321") == true, "rung-1 twin lost the patent number")
        #expect(a.answerText?.contains(Self.gen.applicationNumber) == false, "application number leaked into the primary")
        #expect(a.answerText?.lowercased().contains("conflict") == false, "noise produced a false conflict")
    }

    @Test("F8 GREEN rung-1n twin: known-absent field returns a verified not-found naming the field, with a receipt")
    func rung1nTwin() async throws {
        let rig = try await FixtureRig.make(document: Self.gen.noisyGrantLetter, name: "grant-letter.md")
        defer { try? FileManager.default.removeItem(at: rig.dir) }
        let a = try await rig.answer("what is the trademark number")
        print("F8 rung-1n twin: refused=\(a.refused) text=\(a.answerText ?? "nil") body=\(a.body.prefix(200))")
        let text = (a.answerText ?? "") + " " + a.body
        #expect(text.lowercased().contains("trademark"), "not-found does not name the absent field")
        #expect(!a.body.contains("Reported:"), "fact-spam shipped instead of a verified not-found")
        #expect(text.contains("Receipt:"), "the abstention must carry its exhaustion receipt")
    }

    @Test("RED rung-2 twin: timeline of the patent must be one anchored, ordered, cited chain")
    func rung2Twin() async throws {
        let rig = try await FixtureRig.make(document: Self.gen.noisyGrantLetter, name: "grant-letter.md")
        defer { try? FileManager.default.removeItem(at: rig.dir) }
        let a = try await rig.answer("timeline of the patent")
        print("V0 RED rung-2 twin: refused=\(a.refused) text=\(a.answerText ?? "nil") body=\(a.body.prefix(200))")
        // R-1 DIAGNOSIS (F7 post-drain, 2026-09-03): the DATA layer is no longer
        // the blocker — V3 anchors + V4 class-gated milestones exist, and the
        // live drain rebuilt the full lifecycle chain (FER 2022-11-29 → filed
        // 2023-03-21 → objections → hearings 2024-08 → granted 2024-11-28, all
        // dated + ordered + producer_version 1). The remaining gap is ROUTING +
        // COMPOSER: "timeline of the patent" never reaches a timeline composer
        // and ships general-path "Reported:" fact-spam instead. The flip is
        // owned by Go 2 P3-U2 (temporal chains) + the S2-U5 rungs-1/1n/2 gate.
        withKnownIssue("R-1 diagnosed: routing+composer gap (Go 2 P3-U2); data layer ready — anchored milestones exist") {
            let text = ((a.answerText ?? "") + " " + a.body).lowercased()
            #expect(text.contains("march 2023") && text.contains("june 2025"),
                    "timeline does not carry the filing→grant chain")
            #expect(!a.body.contains("Reported:"), "fact-spam shipped instead of a dated chain")
        }
    }

    // MARK: - Causal-explosion red (binding #2, addenda §A → unit 1.8)

    @Test("RED unit 1.8: near-identical thread events explode into pairwise CONTRIBUTED_TO; the seeded CAUSED must survive")
    func causalExplosion() async throws {
        // A real ingested KO parents the seeded events (events.source_object_id
        // is FK-constrained — first V0 run's constraint failure, recorded).
        let rig = try await FixtureRig.make(document: "Thread seed document.", name: "seed.md")
        defer { try? FileManager.default.removeItem(at: rig.dir) }
        let db = rig.db
        let koID = (try await db.query("SELECT id FROM knowledge_objects LIMIT 1", []))
            .first?.string(0).flatMap(UUID.init(uuidString:))
        let sourceID = try #require(koID, "rig produced no knowledge object")

        let events = EventsRepository(database: db)
        let threadCount = 40
        let seeded = Self.gen.threadEvents(
            count: threadCount, sourceObjectID: sourceID,
            baseDate: Date(timeIntervalSince1970: 1_750_000_000))
        try await events.insertBatch(seeded)

        let discoverer = CausalDiscoverer(
            database: db, events: events,
            entities: EntitiesRepository(database: db),
            objects: KnowledgeObjectRepository(database: db),
            links: EventLinksRepository(database: db))
        let emitted = await discoverer.runOnce()

        let contributed = Int((try await db.query(
            "SELECT COUNT(*) FROM event_links WHERE relation = 'CONTRIBUTED_TO'", [])).first?.int(0) ?? 0)
        let caused = Int((try await db.query(
            "SELECT COUNT(*) FROM event_links WHERE relation = 'CAUSED'", [])).first?.int(0) ?? 0)
        let perEventBound = 5
        print("V0 RED causal: events=\(seeded.count) emitted=\(emitted) CONTRIBUTED_TO=\(contributed) CAUSED=\(caused) bound=\(perEventBound * seeded.count)")

        // The true causal link must exist now AND after the bounding fix.
        #expect(caused >= 1, "the lexical-trigger CAUSED link was not discovered")
        withKnownIssue("unit 1.8: O(n²) pairwise emission has no per-event cap until the bounding lands") {
            #expect(contributed <= perEventBound * seeded.count,
                    "\(contributed) CONTRIBUTED_TO links for \(seeded.count) events — noise manufacturing")
        }
    }
}

// MARK: - Shared fixture rig (PatentSlotGoldTests pattern, reusable for V0+)

/// Real ingest + real retriever + real verifier over one synthetic document —
/// the deterministic end-to-end rig the gold packs use, extracted for reuse.
@MainActor
struct FixtureRig {
    let db: Database
    let retriever: HybridRetriever
    let verifier: EvidenceVerifier
    let dir: URL
    let coordinator: IngestCoordinator

    /// Ingest an additional document into the rig (C-i fixture seeds a
    /// decoy parent object the question under test never retrieves).
    func ingest(fileAt url: URL) async throws {
        _ = try await coordinator.ingest(fileAt: url)
    }

    static func make(document: String, name: String) async throws -> FixtureRig {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("v0rig-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try document.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)

        let db = try Database(url: dir.appendingPathComponent("db.sqlite"))
        try await SchemaMigrations.migrate(db)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let vault = EvidenceVault(root: dir.appendingPathComponent("vault", isDirectory: true))
        let intake = UniversalSourceIntakeCoordinator(repository: CanonicalSourceIntakeRepository(database: db, vault: vault))
        let objects = KnowledgeObjectRepository(database: db)
        let chunks = ChunksRepository(database: db)
        // V3 3d — the fixture-unrealism recalibration flagged at V0: wire the
        // entities + events repos into the coordinator so the rig PERSISTS
        // entities (participant/NER promotion, anchors) and events like the
        // production path, instead of the earlier entities-blind ingest. Any V0
        // twin whose behaviour shifts as a result is a rig-realism change (not a
        // pipeline change) — enumerated in the commit message.
        let entities = EntitiesRepository(database: db)
        let events = EventsRepository(database: db)
        let coordinator = IngestCoordinator(
            universalRegistry: try UniversalParserRegistryBuilder.standard(ocr: VisionOCR()),
            entityExtractor: NLEntityExtractor(), entityLinker: EntityLinker(),
            entityQualityGate: EntityQualityGate(), eventExtractor: RuleEventExtractor(),
            files: FilesRepository(database: db), objects: objects,
            chunks: chunks, entities: entities, events: events,
            evidenceStore: EvidenceStore(database: db),
            ingestAttempts: IngestAttemptsRepository(database: db),
            sourceRelations: SourceRelationsRepository(database: db),
            genericFacts: GenericFactRepository(database: db),
            readiness: SourceReadinessRepository(database: db),
            containerInspection: ContainerInspectionRepository(database: db),
            intakeCoordinator: intake)
        _ = try await coordinator.ingest(fileAt: dir.appendingPathComponent(name))

        let retriever = HybridRetriever(
            memory: MemoryRepository(database: db),
            events: events,
            entities: entities,
            chunks: chunks,
            summaries: SummariesRepository(database: db),
            graph: GraphStore(relationships: RelationshipsRepository(database: db)),
            vectors: SQLiteVectorStore(database: db, modelID: "apple.nl.v1"),
            embedder: NLEmbedder(),
            objects: objects,
            genericFacts: GenericFactRepository(database: db))
        return FixtureRig(db: db, retriever: retriever,
                          verifier: EvidenceVerifier(answerabilityMinRetrievalScore: 0.0), dir: dir,
                          coordinator: coordinator)
    }

    func answer(_ question: String) async throws -> VerifiedAnswer {
        let intent = (try? await RuleIntentDetector().detect(question: question))
            ?? UserIntent(kind: .factualLookup, scope: .global, rawQuestion: question)
        let retrieval = try await retriever.retrieve(for: intent, layers: [])
        let claims = ReasoningExpert.factClaims(from: retrieval)
        let findings = ExpertFindings(
            expertID: "expert.reasoning", claims: claims,
            confidence: claims.isEmpty ? .zero : .medium, droppedUnverifiable: 0)
        return try await verifier.verify(intent: intent, findings: [findings], retrieval: retrieval)
    }
}
