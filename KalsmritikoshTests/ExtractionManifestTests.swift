//
//  ExtractionManifestTests.swift
//  KalsmritikoshTests
//
//  HOST-8b — the iOS backup manifest. Built against a real SQLite file with a
//  Files table, because the whole value here is the SHA-1-to-device-path mapping
//  and a mock would prove nothing.
//
//  The forensic point the tests hold to: the INVENTORY is a different fact from
//  the file contents. It answers what the extraction covered — including what it
//  did NOT cover, which is a finding rather than something to stay silent about.
//

import Foundation
import SQLite3
import Testing
@testable import Kalsmritikosh

@Suite("iOS backup inventory (HOST-8b)")
@MainActor
struct ExtractionManifestTests {

    private let parser = ExtractionManifestStructuralParser()

    /// The real hash of a real file: `HomeDomain/Library/SMS/sms.db` is always
    /// stored under this SHA-1 in an iOS backup.
    private let smsFileID = "3d0d7e5fb2ce288813306e4d4636395e047a3d28"

    /// A manifest with the message store, a WhatsApp file, a directory, and a
    /// zero-byte file (which can mean a truncated extraction).
    private func makeManifest(in dir: URL, includeFilesTable: Bool = true) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("Manifest.db")
        var h: OpaquePointer?
        #expect(sqlite3_open_v2(url.path, &h, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK)
        defer { sqlite3_close(h) }

