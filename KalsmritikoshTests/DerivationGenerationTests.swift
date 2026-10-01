//
//  DerivationGenerationTests.swift
//  KalsmritikoshTests
//
//  F16/F25 (residual, 2026-09-29 review) — activating a changed parser output superseded the blocks
//  but (a) carried multi-object ownership by ORDINAL, so a parser that inserts a block shifted every
//  later block onto the wrong knowledge object; (b) left the search chunks and vectors of the old
//  derivation serving as current output, because index repair skipped any object with a chunk; and
//  (c) ignored block attributes in change detection. A derivation generation now binds ownership by
//  parser-native record identity, switches the index with it, and detects attribute changes.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("F16/F25 — an activated derivation switches ownership, search and vectors coherently", .serialized)
@MainActor
struct DerivationGenerationTests {

    private struct Rig { let c: IngestCoordinator; let db: Database; let dir: URL; let vault: EvidenceVault }

    private func rig() async throws -> Rig {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dgen-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try Database(url: dir.appendingPathComponent("db.sqlite"))
        try await SchemaMigrations.migrate(db); try await db.exec("PRAGMA foreign_keys = ON;")
        let vault = EvidenceVault(root: dir.appendingPathComponent("vault", isDirectory: true))
        let intake = UniversalSourceIntakeCoordinator(repository: CanonicalSourceIntakeRepository(database: db, vault: vault))
        let c = IngestCoordinator(
            universalRegistry: try UniversalParserRegistryBuilder.standard(ocr: VisionOCR()),
            entityExtractor: NLEntityExtractor(), entityLinker: EntityLinker(), eventExtractor: RuleEventExtractor(),
            files: FilesRepository(database: db), objects: KnowledgeObjectRepository(database: db),
            chunks: ChunksRepository(database: db), evidenceStore: EvidenceStore(database: db),
            ingestAttempts: IngestAttemptsRepository(database: db), sourceRelations: SourceRelationsRepository(database: db),
            evidenceVault: vault, readiness: SourceReadinessRepository(database: db),
            containerInspection: ContainerInspectionRepository(database: db), intakeCoordinator: intake,
            custodyModeOverride: .referenced)
        await c.configureUpgrades(database: db, jobs: SourceUpgradeJobRepository(database: db))
        return Rig(c: c, db: db, dir: dir, vault: vault)
    }

    /// Three messages with distinct subjects → three thread objects, each owning its own blocks.
    private func ingestMailbox(_ r: Rig) async throws -> UUID {
        let bodies = ["Alpha matter: the alphaterm contract was signed on the first day.",
                      "Bravo matter: the bravoterm shipment left the harbour on time.",
                      "Charlie matter: the charlieterm invoice was settled in full."]
        var mbox = ""
        for (i, body) in bodies.enumerated() {
            mbox += "From m\(i)@example.com Mon Jan 0\(i + 1) 00:00:00 2024\nFrom: Sender \(i) <m\(i)@example.com>\n"
                + "To: owner@example.com\nSubject: Subject \(["Alpha", "Bravo", "Charlie"][i])\n"
                + "Date: Mon, 0\(i + 1) Jan 2024 10:00:00 +0000\n\n\(body)\n\n"
        }
        let url = r.dir.appendingPathComponent("box.mbox")
        try mbox.write(to: url, atomically: true, encoding: .utf8)
        return try #require(try await r.c.ingest(fileAt: url, intent: .fullAvailable).sourceVersionID)
    }

    private func messageIndex(_ b: EvidenceBlock) -> Int? {
        if case .int(let i)? = b.attributes["messageIndex"]?.value { return Int(i) }
        return nil
    }

    /// owner of each active block, keyed by block id.
    private func owners(_ r: Rig, _ svid: UUID) async throws -> [UUID: UUID] {
        var out: [UUID: UUID] = [:]
        for row in try await r.db.query("""
            SELECT b.id, ebo.knowledge_object_id FROM evidence_blocks b JOIN evidence_block_objects ebo ON ebo.evidence_block_id = b.id
             WHERE b.source_version_id = ? AND b.superseded_by_run IS NULL;
            """, [.uuid(svid)]) {
            if let b = row.uuid(0), let k = row.uuid(1) { out[b] = k }
        }
        return out
    }

