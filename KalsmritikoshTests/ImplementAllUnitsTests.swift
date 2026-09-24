//
//  ImplementAllUnitsTests.swift
//  KalsmritikoshTests
//
//  Coverage for the units landed in the implement-all program that had NONE:
//  P3.3 induction gates, P3.5/P3.6 honesty reports, A-1 Golden Thread, B-1/B-2
//  layer diagnoses, D-1 fingerprinting, the superseded-schema invariant, and
//  the reranker tokenizer's parity property.
//
//  WHAT IS TESTED HERE AND WHAT IS NOT. These are the deterministic safety
//  properties — the gates that decide whether a model-proposed value may be
//  written, whether an empty layer reports its cause, whether an "empty" table
//  is verified empty. They run without a model and without a real archive.
//
//  The report PROSE is deliberately not asserted. A test that pins wording
//  turns every honest rewording into a red, and the wording is the part most
//  likely to improve.
//

import Foundation
import Testing
@testable import Kalsmritikosh

// MARK: - P3.3 · the four gates that let a model near the ledger

@Suite("P3.3 schema induction — admissibility gates")
struct InducedSchemaGateTests {

    /// A registry with no generative provider. Induction must DECLINE against
    /// it, never invent — which is the point: these gates are asserted without
    /// any model in the loop.
    static func registry() -> CapabilityRegistry {
        let hw = HardwareProfile(
            totalRAMBytes: 16 * 1_073_741_824, availableRAMBytes: 8 * 1_073_741_824,
            processorCount: 8, isAppleSilicon: true, chipName: "TestChip",
            hasNeuralEngine: true)
        return CapabilityRegistry(hardware: hw, benchmark: PerformanceBenchmark(hardwareProfile: hw))
    }

    // ── field names ──────────────────────────────────────────────────────────