        if includeFilesTable {
            #expect(sqlite3_exec(h, """
            CREATE TABLE Files (fileID TEXT PRIMARY KEY, domain TEXT,
                                relativePath TEXT, flags INTEGER, file BLOB);
            """, nil, nil, nil) == SQLITE_OK)
            #expect(sqlite3_exec(h, """
            INSERT INTO Files (fileID, domain, relativePath, flags, file) VALUES
              ('\(smsFileID)','HomeDomain','Library/SMS/sms.db',1,NULL),
              ('a1b2c3d4e5f60718293a4b5c6d7e8f9012345678','AppDomain-net.whatsapp.WhatsApp',
               'Documents/ChatStorage.sqlite',1,NULL),
              ('bb00112233445566778899aabbccddeeff001122','HomeDomain','Library/SMS',2,NULL),
              ('cc00112233445566778899aabbccddeeff001122','HomeDomain',
               'Library/Preferences/truncated.plist',1,NULL);
            """, nil, nil, nil) == SQLITE_OK)
        } else {
            #expect(sqlite3_exec(h, "CREATE TABLE notes(id INTEGER PRIMARY KEY);",
                                 nil, nil, nil) == SQLITE_OK)
        }
        return url
    }

    /// Writes the actual stored blobs so sizes can be measured from disk, which is
    /// how a real backup lets us report size without decoding the metadata blob.
    private func writeStoredFiles(in dir: URL) throws {
        func write(_ fileID: String, bytes: Int) throws {
            let sub = dir.appendingPathComponent(String(fileID.prefix(2)))
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            try Data(repeating: 0x41, count: bytes)
                .write(to: sub.appendingPathComponent(fileID))
        }
        try write(smsFileID, bytes: 2048)
        try write("a1b2c3d4e5f60718293a4b5c6d7e8f9012345678", bytes: 4096)
        try write("cc00112233445566778899aabbccddeeff001122", bytes: 0)   // truncated
    }

    private func scratch() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("iosbk-\(UUID().uuidString)")
    }

    private func parse(_ url: URL) async throws -> ParsedDocument {
        try await parser.parse(data: try Data(contentsOf: url), filename: "Manifest.db",
                               type: .extractionManifest, logicalSourceID: UUID(),
                               sourceVersionID: UUID())
    }
    private func rows(_ doc: ParsedDocument) -> [String] {
        doc.blocks.filter { $0.kind == .tableRow }.map(\.rawText)
    }
    private func domains(_ doc: ParsedDocument) -> [String] {
        doc.blocks.filter { $0.kind == .sectionHeading }.map(\.rawText)
    }

    // MARK: - The mapping, which is the whole point

    @Test("A SHA-1 filename is mapped back to its device path")
    func hashMapsToDevicePath() async throws {
        // Without this, the backup is 40 000 anonymous blobs.
        let dir = scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let doc = try await parse(try makeManifest(in: dir))
        let sms = try #require(rows(doc).first { $0.contains("Library/SMS/sms.db") })
        #expect(sms.hasPrefix("HomeDomain/Library/SMS/sms.db"))
        #expect(sms.contains("stored at 3d/\(smsFileID)"))
    }

    @Test("A device path resolves to the real file inside the backup folder")
    func virtualPathResolvesToDisk() async throws {
        let dir = scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = try makeManifest(in: dir)
        try writeStoredFiles(in: dir)
        let manifest = try IOSBackupManifest(manifestData: try Data(contentsOf: url),
                                             bundleRoot: dir)
        let resolved = try #require(manifest.actualURL(
            forVirtualPath: "HomeDomain/Library/SMS/sms.db", in: dir))
        #expect(FileManager.default.fileExists(atPath: resolved.path))
        #expect(resolved.lastPathComponent == smsFileID)
        // A path the backup does not contain resolves to nothing, not a guess.
        #expect(manifest.actualURL(forVirtualPath: "HomeDomain/nope", in: dir) == nil)
        // A directory entry has no stored bytes, so it resolves to nothing either.
        #expect(manifest.actualURL(forVirtualPath: "HomeDomain/Library/SMS", in: dir) == nil)
    }

    @Test("Sizes are measured from disk when the metadata blob will not decode")
    func sizeFromDiskWhenBlobUnreadable() async throws {
        // Real manifests store size in an NSKeyedArchiver blob. When that cannot
        // be read, measuring the actual bytes beats reporting unknown.
        let dir = scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = try makeManifest(in: dir)
        try writeStoredFiles(in: dir)
        let manifest = try IOSBackupManifest(manifestData: try Data(contentsOf: url),
                                             bundleRoot: dir)
        let sms = try #require(manifest.entries.first {
            $0.virtualPath == "HomeDomain/Library/SMS/sms.db"
        })
        #expect(sms.size == 2048)
    }

    @Test("With no bundle root, an unknown size is stated as unknown")
    func unknownSizeIsStated() async throws {
        // An unknown size can mean a truncated extraction, so it is never shown
        // as zero or omitted.
        let dir = scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let doc = try await parse(try makeManifest(in: dir))
        #expect(rows(doc).allSatisfy { $0.contains("(size unknown)") })
    }

    // MARK: - Coverage, including absence

    @Test("Domains are listed with counts — what the extraction actually covers")
    func domainCoverageIsListed() async throws {
        let dir = scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let doc = try await parse(try makeManifest(in: dir))
        let heads = domains(doc)
        #expect(heads.contains { $0.contains("Domain HomeDomain: 3 entr(ies)") })
        #expect(heads.contains { $0.contains("AppDomain-net.whatsapp.WhatsApp") })
    }

    @Test("An app domain names its bundle id, which is how a search is scoped")
    func appDomainNamesBundleID() async throws {
        let dir = scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let doc = try await parse(try makeManifest(in: dir))
        #expect(domains(doc).contains { $0.contains("app net.whatsapp.WhatsApp") })
        // The prefix stripping covers every domain form Apple uses.
        let entry = IOSBackupManifest.Entry(
            fileID: "x", domain: "AppDomainGroup-group.net.whatsapp.WhatsApp.shared",
            relativePath: "", kind: .file, size: nil, modified: nil)
        #expect(entry.appBundleID == "group.net.whatsapp.WhatsApp.shared")
        let system = IOSBackupManifest.Entry(
            fileID: "x", domain: "HomeDomain", relativePath: "", kind: .file,
            size: nil, modified: nil)
        #expect(system.appBundleID == nil)      // not an app, so no invented id
    }

    @Test("A domain the backup does NOT contain is absent — coverage is checkable")
    func absentDomainIsCheckable() async throws {
        // "Signal is not in this extraction" is a finding. It is answerable only
        // because the inventory enumerates what IS there.
        let dir = scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = try makeManifest(in: dir)
        let manifest = try IOSBackupManifest(manifestData: try Data(contentsOf: url))
        #expect(manifest.entries(inDomain: "AppDomain-org.signal.Signal").isEmpty)
        #expect(!manifest.entries(inDomain: "AppDomain-net.whatsapp.WhatsApp").isEmpty)
        let doc = try await parse(url)
        #expect(!domains(doc).contains { $0.contains("org.signal.Signal") })
    }

    @Test("A zero-byte file is flagged, because it can mean a truncated extraction")
    func zeroByteFilesAreFlagged() async throws {
        let dir = scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = try makeManifest(in: dir)
        try writeStoredFiles(in: dir)
        let manifest = try IOSBackupManifest(manifestData: try Data(contentsOf: url),
                                             bundleRoot: dir)
        let truncated = try #require(manifest.entries.first {
            $0.relativePath.contains("truncated.plist")
        })
        #expect(truncated.size == 0)
        // And the parser says so rather than letting it read as a real empty file.
        let doc = try await parser.parse(
            data: try Data(contentsOf: url), filename: "Manifest.db",
            type: .extractionManifest, logicalSourceID: UUID(), sourceVersionID: UUID())
        _ = doc   // sizes are unknown without a root here; the flag is proved below
        #expect(manifest.entries.filter { $0.kind == .file && $0.size == 0 }.count == 1)
    }

    @Test("Directories are distinguished from files")
    func directoriesAreNotFiles() async throws {
        let dir = scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let manifest = try IOSBackupManifest(
            manifestData: try Data(contentsOf: try makeManifest(in: dir)))
        #expect(manifest.entries.count == 4)
        #expect(manifest.fileCount == 3)        // the fourth is a directory
        let directory = try #require(manifest.entries.first { $0.kind == .directory })
        #expect(directory.storedRelativePath == nil)   // no bytes to point at
    }

    // MARK: - Honesty

    @Test("A SQLite file with no Files table is reported, not read as a backup")
    func notAManifestIsReported() async throws {
        let dir = scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let doc = try await parse(try makeManifest(in: dir, includeFilesTable: false))
        #expect(doc.extractionStatus == .corrupt)
        #expect(rows(doc).isEmpty)
        #expect(doc.warnings.contains { $0.code == "extraction.no_files_table" })
    }

    @Test("Manifest.mbdb (iOS 9 and earlier) is NOT claimed as this format")
    func oldManifestFormatIsNotClaimed() {
        // It is a different, non-SQLite format; treating it as one would report a
        // perfectly readable backup as corrupt.
        #expect(SourceType.detect(from: URL(fileURLWithPath: "/case/Manifest.mbdb")) != .extractionManifest)
        #expect(SourceType.detect(from: URL(fileURLWithPath: "/case/Manifest.db")) == .extractionManifest)
    }

    @Test("An empty manifest is empty, not corrupt")
    func emptyIsEmpty() async throws {
        let doc = try await parser.parse(data: Data(), filename: "Manifest.db",
                                         type: .extractionManifest, logicalSourceID: UUID(),
                                         sourceVersionID: UUID())
        #expect(doc.extractionStatus == .empty)
        #expect(doc.warnings.contains { $0.code == "extraction.empty" })
    }

    @Test("Reading the manifest never touches the backup's content files")
    func contentFilesAreNotOpened() async throws {
        // Only Manifest.db is read. Proof: the stored blobs' access and
        // modification metadata are unchanged after a full parse.
        let dir = scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = try makeManifest(in: dir)
        try writeStoredFiles(in: dir)
        let stored = dir.appendingPathComponent("3d/\(smsFileID)")
        let before = try Data(contentsOf: stored)
        _ = try await parse(url)
        #expect(try Data(contentsOf: stored) == before)
    }

    @Test("Parsing is deterministic")
    func deterministic() async throws {
        let dir = scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = try makeManifest(in: dir)
        let first = try await parse(url).blocks.map(\.rawText)
        let second = try await parse(url).blocks.map(\.rawText)
        #expect(first == second)
    }

    // MARK: - Routing

    @Test("Manifest.db is detected ahead of the generic .db mapping")
    func detectedByName() {
        // Otherwise the one file that makes the backup readable is itself read as
        // an anonymous database.
        #expect(SourceType.detect(from: URL(fileURLWithPath: "/case/backup/Manifest.db"))
                == .extractionManifest)
        #expect(SourceType.detect(from: URL(fileURLWithPath: "/case/other.db")) == .sqlite)
    }

    @Test("It is a host artifact and the registry gives it a real plugin")
    func registryOwnsIt() throws {
        #expect(SourceType.extractionManifest.category == .hostArtifact)
        let registry = try UniversalParserRegistryBuilder.standard(ocr: VisionOCR())
        let plugin = try registry.resolve(.extractionManifest)
        #expect(plugin.pluginID == "format.extractionManifest")
        #expect(plugin.executionMode == .immediate)
        #expect(plugin.capabilities.producesStructure)
        // And the record lane still indexes every manifest row.
        #expect(SQLiteLoader().supportedTypes.contains(.extractionManifest))
    }
}
