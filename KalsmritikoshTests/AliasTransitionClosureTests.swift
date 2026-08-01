//
//  AliasTransitionClosureTests.swift
//  KalsmritikoshTests
//
//  USF-001.2 — an alias URL whose bytes change resolves to exactly one transition and NEVER
//  creates a second file row for that URL: new bytes matching another canonical re-point the
//  alias at it (reusing the target version); entirely new bytes promote the occurrence to its
//  own canonical source (first version). And a managed custody version whose hash is already
//  vaulted reuses that vault address rather than deriving managedCopyStored from the absence of
//  a copy failure. Synthetic sources only.
//

import Foundation
import Testing
import CryptoKit
@testable import Kalsmritikosh

@Suite("USF-001.2 — alias transition closure + managed vault reuse", .serialized)
struct AliasTransitionClosureTests {

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private struct FileRow { let id: UUID; let aliasOf: UUID?; let hash: String }
    private func fileRow(_ rig: USFRig, _ url: URL) async throws -> FileRow {
        let r = try #require(try await rig.db.query("SELECT id, alias_of, content_hash FROM files WHERE url = ?;",
                                                    [.text(url.absoluteString)]).first)
        return FileRow(id: try #require(r.uuid(0)), aliasOf: r.uuid(1), hash: r.string(2) ?? "")
    }
    private func fileCount(_ rig: USFRig, _ url: URL) async throws -> Int64 {
        try await rig.db.query("SELECT COUNT(*) FROM files WHERE url = ?;", [.text(url.absoluteString)]).first?.int(0) ?? -1
    }
    private func versionCount(_ rig: USFRig) async throws -> Int64 {
        try await rig.db.query("SELECT COUNT(*) FROM source_versions;", []).first?.int(0) ?? -1
    }

    // MARK: - Alias whose bytes become entirely new → promote in place

    @Test("An alias whose bytes become entirely new is PROMOTED to its own canonical source (no second row)")
    func aliasNewUniqueBytesPromotes() async throws {
        let rig = try await USF001Fixtures.makeRig()
        let bytesA = USF001Fixtures.bytes("canonical A bytes")
        let aURL = try USF001Fixtures.writeFile(rig, name: "a.txt", bytes: bytesA)
        _ = try await USF001Fixtures.intake(rig, url: aURL)
        // b.txt with the SAME bytes → alias of A (a.txt still present).
        let bURL = try USF001Fixtures.writeFile(rig, name: "b.txt", bytes: bytesA)
        let alias = try await USF001Fixtures.intake(rig, url: bURL, at: USF001Fixtures.t0.addingTimeInterval(1))
        #expect(alias.outcome == .aliased)
        let occ = try await fileRow(rig, bURL)

        // b.txt now becomes ENTIRELY NEW bytes (not matching any canonical).
        let bytesNew = USF001Fixtures.bytes("entirely new distinct bytes for b")
        _ = try USF001Fixtures.writeFile(rig, name: "b.txt", bytes: bytesNew)
        let promoted = try await USF001Fixtures.intake(rig, url: bURL, at: USF001Fixtures.t0.addingTimeInterval(2))

        #expect(promoted.outcome == .newLogicalSource)
        #expect(promoted.contentHash == sha256(bytesNew))
        // Same occurrence row, now canonical (alias_of NULL), hash refreshed — never a second row.
        let after = try await fileRow(rig, bURL)
        #expect(after.id == occ.id)
        #expect(after.aliasOf == nil)
        #expect(after.hash == sha256(bytesNew))
        #expect(try await fileCount(rig, bURL) == 1)
        // A first source version exists for this promoted logical source.
        let vHash = try await rig.db.query("SELECT content_hash FROM source_versions WHERE logical_source_id = ? AND is_current = 1;",
                                           [.uuid(occ.id)]).first?.string(0)
        #expect(vHash == sha256(bytesNew))
    }

    // MARK: - Alias whose bytes match another canonical → retarget

    @Test("An alias whose bytes match another canonical is RE-POINTED at it, reusing that version")
    func aliasMatchingAnotherCanonicalRetargets() async throws {
        let rig = try await USF001Fixtures.makeRig()
        let bytesA = USF001Fixtures.bytes("canonical A")
        let bytesC = USF001Fixtures.bytes("canonical C — different")
        let aURL = try USF001Fixtures.writeFile(rig, name: "a.txt", bytes: bytesA)
        let cURL = try USF001Fixtures.writeFile(rig, name: "c.txt", bytes: bytesC)
        let a = try await USF001Fixtures.intake(rig, url: aURL)
        let c = try await USF001Fixtures.intake(rig, url: cURL, at: USF001Fixtures.t0.addingTimeInterval(1))
        // b.txt aliases A (same bytes as A).
        let bURL = try USF001Fixtures.writeFile(rig, name: "b.txt", bytes: bytesA)
        let alias = try await USF001Fixtures.intake(rig, url: bURL, at: USF001Fixtures.t0.addingTimeInterval(2))
        #expect(alias.outcome == .aliased)
        #expect(try await fileRow(rig, bURL).aliasOf == a.logicalSourceID)
        let versionsBefore = try await versionCount(rig)

        // b.txt now changes to C's bytes → retarget the alias at C, reuse C's version.
        _ = try USF001Fixtures.writeFile(rig, name: "b.txt", bytes: bytesC)
        let retarget = try await USF001Fixtures.intake(rig, url: bURL, at: USF001Fixtures.t0.addingTimeInterval(3))

        #expect(retarget.outcome == .aliased)
        #expect(retarget.sourceVersionID == c.sourceVersionID)          // reuses C's current version
        let after = try await fileRow(rig, bURL)
        #expect(after.aliasOf == c.logicalSourceID)                     // now points at C
        #expect(after.hash == sha256(bytesC))
        #expect(try await fileCount(rig, bURL) == 1)                    // no second row
        #expect(try await versionCount(rig) == versionsBefore)         // no new version created
    }

    @Test("Every alias transition keeps exactly one file row for the URL")
    func aliasTransitionNeverSecondFileRow() async throws {
        let rig = try await USF001Fixtures.makeRig()
        let bytesA = USF001Fixtures.bytes("A")
        _ = try await USF001Fixtures.intake(rig, url: try USF001Fixtures.writeFile(rig, name: "a.txt", bytes: bytesA))
        let bURL = try USF001Fixtures.writeFile(rig, name: "b.txt", bytes: bytesA)
        _ = try await USF001Fixtures.intake(rig, url: bURL, at: USF001Fixtures.t0.addingTimeInterval(1))    // alias
        _ = try USF001Fixtures.writeFile(rig, name: "b.txt", bytes: USF001Fixtures.bytes("changed once"))
        _ = try await USF001Fixtures.intake(rig, url: bURL, at: USF001Fixtures.t0.addingTimeInterval(2))    // promote
        _ = try USF001Fixtures.writeFile(rig, name: "b.txt", bytes: USF001Fixtures.bytes("changed twice"))
        _ = try await USF001Fixtures.intake(rig, url: bURL, at: USF001Fixtures.t0.addingTimeInterval(3))    // new version
        #expect(try await fileCount(rig, bURL) == 1)
    }

    @Test("An alias re-intaked with unchanged bytes still reuses the occurrence and version")
    func aliasUnchangedStillReuses() async throws {
        let rig = try await USF001Fixtures.makeRig()
        let bytesA = USF001Fixtures.bytes("stable A")
        _ = try await USF001Fixtures.intake(rig, url: try USF001Fixtures.writeFile(rig, name: "a.txt", bytes: bytesA))
        let bURL = try USF001Fixtures.writeFile(rig, name: "b.txt", bytes: bytesA)
        let first = try await USF001Fixtures.intake(rig, url: bURL, at: USF001Fixtures.t0.addingTimeInterval(1))
        let versions = try await versionCount(rig)
        let second = try await USF001Fixtures.intake(rig, url: bURL, at: USF001Fixtures.t0.addingTimeInterval(2))
        #expect(second.outcome == .aliased)
        #expect(second.occurrenceFileID == first.occurrenceFileID)
        #expect(second.sourceVersionID == first.sourceVersionID)
        #expect(try await versionCount(rig) == versions)
    }

    @Test("A retarget writes a receipt whose hash matches the reused version (composite FK holds)")
    func retargetReceiptHashPinned() async throws {
        let rig = try await USF001Fixtures.makeRig()
        let bytesA = USF001Fixtures.bytes("A-r")
        let bytesC = USF001Fixtures.bytes("C-r different")
        _ = try await USF001Fixtures.intake(rig, url: try USF001Fixtures.writeFile(rig, name: "a.txt", bytes: bytesA))
        let c = try await USF001Fixtures.intake(rig, url: try USF001Fixtures.writeFile(rig, name: "c.txt", bytes: bytesC), at: USF001Fixtures.t0.addingTimeInterval(1))
        let bURL = try USF001Fixtures.writeFile(rig, name: "b.txt", bytes: bytesA)
        _ = try await USF001Fixtures.intake(rig, url: bURL, at: USF001Fixtures.t0.addingTimeInterval(2))
        _ = try USF001Fixtures.writeFile(rig, name: "b.txt", bytes: bytesC)
        _ = try await USF001Fixtures.intake(rig, url: bURL, at: USF001Fixtures.t0.addingTimeInterval(3))
        // The most recent receipt for C's version carries C's hash.
        let receiptHash = try await rig.db.query("""
            SELECT content_hash FROM source_intake_receipts WHERE source_version_id = ? ORDER BY recorded_at DESC LIMIT 1;
            """, [.uuid(c.sourceVersionID)]).first?.string(0)
        #expect(receiptHash == sha256(bytesC))
    }

    // MARK: - Managed vault reuse (gap 4)

    @Test("A managed new version reverting to an already-vaulted hash reuses the stored address")
    func managedRevertReusesVaultAddress() async throws {
        let rig = try await USF001Fixtures.makeRig()
        let bytesA = USF001Fixtures.bytes("managed A original")
        let bytesB = USF001Fixtures.bytes("managed B updated")
        let url = try USF001Fixtures.writeFile(rig, name: "m.txt", bytes: bytesA)
        let v1 = try await USF001Fixtures.intake(rig, url: url, custody: .managed)
        #expect(v1.preservationStatus == .managedCopyStored)
        #expect(await rig.vault.contains(sha256(bytesA)))
        // change to B (new version, new managed copy)
        _ = try USF001Fixtures.writeFile(rig, name: "m.txt", bytes: bytesB)
        _ = try await USF001Fixtures.intake(rig, url: url, custody: .managed, at: USF001Fixtures.t0.addingTimeInterval(1))
        // revert to A — the bytes are ALREADY vaulted; this must still be managedCopyStored with A's address.
        _ = try USF001Fixtures.writeFile(rig, name: "m.txt", bytes: bytesA)
        let revert = try await USF001Fixtures.intake(rig, url: url, custody: .managed, at: USF001Fixtures.t0.addingTimeInterval(2))
        #expect(revert.outcome == .newVersion)
        #expect(revert.preservationStatus == .managedCopyStored)
        #expect(revert.vaultAddress == sha256(bytesA))               // reused the existing address, not null
        // The persisted version row is consistent (managedCopyStored REQUIRES a non-null vault address).
        let row = try #require(try await rig.db.query("""
            SELECT preservation_status, vault_address FROM source_versions WHERE id = ?;
            """, [.uuid(revert.sourceVersionID)]).first)
        #expect(row.string(0) == "managedCopyStored")
        #expect(row.string(1) == sha256(bytesA))
    }

    @Test("A managed copy with no vault stays managedCopyFailed with a null address")
    func managedNoVaultFailsVisibly() async throws {
        let rig = try await USF001Fixtures.makeRig(withVault: false)
        let url = try USF001Fixtures.writeFile(rig, name: "m.txt", bytes: USF001Fixtures.bytes("no vault"))
        let h = try await USF001Fixtures.intake(rig, url: url, custody: .managed)
        #expect(h.preservationStatus == .managedCopyFailed)
        #expect(h.vaultAddress == nil)
    }
}