    @Test("A field name must name the datum, not the container")
    func containerWordsRefused() {
        for raw in ["document", "File", "TEXT", "value", "data", "contents",
                    "page", "info", "details", "misc", "type"] {
            #expect(InducedSchemaExtractor.usableFieldID(raw) == nil,
                    "“\(raw)” names the container, not the datum — it must be refused")
        }
    }

    @Test("A field name must contain a letter and be a sane length")
    func degenerateFieldNamesRefused() {
        #expect(InducedSchemaExtractor.usableFieldID("") == nil)
        #expect(InducedSchemaExtractor.usableFieldID("   ") == nil)
        #expect(InducedSchemaExtractor.usableFieldID("12345") == nil, "a number is a value in the wrong slot")
        #expect(InducedSchemaExtractor.usableFieldID("-----") == nil)
        #expect(InducedSchemaExtractor.usableFieldID(String(repeating: "a", count: 41)) == nil,
                "41 characters is a sentence, not a field name")
    }

    @Test("A real field name normalizes and survives")
    func realFieldNamesAccepted() throws {
        let id = try #require(InducedSchemaExtractor.usableFieldID("Policy Holder"))
        #expect(id == FactSchemaRegistry.normalizeField("Policy Holder"))
        #expect(InducedSchemaExtractor.usableFieldID("cover starts") != nil)
    }

    // ── values ───────────────────────────────────────────────────────────────

    @Test("A form's empty field is not a fact")
    func placeholderValuesRefused() {
        // Storing "N/A" asserts a value the document explicitly denies.
        for raw in ["N/A", "n/a", "none", "TBD", "unknown", "--", "pending", "..."] {
            #expect(InducedSchemaExtractor.isUsableValue(raw) == false,
                    "“\(raw)” is a placeholder, not data")
        }
        #expect(InducedSchemaExtractor.isUsableValue("") == false)
        #expect(InducedSchemaExtractor.isUsableValue("!!!") == false, "no alphanumerics")
        #expect(InducedSchemaExtractor.isUsableValue(String(repeating: "x", count: 301)) == false)
        #expect(InducedSchemaExtractor.isUsableValue("Asha Rao") == true)
    }

    // ── THE ANTI-FABRICATION GATE ────────────────────────────────────────────

    @Test("The verbatim gate tolerates whitespace and case, and NOTHING else")
    func verbatimGateIsNarrow() {
        let source = """
        The holder of this policy is  Asha   Rao.
        Cover begins on 1 April 2024 and the sum assured is INR 25,00,000.
        """
        // Tolerated: a PDF line-wrap becomes a space; case differs. Rejecting
        // these would reject correct extractions from most real documents.
        #expect(InducedSchemaExtractor.contains("Asha Rao", in: source))
        #expect(InducedSchemaExtractor.contains("asha rao", in: source))
        #expect(InducedSchemaExtractor.contains("INR 25,00,000", in: source))

        // NOT tolerated — these are the fabrication shapes the gate exists for.
        #expect(!InducedSchemaExtractor.contains("Asha Roy", in: source),
                "a changed letter must not pass")
        #expect(!InducedSchemaExtractor.contains("INR 25,00,001", in: source),
                "a changed DIGIT must not pass — this is the money case")
        #expect(!InducedSchemaExtractor.contains("1 April 2025", in: source),
                "a changed year must not pass")
        #expect(!InducedSchemaExtractor.contains("sum assured is 25,00,000", in: source),
                "a dropped word must not pass")
        #expect(!InducedSchemaExtractor.contains("", in: source),
                "an empty needle must never match")
    }

    // ── the ordering claim, checked against the real function ────────────────

    @Test("An induced fact can never outrank a deterministically extracted one")
    func inducedConfidenceIsBelowEveryDeterministicConfidence() {
        // Computed from OpenFieldExtractor.confidence(for:), not from a copied
        // number — a hardcoded bound can pass while the real ordering breaks.
        #expect(InducedSchemaExtractor.inducedConfidenceIsLowest,
                "induced confidence must sit below every block-kind confidence")
    }

    // ── reply parsing ────────────────────────────────────────────────────────

    @Test("The reply parser tolerates fences and trailing prose")
    func parseArrayTolerant() {
        let decoder = JSONDecoder()
        let fenced = """
        Sure! Here you go:
        ```json
        [{"field": "policy holder", "value": "Asha Rao"}]
        ```
        Let me know if you need more.
        """
        #expect(InducedSchemaExtractor.parseArray(fenced, decoder: decoder).count == 1)
        #expect(InducedSchemaExtractor.parseArray("no json here", decoder: decoder).isEmpty)
        #expect(InducedSchemaExtractor.parseArray("[", decoder: decoder).isEmpty,
                "an unbalanced bracket must not crash or half-parse")
        #expect(InducedSchemaExtractor.parseArray("[]", decoder: decoder).isEmpty)
    }

    // ── gate 1, and the decline reasons ──────────────────────────────────────

    @Test("Induction declines with a REASON, never with a bare empty result")
    func declinesCarryReasons() async throws {
        let inducer = InducedSchemaExtractor(capabilities: Self.registry())
        let block = (id: UUID(), text: "Some prose with no labels at all.",
                     kind: EvidenceBlockKind.paragraph)

        // Gate 1: a document that already yielded facts is not a candidate, and
        // the outcome says so rather than returning a silent empty.
        let notCandidate = await inducer.induce(
            blocks: [block], subjectLabel: "doc", existingFactCount: 3)
        #expect(notCandidate.facts.isEmpty)
        let decline = try #require(notCandidate.declined)
        // Either reason is correct depending on the module switch; what must
        // NOT happen is facts with no decline, or a decline with no reason.
        #expect(decline == .documentAlreadyYieldedFacts(3) || decline == .moduleDisabled)
        #expect(!decline.explanation.isEmpty, "a decline must always explain itself")

        // Furniture-only documents cannot carry a field at all.
        let footerOnly = await inducer.induce(
            blocks: [(id: UUID(), text: "Page 3 of 9", kind: EvidenceBlockKind.pageFooter)],
            subjectLabel: "doc", existingFactCount: 0)
        #expect(footerOnly.facts.isEmpty)
        #expect(footerOnly.declined != nil, "an empty result must name its cause")
    }

    @Test("Every decline case produces a non-empty explanation")
    func everyDeclineExplains() {
        let all: [InducedSchemaExtractor.Decline] = [
            .moduleDisabled, .documentAlreadyYieldedFacts(2), .noEligibleBlocks,
            .providerUnavailable, .providerFailed("boom"), .emptyReply,
            .allProposalsRejected(InducedSchemaExtractor.RejectionTally()),
        ]
        for d in all { #expect(!d.explanation.isEmpty, "\(d) explained itself with nothing") }
    }

    @Test("Rejection tallies stay separated, because they mean different things")
    func rejectionTalliesAreDistinct() {
        var t = InducedSchemaExtractor.RejectionTally()
        t.valueNotFoundInDocument = 3   // the model is fabricating
        t.reservedField = 2             // a prompt problem
        #expect(t.total == 5)
        let s = t.summary
        #expect(s.contains("not found"), "a fabrication signal must be visible in the summary")
        #expect(s.contains("built-in reader"), "a reserved-field collision must be named separately")
        #expect(InducedSchemaExtractor.RejectionTally().summary == "no proposals")
    }
}

