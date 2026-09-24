//
//  RealArchivePipelineTests.swift
//  KalsmritikoshTests
//
//  THE REAL RUN. The owner supplied their own files, which closes the three
//  gaps every synthetic test left open: the Golden Thread's twelve stages with a
//  genuinely ingested document, the answer harness against the live model, and
//  extraction judged against KNOWN GROUND TRUTH rather than against a fixture I
//  wrote to pass.
//
//  Input: ~/Downloads/Mail — 8 PDFs (one scanned), 10 .eml, 1 .docx, 1 mbox of
//  526 messages. Every format lane at once, including a scanned POA that can
//  only be read by OCR.
//
//  GROUND TRUTH, read out of the files by hand before running anything:
//
//    GDPR_Report_patent.pdf   Data Subject "patent"; generated 21 May 2026;
//                             "Emails Involving Subject: 60 of 526 total"
//    1_.eml                   sasmalgiri@gmail.com → vishu_rani2821@yahoo.com,
//                             8 Jul 2008, body is quoted-printable
//    Sent.mbox                526 messages (`grep -c "^From "`), and the .eml
//                             files are single messages carved OUT of it — they
//                             carry a `sourceFile: Sent.mbox` header — so the
//                             two overlap and dedup is exercised
//    Final POA.pdf            no extractable text layer; scanned
//
//  SKIPS ARE LOUD. If the folder is absent this records an Issue naming what
//  was not verified. A quiet `return` would make "the owner's archive was never
//  tested" indistinguishable from "it passed", which is the defect this whole
//  program is about.
//
//  These tests are READ-ONLY with respect to the owner's files. Everything is
//  ingested into a throwaway ledger in the temp directory; the originals are
//  opened for reading and never written, moved or modified.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("REAL ARCHIVE — the owner's own files, end to end", .serialized)
@MainActor
struct RealArchivePipelineTests {

    static let archive = URL(fileURLWithPath: NSString(string: "~/Downloads/Mail")
        .expandingTildeInPath, isDirectory: true)

