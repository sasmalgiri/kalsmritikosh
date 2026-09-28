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
//  Counts can look healthy over a ledger full of orphans: a fact citing a
//  deleted block still counts as a fact, and an answer built on it still counts
//  as cited.
//
//  ─────────────────────────────────────────────────────────────────────────
//  SECOND PASS. The first version of this file returned all zeros and I
//  reported the ledger sound. Re-reading it on the owner's "check again", the
//  audit was weaker than the claim it produced in three ways. All three are
//  the same underlying error — A CHECK THAT CANNOT FAIL IS NOT EVIDENCE —
//  and all three are now closed:
//
//   1. VACUOUS PASSES. "embeddings whose chunk is gone: 0" is equally true of
//      a correct ledger and of an EMPTY `chunk_embeddings` table, and the
//      run report for this very archive says the embedding drain had not
//      finished. Every check now prints the size of the table it audits, and
//      a check over an empty table is reported as NOT VERIFIED — never as ✓.
//
//   2. THE CITATION CHECK WAS LOOSE. It asked whether a fact's
//      `source_blocks_json` LIKE-matched ANY surviving block id. A fact
//      citing five blocks of which four are gone passed. I reported it as
//      "every fact cites a block that resolves", which the SQL could not
//      support. It now walks EVERY citation with `json_each` and counts
//      dangling ones individually.
//
//   3. NO NEGATIVE CONTROL. Nothing proved these queries can report a
//      problem at all. A typo'd join or a wrong column name yields a clean
//      zero. Phase C now breaks the ledger on purpose — inside a SAVEPOINT,
//      with FKs off, rolled back after — and requires each check to FIRE.
//
//  SIX PROPERTIES, each the kind that silently rots:
//
//   1. FOREIGN KEYS — `PRAGMA foreign_key_check`, SQLite's own verdict.
//   2. ORPHANS along the derivation chain.
//   3. THE CLAIM–EVIDENCE CONTRACT — every cited block must RESOLVE.
//   4. DUPLICATE DENSITY — the ledger was once 96% duplicate facts.
//   5. CANONICALIZATION — `merged_into` live, non-merged, unchained.
//   6. IDENTIFIER ANCHOR UNIQUENESS.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("LEDGER INTEGRITY — is the database built soundly?", .serialized, .enabled(if: LocalFixtures.ownerArchiveAvailable, LocalFixtures.archiveReason))
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
        func rows(in table: String) async -> Int? {
            await scalar("SELECT COUNT(*) FROM \(table);")
        }

        var problems: [String] = []      // real integrity violations
        var unverified: [String] = []    // checks that could not have failed
        var toothless: [String] = []     // checks that did not fire when broken

        /// `over` names the table the check audits. If that table is empty the
        /// zero is meaningless and is recorded as NOT VERIFIED — the whole
        /// point of the second pass.
        func check(_ label: String, over table: String, _ sql: String) async {
            let n = await scalar(sql)
            let denom = await rows(in: table)
            guard let n, let denom else {
                problems.append("\(label): PROBE FAILED — not verified")
                print("   ?  \(label): probe failed")
                return
            }
            if denom == 0 {
                unverified.append("\(label) — \(table) is empty")
                print("   –  \(label): NOT VERIFIED (\(table) has 0 rows)")
                return
            }
            print("   \(n == 0 ? "✓" : "✗")  \(label): \(n) of \(denom) \(table)")
            if n != 0 { problems.append("\(label) = \(n)") }
        }

        print("\n══ LEDGER INTEGRITY — PHASE A: what is there to audit")
        let inventory = ["files", "knowledge_objects", "source_documents", "evidence_blocks",
                         "evidence_block_objects", "chunks", "chunk_embeddings", "entities",
                         "entity_mentions", "entity_aliases", "events", "event_entities",
                         "generic_facts"]
        for t in inventory {
            print(String(repeating: " ", count: 3) + t.padding(toLength: 24, withPad: " ", startingAt: 0)
                  + "\(await rows(in: t).map(String.init) ?? "PROBE FAILED")")
        }

        print("\n══ PHASE B: the audit")

        // 1 — SQLite's own verdict. FKs must be ON for this to mean anything.
        let fkOn = await scalar("PRAGMA foreign_keys;")
        print("   foreign_keys pragma = \(fkOn ?? -1) (0 would make the next line meaningless)")
        if fkOn != 1 { problems.append("foreign_keys pragma is OFF — FK enforcement not in effect") }
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
        await check("chunks whose document is gone", over: "chunks", """
            SELECT COUNT(*) FROM chunks c
            WHERE NOT EXISTS (SELECT 1 FROM knowledge_objects k WHERE k.id = c.object_id);
            """)
        await check("embeddings whose chunk is gone", over: "chunk_embeddings", """
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
        await check("blocks whose source document is gone", over: "evidence_blocks", """
            SELECT COUNT(*) FROM evidence_blocks b
            WHERE NOT EXISTS (SELECT 1 FROM source_documents d WHERE d.id = b.document_id);
            """)
        await check("blocks not linked to any knowledge object", over: "evidence_blocks", """
            SELECT COUNT(*) FROM evidence_blocks b
            WHERE NOT EXISTS (
              SELECT 1 FROM evidence_block_objects x WHERE x.evidence_block_id = b.id);
            """)
        await check("block→object links pointing at a missing block", over: "evidence_block_objects", """
            SELECT COUNT(*) FROM evidence_block_objects x
            WHERE NOT EXISTS (SELECT 1 FROM evidence_blocks b WHERE b.id = x.evidence_block_id);
            """)
        await check("block→object links pointing at a missing object", over: "evidence_block_objects", """
            SELECT COUNT(*) FROM evidence_block_objects x
            WHERE NOT EXISTS (
              SELECT 1 FROM knowledge_objects k WHERE k.id = x.knowledge_object_id);
            """)
        await check("mentions whose entity is gone", over: "entity_mentions", """
            SELECT COUNT(*) FROM entity_mentions m
            WHERE NOT EXISTS (SELECT 1 FROM entities e WHERE e.id = m.entity_id);
            """)
        await check("mentions whose source document is gone", over: "entity_mentions", """
            SELECT COUNT(*) FROM entity_mentions m
            WHERE NOT EXISTS (SELECT 1 FROM knowledge_objects k WHERE k.id = m.source_object_id);
            """)
        await check("events whose source document is gone", over: "events", """
            SELECT COUNT(*) FROM events v
            WHERE NOT EXISTS (SELECT 1 FROM knowledge_objects k WHERE k.id = v.source_object_id);
            """)
        await check("event_entities pointing at a missing event", over: "event_entities", """
            SELECT COUNT(*) FROM event_entities x
            WHERE NOT EXISTS (SELECT 1 FROM events v WHERE v.id = x.event_id);
            """)
        await check("event_entities pointing at a missing entity", over: "event_entities", """
            SELECT COUNT(*) FROM event_entities x
            WHERE NOT EXISTS (SELECT 1 FROM entities e WHERE e.id = x.entity_id);
            """)
        await check("knowledge objects whose file is gone", over: "knowledge_objects", """
            SELECT COUNT(*) FROM knowledge_objects k
            WHERE NOT EXISTS (SELECT 1 FROM files f WHERE f.id = k.file_id);
            """)

        // 3 — the claim–evidence contract, on real data.
        //
        // EVERY citation, not "at least one". `source_blocks_json` is a JSON
        // array of UUID strings (JSONEncoder on [UUID]) and `evidence_blocks.id`
        // is bound as `uuidString`, so the two are directly comparable — which
        // is what makes an exact per-citation join possible instead of the LIKE
        // match the first version settled for.
        print("── claim–evidence contract")
        let factsTotal = await rows(in: "generic_facts") ?? 0
        await check("facts citing NO block at all", over: "generic_facts", """
            SELECT COUNT(*) FROM generic_facts
            WHERE source_blocks_json IS NULL OR TRIM(source_blocks_json) IN ('', '[]');
            """)
        await check("facts whose citation list is not valid JSON", over: "generic_facts", """
            SELECT COUNT(*) FROM generic_facts
            WHERE source_blocks_json IS NOT NULL AND json_valid(source_blocks_json) = 0;
            """)
        let citationsTotal = await scalar("""
            SELECT COUNT(*) FROM (
              SELECT source_blocks_json AS j FROM generic_facts WHERE json_valid(source_blocks_json)
            ) f, json_each(f.j);
            """)
        let danglingCitations = await scalar("""
            SELECT COUNT(*) FROM (
              SELECT source_blocks_json AS j FROM generic_facts WHERE json_valid(source_blocks_json)
            ) f, json_each(f.j)
            WHERE NOT EXISTS (SELECT 1 FROM evidence_blocks b WHERE b.id = json_each.value);
            """)
        if let citationsTotal, let danglingCitations {
            print("   \(danglingCitations == 0 ? "✓" : "✗")  DANGLING CITATIONS: \(danglingCitations) of \(citationsTotal) individual citations across \(factsTotal) facts")
            if danglingCitations != 0 { problems.append("dangling citations = \(danglingCitations)") }
            if citationsTotal == 0 && factsTotal > 0 {
                unverified.append("citation resolvability — no citations to walk")
            }
            // Informational, surfaced because the negative control tripped over
            // it: most blocks support no fact, so "a block" and "a CITED block"
            // are different populations. Not a defect — a block can be a page
            // header or boilerplate no fact should ever rest on — but it is the
            // denominator anyone reasoning about evidence coverage needs.
            let blocksCited = await scalar("""
                SELECT COUNT(DISTINCT b.id) FROM evidence_blocks b
                WHERE EXISTS (
                  SELECT 1 FROM (
                    SELECT source_blocks_json AS j FROM generic_facts WHERE json_valid(source_blocks_json)
                  ) f, json_each(f.j)
                  WHERE json_each.value = b.id);
                """) ?? -1
            let blocksTotal = await rows(in: "evidence_blocks") ?? 0
            print("   ·  blocks cited by at least one fact: \(blocksCited) of \(blocksTotal) (informational)")
        } else {
            problems.append("citation walk: PROBE FAILED — resolvability NOT verified")
            print("   ?  citation walk: probe failed (json_each unavailable?)")
        }

        // 4 — duplicate density. The ledger was once 96% duplicate facts.
        let distinctFacts = await scalar("""
            SELECT COUNT(*) FROM (
              SELECT DISTINCT subject_label, field, value FROM generic_facts);
            """) ?? 0
        let dupPct = factsTotal == 0 ? 0 : Int(Double(factsTotal - distinctFacts) / Double(factsTotal) * 100)
        print("── duplicate density")
        print("   \(dupPct <= 40 ? "✓" : "✗")  \(distinctFacts) distinct of \(factsTotal) facts — \(dupPct)% duplicated")
        if dupPct > 40 { problems.append("duplicate fact density = \(dupPct)%") }
        if factsTotal == 0 { unverified.append("duplicate density — no facts") }

        // 5 — canonicalization
        print("── canonicalization")
        let merged = await scalar("SELECT COUNT(*) FROM entities WHERE merged_into IS NOT NULL;") ?? 0
        print("   (\(merged) merged entities — the population these two checks audit)")
        await check("merged_into pointing at a missing entity", over: "entities", """
            SELECT COUNT(*) FROM entities e
            WHERE e.merged_into IS NOT NULL
              AND NOT EXISTS (SELECT 1 FROM entities t WHERE t.id = e.merged_into);
            """)
        await check("merge CHAINS (a merged entity pointing at another merged one)", over: "entities", """
            SELECT COUNT(*) FROM entities e
            JOIN entities t ON t.id = e.merged_into
            WHERE e.merged_into IS NOT NULL AND t.merged_into IS NOT NULL;
            """)
        if merged == 0 {
            // The QUERIES are proven live by the negative control below; what
            // is missing is a population to audit. Both facts belong in the
            // verdict: the check works, and this archive has never merged an
            // entity — which is itself worth knowing, since entity unification
            // across documents is a headline capability.
            unverified.append("merge checks — 0 entities have ever been merged in this ledger "
                              + "(the checks themselves are proven live by negative control)")
        }
        await check("aliases whose entity is gone", over: "entity_aliases", """
            SELECT COUNT(*) FROM entity_aliases a
            WHERE NOT EXISTS (SELECT 1 FROM entities e WHERE e.id = a.entity_id);
            """)

        // CROSS-DOCUMENT UNIFICATION — measured where it actually happens.
        //
        // `merged_into` is NOT the unification mechanism: `merge()` has three
        // callers and all three are user-initiated or repair (KnowledgeView,
        // the Investigator's identity resolution, and EntityRegisterRefresh,
        // which merges only when a producer-version cleanup collides). Real
        // unification happens at WRITE time — every entity insert is
        // `ON CONFLICT(kind, normalized) DO UPDATE`, so one person named in
        // nineteen documents becomes ONE row, no merge required.
        //
        // So "0 merged entities" says nothing about whether the canonical-entity
        // promise works, and reading it as a gap would have been a fourth false
        // alarm. THIS is the number that answers it: an entity whose mentions
        // come from two or more documents was unified across them.
        let spanning = await scalar("""
            SELECT COUNT(*) FROM (
              SELECT entity_id FROM entity_mentions
              GROUP BY entity_id HAVING COUNT(DISTINCT source_object_id) > 1);
            """) ?? -1
        let mentioned = await scalar("SELECT COUNT(DISTINCT entity_id) FROM entity_mentions;") ?? 0
        print("   ·  entities unified across ≥2 documents: \(spanning) of \(mentioned) mentioned (informational)")
        if mentioned > 0 && spanning == 0 {
            // Not an integrity violation — but on a 19-document archive with
            // repeated correspondents it would mean write-time unification is
            // not working, which is a headline capability.
            problems.append("NO entity is mentioned in more than one document — cross-document unification is not happening")
        }

        // 6 — the anchor uniqueness law
        let anchors = await scalar("""
            SELECT COUNT(*) FROM entities WHERE kind = 'identifierAnchor' AND merged_into IS NULL;
            """) ?? 0
        print("   (\(anchors) identifier anchors)")
        await check("identifier anchors duplicated on one identity", over: "entities", """
            SELECT COUNT(*) FROM (
              SELECT normalized, COUNT(*) AS n FROM entities
              WHERE kind = 'identifierAnchor' AND merged_into IS NULL
              GROUP BY normalized HAVING n > 1);
            """)
        if anchors == 0 { unverified.append("anchor uniqueness — no identifier anchors exist") }

        // ── PHASE C: NEGATIVE CONTROLS ──────────────────────────────────────
        //
        // Break the ledger on purpose and require each check to notice. Without
        // this, a mistyped column or a join to the wrong table reads as a clean
        // pass — which is exactly how the first version of this file reported
        // 217 orphans as an ALARM and would equally have reported a broken
        // query as SOUND.
        //
        // Safe by construction: this ledger is a throwaway temp database built
        // seconds ago from read-only copies, each mutation runs inside a
        // SAVEPOINT that is rolled back, and FK enforcement is disabled only
        // for the duration (otherwise the deletes that simulate corruption
        // would be refused by the very constraint being tested) and restored
        // immediately after.
        print("\n══ PHASE C: negative controls — does each check have teeth?")

        func firstID(_ table: String) async -> String? {
            guard let r = try? await db.query("SELECT id FROM \(table) LIMIT 1;", []) else { return nil }
            return r.first?.string(0)
        }
        /// A block that some fact ACTUALLY CITES.
        ///
        /// The first version of this control deleted `evidence_blocks LIMIT 1`
        /// and reported the citation check as toothless when nothing dangled.
        /// The check was fine; the control was wrong — only a minority of
        /// blocks are cited by a fact, and an arbitrary block is unlikely to be
        /// one of them. To prove a citation check fires you must delete
        /// something that is CITED, which is a different row from something
        /// that merely exists.
        func firstCitedBlockID() async -> String? {
            guard let r = try? await db.query("""
            SELECT b.id FROM evidence_blocks b
            WHERE EXISTS (
              SELECT 1 FROM (
                SELECT source_blocks_json AS j FROM generic_facts WHERE json_valid(source_blocks_json)
              ) f, json_each(f.j)
              WHERE json_each.value = b.id)
            LIMIT 1;
            """, []) else { return nil }
            return r.first?.string(0)
        }
        func control(_ label: String, break mutation: String, probe: String) async {
            guard let before = await scalar(probe) else {
                toothless.append("\(label): probe failed before mutation"); return
            }
            do {
                try await db.exec("SAVEPOINT negcontrol;")
                try await db.exec(mutation)
            } catch {
                try? await db.exec("ROLLBACK TO negcontrol;")
                try? await db.exec("RELEASE negcontrol;")
                toothless.append("\(label): could not inject the fault (\(error)) — check NOT proven")
                print("   ?  \(label): fault injection failed")
                return
            }
            let after = await scalar(probe) ?? before
            try? await db.exec("ROLLBACK TO negcontrol;")
            try? await db.exec("RELEASE negcontrol;")
            let fired = after > before
            print("   \(fired ? "✓" : "✗")  \(label): \(before) → \(after)")
            if !fired { toothless.append("\(label) did NOT fire when broken (\(before) → \(after))") }
        }

        try? await db.exec("PRAGMA foreign_keys=OFF;")

        if let ko = await firstID("knowledge_objects") {
            await control("delete a knowledge object → orphan chunks detected",
                          break: "DELETE FROM knowledge_objects WHERE id = '\(ko)';",
                          probe: """
                          SELECT COUNT(*) FROM chunks c
                          WHERE NOT EXISTS (SELECT 1 FROM knowledge_objects k WHERE k.id = c.object_id);
                          """)
        } else { toothless.append("no knowledge object to delete — control not run") }

        if let cited = await firstCitedBlockID() {
            await control("delete a CITED block → dangling citation detected",
                          break: "DELETE FROM evidence_blocks WHERE id = '\(cited)';",
                          probe: """
                          SELECT COUNT(*) FROM (
                            SELECT source_blocks_json AS j FROM generic_facts WHERE json_valid(source_blocks_json)
                          ) f, json_each(f.j)
                          WHERE NOT EXISTS (SELECT 1 FROM evidence_blocks b WHERE b.id = json_each.value);
                          """)
        } else { toothless.append("no fact cites any block — citation control not run") }

        if let blk = await firstID("evidence_blocks") {
            await control("delete a block → orphan block→object link detected",
                          break: "DELETE FROM evidence_blocks WHERE id = '\(blk)';",
                          probe: """
                          SELECT COUNT(*) FROM evidence_block_objects x
                          WHERE NOT EXISTS (SELECT 1 FROM evidence_blocks b WHERE b.id = x.evidence_block_id);
                          """)
        } else { toothless.append("no evidence block to delete — controls not run") }

        if let ent = await firstID("entities") {
            await control("delete an entity → orphan mentions detected",
                          break: "DELETE FROM entities WHERE id = '\(ent)';",
                          probe: """
                          SELECT COUNT(*) FROM entity_mentions m
                          WHERE NOT EXISTS (SELECT 1 FROM entities e WHERE e.id = m.entity_id);
                          """)
            await control("point merged_into at a nonexistent entity → dangling merge detected",
                          break: "UPDATE entities SET merged_into = 'DEAD-0000-0000-0000-000000000000' WHERE id = '\(ent)';",
                          probe: """
                          SELECT COUNT(*) FROM entities e
                          WHERE e.merged_into IS NOT NULL
                            AND NOT EXISTS (SELECT 1 FROM entities t WHERE t.id = e.merged_into);
                          """)
        } else { toothless.append("no entity to mutate — controls not run") }

        if let ko = await firstID("knowledge_objects") {
            await control("delete a knowledge object → PRAGMA foreign_key_check reports it",
                          break: "DELETE FROM knowledge_objects WHERE id = '\(ko)';",
                          probe: "SELECT COUNT(*) FROM pragma_foreign_key_check;")
        }

        try? await db.exec("PRAGMA foreign_keys=ON;")
        let fkRestored = await scalar("PRAGMA foreign_keys;")
        if fkRestored != 1 { problems.append("foreign_keys not restored after controls") }

        // ── VERDICT ─────────────────────────────────────────────────────────
        print("\n══ VERDICT")
        if problems.isEmpty { print("   ✓ no integrity violations found") }
        for p in problems { print("   ✗ VIOLATION: \(p)") }
        for u in unverified { print("   – NOT VERIFIED: \(u)") }
        for t in toothless { print("   ✗ CHECK WITHOUT TEETH: \(t)") }
        print("   \(problems.count) violation(s) · \(unverified.count) not verified · \(toothless.count) toothless check(s)")

        #expect(problems.isEmpty, "ledger integrity violations: \(problems.joined(separator: " · "))")
        // A check that cannot report a problem is a defect in the audit, and an
        // audit that is wrong is worse than no audit — it is what made me tell
        // the owner the ledger was sound on the strength of a LIKE match.
        #expect(toothless.isEmpty, "checks that did not fire when the ledger was broken on purpose: \(toothless.joined(separator: " · "))")
        // Unverified checks are NOT failures — an empty table can be legitimate
        // (the embedding drain may simply not have run). They are printed so the
        // verdict is never read as covering more than it does.

        await RealArchivePipelineTests.teardown(state, dir)
    }
}