// MARK: - The four-state outcome, and the trap in reading it

@Suite("PipelineStageOutcome — four states, and isPopulated means only one")
struct PipelineStageOutcomeTests {

    @Test("isPopulated is true ONLY for .present")
    func populatedIsNarrow() {
        #expect(PipelineStageOutcome.present(count: 1, detail: "d").isPopulated)
        // The trap this property exists to close: absentExpected and
        // couldNotCheck are both NOT defects, and neither one means the stage
        // produced anything. A caller reading "not a defect" as "fine" is the
        // false-green pattern.
        #expect(!PipelineStageOutcome.absentExpected(reason: "r").isPopulated)
        #expect(!PipelineStageOutcome.couldNotCheck(why: "w").isPopulated)
        #expect(!PipelineStageOutcome.absentUnexpected(reason: "r").isPopulated)
    }

    @Test("Only absentUnexpected is a defect; only couldNotCheck is unknown")
    func defectAndUnknownAreDisjoint() {
        #expect(PipelineStageOutcome.absentUnexpected(reason: "r").isDefect)
        #expect(!PipelineStageOutcome.absentExpected(reason: "r").isDefect,
                "a legitimately empty stage is not a defect")
        #expect(!PipelineStageOutcome.couldNotCheck(why: "w").isDefect,
                "a failed check is a defect in the KNOWING, not in the pipeline")
        #expect(PipelineStageOutcome.couldNotCheck(why: "w").isUnknown)
        #expect(!PipelineStageOutcome.present(count: 0, detail: "d").isUnknown)
    }

    @Test("Every state renders a line that says which kind of empty it is")
    func linesDistinguish() {
        #expect(PipelineStageOutcome.absentExpected(reason: "no dates").line.contains("expected"))
        #expect(PipelineStageOutcome.absentUnexpected(reason: "broken").line.contains("NONE"))
        #expect(PipelineStageOutcome.couldNotCheck(why: "threw").line.contains("could not"))
    }
}

// MARK: - A-1 · the probe phrase

@Suite("Golden Thread — probe phrase selection")
struct GoldenThreadProbeTests {