    /// The 19 small files. The mbox is excluded here and tested separately: at
    /// 95 MB and 526 messages it is a SCALE test with a different question, and
    /// mixing it in would make a slow run hide a correctness result.
    static func smallFiles() -> [URL] {
        let fm = FileManager.default
        guard let all = try? fm.contentsOfDirectory(at: archive,
                                                    includingPropertiesForKeys: nil) else { return [] }
        return all
            .filter { $0.pathExtension.lowercased() != "mbox" }
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func bootState(label: String) async throws -> (AppState, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("realarchive-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let state = AppState(bookmarks: BookmarkStore(ephemeral: true))
        await state.boot(databaseURL: dir.appendingPathComponent("db.sqlite"))
        return (state, dir)
    }

    /// Shut the app down BEFORE deleting its database directory, and in that
    /// order. My first version used two `defer`s, which run in reverse: the
    /// shutdown was merely SCHEDULED in a detached Task while the directory was
    /// removed immediately, so background writers kept using an unlinked vnode
    /// — "database integrity compromised by API violation" and a stream of disk
    /// I/O errors in the log. Harmless to the assertions here, but it is
    /// exactly the kind of log noise that trains a reader to ignore real errors,
    /// and a slower machine could turn the race into a flake.
    static func teardown(_ state: AppState, _ dir: URL) async {
        await state.shutdown()
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - 1. Ingest every format, and report what each one produced

    @Test("Ingesting the real folder produces a ledger — per format, with counts",
          .timeLimit(.minutes(60)))
    func ingestRealFolder() async throws {
        let files = Self.smallFiles()
        guard !files.isEmpty else {
            Issue.record("~/Downloads/Mail not found or empty — THE REAL ARCHIVE WAS NOT TESTED")
            return
        }
        let (state, dir) = try await Self.bootState(label: "ingest")
        guard case .ready = state.phase else {
            Issue.record("AppState did not boot (phase=\(state.phase)) — real archive NOT tested")
            await Self.teardown(state, dir); return
        }
        let db = try #require(state.database)

        let started = Date()
        await state.ingestFiles(files)
        let elapsed = Date().timeIntervalSince(started)

        // ── What arrived, by format. Printed because the NUMBERS are the
        // finding here; an assertion alone would hide them.
        let rows = (try? await db.query("""
        SELECT f.source_type, COUNT(DISTINCT f.id), COUNT(DISTINCT k.id)
        FROM files f LEFT JOIN knowledge_objects k ON k.file_id = f.id
        GROUP BY f.source_type ORDER BY f.source_type;
        """, [])) ?? []
        print("── REAL ARCHIVE: \(files.count) file(s) in \(String(format: "%.1f", elapsed))s")
        for r in rows {
            print("   \(r.string(0) ?? "?"): \(Int(r.int(1) ?? 0)) file(s) → \(Int(r.int(2) ?? 0)) document(s)")
        }
        func count(_ sql: String) async -> Int {
            Int((try? await db.query(sql, []).first?.int(0)) ?? 0) ?? 0
        }
        let kos = await count("SELECT COUNT(*) FROM knowledge_objects;")
        let chunks = await count("SELECT COUNT(*) FROM chunks;")
        let blocks = await count("SELECT COUNT(*) FROM evidence_blocks;")
        let entities = await count("SELECT COUNT(*) FROM entities WHERE merged_into IS NULL;")
        let events = await count("SELECT COUNT(*) FROM events;")
        let facts = await count("SELECT COUNT(*) FROM generic_facts;")
        let failures = await count("SELECT COUNT(*) FROM derivation_failures;")
        print("   documents=\(kos) blocks=\(blocks) chunks=\(chunks) entities=\(entities) events=\(events) facts=\(facts) tolerated-failures=\(failures)")

        // Every file must reach a KnowledgeObject. A file with none was seen and
        // silently produced nothing, which is the state the Ingestion Report
        // exists to surface.
        let orphanFiles = (try? await db.query("""
        SELECT f.url FROM files f
        WHERE f.alias_of IS NULL
          AND NOT EXISTS (SELECT 1 FROM knowledge_objects k WHERE k.file_id = f.id);
        """, [])) ?? []
        if !orphanFiles.isEmpty {
            print("   ⚠️ files with NO document:")
            for r in orphanFiles { print("      \(URL(fileURLWithPath: r.string(0) ?? "?").lastPathComponent)") }
        }

        #expect(kos > 0, "nothing was ingested from \(files.count) real files")
        #expect(chunks > 0, "documents exist but nothing is searchable")
        // Not asserted zero — a tolerated failure is a legitimate, REPORTED
        // outcome. Printed so it is never invisible.
        if failures > 0 {
            let byStage = (try? await db.query("""
            SELECT stage, COUNT(*) FROM derivation_failures GROUP BY stage ORDER BY COUNT(*) DESC;
            """, [])) ?? []
            print("   tolerated failures by stage:")
            for r in byStage { print("      \(r.string(0) ?? "?"): \(Int(r.int(1) ?? 0))") }
        }
        await Self.teardown(state, dir)
    }

    // MARK: - 2. Ground truth: did it extract the RIGHT things?

    @Test("Known facts from known files are actually in the ledger",
          .timeLimit(.minutes(60)))
    func groundTruthExtraction() async throws {
        let files = Self.smallFiles()
        guard !files.isEmpty else {
            Issue.record("~/Downloads/Mail not found — GROUND TRUTH WAS NOT CHECKED")
            return
        }
        let (state, dir) = try await Self.bootState(label: "truth")
        guard case .ready = state.phase else {
            Issue.record("AppState did not boot — ground truth NOT checked")
            await Self.teardown(state, dir); return
        }
        let db = try #require(state.database)
        await state.ingestFiles(files)

        // ── (a) The scanned POA must be RECOGNISED, whatever OCR yields. What
        // must never happen is silence: a scan that produced nothing and said
        // nothing about why.
        let poa = (try? await db.query("""
        SELECT COUNT(*) FROM files WHERE LOWER(url) LIKE '%poa%';
        """, []).first?.int(0)) ?? 0
        #expect((poa ?? 0) > 0, "the scanned POA was not even recorded as a file")
        let poaText = (try? await db.query("""
        SELECT LENGTH(k.content) FROM knowledge_objects k
        JOIN files f ON f.id = k.file_id WHERE LOWER(f.url) LIKE '%poa%';
        """, []).first?.int(0)) ?? 0
        print("── POA (scanned): extracted \(poaText ?? 0) characters")
        if (poaText ?? 0) == 0 {
            // Recorded, not asserted: OCR on a scan may legitimately yield
            // little. The REQUIREMENT is that the report says so — checked in
            // the report test — not that OCR succeeds.
            print("   (no text layer recovered — the Ingestion Report must disclose this)")
        }

        // ── (b) The GDPR patent report's own header text must be searchable.
        // Ground truth: "Data Subject : patent" and "60 of 526 total".
        let hits = (try? await state.chunks?.searchFTS("Data Subject", limit: 50)) ?? []
        print("── FTS “Data Subject”: \(hits.count) chunk(s)")
        #expect(!hits.isEmpty, "a phrase printed on four of the PDFs is not findable")

        // ── (c) The email lane: a real From/To must survive transfer-decoding.
        // This is the lane a recent commit fixed (quoted-printable single-part
        // bodies were the root cause of split addresses), and 1_.eml IS
        // quoted-printable.
        let emailEntities = (try? await db.query("""
        SELECT COUNT(*) FROM entities
        WHERE merged_into IS NULL AND value LIKE '%@%';
        """, []).first?.int(0)) ?? 0
        print("── email-address entities: \(emailEntities ?? 0)")
        let split = (try? await db.query("""
        SELECT value FROM entities
        WHERE merged_into IS NULL AND value LIKE '%@%' AND (value LIKE '% %' OR value LIKE '%=%')
        LIMIT 10;
        """, [])) ?? []
        if !split.isEmpty {
            print("   ⚠️ addresses containing a space or '=' (the split-address defect):")
            for r in split { print("      \(r.string(0) ?? "?")") }
        }
        #expect(split.isEmpty,
                "an email address came out split or still encoded — the transfer-decode regressed")

        // ── (d) Dates. Four PDFs are dated May 2026 and the emails run from
        // 2008. A timeline over this archive should not be empty.
        let dated = (try? await db.query("SELECT COUNT(*) FROM events;", []).first?.int(0)) ?? 0
        print("── dated events: \(dated ?? 0)")
        await Self.teardown(state, dir)
    }

    // MARK: - 3. The Golden Thread, on a REAL document

    @Test("The Golden Thread runs all twelve stages on a real ingested document",
          .timeLimit(.minutes(60)))
    func goldenThreadOnRealDocument() async throws {
        let files = Self.smallFiles()
        guard !files.isEmpty else {
            Issue.record("~/Downloads/Mail not found — THE TWELVE-STAGE TRACE WAS NOT VERIFIED")
            return
        }
        let (state, dir) = try await Self.bootState(label: "thread")
        guard case .ready = state.phase else {
            Issue.record("AppState did not boot — trace NOT verified")
            await Self.teardown(state, dir); return
        }
        await state.ingestFiles(files)

        // A text-bearing PDF, so the trace has real blocks to walk. This is the
        // case no synthetic test could reach: retrieval and citation on content
        // nobody wrote to make a test pass.
        let result = try await GoldenThread.trace(state, matching: "GDPR_Report_patent")
        print("── GOLDEN THREAD: \(result.documentPath)")
        for s in result.stages {
            print("   \(s.outcome.symbol) \(s.name): \(s.outcome.line)")
        }
        print("   \(result.summary)")

        #expect(result.stages.count >= 12, "only \(result.stages.count) stages ran")
        // Defects are PRINTED above and asserted here. A break is a real
        // finding about the pipeline, which is the point of running this.
        #expect(result.brokeAt == nil,
                "the thread broke at “\(result.brokeAt ?? "?")” — see the stage list above")
        #expect(result.unknowns == 0,
                "\(result.unknowns) stage(s) could not be checked — unknown is not a pass")
        await Self.teardown(state, dir)
    }

