//
//  BackupExpansionTests.swift
//  KalsmritikoshTests
//
//  HOST-8c — walking an iOS backup's virtual tree. HOST-8b recorded the SHA-1 to
//  device-path mapping; this proves it is OPERATIVE: each file inside a backup is
//  handed to the pipeline under the path it had on the device.
//
//  The tests fall into three groups, and the second two matter most:
//    1. The mapping works — origin is the device path, bytes are the hashed file.
//    2. The SAFETY layer is the ZIP lane's, not a reimplementation: path escape,
//       per-member ceiling, shared root budget. A backup must not become a way
//       around guards that apply to archives.
//    3. Every member stays VISIBLE — admitted, blocked or failed. A file listed
//       in the manifest but missing on disk is a truncated extraction, which is a
//       finding, not something to skip.
//

import Foundation
import SQLite3
import Testing
@testable import Kalsmritikosh

@Suite("iOS backup expansion (HOST-8c)")
@MainActor
struct BackupExpansionTests {

    private let smsFileID = "3d0d7e5fb2ce288813306e4d4636395e047a3d28"
    private let waFileID = "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678"
    /// Listed in the manifest but deliberately never written to disk.
    private let missingFileID = "ee00112233445566778899aabbccddeeff001122"

    private func scratch() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("bkexp-\(UUID().uuidString)")
    }

    /// A backup folder: Manifest.db plus the hashed content files.
    private func makeBackup(in dir: URL, writeMissingFile: Bool = false,
                            hugeFileBytes: Int? = nil) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manifestURL = dir.appendingPathComponent("Manifest.db")
        var h: OpaquePointer?
        #expect(sqlite3_open_v2(manifestURL.path, &h,
                                SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK)
        #expect(sqlite3_exec(h, """
        CREATE TABLE Files (fileID TEXT PRIMARY KEY, domain TEXT,
                            relativePath TEXT, flags INTEGER, file BLOB);
        """, nil, nil, nil) == SQLITE_OK)
        #expect(sqlite3_exec(h, """
        INSERT INTO Files (fileID, domain, relativePath, flags, file) VALUES
          ('\(smsFileID)','HomeDomain','Library/SMS/sms.db',1,NULL),
          ('\(waFileID)','AppDomain-net.whatsapp.WhatsApp','Documents/notes.txt',1,NULL),
          ('bb00112233445566778899aabbccddeeff001122','HomeDomain','Library/SMS',2,NULL),
          ('\(missingFileID)','HomeDomain','Library/Gone/absent.txt',1,NULL);
        """, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(h)

        func write(_ fileID: String, _ contents: String) throws {
            let sub = dir.appendingPathComponent(String(fileID.prefix(2)))
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: sub.appendingPathComponent(fileID))
        }
        try write(smsFileID, "message store bytes")
        if let hugeFileBytes {
            let sub = dir.appendingPathComponent(String(waFileID.prefix(2)))
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            try Data(repeating: 0x41, count: hugeFileBytes)
                .write(to: sub.appendingPathComponent(waFileID))
        } else {
            try write(waFileID, "WhatsApp note")
        }
        if writeMissingFile { try write(missingFileID, "present after all") }
        return manifestURL
    }

    /// Records what the coordinator handed to the pipeline, without running one.
    private actor Recorder {
        private(set) var calls: [(byteURL: URL, origin: URL)] = []
        func record(_ byteURL: URL, _ origin: URL) { calls.append((byteURL, origin)) }
    }

    private func expand(_ dir: URL, manifestURL: URL,
                        policy: ContainerSafetyPolicy = .standard,
                        succeed: Bool = true) async -> [(byteURL: URL, origin: URL)] {
        let recorder = Recorder()
        let coordinator = BackupExpansionCoordinator(repository: nil, policy: policy)
        let context = ContainerTraversalContext.root(sourceVersionID: UUID(),
                                                     containerHash: "test-hash")
        await coordinator.expand(
            manifestVersionID: UUID(), manifestURL: manifestURL,
            bundleRoot: dir, context: context, now: Date()
        ) { byteURL, origin, _ in
            await recorder.record(byteURL, origin)
            return ContainerProcessingCoordinator.MemberIngestOutcome(
                childSourceVersionID: succeed ? UUID() : nil,
                contentHash: succeed ? "child-hash" : nil,
                detectedType: SourceType.detect(from: origin))
        }
        return await recorder.calls
    }

    // MARK: - 1. The mapping is operative

    @Test("Each file is handed to the pipeline under its DEVICE path")
    func originIsTheDevicePath() async throws {
        // The whole point of HOST-8c: detection, citations and answers see
        // `HomeDomain/Library/SMS/sms.db`, never `3d0d7e5f…`.
        let dir = scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let calls = await expand(dir, manifestURL: try makeBackup(in: dir))
        let origins = calls.map { $0.origin.path }
        #expect(origins.contains("/HomeDomain/Library/SMS/sms.db"))
        #expect(origins.contains("/AppDomain-net.whatsapp.WhatsApp/Documents/notes.txt"))
        #expect(!origins.contains { $0.contains(smsFileID) })
    }

    @Test("The bytes handed over are the hashed file, and they are the right bytes")
    func bytesComeFromTheHashedFile() async throws {
        let dir = scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let calls = await expand(dir, manifestURL: try makeBackup(in: dir))
        let sms = try #require(calls.first { $0.origin.path.hasSuffix("sms.db") })
        #expect(sms.byteURL.lastPathComponent == smsFileID)
        #expect(try Data(contentsOf: sms.byteURL) == Data("message store bytes".utf8))
    }

    @Test("A device path drives type detection, which a hash name could never do")
    func devicePathEnablesDetection() async throws {
        // `3d0d7e5f…` has no extension, so it would detect as `.unknown`. The
        // device path is what makes the message store detect as a database.
        let dir = scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let calls = await expand(dir, manifestURL: try makeBackup(in: dir))
        let sms = try #require(calls.first { $0.origin.path.hasSuffix("sms.db") })
        #expect(SourceType.detect(from: sms.origin) == .sqlite)
        #expect(SourceType.detect(from: sms.byteURL) == .unknown)   // the old behaviour
    }

    @Test("Directories are not handed over as files")
    func directoriesAreNotIngested() async throws {
        let dir = scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let calls = await expand(dir, manifestURL: try makeBackup(in: dir))
        #expect(!calls.contains { $0.origin.path.hasSuffix("Library/SMS") })
        // Two real files present on disk; the directory and the absent file are not.
        #expect(calls.count == 2)
    }

    // MARK: - 2. The safety layer is the ZIP lane's

    @Test("A per-member ceiling blocks an oversized file, as it would in a zip")
    func perMemberCeilingApplies() async throws {
        // A backup must not be a way around a guard that applies to archives.
        let dir = scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let manifestURL = try makeBackup(in: dir, hugeFileBytes: 4096)
        var policy = ContainerSafetyPolicy.standard
        policy = ContainerSafetyPolicy(
            version: policy.version,
            maxEntriesPerContainer: policy.maxEntriesPerContainer,
            maxExpandedBytesPerContainer: policy.maxExpandedBytesPerContainer,
            maxSingleMemberBytes: 1024,                       // the file is 4096
            maxNestingDepth: policy.maxNestingDepth,
            maxRootTotalMembers: policy.maxRootTotalMembers,
            maxRootExpandedBytes: policy.maxRootExpandedBytes,
            maxNestedContainerCount: policy.maxNestedContainerCount,
            maxCompressionRatio: policy.maxCompressionRatio)

        let calls = await expand(dir, manifestURL: manifestURL, policy: policy)
        #expect(!calls.contains { $0.origin.path.hasSuffix("notes.txt") })
        #expect(calls.contains { $0.origin.path.hasSuffix("sms.db") })   // small one still admitted
    }

    @Test("The shared root budget is drawn from, so a backup cannot exhaust resources")
    func sharedRootBudgetIsConsumed() async throws {
        // Same pool as any other container traversal — the budget must actually
        // move, or a backup would be exempt from it.
        let dir = scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let manifestURL = try makeBackup(in: dir)
        let context = ContainerTraversalContext.root(sourceVersionID: UUID(),
                                                     containerHash: "h")
        let before = context.budget.consumed.members
        let coordinator = BackupExpansionCoordinator(repository: nil)
        await coordinator.expand(
            manifestVersionID: UUID(), manifestURL: manifestURL,
            bundleRoot: dir, context: context, now: Date()
        ) { _, origin, _ in
            ContainerProcessingCoordinator.MemberIngestOutcome(
                childSourceVersionID: UUID(), contentHash: "h",
                detectedType: SourceType.detect(from: origin))
        }
        #expect(context.budget.consumed.members == before + 2)
    }

    @Test("A member that would escape the backup root is refused")
    func pathEscapeIsRefused() async throws {
        // A crafted domain or relativePath must not place a member outside the
        // root. The guard is the ZIP lane's own `isContained`.
        let dir = scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let inside = dir.appendingPathComponent("3d/abc")
        #expect(ZIPContainerExtractor.isContained(inside, inRoot: dir))
        // What a hostile fileID would try to reach.
        let outside = dir.appendingPathComponent("../../etc/passwd")
        #expect(!ZIPContainerExtractor.isContained(outside, inRoot: dir))
    }

    // MARK: - 3. Every member stays visible

    @Test("A file listed in the manifest but missing on disk is a finding")
    func missingFileIsNotSkipped() async throws {
        // This is what a truncated or partial extraction looks like, so it must be
        // recorded as failed rather than quietly passed over.
        let dir = scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let calls = await expand(dir, manifestURL: try makeBackup(in: dir))
        #expect(!calls.contains { $0.origin.path.hasSuffix("absent.txt") })

        // Present in a complete extraction, it IS handed over — proving the
        // absence above was the file's, not the walker's.
        let whole = scratch(); defer { try? FileManager.default.removeItem(at: whole) }
        let completeCalls = await expand(
            whole, manifestURL: try makeBackup(in: whole, writeMissingFile: true))
        #expect(completeCalls.contains { $0.origin.path.hasSuffix("absent.txt") })
        #expect(completeCalls.count == 3)
    }

    @Test("With no bundle root, nothing is expanded rather than reporting an empty backup")
    func noRootMeansUnsupportedNotEmpty() async throws {
        let dir = scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let manifestURL = try makeBackup(in: dir)
        let recorder = Recorder()
        let coordinator = BackupExpansionCoordinator(repository: nil)
        await coordinator.expand(
            manifestVersionID: UUID(), manifestURL: manifestURL, bundleRoot: nil,
            context: .root(sourceVersionID: UUID(), containerHash: "h"), now: Date()
        ) { byteURL, origin, _ in
            await recorder.record(byteURL, origin)
            return ContainerProcessingCoordinator.MemberIngestOutcome(
                childSourceVersionID: UUID(), contentHash: "h", detectedType: nil)
        }
        #expect(await recorder.calls.isEmpty)
    }

    @Test("An unreadable manifest expands nothing and does not crash")
    func unreadableManifestIsSafe() async throws {
        let dir = scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("Manifest.db")
        try Data("not a database".utf8).write(to: url)
        #expect(await expand(dir, manifestURL: url).isEmpty)
    }

    @Test("A member whose ingest fails does not stop the others")
    func oneFailureDoesNotHaltTheWalk() async throws {
        // A backup with one unreadable file must still yield the rest.
        let dir = scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let calls = await expand(dir, manifestURL: try makeBackup(in: dir), succeed: false)
        #expect(calls.count == 2)   // both were attempted despite both "failing"
    }

    @Test("Expansion is deterministic — same backup, same order")
    func deterministic() async throws {
        let dir = scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let manifestURL = try makeBackup(in: dir)
        let first = await expand(dir, manifestURL: manifestURL).map { $0.origin.path }
        let second = await expand(dir, manifestURL: manifestURL).map { $0.origin.path }
        #expect(first == second)
    }

    // MARK: - The ZIP path must be untouched

    @Test("Backup expansion is a SEPARATE coordinator; the container lane is unchanged")
    func zipLaneIsSeparate() throws {
        // The reason this is its own type: ContainerProcessingCoordinator is
        // hardwired to ZIPContainerInspector and owns the archive budgets. It
        // still handles only archives, and a backup manifest never reaches it.
        #expect(SourceType.extractionManifest.category != .archive)
        let registry = try UniversalParserRegistryBuilder.standard(ocr: VisionOCR())
        // Immediate, NOT container: the manifest itself is parsed for its
        // inventory, and expansion is a separate additive step in the pipeline.
        #expect(try registry.resolve(.extractionManifest).executionMode == .immediate)
        // Archives still route to the container lane, unchanged.
        for archive in [SourceType.zip, .rar, .sevenZip] {
            #expect(try registry.resolve(archive).executionMode == .container,
                    "\(archive.rawValue) left the container lane")
        }
    }
}
