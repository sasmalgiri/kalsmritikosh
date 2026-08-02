//
//  MMIIngestionIntegrationTests.swift
//  KalsmritikoshTests
//
//  MMI-FINAL — end-to-end: ingesting a document runs the deterministic typed-field producer
//  over the SAME persisted EvidenceBlocks, stores the fields with provenance, advances the
//  typedFieldExtraction readiness dimension, and the content-surface projector reports a real
//  typedFields surface. A document without identity fields extracts nothing (no false
//  readiness). Synthetic only.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("MMI-FINAL — typed-field ingestion integration", .serialized)
@MainActor
struct MMIIngestionIntegrationTests {

    private struct Rig { let c: IngestCoordinator; let db: Database; let typed: TypedFieldRepository; let dir: URL }

    private func makeRig() async throws -> Rig {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mmi-ingest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try Database(url: dir.appendingPathComponent("db.sqlite"))
        try await SchemaMigrations.migrate(db); try await db.exec("PRAGMA foreign_keys = ON;")
        let vault = EvidenceVault(root: dir.appendingPathComponent("vault", isDirectory: true))
        let intake = UniversalSourceIntakeCoordinator(repository: CanonicalSourceIntakeRepository(database: db, vault: vault))
        let typed = TypedFieldRepository(database: db)
        let c = IngestCoordinator(
            universalRegistry: try UniversalParserRegistryBuilder.standard(ocr: VisionOCR()),
            entityExtractor: NLEntityExtractor(), entityLinker: EntityLinker(), eventExtractor: RuleEventExtractor(),
            files: FilesRepository(database: db), objects: KnowledgeObjectRepository(database: db),
            chunks: ChunksRepository(database: db), evidenceStore: EvidenceStore(database: db),
            ingestAttempts: IngestAttemptsRepository(database: db), sourceRelations: SourceRelationsRepository(database: db),
            evidenceVault: vault, readiness: SourceReadinessRepository(database: db),
            typedFields: typed,
            containerInspection: ContainerInspectionRepository(database: db), intakeCoordinator: intake)
        return Rig(c: c, db: db, typed: typed, dir: dir)
    }

    private func write(_ rig: Rig, _ name: String, _ body: String) throws -> URL {
        let url = rig.dir.appendingPathComponent(name); try body.write(to: url, atomically: true, encoding: .utf8); return url
    }

    private let identityDoc = """
    IDENTITY CARD
    Name: Jane Roe
    Passport No: A1234567
    Date of Birth: 14/03/1990
    Date of Issue: 01 Jan 2020
    Valid Until: 31/12/2030
    Email: jane.roe@example.com
    """

    @Test("Ingesting an identity document extracts typed fields with provenance")
    func extractsIdentityFields() async throws {
        let rig = try await makeRig()
        let url = try write(rig, "id.txt", identityDoc)
        let sv = try #require(try await rig.c.ingest(fileAt: url, intent: .fullAvailable).sourceVersionID)
        let fields = try await rig.typed.fields(forVersion: sv)
        #expect(fields.contains { $0.fieldType == .personName && $0.normalizedValue == "Jane Roe" })
        #expect(fields.contains { $0.fieldType == .documentNumber && $0.normalizedValue == "A1234567" })
        #expect(fields.contains { $0.fieldType == .issueDate })
        // Every field is pinned to a real evidence block of this exact version.
        for f in fields {
            #expect(f.sourceVersionID == sv)
            let blockRows = try await rig.db.query("SELECT source_version_id FROM evidence_blocks WHERE id = ?;", [.uuid(f.evidenceBlockID)])
            #expect(blockRows.first?.uuid(0) == sv)
        }
    }

    @Test("Typed-field extraction advances the typedFieldExtraction readiness dimension")
    func advancesReadiness() async throws {
        let rig = try await makeRig()
        let url = try write(rig, "id.txt", identityDoc)
        let sv = try #require(try await rig.c.ingest(fileAt: url, intent: .fullAvailable).sourceVersionID)
        let row = try #require(try await rig.db.query("""
            SELECT state, completed_units FROM source_readiness_dimensions
            WHERE source_version_id = ? AND dimension = 'typedFieldExtraction';
            """, [.uuid(sv)]).first)
        #expect(row.string(0) == "ready")
        #expect((row.int(1) ?? 0) > 0)
    }

    @Test("A document with no identity fields extracts nothing and does not falsely satisfy readiness")
    func plainDocNoFields() async throws {
        let rig = try await makeRig()
        let url = try write(rig, "plain.txt", "The quarterly meeting discussed the schedule and next steps.")
        let sv = try #require(try await rig.c.ingest(fileAt: url, intent: .fullAvailable).sourceVersionID)
        #expect(try await rig.typed.fields(forVersion: sv).isEmpty)
        // typedFieldExtraction was not advanced to ready-with-content by this pass.
        let rows = try await rig.db.query("""
            SELECT state FROM source_readiness_dimensions
            WHERE source_version_id = ? AND dimension = 'typedFieldExtraction' AND state = 'ready' AND completed_units > 0;
            """, [.uuid(sv)])
        #expect(rows.isEmpty)
    }

    @Test("Re-ingesting the same document does not double the typed fields")
    func reingestIdempotent() async throws {
        let rig = try await makeRig()
        let url = try write(rig, "id.txt", identityDoc)
        let sv = try #require(try await rig.c.ingest(fileAt: url, intent: .fullAvailable).sourceVersionID)
        let first = try await rig.typed.fields(forVersion: sv).count
        _ = try await rig.c.ingest(fileAt: url, intent: .fullAvailable)   // unchanged bytes
        #expect(try await rig.typed.fields(forVersion: sv).count == first)
    }

    @Test("The content-surface projector reports a real typedFields surface (accepted producer)")
    func contentSurfaceProducer() {
        let sv = UUID()
        let withFields = [EvidenceBlock(documentID: UUID(), sourceVersionID: sv, ordinal: 0, kind: .paragraph,
                                        rawText: "Name: Jane Roe\nPassport No: A1234567")]
        let s1 = ContentSurfaceProjector.project(blocks: withFields, metadata: [:], extractionStatus: .complete)
        let typed1 = try? #require(s1.first { $0.kind == .typedFields })
        #expect(typed1?.coverage == .complete)
        #expect((typed1?.unitCount ?? 0) > 0)

        let plain = [EvidenceBlock(documentID: UUID(), sourceVersionID: sv, ordinal: 0, kind: .paragraph, rawText: "meeting notes")]
        let s2 = ContentSurfaceProjector.project(blocks: plain, metadata: [:], extractionStatus: .complete)
        #expect(s2.first { $0.kind == .typedFields }?.coverage == .notApplicable)
    }
}