    @Test("No usable text yields NO probe, reported as unchecked rather than failed")
    func emptyTextHasNoProbe() {
        #expect(GoldenThread.probeTerm(in: "") == nil)
        #expect(GoldenThread.probeTerm(in: "   \n  ") == nil)
        #expect(GoldenThread.probeTerm(in: "a of to the") == nil,
                "only stopwords and short words — nothing distinctive to search by")
    }

    @Test("A distinctive three-word phrase is preferred over a single common word")
    func prefersThreeWordWindow() throws {
        let text = "The parties hereby agree that the total consideration payable "
                 + "under this Agreement shall be Schedule Two."
        let probe = try #require(GoldenThread.probeTerm(in: text))
        #expect(probe.split(separator: " ").count == 3, "got “\(probe)”")
        for w in probe.split(separator: " ") {
            #expect(!["the", "that", "this", "shall", "be"].contains(w.lowercased()),
                    "stopword “\(w)” leaked into the probe")
        }
    }

    @Test("One long identifier is a better probe than nothing")
    func singleLongWordFallback() throws {
        let probe = try #require(GoldenThread.probeTerm(in: "Ref: ABC123456789"))
        #expect(probe.contains("ABC123456789") || probe == "ABC123456789")
    }
}

// MARK: - S-0b · the one-ledger invariant

@Suite("SupersededSchema — kept, empty, and CHECKED")
struct SupersededSchemaTests {

    @Test("Every superseded table names its replacement and a live consumer")
    func entriesAreSelfJustifying() {
        #expect(!SupersededSchema.entries.isEmpty)
        for e in SupersededSchema.entries {
            #expect(!e.supersededBy.isEmpty, "\(e.table) claims no replacement")
            #expect(!e.liveConsumer.isEmpty,
                    "\(e.table): the claim “redundant” needs the surface that reads the replacement")
        }
        #expect(SupersededSchema.tableNames.contains("people"))
        // `vectors` must NOT be here: it has no writer but a MIGRATION reads it.
        #expect(!SupersededSchema.tableNames.contains("vectors"),
                "vectors is a legacy migration source, not superseded schema")
        // Nor evidence_block_edges: nothing replaced it, it was never built.
        #expect(!SupersededSchema.tableNames.contains("evidence_block_edges"),
                "an unbuilt feature must not be recorded as superseded")
    }

    @Test("A fresh ledger has them verified empty — and a row is DETECTED")
    func invariantActuallyFires() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("superseded-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try Database(url: dir.appendingPathComponent("db.sqlite"))
        try await SchemaMigrations.migrate(db)

        let clean = await SupersededSchema.unexpectedlyPopulated(database: db)
        #expect(clean.populated.isEmpty, "a fresh ledger must have these empty")
        #expect(clean.unreadable.isEmpty, "all four must be READABLE to be verified empty")

        // Now write a parallel truth and prove the check catches it. A guard
        // that cannot fail is the defect it exists to prevent.
        try await db.exec("INSERT INTO people (id, name) VALUES (?, ?);",
                          [.uuid(UUID()), .text("A Parallel Copy")])
        let dirty = await SupersededSchema.unexpectedlyPopulated(database: db)
        #expect(dirty.populated.contains { $0.table == "people" && $0.rows == 1 },
                "a row in a superseded table MUST be reported as a one-ledger violation")
        #expect(SupersededSchema.reportSection(populated: dirty.populated,
                                               unreadable: dirty.unreadable)
                    .contains("NOT EMPTY"))
    }
}

// MARK: - v132 · the induction attempt ledger

@Suite("P3.3 attempt ledger — the resume marker")
struct InducedSchemaAttemptRepositoryTests {

    private func freshDB() async throws -> (Database, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("attempts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try Database(url: dir.appendingPathComponent("db.sqlite"))
        try await SchemaMigrations.migrate(db)
        return (db, dir)
    }

    @Test("An attempt round-trips, and IS the skip marker for the next run")
    func attemptRoundTrip() async throws {
        let (db, dir) = try await freshDB()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = InducedSchemaAttemptRepository(database: db)

        #expect(await repo.attemptedVersionIDs().isEmpty)
        #expect(await repo.attemptsReadable, "a readable empty table is not an error")

        let version = UUID()
        await repo.record(InducedSchemaAttempt(
            sourceVersionID: version, knowledgeObjectID: UUID(),
            fieldsWritten: 0, declineReason: "every proposal was rejected",
            rejectedNotFound: 4))
        let seen = await repo.attemptedVersionIDs()
        #expect(seen.contains(version),
                "without this the pass re-calls the model forever on documents where it already failed")

        // Idempotent by primary key: a second attempt for the same version
        // replaces rather than duplicating.
        await repo.record(InducedSchemaAttempt(
            sourceVersionID: version, knowledgeObjectID: nil,
            fieldsWritten: 2, declineReason: nil))
        let summary = await repo.summary()
        #expect(summary.attempted == 1, "one version must not produce two attempt rows")
        #expect(summary.produced == 1)
        #expect(summary.declined == 0)
    }

