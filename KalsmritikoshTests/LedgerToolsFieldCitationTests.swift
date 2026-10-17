//
//  LedgerToolsFieldCitationTests.swift
//  KalsmritikoshTests
//
//  F06 — a field-tool result cites the DOCUMENT that owns its source blocks. Block ids
//  travel separately and never masquerade as object ids, so the citation the answer ships
//  opens through the same resolver the UI uses.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("F06 — field-tool citations resolve to their owning document")
struct LedgerToolsFieldCitationTests {

    private let clock = Date(timeIntervalSince1970: 1_750_000_000)

    private func fact(blocks: [UUID]) -> GenericFact {
        GenericFact(subjectLabel: "s", field: "applicant", value: "shirshendu sasmal",
                    status: .sourceAsserted, confidence: 0.8, sourceBlockIDs: blocks,
                    producerVersion: 4, rawMatch: nil, sourceCount: 1)
    }

    @Test("Without a block resolver a field result cites nothing — never a block id as an object id")
    func noResolverNoFakeObjectIDs() async {
        let block = UUID()
        let tools = LedgerTools(events: { _ in [] }, facts: { _ in [fact(blocks: [block])] },
                                chunksForQuestion: { _ in [] })
        let r = await tools.lookupField("applicant")
        #expect(r.count == 1)
        #expect(r.first?.objectIDs == [])
        #expect(r.first?.blockIDs == [block])
    }

    @Test("A persisted block resolves to the object the UI opens; unresolvable blocks are dropped")
    func resolvesThroughTheLedger() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        let store = EvidenceStore(database: db)
        let objectID = UUID(), docID = UUID(), versionID = UUID()
        let block = EvidenceBlock(documentID: docID, ordinal: 1, kind: .paragraph,
                                  rawText: "Applicant: Shirshendu Sasmal")
        try await db.exec("""
            INSERT INTO source_versions (id, logical_source_id, content_hash, valid_from, is_current, created_at,
                filename, detected_type, detection_basis, size_bytes, custody_mode, preservation_status, intake_recorded_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?);
            """, [.uuid(versionID), .uuid(objectID), .text("h"), .real(0), .integer(1), .real(0),
                  .text("patent.txt"), .text("txt"), .text("declaredExtension"), .integer(0), .text("referenced"),
                  .text("legacyImported"), .real(0)])
        try await store.persist(ParsedDocument(id: docID, logicalSourceID: objectID, sourceVersionID: versionID,
                                               filename: "patent.txt", detectedType: .txt, contentHash: "h",
                                               blocks: [block]),
                                parser: "txt", parserVersion: "1", startedAt: clock)

        let orphan = UUID()
        var tools = LedgerTools(events: { _ in [] }, facts: { _ in [fact(blocks: [block.id, orphan])] },
                                chunksForQuestion: { _ in [] })
        tools.blockOwners = LedgerTools.blockOwners(using: store)
        let r = try #require(await tools.lookupField("applicant").first)
        #expect(r.objectIDs == [objectID])            // the document, not the block
        #expect(!r.objectIDs.contains(block.id))
        #expect(r.blockIDs == [block.id, orphan])     // block provenance kept separately
        // The object id is the one the production resolver hands back for this block.
        #expect(try await store.resolveEvidenceBlocks([block.id]).first?.objectID == objectID)
    }
}
