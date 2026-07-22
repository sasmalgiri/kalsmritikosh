//
//  HistoryArtifactRepositoryTests.swift
//  Kalsmritikosh Tests
//
//  Universal History program, Phase 9 (HIST-060/061). The v61 migration applies; a
//  reconstruction persists (header + chapters + items + evidence + gaps) and reloads;
//  a rebuild creates a NEW artifact and supersedes the old, which stays loadable
//  (preserve-not-delete / replayable).
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("HIST Phase 9 — artifact persistence + versioning")
struct HistoryArtifactRepositoryTests {

    private let subjectID = UUID()
    private let clock = Date(timeIntervalSince1970: 1_700_000_000)

    private func freshDB() async throws -> Database {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ha-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try Database(url: dir.appendingPathComponent("t.sqlite"))
        try await SchemaMigrations.migrate(db)
        return db
    }

    private func result() -> HistoryReconstructionResult {
        let subject = ResolvedHistorySubject(subject: .person(subjectID), displayName: "Shirshendu",
                                             canonicalEntityID: subjectID, resolutionConfidence: 1.0)
        let item = HistoryItem(subject: .person(subjectID), kind: .stateStart, title: "Worked at Orchid",
                               start: TemporalValue(start: Date(timeIntervalSince1970: 1_072_915_200), precision: .day, confidence: 0.8),
                               evidenceStatus: .sourceAsserted, confidence: 0.8,
                               evidence: [EvidenceReference(objectID: UUID()), EvidenceReference(objectID: UUID())])
        let outline = HistoryOutline(
            subject: subject, corpusSnapshotID: nil, items: [item],
            chapters: [HistoryChapterPlan(ordinal: 0, title: "2004", itemIDs: [item.id])],
            actors: [subjectID], relationships: [],
            coverage: HistoryCoverage(totalItems: 1, datedItems: 1, undatedItems: 0,
                                      earliest: Date(timeIntervalSince1970: 1_072_915_200), latest: nil,
                                      evidenceObjectCount: 2, assertionCount: 0, genericFactCount: 0, eventCount: 0),
            gaps: [HistoryGap(kind: .missingEndDate, subject: .person(subjectID),
                              description: "No end date.", expectedEvidenceTypes: ["relieving letter"], confidence: 0.7)])
        return HistoryReconstructionResult(subject: subject, outline: outline, claims: [],
                                           engineVersion: "history-engine-1", generatedAt: clock)
    }

    @Test("Migration reaches v61 (history_artifacts exists)")
    func migration() async throws {
        let db = try await freshDB()
        #expect(try await db.currentUserVersion() == 61)
        #expect(SchemaMigrations.latestVersion == 61)
        let t = try await db.query("SELECT name FROM sqlite_master WHERE type='table' AND name='history_artifacts';", [])
        #expect(!t.isEmpty)
    }

    @Test("Save persists the full graph and reloads; coverage round-trips")
    func saveAndLoad() async throws {
        let repo = HistoryArtifactRepository(database: try await freshDB())
        let r = result()
        let id = try await repo.save(r, at: clock)
        let header = try #require(try await repo.header(id: id))
        #expect(header.subjectLabel == "Shirshendu")
        #expect(header.subjectID == subjectID)
        #expect(header.engineVersion == "history-engine-1")
        #expect(header.coverage.datedItems == 1)          // coverage round-tripped
        #expect(header.isCurrent)
        #expect(try await repo.itemCount(artifactID: id) == 1)
        #expect(try await repo.gapCount(artifactID: id) == 1)
        let itemID = r.outline.items[0].id
        #expect(try await repo.evidenceCount(itemID: itemID) == 2)
    }

    @Test("Rebuild creates a new artifact + supersedes the old; old stays loadable")
    func versioning() async throws {
        let repo = HistoryArtifactRepository(database: try await freshDB())
        let old = try await repo.save(result(), at: clock)
        let new = try await repo.save(result(), at: clock.addingTimeInterval(60))
        try await repo.supersede(old, by: new, at: clock.addingTimeInterval(60))

        let oldHeader = try #require(try await repo.header(id: old))
        #expect(oldHeader.supersededBy == new)             // linked, not overwritten
        #expect(oldHeader.isCurrent == false)
        #expect(try await repo.header(id: old) != nil)     // old still replayable
        let current = try await repo.current(subjectID: subjectID)
        #expect(current.map(\.id) == [new])                // only the new artifact is current
    }
}