    @Test("A decline reason is truncated, not allowed to bloat the table")
    func reasonBounded() {
        let attempt = InducedSchemaAttempt(
            sourceVersionID: UUID(), knowledgeObjectID: nil, fieldsWritten: 0,
            declineReason: String(repeating: "x", count: 5_000))
        #expect((attempt.declineReason?.count ?? 0) <= InducedSchemaAttempt.maximumReasonLength)
    }
}

// MARK: - B-1 / B-2 · the layer diagnoses and their DEPENDENCY ORDER

@Suite("B-1/B-2 layer diagnoses — the first missing link is the cause")
struct LayerDiagnosisTests {

    private func freshDB() async throws -> (Database, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("diag-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try Database(url: dir.appendingPathComponent("db.sqlite"))
        try await SchemaMigrations.migrate(db)
        return (db, dir)
    }

    @Test("An empty archive blames NOTHING INGESTED — and calls it correct")
    func topicEmptyArchiveIsCorrectNotBroken() async throws {
        let (db, dir) = try await freshDB()
        defer { try? FileManager.default.removeItem(at: dir) }
        let d = await TopicLayerDiagnosis.run(database: db)
        let first = try #require(d.firstMissing)
        #expect(first.id == .documents,
                "with nothing ingested the cause is documents, not entities or groups")
        #expect(d.emptyButCorrect,
                "an empty archive is the app working, not failing — telling the user to fix it is worse than silence")
        #expect(!first.remedy.isEmpty, "the one actionable cause must carry its remedy")
    }

    @Test("Documents but no entities is a DEFECT, and stops the chain there")
    func topicNoEntitiesIsADefect() async throws {
        let (db, dir) = try await freshDB()
        defer { try? FileManager.default.removeItem(at: dir) }
        // One KO, no entities: the dependency order must report ENTITIES, not
        // the four consequences downstream of it.
        // A KO needs its `files` parent (FK), and the path lives THERE — the
        // real column layout, which is what caught two live defects in the
        // code under test.
        let fileID = UUID()
        try await db.exec("""
        INSERT INTO files (id, url, source_type, size_bytes, modified_at, ingested_at, content_hash)
        VALUES (?, ?, 'text', 10, 0, 0, 'h');
        """, [.uuid(fileID), .text("/tmp/a.txt")])
        try await db.exec("""
        INSERT INTO knowledge_objects (id, file_id, source_type, content, metadata_json,
            confidence, created_at, updated_at)
        VALUES (?, ?, 'text', 'body', '{}', 0.5, 0, 0);
        """, [.uuid(UUID()), .uuid(fileID)])

        let d = await TopicLayerDiagnosis.run(database: db)
        let first = try #require(d.firstMissing)
        #expect(first.id == .entities, "got \(first.id) — dependency order broken")
        #expect(first.outcome.isDefect, "ingested documents yielding no names IS a defect")
        #expect(!d.emptyButCorrect)
    }

    @Test("The story layer blames no subjects before no events")
    func historyDependencyOrder() async throws {
        let (db, dir) = try await freshDB()
        defer { try? FileManager.default.removeItem(at: dir) }
        let d = await HistoryLayerDiagnosis.run(database: db)
        let first = try #require(d.firstMissing)
        #expect(first.id == .entities, "got \(first.id)")
        #expect(d.emptyButCorrect, "no subjects yet is not a fault")
        #expect(!d.headline.isEmpty)
    }

    @Test("Link display names are stable and non-empty for every case")
    func linkNamesComplete() {
        for id in TopicLayerDiagnosis.LinkID.allCases {
            #expect(!id.displayName.isEmpty, "\(id) has no display name")
        }
        for id in HistoryLayerDiagnosis.LinkID.allCases {
            #expect(!id.displayName.isEmpty, "\(id) has no display name")
        }
    }
}

