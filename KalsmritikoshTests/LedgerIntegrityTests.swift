//
//  LedgerIntegrityTests.swift
//  KalsmritikoshTests
//
//  "Is the database building properly?"
//
//  A different question from the engine sweep, which asked whether rows EXIST.
//  This asks whether the rows that exist are STRUCTURALLY SOUND — whether every
//  reference resolves, every derived row still has the thing it was derived
//  from, and the ledger is not mostly duplicates of itself.
//
//  Nothing built before this checked any of that. Counts can look healthy over
//  a ledger full of orphans: a fact citing a deleted block still counts as a
//  fact, and an answer built on it still counts as cited.
//
//  SIX PROPERTIES, each the kind that silently rots:
//
//   1. FOREIGN KEYS — `PRAGMA foreign_key_check`, the one authoritative answer
//      SQLite will give for free and which I had never asked for.
//   2. ORPHANS across the derivation chain: a chunk whose document is gone, an
//      embedding whose chunk is gone, a mention whose entity is gone, an
//      event_entities row pointing at neither, a fact citing a block that does
//      not exist. FKs catch these only where a FK was declared.
//   3. THE CLAIM–EVIDENCE CONTRACT — every fact's `source_blocks_json` must
//      name blocks that RESOLVE. A fact whose evidence cannot be produced is
//      exactly the thing this product promises never to show.
//   4. DUPLICATE DENSITY — the ledger was once 96% duplicate facts. Measured,
//      not assumed.
//   5. CANONICALIZATION — `merged_into` must point at a live, non-merged
//      entity; a chain or a dangling merge splits one subject into two.
//   6. IDENTIFIER ANCHOR UNIQUENESS — one anchor row per identity, the law the
//      whole anchor design rests on.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("LEDGER INTEGRITY — is the database built soundly?", .serialized)
@MainActor
struct LedgerIntegrityTests {

