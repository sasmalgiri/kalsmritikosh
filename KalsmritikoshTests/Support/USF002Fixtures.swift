//
//  USF002Fixtures.swift
//  KalsmritikoshTests
//
//  USF-002 — shared rig for source-readiness tests. Builds a v85 database and seeds exact
//  source versions (hex SHA-256 custody). Synthetic sources only.
//

import Foundation
@testable import Kalsmritikosh

struct USF002Rig {
    let db: Database
    let repo: SourceReadinessRepository
    let inspector: SourceReadinessLedgerInspector
    let dir: URL
    let dbURL: URL
}

enum USF002Fixtures {
    static let t0 = Date(timeIntervalSince1970: 1_753_900_000)
    static let hexHash = String(repeating: "a", count: 64)

    static func makeRig(atVersion version: Int = SchemaMigrations.latestVersion) async throws -> USF002Rig {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("usf002-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let dbURL = base.appendingPathComponent("readiness.sqlite")
        let db = try await MigrationFixtureBuilder.database(atVersion: version, at: dbURL)
        try await db.exec("PRAGMA foreign_keys = ON;")
        return USF002Rig(db: db, repo: SourceReadinessRepository(database: db),
                         inspector: SourceReadinessLedgerInspector(database: db), dir: base, dbURL: dbURL)
    }

    /// Insert an exact source version (files + source_versions). Returns its id.
    @discardableResult
    static func seedVersion(_ rig: USF002Rig, id: UUID = UUID(), type: String = "txt",
                            preservation: String = "referenceRecorded", documentID: UUID? = nil,
                            hash: String? = nil) async throws -> UUID {
        try await rig.db.exec("INSERT INTO files (id, url, source_type, availability) VALUES (?,?,?,?);",
                              [.uuid(id), .text("file:///x/\(id.uuidString)"), .text(type), .text("available")])
        let managed = preservation == "managedCopyStored"
        try await rig.db.exec("""
            INSERT INTO source_versions (id, logical_source_id, document_id, content_hash, valid_from, is_current, created_at,
                filename, detected_type, detection_basis, size_bytes, custody_mode, preservation_status, vault_address, intake_recorded_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);
            """, [.uuid(id), .uuid(id), documentID.map(SQLValue.uuid) ?? .null, .text(hash ?? hexHash), .real(100), .integer(1), .real(100),
                  .text("f.\(type)"), .text(type), .text("magicBytes"), .integer(1),
                  .text(managed ? "managed" : "referenced"), .text(preservation),
                  managed ? .text(hash ?? hexHash) : .null, .real(100)])
        return id
    }

    /// Insert an evidence block owned by a source version. Returns its id.
    @discardableResult
    static func seedBlock(_ rig: USF002Rig, versionID: UUID, documentID: UUID = UUID()) async throws -> UUID {
        let blockID = UUID()
        try await rig.db.exec("""
            INSERT INTO evidence_blocks (id, document_id, source_version_id, ordinal, kind, raw_text, normalized_text,
                extraction_method, extraction_confidence) VALUES (?,?,?,?,?,?,?,?,?);
            """, [.uuid(blockID), .uuid(documentID), .uuid(versionID), .integer(0), .text("paragraph"),
                  .text("t"), .text("t"), .text("native"), .real(1.0)])
        return blockID
    }

    /// One dimension update convenience.
    static func update(_ dim: SourceReadinessDimension, _ state: SourceReadinessDimensionState,
                       action: SourceReadinessAction, appl: SourceReadinessApplicability = .required,
                       cond: SourceReadinessCondition? = nil, c: Int? = nil, t: Int? = nil,
                       basis: SourceReadinessBasis? = nil, detail: String? = nil) -> SourceReadinessDimensionUpdate {
        SourceReadinessDimensionUpdate(dimension: dim, state: state, action: action, applicability: appl,
                                       condition: cond, completedUnits: c, totalUnits: t, basis: basis, detail: detail)
    }

    static func plan(_ versionID: UUID, expectedRevision: Int, _ updates: [SourceReadinessDimensionUpdate],
                     at: Date = t0) -> SourceReadinessUpdatePlan {
        SourceReadinessUpdatePlan(sourceVersionID: versionID, expectedRevision: expectedRevision, updates: updates,
                                  producerID: "test.producer", producerVersion: "1", occurredAt: at)
    }
}