// MARK: - D-1 · fingerprint comparison

@Suite("D-1 fixed point — fingerprints catch replacement, not just growth")
struct FixedPointFingerprintTests {

    private func fp(_ table: String, rows: Int, hash: Int?) -> FixedPointCheck.TableFingerprint {
        FixedPointCheck.TableFingerprint(table: table, rowCount: rows,
                                        idHash: hash, hashSkippedReason: nil)
    }

    @Test("A changed row COUNT is a difference")
    func countChangeDetected() {
        #expect(fp("t", rows: 10, hash: 1).differs(from: fp("t", rows: 11, hash: 1)))
    }

    @Test("A stable count with CHANGED IDS is still a difference")
    func identityChangeDetected() {
        // The topic-rebuild defect's actual shape: delete one, insert another.
        // Every dashboard count looks correct while ids churn underneath.
        #expect(fp("t", rows: 10, hash: 111).differs(from: fp("t", rows: 10, hash: 222)))
    }

    @Test("Identical fingerprints do not differ")
    func stableIsStable() {
        #expect(!fp("t", rows: 10, hash: 111).differs(from: fp("t", rows: 10, hash: 111)))
    }

    @Test("With no hash available, only the count can be compared — and that is weaker")
    func countOnlyIsWeaker() {
        // Honest limitation, asserted so it is not mistaken for full coverage:
        // a replacement is INVISIBLE when ids cannot be hashed.
        #expect(!fp("t", rows: 10, hash: nil).differs(from: fp("t", rows: 10, hash: nil)))
        #expect(fp("t", rows: 10, hash: nil).differs(from: fp("t", rows: 12, hash: nil)))
    }
}

// MARK: - PERF · the property that made the tokenizer fix shippable

@Suite("BGETokenizer — the fast path emits IDENTICAL ids")
struct BGETokenizerParityTests {

    @Test("Length-descending lookup matches the legacy bucket scan exactly")
    func parityWithLegacyScan() throws {
        guard let tok = BGETokenizer() else {
            // NOT a silent skip. The reranker feeds these ids to a scoring
            // model; "we could not check" must be visible in the run, because
            // a quietly skipped parity check is indistinguishable from a
            // passing one.
            Issue.record("tokenizer.json is not bundled in the test target — tokenizer PARITY WAS NOT VERIFIED by this run")
            return
        }
        let mismatches = tok.parityMismatches(in: BGETokenizer.paritySamples)
        let shown = mismatches.map { String($0.prefix(40)) }.joined(separator: " | ")
        #expect(mismatches.isEmpty,
                "tokenization diverged on \(mismatches.count) sample(s): \(shown) — diverging ids silently reorder evidence with no latency signal")
    }

    @Test("The vocab really is dominated by one first-character bucket")
    func hotBucketMeasured() throws {
        guard let tok = BGETokenizer() else {
            Issue.record("tokenizer.json not bundled — bucket shape not measured")
            return
        }
        let d = tok.vocabDiagnostics
        #expect(d.tokens > 1_000, "a real vocab was expected, got \(d.tokens)")
        #expect(d.maxPiece >= 1)
        // The root cause, recorded as a measurement: an index keyed on a
        // character nearly every token shares is a full scan in disguise. If a
        // future vocab swap makes this small, the old bucket scan would have
        // been fine and this note should be revisited.
        let pct = Int(d.largestBucketShare * 100)
        #expect(d.largestBucketShare > 0.2,
                "largest bucket is \(pct)% — the documented cause assumed it dominates")
    }
}

// MARK: - The test that would have caught the two live defects

@Suite("Every new diagnostic's SQL actually EXECUTES against the real schema")
struct DiagnosticQueryExecutionTests {

