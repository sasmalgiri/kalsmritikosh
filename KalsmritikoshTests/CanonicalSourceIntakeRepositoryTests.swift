//
//  CanonicalSourceIntakeRepositoryTests.swift
//  KalsmritikoshTests
//
//  USF-001 — the atomic canonical-identity transaction: new logical source / unchanged /
//  new version / move / alias, custody modes, parent relations, empty + unknown inputs,
//  streaming capture, and atomic rollback. Synthetic sources only.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("USF-001 — canonical source intake repository", .serialized)
struct CanonicalSourceIntakeRepositoryTests {

    private let t0 = USF001Fixtures.t0

    private func currentVersionRow(_ rig: USFRig, logical: UUID) async throws -> SQLRow? {
        try await rig.db.query("""
            SELECT id, content_hash, supersedes, is_current, preservation_status, custody_mode, vault_address, filename, detected_type, detection_basis, size_bytes
              FROM source_versions WHERE logical_source_id = ? AND is_current = 1;
            """, [.uuid(logical)]).first
    }

    // MARK: - Identity outcomes

    @Test("A new URL with new bytes creates one logical source, version, file and receipt")
    func newLogicalSource() async throws {
        let rig = try await USF001Fixtures.makeRig()
        let url = try USF001Fixtures.writeFile(rig, name: "report.txt", bytes: USF001Fixtures.bytes("hello world"))
        let h = try await USF001Fixtures.intake(rig, url: url)
        #expect(h.outcome == .newLogicalSource)
        #expect(h.shouldProcess == true)
        #expect(h.occurrenceFileID == h.logicalSourceID)
        #expect(try await rig.db.query("SELECT COUNT(*) FROM files;", []).first?.int(0) == 1)
        #expect(try await rig.db.query("SELECT COUNT(*) FROM source_versions;", []).first?.int(0) == 1)
        #expect(try await rig.db.query("SELECT COUNT(*) FROM source_intake_receipts WHERE outcome='newLogicalSource';", []).first?.int(0) == 1)
        #expect(h.contentHash.count == 64 && h.contentHash == h.contentHash.lowercased())
    }

    @Test("The same URL with the same bytes is unchanged and must not reprocess")
    func unchanged() async throws {
        let rig = try await USF001Fixtures.makeRig()
        let url = try USF001Fixtures.writeFile(rig, name: "a.txt", bytes: USF001Fixtures.bytes("same"))
        let first = try await USF001Fixtures.intake(rig, url: url)
        let second = try await USF001Fixtures.intake(rig, url: url, at: t0.addingTimeInterval(10))
        #expect(second.outcome == .unchanged)
        #expect(second.shouldProcess == false)
        #expect(second.sourceVersionID == first.sourceVersionID)
        #expect(try await rig.db.query("SELECT COUNT(*) FROM source_versions;", []).first?.int(0) == 1)
        #expect(try await rig.db.query("SELECT COUNT(*) FROM source_intake_receipts;", []).first?.int(0) == 2)  // both audited
    }

    @Test("The same URL with changed bytes creates a new current version and preserves the old")
    func changedBytesNewVersion() async throws {
        let rig = try await USF001Fixtures.makeRig()
        let url = try USF001Fixtures.writeFile(rig, name: "a.txt", bytes: USF001Fixtures.bytes("v1"))
        let first = try await USF001Fixtures.intake(rig, url: url)
        try USF001Fixtures.bytes("v2 content").write(to: url)      // change bytes at the same URL
        let second = try await USF001Fixtures.intake(rig, url: url, at: t0.addingTimeInterval(10))

        #expect(second.outcome == .newVersion)
        #expect(second.shouldProcess == true)
        #expect(second.logicalSourceID == first.logicalSourceID)
        #expect(second.sourceVersionID != first.sourceVersionID)
        // Old version preserved, retired, and superseded by the new one.
        #expect(try await rig.db.query("SELECT COUNT(*) FROM source_versions;", []).first?.int(0) == 2)
        #expect(try await rig.db.query("SELECT is_current FROM source_versions WHERE id = ?;", [.uuid(first.sourceVersionID)]).first?.int(0) == 0)
        let cur = try #require(try await currentVersionRow(rig, logical: first.logicalSourceID))
        #expect(cur.uuid(0) == second.sourceVersionID)
        #expect(cur.uuid(2) == first.sourceVersionID)             // supersedes chain
    }

