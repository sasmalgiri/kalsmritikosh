//
//  ContainerInspectionRepositoryTests.swift
//  KalsmritikoshTests
//
//  USF-M2 (USF-006 §28) — the sole v87 writer. Atomic manifest + member persistence, DERIVED counts,
//  CAS revision, member replacement, non-container rejection, missing-version rejection, and the
//  admitted-child / non-admitted invariants. Synthetic sources only.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("USF-M2 — container inspection repository", .serialized)
struct ContainerInspectionRepositoryTests {

    private func makeDB() async throws -> Database {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("usfm2-repo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try Database(url: dir.appendingPathComponent("db.sqlite"))
        try await SchemaMigrations.migrate(db)
        try await db.exec("PRAGMA foreign_keys = ON;")
        return db
    }

    private func seedVersion(_ db: Database, id: UUID, hash: String, type: String) async throws {
        try await db.exec("INSERT INTO files (id, url, source_type, availability) VALUES (?,?,?,?);",
                          [.uuid(id), .text("file:///x/\(id.uuidString)"), .text(type), .text("available")])
        try await db.exec("""
            INSERT INTO source_versions (id, logical_source_id, content_hash, valid_from, is_current, created_at,
                filename, detected_type, detection_basis, size_bytes, custody_mode, preservation_status, intake_recorded_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?);
            """, [.uuid(id), .uuid(id), .text(hash), .real(100), .integer(1), .real(100),
                  .text("f.\(type)"), .text(type), .text("magicBytes"), .integer(1), .text("referenced"),
                  .text("referenceRecorded"), .real(100)])
    }

    private func member(_ parent: UUID, _ ord: Int, _ disp: ContainerMemberDisposition,
                        child: UUID? = nil, hash: String? = nil, kind: ContainerEntryKind = .file, bytes: Int64 = 10) -> ContainerMember {
        ContainerMember(parentSourceVersionID: parent, ordinal: ord, memberPath: "m/\(ord).bin",
                        normalizedMemberPath: "m/\(ord).bin", entryKind: kind, compressedSize: 5, uncompressedSize: bytes,
                        detectedType: .pdf, disposition: disp, childSourceVersionID: child, contentHash: hash)
    }

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("Records a manifest + members and reads them back with DERIVED counts")
    func roundTrip() async throws {
        let db = try await makeDB()
        let repo = ContainerInspectionRepository(database: db)
        let parent = UUID(); try await seedVersion(db, id: parent, hash: String(repeating: "a", count: 64), type: "zip")
        let child = UUID(); let ch = String(repeating: "c", count: 64); try await seedVersion(db, id: child, hash: ch, type: "pdf")
        let members = [member(parent, 0, .admitted, child: child, hash: ch), member(parent, 1, .encrypted),
                       member(parent, 2, .unsupported), member(parent, 3, .directory, kind: .directory, bytes: 0)]
        let m = try await repo.record(sourceVersionID: parent, containerType: .zip, status: .complete, members: members, at: t0)
        #expect(m.revision == 1)
        #expect(m.totalEntries == 4)
        #expect(m.regularFileEntries == 3)
        #expect(m.admittedMembers == 1)
        #expect(m.blockedMembers == 1)
        #expect(m.unsupportedMembers == 1)
        let read = try await repo.manifest(sourceVersionID: parent)
        #expect(read?.admittedMembers == 1)
        #expect(try await repo.members(parentSourceVersionID: parent).count == 4)
    }

    @Test("Re-recording increments the revision and replaces the member rows")
    func revisionAndReplace() async throws {
        let db = try await makeDB()
        let repo = ContainerInspectionRepository(database: db)
        let parent = UUID(); try await seedVersion(db, id: parent, hash: String(repeating: "a", count: 64), type: "zip")
        _ = try await repo.record(sourceVersionID: parent, containerType: .zip, status: .partial,
                                  members: [member(parent, 0, .encrypted), member(parent, 1, .unsupported)], at: t0)
        let m2 = try await repo.record(sourceVersionID: parent, containerType: .zip, status: .complete,
                                       members: [member(parent, 0, .unsupported)], at: t0)
        #expect(m2.revision == 2)
        let members = try await repo.members(parentSourceVersionID: parent)
        #expect(members.count == 1)                       // old two rows replaced by one
        #expect(members.first?.disposition == .unsupported)
    }

    @Test("A missing container SourceVersion is rejected")
    func missingVersion() async throws {
        let db = try await makeDB()
        let repo = ContainerInspectionRepository(database: db)
        await #expect(throws: ContainerError.self) {
            _ = try await repo.record(sourceVersionID: UUID(), containerType: .zip, status: .complete, members: [], at: self.t0)
        }
    }