    // WHY THIS SUITE EXISTS, and it is the most useful thing in this file.
    //
    // The suites above test PURE FUNCTIONS — gates, comparisons, phrase
    // selection. Every one passed while two shipped features were dead:
    //
    //   GoldenThread selected `knowledge_objects.source_file`. There is no such
    //   column; the path lives in `files.url`. Every trace threw, and the UI
    //   said "could not trace" forever.
    //
    //   ExtractionLanguageReport read `json_extract(metadata, …)`. The column
    //   is `metadata_json`. It threw, returned nil, and the Ingestion Report
    //   silently omitted the language section — an English-only limit rendered
    //   as NO limit. The precise failure that report was written to prevent.
    //
    // Neither is visible to the compiler, because SQL is a string, and neither
    // is visible to a unit test that never opens a database. So these run each
    // diagnostic against a MIGRATED, EMPTY ledger and assert only that it did
    // not fail to run. Emptiness is fine — a wrong column name is not.
    //
    // Empty is deliberately the fixture: a bad identifier throws on PREPARE,
    // before any row is read, so zero rows is enough to catch it and the test
    // stays fast.

    private func freshDB() async throws -> (Database, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sqlexec-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try Database(url: dir.appendingPathComponent("db.sqlite"))
        try await SchemaMigrations.migrate(db)
        return (db, dir)
    }

    @Test("The language report's query names real columns")
    func languageReportQueryRuns() async throws {
        let (db, dir) = try await freshDB()
        defer { try? FileManager.default.removeItem(at: dir) }
        // nil here means the query FAILED (the reason the report returns nil at
        // all). On an empty-but-valid ledger it must return a report with zero
        // documents, never nil.
        let report = await ExtractionLanguageReport.build(database: db)
        if KnowledgeModuleFlags.isEnabled(.languageHonesty) {
            let r = try #require(report, "the language query did not execute — check column names")
            #expect(r.totalDocuments == 0)
            #expect(r.limitationStatement() == nil, "no documents means no limit to state")
        }
    }

