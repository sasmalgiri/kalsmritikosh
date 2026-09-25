//
//  EngineFiringTests.swift
//  KalsmritikoshTests
//
//  "Is ingestion working properly and do ALL ENGINES FIRE?"
//
//  Every check before this one measured the tables I happened to name —
//  documents, chunks, entities, events, facts. That answers "did the main path
//  run", not "did every producer run". A pipeline with thirty producers can
//  look healthy on six of them while two dozen sit silent, and the counts I was
//  reporting could not tell the difference.
//
//  So this ENUMERATES the schema instead of naming tables: ingest the real
//  archive, run every derived pass the app runs, then report the row count of
//  EVERY real table. Nothing is left out because I forgot to look at it.
//
//  A ZERO IS NOT AUTOMATICALLY A FAULT, and the classification is the point:
//
//    fired            rows present — the engine ran and produced
//    silent-by-design the feature is off, opt-in, on-demand, or needs input
//                     this archive does not contain
//    SILENT-UNEXPECTED it should have produced on this input and did not
//
//  The third list is the answer to the owner's question. The first two are
//  context that stops the third from being read as alarming.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("ENGINE FIRING — does every producer run on a real ingest?", .serialized)
@MainActor
struct EngineFiringTests {

    /// Tables that are EMPTY ON PURPOSE after a plain document ingest, with the
    /// reason. Anything not listed here and still empty is reported as
    /// unexpected, so a new silent producer cannot hide behind an unexplained
    /// zero.
    static let silentByDesign: [String: String] = [
        // Superseded schema — see SupersededSchema.swift. Writing these would
        // fork the truth.
        "people": "superseded by entities(kind:.person)",
        "companies": "superseded by entities(kind:.organization)",
        "projects": "superseded by entities(kind:.project)",
        "timelines": "superseded by events composed on read",
        "vectors": "legacy table, read by a migration only",
        "evidence_block_edges": "declared, feature never built",
        // On-demand: a user action creates these, not an ingest.
        "investigations": "created when the user opens an investigation",
        "investigation_steps": "ditto",
        "saved_queries": "created when the user saves a query",
        "saved_views": "created when the user saves a view",
        "saved_view_filters": "ditto",
        "review_decisions": "created when the user reviews an item",
        "review_tags": "ditto",
        "screening_protocols": "created when the user defines screening",
        "screening_records": "ditto",
        "history_artifacts": "a story is reconstructed when asked for",
        "history_chapters": "ditto",
        "history_items": "ditto",
        "history_item_evidence": "ditto",
        "history_gaps": "ditto",
        "history_alternative_accounts": "ditto",
        "qa_pairs": "recorded when the user asks a question",
        "conversation_turns": "ditto",
        "answer_ledger": "ditto",
        "monitor_snapshots": "written when the Changes digest is acknowledged",
        "corpus_snapshots": "written on the answer path",
        "derived_objects": "written on the answer path",
        // Opt-in modules, default off.
        "induced_schema_attempts": "schema induction defaults OFF",
        "transcript_segments": "audio/video transcription is opt-in",
        // Needs input this archive does not contain.
        "container_inspections": "no archive/zip at the top level of the input",
        "password_protected_files": "no encrypted files in the input",
        "derivation_failures": "nothing failed — this empty IS the good result",
    ]

    @Test("Ingest the real archive, run every pass, and report every engine",
          .timeLimit(.minutes(60)))
    func everyEngineReportsIn() async throws {
        let files = RealArchivePipelineTests.smallFiles()
        guard !files.isEmpty else {
            Issue.record("~/Downloads/Mail not found — ENGINE FIRING WAS NOT CHECKED")
            return
        }
        let (state, dir) = try await RealArchivePipelineTests.bootState(label: "engines")
        guard case .ready = state.phase else {
            Issue.record("AppState did not boot — engine firing NOT checked")
            await RealArchivePipelineTests.teardown(state, dir); return
        }
        let db = try #require(state.database)

        // 1 — ingest
        let t0 = Date()
        await state.ingestFiles(files)
        let ingestSeconds = Date().timeIntervalSince(t0)

        // 2 — run the DERIVED passes to completion. Without this, engines that
        // run at boot or idle would be reported silent merely because the test
        // tore down before they were scheduled — measuring my own impatience
        // rather than the pipeline.
        let t1 = Date()
        _ = try? await FixedPointCheck.run(state)   // runs drain + reindex + salience + topic tree + twins, to quiescence
        let derivedSeconds = Date().timeIntervalSince(t1)

        // 3 — enumerate EVERY real table and count it.
        let tableRows = (try? await db.query("""
        SELECT name FROM sqlite_master
        WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE '%_fts%'
        ORDER BY name;
        """, [])) ?? []
        let tables = tableRows.compactMap { $0.string(0) }
            .filter { !$0.contains("__v") && !$0.hasSuffix("_old") }

        var fired: [(String, Int)] = []
        var byDesign: [(String, String)] = []
        var unexpected: [String] = []
        var unreadable: [String] = []

        for t in tables {
            guard let r = try? await db.query("SELECT COUNT(*) FROM \"\(t)\";", []) else {
                unreadable.append(t); continue
            }
            let n = Int(r.first?.int(0) ?? 0)
            if n > 0 { fired.append((t, n)) }
            else if let why = Self.silentByDesign[t] { byDesign.append((t, why)) }
            else { unexpected.append(t) }
        }

        print("══ ENGINE FIRING REPORT")
        print("   \(files.count) file(s) ingested in \(String(format: "%.0f", ingestSeconds))s; "
            + "derived passes \(String(format: "%.0f", derivedSeconds))s")
        print("   \(tables.count) real tables · \(fired.count) FIRED · "
            + "\(byDesign.count) silent by design · \(unexpected.count) SILENT-UNEXPECTED")

        print("\n── FIRED (\(fired.count))")
        for (t, n) in fired.sorted(by: { $0.1 > $1.1 }) { print("   \(n)\t\(t)") }

        print("\n── SILENT, BY DESIGN (\(byDesign.count))")
        for (t, why) in byDesign.sorted(by: { $0.0 < $1.0 }) { print("   \(t) — \(why)") }

        print("\n── SILENT, UNEXPECTED (\(unexpected.count)) ← the answer to the question")
        for t in unexpected.sorted() { print("   \(t)") }

        if !unreadable.isEmpty {
            print("\n── COULD NOT BE READ (\(unreadable.count)) — not verified empty")
            for t in unreadable.sorted() { print("   \(t)") }
        }

        // The load-bearing assertions. Counts are printed above because the
        // NUMBERS are the deliverable; these pin the properties.
        #expect(!fired.isEmpty)
        #expect(unreadable.isEmpty, "unreadable tables are not verified empty: \(unreadable)")
        // Core lanes MUST have fired on 19 real documents. Named explicitly so a
        // regression in any one of them is a red, not a line in a dump.
        for core in ["files", "knowledge_objects", "evidence_blocks", "chunks",
                     "entities", "entity_mentions", "events", "generic_facts",
                     "chunk_embeddings", "document_terms",
                     // Added after this sweep found it DEAD: the repository was
                     // constructed nowhere outside its own unit test, so ten
                     // real .eml files wrote zero participants. Pinned here
                     // because a lane that is silent in production while its
                     // own tests pass is invisible any other way.
                     "email_participant_occurrences"] {
            #expect(fired.contains { $0.0 == core },
                    "CORE ENGINE SILENT: \(core) produced nothing from \(files.count) real documents")
        }
        await RealArchivePipelineTests.teardown(state, dir)
    }
}