    @Test("A non-container SourceVersion is rejected")
    func nonContainerRejected() async throws {
        let db = try await makeDB()
        let repo = ContainerInspectionRepository(database: db)
        let parent = UUID(); try await seedVersion(db, id: parent, hash: String(repeating: "a", count: 64), type: "txt")
        await #expect(throws: ContainerError.self) {
            _ = try await repo.record(sourceVersionID: parent, containerType: .zip, status: .complete, members: [], at: self.t0)
        }
    }

    @Test("An admitted member missing its child/hash is rejected before any write")
    func admittedMissingChildRejected() async throws {
        let db = try await makeDB()
        let repo = ContainerInspectionRepository(database: db)
        let parent = UUID(); try await seedVersion(db, id: parent, hash: String(repeating: "a", count: 64), type: "zip")
        await #expect(throws: ContainerError.self) {
            _ = try await repo.record(sourceVersionID: parent, containerType: .zip, status: .complete,
                                      members: [self.member(parent, 0, .admitted)], at: self.t0)   // no child/hash
        }
        #expect(try await repo.manifest(sourceVersionID: parent) == nil)   // nothing persisted
    }

    @Test("A non-admitted member carrying a child version is rejected")
    func nonAdmittedWithChildRejected() async throws {
        let db = try await makeDB()
        let repo = ContainerInspectionRepository(database: db)
        let parent = UUID(); try await seedVersion(db, id: parent, hash: String(repeating: "a", count: 64), type: "zip")
        let child = UUID(); let ch = String(repeating: "c", count: 64); try await seedVersion(db, id: child, hash: ch, type: "pdf")
        await #expect(throws: ContainerError.self) {
            _ = try await repo.record(sourceVersionID: parent, containerType: .zip, status: .complete,
                                      members: [self.member(parent, 0, .encrypted, child: child, hash: ch)], at: self.t0)
        }
    }

    @Test("The caller's judged status is preserved while counts stay derived")
    func statusPreserved() async throws {
        let db = try await makeDB()
        let repo = ContainerInspectionRepository(database: db)
        let parent = UUID(); try await seedVersion(db, id: parent, hash: String(repeating: "a", count: 64), type: "zip")
        let m = try await repo.record(sourceVersionID: parent, containerType: .zip, status: .partial,
                                      members: [member(parent, 0, .blockedRootBudget)], at: t0)
        #expect(m.status == .partial)
        #expect(m.blockedMembers == 1)
    }

    @Test("An unsupported (RAR/7z) container records a manifest with no members and status unsupported")
    func unsupportedContainerManifest() async throws {
        let db = try await makeDB()
        let repo = ContainerInspectionRepository(database: db)
        let parent = UUID(); try await seedVersion(db, id: parent, hash: String(repeating: "a", count: 64), type: "rar")
        let m = try await repo.record(sourceVersionID: parent, containerType: .rar, status: .unsupported, members: [], at: t0)
        #expect(m.status == .unsupported)
        #expect(m.totalEntries == 0)
        // Contents unknown ≠ empty container: the manifest EXISTS to say "not enumerated".
        #expect(try await repo.manifest(sourceVersionID: parent) != nil)
    }
}