    @Test("Build the ledger from the real archive, then audit its structure",
          .timeLimit(.minutes(60)))
    func ledgerIsStructurallySound() async throws {
        let files = RealArchivePipelineTests.smallFiles()
        guard !files.isEmpty else {
            Issue.record("~/Downloads/Mail not found — LEDGER INTEGRITY WAS NOT CHECKED")
            return
        }
        let (state, dir) = try await RealArchivePipelineTests.bootState(label: "integrity")
        guard case .ready = state.phase else {
            Issue.record("AppState did not boot — integrity NOT checked")
            await RealArchivePipelineTests.teardown(state, dir); return
        }
        let db = try #require(state.database)
        await state.ingestFiles(files)
        _ = try? await FixedPointCheck.run(state)   // drive every derived pass

        func scalar(_ sql: String) async -> Int? {
            guard let r = try? await db.query(sql, []) else { return nil }
            return Int(r.first?.int(0) ?? 0)
        }
        var problems: [String] = []
        func check(_ label: String, _ sql: String, expectZero: Bool = true) async {
            guard let n = await scalar(sql) else {
                problems.append("\(label): PROBE FAILED — not verified")
                print("   ?  \(label): probe failed")
                return
            }
            let ok = expectZero ? n == 0 : n > 0
            print("   \(ok ? "✓" : "✗")  \(label): \(n)")
            if !ok { problems.append("\(label) = \(n)") }
        }

        print("══ LEDGER INTEGRITY")

        // 1 — SQLite's own verdict. FKs must be ON for this to mean anything.
        let fkOn = await scalar("PRAGMA foreign_keys;")
        print("   foreign_keys pragma = \(fkOn ?? -1) (0 would make the next line meaningless)")
        let fkViolations = (try? await db.query("PRAGMA foreign_key_check;", []))?.count
        if let fkViolations {
            print("   \(fkViolations == 0 ? "✓" : "✗")  foreign_key_check violations: \(fkViolations)")
            if fkViolations != 0 { problems.append("foreign_key_check = \(fkViolations)") }
        } else {
            problems.append("foreign_key_check: PROBE FAILED")
            print("   ?  foreign_key_check: probe failed")
        }

        // 2 — orphans along the derivation chain
        print("── orphans (each must be 0)")
        await check("chunks whose document is gone", """
            SELECT COUNT(*) FROM chunks c
            WHERE NOT EXISTS (SELECT 1 FROM knowledge_objects k WHERE k.id = c.object_id);
            """)
        await check("embeddings whose chunk is gone", """
            SELECT COUNT(*) FROM chunk_embeddings e
            WHERE NOT EXISTS (SELECT 1 FROM chunks c WHERE c.id = e.chunk_id);
            """)
        // `evidence_blocks.document_id` references SOURCE_DOCUMENTS — the parsed
        // structural document — NOT knowledge_objects. Blocks reach a KO through
        // the `evidence_block_objects` join. My first version of this check
        // assumed the KO referent and reported all 217 blocks as orphans, which
        // the Golden Thread had already disproved by resolving 8 of them to
        // citations. Assuming a column's referent is the same mistake as
        // assuming a call site; both need reading.
        await check("blocks whose source document is gone", """
            SELECT COUNT(*) FROM evidence_blocks b
            WHERE NOT EXISTS (SELECT 1 FROM source_documents d WHERE d.id = b.document_id);
            """)
        await check("blocks not linked to any knowledge object", """
            SELECT COUNT(*) FROM evidence_blocks b
            WHERE NOT EXISTS (
              SELECT 1 FROM evidence_block_objects x WHERE x.evidence_block_id = b.id);
            """)
        await check("block→object links pointing at a missing block", """
            SELECT COUNT(*) FROM evidence_block_objects x
            WHERE NOT EXISTS (SELECT 1 FROM evidence_blocks b WHERE b.id = x.evidence_block_id);
            """)
        await check("block→object links pointing at a missing object", """
            SELECT COUNT(*) FROM evidence_block_objects x
            WHERE NOT EXISTS (
              SELECT 1 FROM knowledge_objects k WHERE k.id = x.knowledge_object_id);
            """)
        await check("mentions whose entity is gone", """
            SELECT COUNT(*) FROM entity_mentions m
            WHERE NOT EXISTS (SELECT 1 FROM entities e WHERE e.id = m.entity_id);
            """)
        await check("mentions whose source document is gone", """
            SELECT COUNT(*) FROM entity_mentions m
            WHERE NOT EXISTS (SELECT 1 FROM knowledge_objects k WHERE k.id = m.source_object_id);
            """)
        await check("events whose source document is gone", """
            SELECT COUNT(*) FROM events v
            WHERE NOT EXISTS (SELECT 1 FROM knowledge_objects k WHERE k.id = v.source_object_id);
            """)
        await check("event_entities pointing at a missing event", """
            SELECT COUNT(*) FROM event_entities x
            WHERE NOT EXISTS (SELECT 1 FROM events v WHERE v.id = x.event_id);
            """)
        await check("event_entities pointing at a missing entity", """
            SELECT COUNT(*) FROM event_entities x
            WHERE NOT EXISTS (SELECT 1 FROM entities e WHERE e.id = x.entity_id);
            """)
        await check("knowledge objects whose file is gone", """
            SELECT COUNT(*) FROM knowledge_objects k
            WHERE NOT EXISTS (SELECT 1 FROM files f WHERE f.id = k.file_id);
            """)

        // 3 — the claim–evidence contract, on real data
        print("── claim–evidence contract")
        await check("facts citing NO block at all", """
            SELECT COUNT(*) FROM generic_facts
            WHERE source_blocks_json IS NULL OR source_blocks_json IN ('', '[]');
            """)
        // A fact whose cited block cannot be produced is the promise broken.
        let factsTotal = await scalar("SELECT COUNT(*) FROM generic_facts;") ?? 0
        let factsResolvable = await scalar("""
            SELECT COUNT(*) FROM generic_facts gf
            WHERE EXISTS (
              SELECT 1 FROM evidence_blocks b
              WHERE gf.source_blocks_json LIKE '%' || b.id || '%');
            """) ?? 0
        let unresolvable = factsTotal - factsResolvable
        print("   \(unresolvable == 0 ? "✓" : "✗")  facts whose cited block does not resolve: \(unresolvable) of \(factsTotal)")
        if unresolvable != 0 { problems.append("unresolvable fact evidence = \(unresolvable)") }

        // 4 — duplicate density. The ledger was once 96% duplicate facts.
        let distinctFacts = await scalar("""
            SELECT COUNT(*) FROM (
              SELECT DISTINCT subject_label, field, value FROM generic_facts);
            """) ?? 0
        let dupPct = factsTotal == 0 ? 0 : Int(Double(factsTotal - distinctFacts) / Double(factsTotal) * 100)
        print("── duplicate density")
        print("   \(dupPct <= 40 ? "✓" : "✗")  \(distinctFacts) distinct of \(factsTotal) facts — \(dupPct)% duplicated")
        if dupPct > 40 { problems.append("duplicate fact density = \(dupPct)%") }

        // 5 — canonicalization
        print("── canonicalization")
        await check("merged_into pointing at a missing entity", """
            SELECT COUNT(*) FROM entities e
            WHERE e.merged_into IS NOT NULL
              AND NOT EXISTS (SELECT 1 FROM entities t WHERE t.id = e.merged_into);
            """)
        await check("merge CHAINS (a merged entity pointing at another merged one)", """
            SELECT COUNT(*) FROM entities e
            JOIN entities t ON t.id = e.merged_into
            WHERE e.merged_into IS NOT NULL AND t.merged_into IS NOT NULL;
            """)
        await check("aliases whose entity is gone", """
            SELECT COUNT(*) FROM entity_aliases a
            WHERE NOT EXISTS (SELECT 1 FROM entities e WHERE e.id = a.entity_id);
            """)

        // 6 — the anchor uniqueness law
        await check("identifier anchors duplicated on one identity", """
            SELECT COUNT(*) FROM (
              SELECT normalized, COUNT(*) AS n FROM entities
              WHERE kind = 'identifierAnchor' AND merged_into IS NULL
              GROUP BY normalized HAVING n > 1);
            """)

        print("\n══ VERDICT: \(problems.isEmpty ? "the ledger is structurally sound" : "\(problems.count) PROBLEM(S)")")
        for p in problems { print("   ✗ \(p)") }

        #expect(problems.isEmpty, "ledger integrity problems: \(problems.joined(separator: " · "))")
        await RealArchivePipelineTests.teardown(state, dir)
    }
}