    /// Parser "v2": inserts a note before message B, changes message A's searchable term, and changes
    /// message C's attribute only. `attributeOnly` keeps every text identical and changes only C.
    private func v2(_ r: Rig, _ svid: UUID, _ committed: [EvidenceBlock], attributeOnly: Bool = false) async throws -> ParsedDocument {
        let row = try #require(try await r.db.query("SELECT logical_source_id, content_hash FROM source_versions WHERE id = ?;", [.uuid(svid)]).first)
        var out: [EvidenceBlock] = []
        var insertedBeforeB = false
        for b in committed.sorted(by: { $0.ordinal < $1.ordinal }) {
            let mi = messageIndex(b)
            if !attributeOnly, mi == 1, !insertedBeforeB {
                out.append(EvidenceBlock(documentID: b.documentID, ordinal: out.count, kind: .paragraph,
                                         rawText: "Inserted note for the bravo message.", locator: b.locator,
                                         attributes: b.attributes))
                insertedBeforeB = true
            }
            var text = b.rawText, attrs = b.attributes
            if !attributeOnly, mi == 0 { text = text.replacingOccurrences(of: "alphaterm", with: "omegaterm") }
            if mi == 2, b.kind == .emailBody { attrs["parserNote"] = AnyCodable(.string("v2")) }
            out.append(EvidenceBlock(documentID: b.documentID, ordinal: out.count, kind: b.kind, rawText: text,
                                     locator: b.locator, attributes: attrs))
        }
        return ParsedDocument(id: UUID(), logicalSourceID: try #require(row.uuid(0)), sourceVersionID: svid,
                              filename: "box.mbox", detectedType: .mbox, contentHash: row.string(1) ?? "", blocks: out)
    }

    private func coordinator(_ r: Rig, _ doc: ParsedDocument) -> SourceReprocessingCoordinator {
        SourceReprocessingCoordinator(
            database: r.db, readiness: SourceReadinessRepository(database: r.db),
            byteResolver: SourceVersionByteResolver(database: r.db, vault: r.vault),
            reparse: { _, _, _ in doc },
            reindex: { [c = r.c] svid in try await c.upgradeIndexing(sourceVersionID: svid) })
    }

    private func downgrade(_ r: Rig, _ svid: UUID) async throws {
        try await r.db.exec("UPDATE source_readiness_dimensions SET producer_version = '0' WHERE source_version_id = ? AND dimension IN ('structuralExtraction','metadataExtraction');", [.uuid(svid)])
    }

    private func currentSearch(_ r: Rig, _ term: String) async throws -> [Chunk] {
        try await ChunksRepository(database: r.db).searchFTS(term, limit: 20)
    }

