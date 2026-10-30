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

    /// §2 — a REAL readable source: a file, its knowledge object with `text`, one evidence block per
    /// sentence (so a quote resolves to a genuine block), and the current source version — included
    /// in the case's scope by exact version. Returns the version, the object and the block ids.
    static func seedPassage(_ db: Database, cases: InvestigationCaseRepository, caseID: UUID, name: String, text: String)
        async throws -> (version: UUID, object: UUID, blocks: [UUID]) {
        let fileID = UUID(), koID = UUID(), version = UUID(), docID = UUID()
        let hex = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let hash = hex + hex   // 64 hexadecimal characters, unique per seed (the ledger's CHECK admits hex only)
        try await db.exec("INSERT INTO files (id, url, source_type, availability, content_hash) VALUES (?,?,?,?,?);",
                          [.uuid(fileID), .text("file:///case-test/\(name)"), .text("txt"), .text("available"), .text(hash)])
        try await db.exec("INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at) VALUES (?,?,?,?,?,?);",
                          [.uuid(koID), .uuid(fileID), .text("txt"), .text(text), .real(0), .real(0)])
        try await db.exec("""
            INSERT INTO source_versions (id, logical_source_id, document_id, content_hash, valid_from, is_current, created_at,
                filename, detected_type, detection_basis, size_bytes, custody_mode, preservation_status, intake_recorded_at, original_url)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);
            """, [.uuid(version), .uuid(fileID), .uuid(docID), .text(hash), .real(100), .integer(1), .real(100),
                  .text(name), .text("txt"), .text("magicBytes"), .integer(Int64(text.utf8.count)), .text("referenced"), .text("referenceRecorded"), .real(100),
                  .text("file:///case-test/\(name)")])
        var blocks: [UUID] = []
        let sentences = text.components(separatedBy: ". ").map { $0.hasSuffix(".") ? $0 : $0 + "." }.filter { $0.count > 2 }
        for (i, sentence) in sentences.enumerated() {
            let blockID = UUID()
            try await db.exec("""
                INSERT INTO evidence_blocks (id, document_id, source_version_id, ordinal, kind, raw_text, normalized_text, extraction_method, extraction_confidence)
                VALUES (?,?,?,?,?,?,?,?,?);
                """, [.uuid(blockID), .uuid(docID), .uuid(version), .integer(Int64(i)), .text("paragraph"), .text(sentence), .text(sentence.lowercased()), .text("native"), .real(1.0)])
            try await db.exec("INSERT INTO evidence_block_objects (evidence_block_id, knowledge_object_id, linked_at) VALUES (?,?,?);", [.uuid(blockID), .uuid(koID), .real(0)])
            blocks.append(blockID)
        }
        let header = try await cases.fetch(caseID: caseID)?.caseHeader
        _ = try await cases.includeSource(caseID: caseID, expectedRevision: header?.revision ?? 1, sourceRef: version.uuidString,
                                          sourceKind: .sourceVersion, actor: "Ada", at: Date())
        return (version, koID, blocks)
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