    @Test("A new-version supersession chain never crosses logical sources")
    func supersessionStaysWithinLogicalSource() async throws {
        let rig = try await USF001Fixtures.makeRig()
        let url = try USF001Fixtures.writeFile(rig, name: "a.txt", bytes: USF001Fixtures.bytes("v1"))
        let first = try await USF001Fixtures.intake(rig, url: url)
        try USF001Fixtures.bytes("v2").write(to: url)
        let second = try await USF001Fixtures.intake(rig, url: url, at: t0.addingTimeInterval(5))
        let priorLogical = try await rig.db.query(
            "SELECT logical_source_id FROM source_versions WHERE id = ?;", [.uuid(first.sourceVersionID)]).first?.uuid(0)
        #expect(priorLogical == second.logicalSourceID)
        // exactly one current version for the logical source
        #expect(try await rig.db.query("SELECT COUNT(*) FROM source_versions WHERE logical_source_id = ? AND is_current = 1;",
                                       [.uuid(second.logicalSourceID)]).first?.int(0) == 1)
    }

    @Test("Identical bytes at a new URL while the old location is gone is a move (no new version)")
    func move() async throws {
        let rig = try await USF001Fixtures.makeRig()
        let urlA = try USF001Fixtures.writeFile(rig, name: "a.txt", bytes: USF001Fixtures.bytes("dup"))
        let first = try await USF001Fixtures.intake(rig, url: urlA)
        try FileManager.default.removeItem(at: urlA)              // old location gone
        let urlB = try USF001Fixtures.writeFile(rig, name: "b.txt", bytes: USF001Fixtures.bytes("dup"))
        let moved = try await USF001Fixtures.intake(rig, url: urlB, at: t0.addingTimeInterval(10))
        #expect(moved.outcome == .moved)
        #expect(moved.shouldProcess == false)
        #expect(moved.sourceVersionID == first.sourceVersionID)
        #expect(try await rig.db.query("SELECT COUNT(*) FROM source_versions;", []).first?.int(0) == 1)   // no new version
        #expect(try await rig.db.query("SELECT url FROM files WHERE id = ?;", [.uuid(first.logicalSourceID)]).first?.string(0) == urlB.absoluteString)
    }

    @Test("Identical bytes at a new URL while the old location still exists is an alias")
    func alias() async throws {
        let rig = try await USF001Fixtures.makeRig()
        let urlA = try USF001Fixtures.writeFile(rig, name: "a.txt", bytes: USF001Fixtures.bytes("dup"))
        let first = try await USF001Fixtures.intake(rig, url: urlA)
        let urlB = try USF001Fixtures.writeFile(rig, name: "b.txt", bytes: USF001Fixtures.bytes("dup"))   // old still present
        let aliased = try await USF001Fixtures.intake(rig, url: urlB, at: t0.addingTimeInterval(10))
        #expect(aliased.outcome == .aliased)
        #expect(aliased.shouldProcess == false)
        #expect(aliased.logicalSourceID == first.logicalSourceID)
        #expect(aliased.sourceVersionID == first.sourceVersionID)      // shares the canonical version
        #expect(aliased.occurrenceFileID != first.logicalSourceID)     // a distinct occurrence file
    }

    @Test("An alias is not independent evidence: it points at the canonical file and adds no version")
    func aliasIsNotIndependentEvidence() async throws {
        let rig = try await USF001Fixtures.makeRig()
        let urlA = try USF001Fixtures.writeFile(rig, name: "a.txt", bytes: USF001Fixtures.bytes("dup"))
        let first = try await USF001Fixtures.intake(rig, url: urlA)
        let urlB = try USF001Fixtures.writeFile(rig, name: "b.txt", bytes: USF001Fixtures.bytes("dup"))
        let aliased = try await USF001Fixtures.intake(rig, url: urlB, at: t0.addingTimeInterval(10))
        let aliasOf = try await rig.db.query("SELECT alias_of FROM files WHERE id = ?;", [.uuid(aliased.occurrenceFileID)]).first
        #expect(aliasOf?.uuid(0) == first.logicalSourceID)
        #expect(try await rig.db.query("SELECT COUNT(*) FROM source_versions;", []).first?.int(0) == 1)
    }

    // MARK: - Content edge cases

    @Test("An empty accessible file still receives full custody")
    func emptyFile() async throws {
        let rig = try await USF001Fixtures.makeRig()
        let url = try USF001Fixtures.writeFile(rig, name: "empty.txt", bytes: Data())
        let h = try await USF001Fixtures.intake(rig, url: url)
        #expect(h.outcome == .newLogicalSource)
        #expect(h.sizeBytes == 0)
        #expect(h.contentHash == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")  // SHA-256 of empty
        #expect(try await rig.db.query("SELECT COUNT(*) FROM source_versions;", []).first?.int(0) == 1)
    }

    @Test("An unknown-type file is still captured with an unknown detected type")
    func unknownType() async throws {
        let rig = try await USF001Fixtures.makeRig()
        let url = try USF001Fixtures.writeFile(rig, name: "mystery.zzz", bytes: Data([0x01, 0x02, 0x03, 0x04]))
        let h = try await USF001Fixtures.intake(rig, url: url)
        #expect(h.detectedType == .unknown)
        #expect(h.detectionBasis == .unknown)
    }

    @Test("Magic-byte detection wins over the declared extension")
    func magicByteDetection() async throws {
        let rig = try await USF001Fixtures.makeRig()
        // PNG magic bytes but a misleading .txt extension.
        let url = try USF001Fixtures.writeFile(rig, name: "image.txt", bytes: USF001Fixtures.pngBytes())
        let h = try await USF001Fixtures.intake(rig, url: url)
        #expect(h.detectedType == .png)
        #expect(h.detectionBasis == .magicBytes)
    }

    @Test("A declared extension detects the type when there are no magic bytes")
    func declaredExtensionDetection() async throws {
        let rig = try await USF001Fixtures.makeRig()
        let url = try USF001Fixtures.writeFile(rig, name: "notes.txt", bytes: USF001Fixtures.bytes("plain text"))
        let h = try await USF001Fixtures.intake(rig, url: url)
        #expect(h.detectedType == .txt)
        #expect(h.detectionBasis == .declaredExtension)
        #expect(h.declaredExtension == "txt")
    }

    @Test("The detection basis is recorded on the source version")
    func detectionBasisPersisted() async throws {
        let rig = try await USF001Fixtures.makeRig()
        let url = try USF001Fixtures.writeFile(rig, name: "image.txt", bytes: USF001Fixtures.pngBytes())
        let h = try await USF001Fixtures.intake(rig, url: url)
        let basis = try await rig.db.query("SELECT detection_basis FROM source_versions WHERE id = ?;", [.uuid(h.sourceVersionID)]).first?.string(0)
        #expect(basis == "magicBytes")
    }

    // MARK: - Custody

    @Test("Reference custody records the reference and stores no vault copy")
    func referenceCustody() async throws {
        let rig = try await USF001Fixtures.makeRig()
        let url = try USF001Fixtures.writeFile(rig, name: "a.txt", bytes: USF001Fixtures.bytes("ref"))
        let h = try await USF001Fixtures.intake(rig, url: url, custody: .referenced)
        #expect(h.custodyMode == .referenced)
        #expect(h.preservationStatus == .referenceRecorded)
        #expect(h.vaultAddress == nil)
        #expect(await rig.vault.contains(h.contentHash) == false)
    }

    @Test("Managed custody stores an immutable content-addressed copy and records the address")
    func managedCustodySuccess() async throws {
        let rig = try await USF001Fixtures.makeRig()
        let url = try USF001Fixtures.writeFile(rig, name: "a.txt", bytes: USF001Fixtures.bytes("managed bytes"))
        let h = try await USF001Fixtures.intake(rig, url: url, custody: .managed)
        #expect(h.custodyMode == .managed)
        #expect(h.preservationStatus == .managedCopyStored)
        #expect(h.vaultAddress == h.contentHash)
        #expect(await rig.vault.contains(h.contentHash) == true)
    }

    @Test("A managed-copy failure remains a visible version, never a silent downgrade")
    func managedCopyFailureRemainsVisible() async throws {
        let rig = try await USF001Fixtures.makeRig(withVault: false)   // no vault → managed copy cannot store
        let url = try USF001Fixtures.writeFile(rig, name: "a.txt", bytes: USF001Fixtures.bytes("bytes"))
        let h = try await USF001Fixtures.intake(rig, url: url, custody: .managed)
        #expect(h.custodyMode == .managed)
        #expect(h.preservationStatus == .managedCopyFailed)
        #expect(h.vaultAddress == nil)
        #expect(try await rig.db.query("SELECT COUNT(*) FROM source_versions;", []).first?.int(0) == 1)  // still recorded
    }

    // MARK: - Parent relations

    @Test("A parent relation pins the exact parent and child versions")
    func parentRelation() async throws {
        let rig = try await USF001Fixtures.makeRig()
        let parentURL = try USF001Fixtures.writeFile(rig, name: "email.eml", bytes: USF001Fixtures.bytes("From: a"))
        let parent = try await USF001Fixtures.intake(rig, url: parentURL)
        let childURL = try USF001Fixtures.writeFile(rig, name: "attach.txt", bytes: USF001Fixtures.bytes("attachment"))
        let ref = SourceParentReference(parentSourceVersionID: parent.sourceVersionID, relation: .attachment, ordinal: 0)
        let child = try await USF001Fixtures.intake(rig, url: childURL, parent: ref, at: t0.addingTimeInterval(1))
        let rel = try #require(try await rig.db.query("""
            SELECT parent_source_version_id, child_source_version_id, relation FROM source_version_relations;
            """, []).first)
        #expect(rel.uuid(0) == parent.sourceVersionID)
        #expect(rel.uuid(1) == child.sourceVersionID)
        #expect(rel.string(2) == "attachment")
    }

    @Test("A duplicate parent-child relation is idempotent (never duplicated)")
    func duplicateRelationIdempotent() async throws {
        let rig = try await USF001Fixtures.makeRig()
        let parentURL = try USF001Fixtures.writeFile(rig, name: "email.eml", bytes: USF001Fixtures.bytes("From: a"))
        let parent = try await USF001Fixtures.intake(rig, url: parentURL)
        let childURL = try USF001Fixtures.writeFile(rig, name: "attach.txt", bytes: USF001Fixtures.bytes("attachment"))
        let ref = SourceParentReference(parentSourceVersionID: parent.sourceVersionID, relation: .attachment)
        _ = try await USF001Fixtures.intake(rig, url: childURL, parent: ref, at: t0.addingTimeInterval(1))
        _ = try await USF001Fixtures.intake(rig, url: childURL, parent: ref, at: t0.addingTimeInterval(2))   // unchanged + same relation
        #expect(try await rig.db.query("SELECT COUNT(*) FROM source_version_relations;", []).first?.int(0) == 1)
    }

    @Test("An intake naming a nonexistent parent version fails and writes nothing (atomic rollback)")
    func invalidParentRollsBack() async throws {
        let rig = try await USF001Fixtures.makeRig()
        let url = try USF001Fixtures.writeFile(rig, name: "a.txt", bytes: USF001Fixtures.bytes("x"))
        let ref = SourceParentReference(parentSourceVersionID: UUID(), relation: .attachment)  // nonexistent parent
        await #expect(throws: SourceIntakeError.self) {
            _ = try await USF001Fixtures.intake(rig, url: url, parent: ref)
        }
        #expect(try await rig.db.query("SELECT COUNT(*) FROM files;", []).first?.int(0) == 0)
        #expect(try await rig.db.query("SELECT COUNT(*) FROM source_versions;", []).first?.int(0) == 0)
        #expect(try await rig.db.query("SELECT COUNT(*) FROM source_intake_receipts;", []).first?.int(0) == 0)
    }

    // MARK: - Capture guards + durability

    @Test("Capturing a directory or a missing file fails with a typed error")
    func captureGuards() async throws {
        let rig = try await USF001Fixtures.makeRig()
        #expect(throws: SourceIntakeError.self) { _ = try SourceByteCapture.capture(rig.dir) }        // a directory
        let missing = rig.dir.appendingPathComponent("nope.txt")
        #expect(throws: SourceIntakeError.self) { _ = try SourceByteCapture.capture(missing) }        // missing
    }

    @Test("A recorded source version reconstructs exactly after a database reopen")
    func reopenReconstruction() async throws {
        let rig = try await USF001Fixtures.makeRig()
        let url = try USF001Fixtures.writeFile(rig, name: "a.txt", bytes: USF001Fixtures.bytes("durable"))
        let h = try await USF001Fixtures.intake(rig, url: url)
        let db2 = try MigrationFixtureBuilder.reopen(at: rig.dbURL)
        let row = try #require(try await db2.query("""
            SELECT logical_source_id, content_hash, filename, custody_mode, preservation_status, is_current
              FROM source_versions WHERE id = ?;
            """, [.uuid(h.sourceVersionID)]).first)
        #expect(row.uuid(0) == h.logicalSourceID)
        #expect(row.string(1) == h.contentHash)
        #expect(row.string(2) == "a.txt")
        #expect(row.string(3) == "referenced")
        #expect(row.int(5) == 1)
    }
}