    @Test("Inserted block + changed term + changed attribute: exact ownership, new-term search, old term historical only, vectors retired")
    func activationSwitchesGeneration() async throws {
        let r = try await rig()
        let svid = try await ingestMailbox(r)
        let store = EvidenceStore(database: r.db)
        let committed = try await store.blocks(forVersion: svid)
        let before = try await owners(r, svid)
        // The owner of each message, from the committed (verified) ingest.
        var ownerOfMessage: [Int: UUID] = [:]
        for b in committed { if let mi = messageIndex(b), let k = before[b.id] { ownerOfMessage[mi] = k } }
        #expect(Set(ownerOfMessage.values).count == 3, "fixture: three messages, three owners")
        // A vector for an old chunk of message A, to prove the old generation stops serving.
        let oldA = try #require(try await r.db.query("""
            SELECT c.id FROM chunks c JOIN chunk_blocks cb ON cb.chunk_id = c.id JOIN evidence_blocks b ON b.id = cb.evidence_block_id
             WHERE c.source_version_id = ? AND b.raw_text LIKE '%alphaterm%' LIMIT 1;
            """, [.uuid(svid)]).first?.uuid(0))
        try await r.db.exec("INSERT OR REPLACE INTO vectors (chunk_id, dim, q, scale) VALUES (?, 1, x'00', 1.0);", [.uuid(oldA)])
        try await downgrade(r, svid)

        let outcome = try await coordinator(r, try await v2(r, svid, committed)).reprocess(sourceVersionID: svid, currentParserVersion: "2", at: Date())
        guard case .activated = outcome else { Issue.record("expected activation, got \(outcome)"); return }

        // Ownership by record identity: every active block belongs to its OWN message's object.
        let after = try await owners(r, svid)
        let active = try await store.blocks(forVersion: svid)
        for b in active {
            let mi = try #require(messageIndex(b))
            #expect(after[b.id] == ownerOfMessage[mi], "block \(b.ordinal) of message \(mi) bound to the wrong object")
        }
        // Current search reflects the active generation only.
        #expect(!(try await currentSearch(r, "omegaterm")).isEmpty, "the new term is not searchable")
        #expect((try await currentSearch(r, "alphaterm")).isEmpty, "the superseded term still serves as current output")
        // The old term still resolves through historical evidence.
        let oldBlocks = try await store.supersededBlocks(forVersion: svid)
        #expect(oldBlocks.contains { $0.rawText.contains("alphaterm") })
        #expect(!(try await store.blocks(ids: oldBlocks.map(\.id))).isEmpty)
        // Vector-generation policy: the superseded chunk's vector is retired; its row stays for citations.
        #expect(try await r.db.query("SELECT COUNT(*) FROM vectors WHERE chunk_id = ?;", [.uuid(oldA)]).first?.int(0) == 0)
        #expect(!(try await ChunksRepository(database: r.db).findByIDs([oldA])).isEmpty, "a chunk cited historically still resolves")
        // No current chunk cites a superseded block; readiness is honest and its proof current.
        #expect(try await r.db.query("""
            SELECT COUNT(*) FROM chunks c JOIN chunk_blocks cb ON cb.chunk_id = c.id JOIN evidence_blocks b ON b.id = cb.evidence_block_id
             WHERE c.source_version_id = ? AND c.superseded_by_run IS NULL AND b.superseded_by_run IS NOT NULL;
            """, [.uuid(svid)]).first?.int(0) == 0)
        let readiness = SourceReadinessRepository(database: r.db)
        #expect(try await readiness.snapshot(sourceVersionID: svid).dimension(.indexing)?.state == .ready)
        #expect(try await readiness.proofIsCurrent(sourceVersionID: svid, dimension: .indexing))
    }

    @Test("A change to a block attribute alone (same text) is a changed derivation, not a re-stamp")
    func attributeOnlyChangeActivates() async throws {
        let r = try await rig()
        let svid = try await ingestMailbox(r)
        let committed = try await EvidenceStore(database: r.db).blocks(forVersion: svid)
        try await downgrade(r, svid)
        let outcome = try await coordinator(r, try await v2(r, svid, committed, attributeOnly: true))
            .reprocess(sourceVersionID: svid, currentParserVersion: "2", at: Date())
        guard case .activated = outcome else { Issue.record("an attribute-only change was re-stamped as unchanged: \(outcome)"); return }
    }

    @Test("Interrupted after activation (index not rebuilt): readiness is not ready; the next upgrade converges with no duplicates or mixed generations")
    func interruptedAfterActivationConverges() async throws {
        let r = try await rig()
        let svid = try await ingestMailbox(r)
        let store = EvidenceStore(database: r.db)
        let committed = try await store.blocks(forVersion: svid)
        let doc = try await v2(r, svid, committed)
        // Activation commits; the process dies before the readiness stamp and the index switch.
        _ = try await store.activateDerivation(doc, parser: "p", parserVersion: "2", startedAt: Date())
        // The next request reconciles: the index is from a superseded derivation, so it is rebuilt.
        _ = try await r.c.ensureUpgrade(sourceVersionID: svid, goal: .searchReady, execution: .foreground)
        #expect(!(try await currentSearch(r, "omegaterm")).isEmpty)
        #expect((try await currentSearch(r, "alphaterm")).isEmpty)
        let mixed = try await r.db.query("""
            SELECT COUNT(*) FROM chunks c JOIN chunk_blocks cb ON cb.chunk_id = c.id JOIN evidence_blocks b ON b.id = cb.evidence_block_id
             WHERE c.source_version_id = ? AND c.superseded_by_run IS NULL AND b.superseded_by_run IS NOT NULL;
            """, [.uuid(svid)]).first?.int(0)
        #expect(mixed == 0, "a current chunk still cites the superseded generation")
        // Exactly one current chunk set per object: re-running changes nothing.
        let count1 = try await r.db.query("SELECT COUNT(*) FROM chunks WHERE source_version_id = ? AND superseded_by_run IS NULL;", [.uuid(svid)]).first?.int(0)
        _ = try await r.c.ensureUpgrade(sourceVersionID: svid, goal: .searchReady, execution: .foreground)
        try await r.c.upgradeIndexing(sourceVersionID: svid)
        let count2 = try await r.db.query("SELECT COUNT(*) FROM chunks WHERE source_version_id = ? AND superseded_by_run IS NULL;", [.uuid(svid)]).first?.int(0)
        #expect(count1 == count2, "a rerun duplicated current chunks")
        #expect(try await SourceReadinessRepository(database: r.db).snapshot(sourceVersionID: svid).dimension(.indexing)?.state == .ready)
    }

    @Test("Interrupted during the index rebuild (one object switched): reconciliation finishes the rest")
    func interruptedDuringRebuildConverges() async throws {
        let r = try await rig()
        let svid = try await ingestMailbox(r)
        let store = EvidenceStore(database: r.db)
        let committed = try await store.blocks(forVersion: svid)
        _ = try await store.activateDerivation(try await v2(r, svid, committed), parser: "p", parserVersion: "2", startedAt: Date())
        // Switch the index of ONE object only, then "crash".
        let oneObject = try #require(try await owners(r, svid).values.first)
        try await r.c.rebuildIndex(sourceVersionID: svid, objects: [oneObject])
        _ = try await r.c.ensureUpgrade(sourceVersionID: svid, goal: .searchReady, execution: .foreground)
        let mixed = try await r.db.query("""
            SELECT COUNT(*) FROM chunks c JOIN chunk_blocks cb ON cb.chunk_id = c.id JOIN evidence_blocks b ON b.id = cb.evidence_block_id
             WHERE c.source_version_id = ? AND c.superseded_by_run IS NULL AND b.superseded_by_run IS NOT NULL;
            """, [.uuid(svid)]).first?.int(0)
        #expect(mixed == 0)
        #expect(!(try await currentSearch(r, "omegaterm")).isEmpty)
    }
}
