//
//  IngestVersioningTests.swift
//  KalsmritikoshTests
//
//  PI.1 — version-instead-of-delete. Proves that when a file's bytes change,
//  the prior version's file record AND its extracted KnowledgeObject content are
//  preserved in the history tables BEFORE the active rows are refreshed — so no
//  extraction is ever silently lost ("never delete extracted data"), while the
//  active tables still hold only the current version (retrieval unchanged).
//
//  NOTE: add this file to the KalsmritikoshTests target in Xcode
//  (File ▸ Add Files…) before running — test bundle membership is explicit.
//

import Testing
import Foundation
@testable import Kalsmritikosh

struct IngestVersioningTests {

    private func makeDB() async throws -> Database {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kalsm-versioning-\(UUID().uuidString)", isDirectory: true)
        let url = dir.appendingPathComponent("test.sqlite")
        let db = try Database(url: url)
        try await SchemaMigrations.migrate(db)
        return db
    }

    @Test func archivePreservesFileAndKOContentBeforeSupersede() async throws {
        let db = try await makeDB()
        let files = FilesRepository(database: db)
        let fileID = UUID()
        let url = URL(fileURLWithPath: "/tmp/contract.txt")

        try await files.upsert(FileRecord(
            id: fileID, url: url, sourceType: .txt,
            sizeBytes: 10, contentHash: "hashA"
        ))
        // A KnowledgeObject tied to the file (inserted raw to keep the test focused
        // on the versioning path, not KO construction).
        try await db.exec("""
        INSERT INTO knowledge_objects
          (id, file_id, source_type, content, metadata_json, confidence, created_at, updated_at)
        VALUES (?, ?, 'txt', 'original v1 content', '{}', 1.0, 0, 0);
        """, [.uuid(UUID()), .uuid(fileID)])

        // Content changed → preserve, THEN refresh the active rows.
        try await files.archiveVersionBeforeSupersede(
            FileRecord(id: fileID, url: url, sourceType: .txt, sizeBytes: 10, contentHash: "hashA"),
            supersededBy: nil
        )
        try await files.deleteByID(fileID)

        // 1. A prior version was recorded for this URL.
        let versions = try await files.versionCount(forURL: url)
        #expect(versions == 1)

        // 2. The old KO CONTENT survived, even though the active cascade removed it.
        let hist = try await db.query(
            "SELECT content FROM knowledge_objects_history WHERE file_id = ?;",
            [.uuid(fileID)]
        )
        #expect(hist.first?.string(0) == "original v1 content")

        // 3. The active tables no longer hold the superseded content (no stale dup).
        let active = try await db.query(
            "SELECT COUNT(*) FROM knowledge_objects WHERE file_id = ?;",
            [.uuid(fileID)]
        )
        #expect((active.first?.int(0) ?? -1) == 0)

        await db.close()
    }

    @Test func noArchiveRowsWhenNothingSuperseded() async throws {
        let db = try await makeDB()
        let files = FilesRepository(database: db)
        let url = URL(fileURLWithPath: "/tmp/fresh.txt")
        try await files.upsert(FileRecord(url: url, sourceType: .txt, contentHash: "h"))
        // A normal first ingest supersedes nothing.
        #expect(try await files.versionCount(forURL: url) == 0)
        await db.close()
    }
}
