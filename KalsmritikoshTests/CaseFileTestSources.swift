//
//  CaseFileTestSources.swift
//  KalsmritikoshTests
//
//  Case-file evidence references must resolve (implementation brief §4), so tests attach real
//  source versions that the case includes, never made-up strings.
//

import Foundation
@testable import Kalsmritikosh

enum CaseFileTestSources {
    /// Insert `count` source versions and include each, by exact version, in the case's scope.
    /// Returns their references (the version ids as the evidence picker writes them).
    static func inScope(_ db: Database, cases: InvestigationCaseRepository, caseID: UUID, count: Int = 1) async throws -> [String] {
        var refs: [String] = []
        for _ in 0..<count {
            let version = try await seed(db)
            let header = try await cases.fetch(caseID: caseID)?.caseHeader
            _ = try await cases.includeSource(caseID: caseID, expectedRevision: header?.revision ?? 1, sourceRef: version.uuidString,
                                              sourceKind: .sourceVersion, actor: "Ada", at: Date())
            refs.append(version.uuidString)
        }
        return refs
    }

    /// A source version that exists in the archive but is in no case's scope.
    static func seed(_ db: Database) async throws -> UUID {
        let version = UUID(), logical = UUID()
        try await db.exec("INSERT INTO files (id, url, source_type, availability) VALUES (?,?,?,?);",
                          [.uuid(logical), .text("file:///case-test/\(logical.uuidString)"), .text("txt"), .text("available")])
        try await db.exec("""
            INSERT INTO source_versions (id, logical_source_id, content_hash, valid_from, is_current, created_at,
                filename, detected_type, detection_basis, size_bytes, custody_mode, preservation_status, intake_recorded_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?);
            """, [.uuid(version), .uuid(logical), .text(String(repeating: "c", count: 64)), .real(100), .integer(1), .real(100),
                  .text("f.txt"), .text("txt"), .text("magicBytes"), .integer(1), .text("referenced"), .text("referenceRecorded"), .real(100)])
        return version
    }
}