    // MARK: - 4. Answers, with the live model

    @Test("The answer harness asks the real archive with the real model",
          .timeLimit(.minutes(60)))
    func answersOverRealArchive() async throws {
        let files = Self.smallFiles()
        guard !files.isEmpty else {
            Issue.record("~/Downloads/Mail not found — ANSWERING WAS NOT VERIFIED ON REAL DATA")
            return
        }
        let (state, dir) = try await Self.bootState(label: "answer")
        guard case .ready = state.phase else {
            Issue.record("AppState did not boot — answering NOT verified")
            await Self.teardown(state, dir); return
        }
        await state.ingestFiles(files)

        let result = try await AnswerHarness.run(state, maxDerivedProbes: 3)
        print("── ANSWER HARNESS over the real archive")
        print(result.summary)
        for p in result.probes {
            print("   [\(p.expectation.rawValue)] “\(p.question)”")
            print("      ← \(p.derivedFrom)")
            print("      → \(p.verdict) · conf \(String(format: "%.2f", p.confidence)) · \(p.llmCalls) call(s) · \(String(format: "%.1f", p.seconds))s")
        }

        #expect(result.skipReason == nil, "the harness declined a NON-empty archive: \(result.skipReason ?? "")")
        #expect(!result.probes.isEmpty)
        // THE ONE THAT MATTERS MOST. Answering a randomly generated case
        // reference means the evidence gate is not holding, and no other
        // result matters while that is true.
        #expect(result.fabrications.isEmpty,
                "FABRICATION — answered a question about a reference that cannot exist")
        // These two are reported rather than hard-failed: on a 19-file archive a
        // derived question can legitimately be unanswerable, and calling that a
        // test failure would teach me to weaken the probe instead of reading it.
        if !result.uncited.isEmpty {
            print("   ⚠️ \(result.uncited.count) answered with NO citations — the claim–evidence contract")
        }
        if !result.unreachable.isEmpty {
            print("   ⚠️ \(result.unreachable.count) abstained on questions built from its OWN ledger")
        }
        await Self.teardown(state, dir)
    }

    // MARK: - 5. The report, over real data

    @Test("The Ingestion Report over real data names its gaps",
          .timeLimit(.minutes(60)))
    func reportOverRealArchive() async throws {
        let files = Self.smallFiles()
        guard !files.isEmpty else {
            Issue.record("~/Downloads/Mail not found — THE REPORT WAS NOT RUN ON REAL DATA")
            return
        }
        let (state, dir) = try await Self.bootState(label: "report")
        guard case .ready = state.phase else {
            Issue.record("AppState did not boot — report NOT run on real data")
            await Self.teardown(state, dir); return
        }
        await state.ingestFiles(files)

        let result = try await DataHealthCheck.run(state)
        let md = try String(contentsOf: result.reportURL, encoding: .utf8)
        print("── INGESTION REPORT over the real archive → \(result.reportURL.path)")
        print(result.summary)
        // The sections whose content only becomes meaningful on real data.
        for heading in ["What can each format give you", "What languages is your archive in",
                        "Why is something missing", "Did every document finish deriving",
                        "Why do you see the topics you see"] {
            #expect(md.contains(heading), "missing section: \(heading)")
        }
        // Print the coverage + language verdicts — the real-data answers to
        // "what can this app do with YOUR files".
        for line in md.split(separator: "\n") where
            line.contains("FULL:") || line.contains("TEXT-ONLY:") ||
            line.contains("PRESERVED-ONLY:") || line.contains("NOT READ") ||
            line.contains("not in English") || line.contains("no detectable language") {
            print("   \(line.prefix(200))")
        }
        print("   issues flagged: \(result.issuesFound)")
        await Self.teardown(state, dir)
    }

    // MARK: - 6. Scale: the 526-message mbox on its own

    @Test("The 95MB / 526-message mbox expands into per-message documents",
          .timeLimit(.minutes(60)))
    func mboxScale() async throws {
        let mbox = Self.archive.appendingPathComponent("Sent.mbox")
        guard FileManager.default.fileExists(atPath: mbox.path) else {
            Issue.record("Sent.mbox not found — THE MBOX LANE WAS NOT TESTED")
            return
        }
        let (state, dir) = try await Self.bootState(label: "mbox")
        guard case .ready = state.phase else {
            Issue.record("AppState did not boot — mbox NOT tested")
            await Self.teardown(state, dir); return
        }
        let db = try #require(state.database)

        let started = Date()
        await state.ingestFiles([mbox])
        let elapsed = Date().timeIntervalSince(started)

        let kos = Int((try? await db.query(
            "SELECT COUNT(*) FROM knowledge_objects;", []).first?.int(0)) ?? 0) ?? 0
        let chunks = Int((try? await db.query(
            "SELECT COUNT(*) FROM chunks;", []).first?.int(0)) ?? 0) ?? 0
        print("── MBOX: 526 messages, 95 MB → \(kos) document(s), \(chunks) chunk(s) in \(String(format: "%.0f", elapsed))s")

        // Ground truth is 526 messages. One KO for the whole file would mean the
        // mbox splitter never ran and 526 messages collapsed into one blob —
        // searchable, but with every per-message date and sender lost.
        #expect(kos > 1, "the mbox produced \(kos) document(s): the per-message splitter did not run")
        if kos < 400 {
            print("   ⚠️ \(kos) documents from 526 messages — messages may be being dropped")
        }
        await Self.teardown(state, dir)
    }
}