    @Test("Both layer diagnoses run every query to the end of their chain")
    func layerDiagnosesRunFully() async throws {
        let (db, dir) = try await freshDB()
        defer { try? FileManager.default.removeItem(at: dir) }
        // On an EMPTY ledger both short-circuit early, so seed enough that the
        // chain runs past its guards and the LATER queries — document_terms,
        // community_summaries, event_entities, history_item_evidence — are
        // actually prepared. Those were never executed by the suites above.
        let fileID = UUID(), koID = UUID(), entityID = UUID()
        try await db.exec("""
        INSERT INTO files (id, url, source_type, size_bytes, modified_at, ingested_at, content_hash)
        VALUES (?, '/tmp/x.txt', 'text', 10, 0, 0, 'h');
        """, [.uuid(fileID)])
        try await db.exec("""
        INSERT INTO knowledge_objects (id, file_id, source_type, content, metadata_json,
            confidence, created_at, updated_at)
        VALUES (?, ?, 'text', 'body', '{}', 0.5, 0, 0);
        """, [.uuid(koID), .uuid(fileID)])
        try await db.exec("""
        INSERT INTO entities (id, kind, value, normalized, source_object_id, confidence, attributes_json)
        VALUES (?, 'person', 'Asha Rao', 'asha rao', ?, 0.9, '{}');
        """, [.uuid(entityID), .uuid(koID)])
        try await db.exec("""
        INSERT INTO entity_communities (community_id, entity_id, level, computed_at)
        VALUES ('c1', ?, 0, 0);
        """, [.uuid(entityID)])
        try await db.exec("""
        INSERT INTO document_terms (object_id, term, score, is_identifier, corroboration)
        VALUES (?, 'consideration', 0.8, 0, 3);
        """, [.uuid(koID)])
        try await db.exec("""
        INSERT INTO events (id, kind, date, title, source_object_id, confidence, attributes_json)
        VALUES (?, 'generic', 0, 'Something happened', ?, 0.8, '{}');
        """, [.uuid(UUID()), .uuid(koID)])

        let topic = await TopicLayerDiagnosis.run(database: db)
        for link in topic.links {
            #expect(!link.outcome.isUnknown,
                    "topic link \(link.name) could not be checked — a query failed: \(link.outcome.line)")
        }
        let history = await HistoryLayerDiagnosis.run(database: db)
        for link in history.links {
            #expect(!link.outcome.isUnknown,
                    "history link \(link.name) could not be checked — a query failed: \(link.outcome.line)")
        }
    }

    @Test("The superseded-table invariant reads all four tables")
    func supersededQueriesRun() async throws {
        let (db, dir) = try await freshDB()
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = await SupersededSchema.unexpectedlyPopulated(database: db)
        #expect(r.unreadable.isEmpty,
                "unreadable: \(r.unreadable) — a COUNT that cannot run is NOT a verified-empty table")
    }

    @Test("The attempt ledger's summary query runs on an empty table")
    func attemptSummaryRuns() async throws {
        let (db, dir) = try await freshDB()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = InducedSchemaAttemptRepository(database: db)
        let s = await repo.summary()
        #expect(s == (0, 0, 0))
        #expect(await repo.attemptsReadable, "the attempt read failed — induction would refuse to run")
    }

    @Test("The Golden Thread's document picker executes — the defect this suite caught")
    func goldenThreadSelectionRuns() async throws {
        let (db, dir) = try await freshDB()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Empty ledger: nil (no match), NOT a throw. A throw here is a bad
        // column name, which is exactly what shipped.
        let none = try await GoldenThread.selectDocument(database: db, matching: nil)
        #expect(none == nil, "an empty ledger has no document to trace")
        let noMatch = try await GoldenThread.selectDocument(database: db, matching: "nothing")
        #expect(noMatch == nil)

        // With one document it must resolve the id AND the path — the path
        // lives in `files.url`, which the broken version never reached.
        let fileID = UUID(), koID = UUID()
        try await db.exec("""
        INSERT INTO files (id, url, source_type, size_bytes, modified_at, ingested_at, content_hash)
        VALUES (?, '/tmp/deed-of-sale.pdf', 'pdf', 10, 0, 0, 'h');
        """, [.uuid(fileID)])
        try await db.exec("""
        INSERT INTO knowledge_objects (id, file_id, source_type, content, metadata_json,
            confidence, created_at, updated_at)
        VALUES (?, ?, 'pdf', 'body', '{}', 0.5, 1, 1);
        """, [.uuid(koID), .uuid(fileID)])

        let latest = try #require(try await GoldenThread.selectDocument(database: db, matching: nil))
        #expect(latest.id == koID)
        #expect(latest.path.hasSuffix("deed-of-sale.pdf"), "got “\(latest.path)” — the path must come from files.url")

        let byName = try #require(try await GoldenThread.selectDocument(database: db, matching: "DEED"))
        #expect(byName.id == koID, "the filename filter must be case-insensitive")
        #expect(try await GoldenThread.selectDocument(database: db, matching: "absent-file") == nil)
    }

    @Test("Format coverage derives from the real registry without throwing")
    func coverageDerives() async throws {
        // P3.5 touches no database, but it DOES build the whole parser registry,
        // which throws on any routing inconsistency.
        let rows = try await MainActor.run { try UniversalParserRegistryBuilder.coverage(ocr: VisionOCR()) }
        #expect(!rows.isEmpty, "the registry claims no source types at all")
        for r in rows {
            #expect(!r.level.isEmpty)
            #expect(!r.pluginID.isEmpty, "\(r.type.rawValue) has an anonymous owner")
        }
        let unclaimed = try await MainActor.run { try UniversalParserRegistryBuilder.unclaimedTypes(ocr: VisionOCR()) }
        // Not asserted empty — an unclaimed type is a real, reportable state.
        // Asserted only that asking the question does not throw.
        #expect(unclaimed.count >= 0)
    }
}
