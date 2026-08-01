//
//  SourceReadinessIngestIntegrationTests.swift
//  KalsmritikoshTests
//
//  USF-002 — with readiness wired, intake bootstraps the ten dimensions in the SAME transaction
//  that creates a new source version, and the loader / structural / indexing stages advance them
//  from durable representations. Unchanged/alias occurrences reuse the canonical readiness; a
//  changed file starts a fresh aggregate and never disturbs the old version's readiness. Media is
//  deferred, a loader failure is failed (custody intact), and search ≠ evidence ≠ analytical.
//  Synthetic sources only.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("USF-002 — readiness ingest integration", .serialized)
struct SourceReadinessIngestIntegrationTests {

    private struct Rig {
        let coordinator: IngestCoordinator
        let readiness: SourceReadinessRepository
        let db: Database
        let dir: URL
    }

    @MainActor
    private func makeRig() async throws -> Rig {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("usf002-ingest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try Database(url: dir.appendingPathComponent("db.sqlite"))
        try await SchemaMigrations.migrate(db)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let readiness = SourceReadinessRepository(database: db)
        let intake = UniversalSourceIntakeCoordinator(repository: CanonicalSourceIntakeRepository(
            database: db, vault: EvidenceVault(root: dir.appendingPathComponent("vault", isDirectory: true))))
        let coordinator = IngestCoordinator(
            loaders: .standard(),
            entityExtractor: NLEntityExtractor(), entityLinker: EntityLinker(), eventExtractor: RuleEventExtractor(),
            files: FilesRepository(database: db), objects: KnowledgeObjectRepository(database: db),
            chunks: ChunksRepository(database: db), evidenceStore: EvidenceStore(database: db),
            structuralRegistry: .standard(ocr: VisionOCR()),
            ingestAttempts: IngestAttemptsRepository(database: db),
            sourceRelations: SourceRelationsRepository(database: db),
            readiness: readiness, intakeCoordinator: intake)
        return Rig(coordinator: coordinator, readiness: readiness, db: db, dir: dir)
    }

    private func write(_ rig: Rig, _ name: String, _ contents: String) throws -> URL {
        let url = rig.dir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
    private func writeData(_ rig: Rig, _ name: String, _ data: Data) throws -> URL {
        let url = rig.dir.appendingPathComponent(name); try data.write(to: url); return url
    }

    private let email = """
    From: Alexandra Rivera <alex@orchidlabs.example>
    To: Legal Team <legal@orchidlabs.example>
    Subject: Orchid Labs services agreement
    Date: Mon, 3 Mar 2025 09:12:00 +0000

    I have signed the Orchid Labs services agreement today, 3 March 2025. The agreement covers
    the full scope of professional services for the 2025 engagement year.
    """

    // MARK: - Intake bootstrap

    @Test("A new source version is initialized with ten readiness dimensions in intake")
    @MainActor func newSourceInitialized() async throws {
        let rig = try await makeRig()
        let result = try await rig.coordinator.ingest(fileAt: try write(rig, "matter.eml", email))
        let versionID = try #require(result.sourceVersionID)
        let snap = try await rig.readiness.snapshot(sourceVersionID: versionID)
        #expect(snap.dimensions.count == 10)
        #expect(try await rig.db.query("SELECT COUNT(*) FROM source_readiness_aggregates;", []).first?.int(0) == 1)
    }

    @Test("An unchanged re-ingest reuses the existing readiness (no second aggregate, no re-bootstrap)")
    @MainActor func unchangedReusesReadiness() async throws {
        let rig = try await makeRig()
        let url = try write(rig, "matter.eml", email)
        let first = try await rig.coordinator.ingest(fileAt: url)
        let versionID = try #require(first.sourceVersionID)
        let afterFirst = try await rig.readiness.snapshot(sourceVersionID: versionID)
        _ = try await rig.coordinator.ingest(fileAt: url)   // unchanged
        let afterSecond = try await rig.readiness.snapshot(sourceVersionID: versionID)
        #expect(try await rig.db.query("SELECT COUNT(*) FROM source_readiness_aggregates;", []).first?.int(0) == 1)
        #expect(afterFirst == afterSecond)   // untouched by the unchanged re-ingest
    }

    @Test("An alias occurrence shares the canonical version's readiness (no independent aggregate)")
    @MainActor func aliasReusesReadiness() async throws {
        let rig = try await makeRig()
        _ = try await rig.coordinator.ingest(fileAt: try write(rig, "a.eml", email))
        _ = try await rig.coordinator.ingest(fileAt: try write(rig, "b.eml", email))   // alias
        #expect(try await rig.db.query("SELECT COUNT(*) FROM source_readiness_aggregates;", []).first?.int(0) == 1)
    }

    @Test("Changed content starts a fresh readiness aggregate and never disturbs the old version")
    @MainActor func changedContentFreshAggregate() async throws {
        let rig = try await makeRig()
        let url = try write(rig, "matter.eml", email)
        let first = try await rig.coordinator.ingest(fileAt: url)
        let v1 = try #require(first.sourceVersionID)
        let v1Before = try await rig.readiness.snapshot(sourceVersionID: v1)
        _ = try write(rig, "matter.eml", email + "\n\nAddendum: amended terms, 10 March 2025.")
        let second = try await rig.coordinator.ingest(fileAt: url)
        let v2 = try #require(second.sourceVersionID)
        #expect(v2 != v1)
        #expect(try await rig.db.query("SELECT COUNT(*) FROM source_readiness_aggregates;", []).first?.int(0) == 2)
        #expect(try await rig.readiness.snapshot(sourceVersionID: v1) == v1Before)   // old version unchanged
    }

    // MARK: - Stage advancement

    @Test("A successful loader + index makes the source searchable (text + indexing ready)")
    @MainActor func loaderSuccessSearchable() async throws {
        let rig = try await makeRig()
        let result = try await rig.coordinator.ingest(fileAt: try write(rig, "matter.eml", email))
        let snap = try await rig.readiness.snapshot(sourceVersionID: try #require(result.sourceVersionID))
        #expect(snap.dimension(.textExtraction)?.state == .ready)
        #expect(snap.dimension(.indexing)?.state == .ready)
        #expect(snap.isSearchReady)
    }

    @Test("Indexing readiness records exact FTS coverage units")
    @MainActor func indexingExactCoverage() async throws {
        let rig = try await makeRig()
        let result = try await rig.coordinator.ingest(fileAt: try write(rig, "matter.eml", email))
        let snap = try await rig.readiness.snapshot(sourceVersionID: try #require(result.sourceVersionID))
        let idx = snap.dimension(.indexing)
        #expect(idx?.state == .ready)
        #expect((idx?.totalUnits ?? 0) > 0)
        #expect(idx?.completedUnits == idx?.totalUnits)
    }

    @Test("Structural extraction advances from the committed document")
    @MainActor func structuralAdvances() async throws {
        let rig = try await makeRig()
        let result = try await rig.coordinator.ingest(fileAt: try write(rig, "matter.eml", email))
        let snap = try await rig.readiness.snapshot(sourceVersionID: try #require(result.sourceVersionID))
        #expect([.ready, .partial].contains(snap.dimension(.structuralExtraction)?.state ?? .notStarted))
    }

    @Test("A loader failure records a failed text dimension while custody is intact")
    @MainActor func loaderFailureTextFailed() async throws {
        let rig = try await makeRig()
        let url = try writeData(rig, "empty.txt", Data())   // text loader rejects empty content
        let result = try? await rig.coordinator.ingest(fileAt: url)
        let versionID = try #require(try await rig.db.query("SELECT id FROM source_versions;", []).first?.uuid(0))
        let snap = try await rig.readiness.snapshot(sourceVersionID: versionID)
        #expect(snap.dimension(.textExtraction)?.state == .failed)
        #expect(snap.dimension(.preservation)?.state == .ready)   // custody intact
        _ = result
    }

    @Test("An unknown, unparseable input is bootstrapped but never evidence-ready")
    @MainActor func unknownNotEvidenceReady() async throws {
        let rig = try await makeRig()
        let result = try await rig.coordinator.ingest(fileAt: try writeData(rig, "mystery.zzz", Data([0x01, 0x02, 0x03, 0x04])))
        let snap = try await rig.readiness.snapshot(sourceVersionID: try #require(result.sourceVersionID))
        #expect(snap.dimensions.count == 10)
        #expect(snap.isEvidenceReady == false)
    }

    @Test("A deferred audio source has blocked/deferred transcription and text, completion deferred")
    @MainActor func deferredAudio() async throws {
        let rig = try await makeRig()
        let result = try await rig.coordinator.ingest(fileAt: try writeData(rig, "voice.mp3", Data(repeating: 0x11, count: 64)))
        let snap = try await rig.readiness.snapshot(sourceVersionID: try #require(result.sourceVersionID))
        let tr = snap.dimension(.transcription)
        #expect(tr?.state == .blocked && tr?.condition == .deferred)
        #expect(snap.dimension(.textExtraction)?.state == .blocked)
        #expect(snap.completionState == .deferred)
    }

    @Test("A deferred video source has blocked/deferred transcription")
    @MainActor func deferredVideo() async throws {
        let rig = try await makeRig()
        let result = try await rig.coordinator.ingest(fileAt: try writeData(rig, "clip.mp4", Data(repeating: 0x22, count: 64)))
        let snap = try await rig.readiness.snapshot(sourceVersionID: try #require(result.sourceVersionID))
        #expect(snap.dimension(.transcription)?.condition == .deferred)
    }

    @Test("Readiness advances are recorded as events on the append-only ledger")
    @MainActor func advancesRecordedAsEvents() async throws {
        let rig = try await makeRig()
        let result = try await rig.coordinator.ingest(fileAt: try write(rig, "matter.eml", email))
        let inspector = SourceReadinessLedgerInspector(database: rig.db)
        let count = try await inspector.eventCount(sourceVersionID: try #require(result.sourceVersionID))
        #expect(count > 10)   // 10 initialize + ≥1 pipeline advance
    }
}
