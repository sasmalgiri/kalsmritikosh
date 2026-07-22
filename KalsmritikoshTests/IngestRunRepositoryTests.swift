//
//  IngestRunRepositoryTests.swift
//  KalsmritikoshTests
//
//  ING-001/ING-004 — durable ingest run-state: transitions persist, an interrupted run is
//  resumable, and resume targets exactly the not-done files.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("ING-001 IngestRunRepository")
struct IngestRunRepositoryTests {

    private func repo() async throws -> IngestRunRepository {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ing-\(UUID().uuidString).sqlite")
        let db = try Database(url: tmp)
        try await SchemaMigrations.migrate(db)
        return IngestRunRepository(database: db)
    }

    @Test("Transitions update completed/failed counts")
    func counts() async throws {
        let r = try await repo()
        let run = try await r.startRun(totalFiles: 3, atMillis: 1)
        try await r.setFileState(run: run, path: "/a", state: .done, atMillis: 2)
        try await r.setFileState(run: run, path: "/b", state: .failed, error: "x", atMillis: 3)
        let hdr = try await r.resumableRuns().first
        #expect(hdr?.completedFiles == 1)
        #expect(hdr?.failedFiles == 1)
    }

    @Test("An interrupted run is resumable; pending files exclude done")
    func resume() async throws {
        let r = try await repo()
        let run = try await r.startRun(totalFiles: 3, atMillis: 1)
        try await r.setFileState(run: run, path: "/a", state: .done, atMillis: 2)
        try await r.setFileState(run: run, path: "/b", state: .failed, error: "x", atMillis: 3)
        try await r.setFileState(run: run, path: "/c", state: .running, atMillis: 4)
        #expect(try await r.resumableRuns().count == 1)
        #expect(Set(try await r.pendingFiles(run: run)) == Set(["/b", "/c"]))
    }

    @Test("Finishing a run removes it from resumable")
    func finish() async throws {
        let r = try await repo()
        let run = try await r.startRun(totalFiles: 1, atMillis: 1)
        try await r.finish(run: run, status: .completed, atMillis: 2)
        #expect(try await r.resumableRuns().isEmpty)
    }

    @Test("Path hash is stable")
    func pathHashStable() {
        #expect(IngestRunRepository.pathHash("/x/y.pdf") == IngestRunRepository.pathHash("/x/y.pdf"))
        #expect(IngestRunRepository.pathHash("/a") != IngestRunRepository.pathHash("/b"))
    }
}
