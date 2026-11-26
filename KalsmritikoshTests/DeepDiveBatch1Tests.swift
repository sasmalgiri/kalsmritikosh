//
//  DeepDiveBatch1Tests.swift
//  KalsmritikoshTests
//
//  Deep dive 2026-11-14 batch 1 (startup, concurrency, isolation) — one regression test per confirmed defect
//  (docs/SMART_MAP_DEFECT_LOG.md, "Deep dive 2026-11-14 batch 1"). No model, no network, no key: every provider here is
//  a spy or the Online provider over scripted seams. No calendar dates are computed (time-zone free).
//

import Foundation
import Testing
@testable import Kalsmritikosh

// MARK: - Helpers

/// A provider that counts its generations (it never answers anything real).
private nonisolated final class DD1SpyProvider: ModelProvider, @unchecked Sendable {
    let id: String
    let capabilities: Set<ModelCapability> = [.textGeneration, .reasoning]
    let manifest: ModelManifest
    private let lock = NSLock()
    private var calls = 0
    private let available: Bool

    init(privacy: PrivacyLevel, available: Bool = true) {
        let id = "provider.test.dd1.\(UUID().uuidString)"
        self.id = id
        self.available = available
        self.manifest = ModelManifest(id: id, displayName: "Spy", capabilities: [.textGeneration, .reasoning], privacyLevel: privacy)
    }

    var generations: Int { lock.withLock { calls } }
    func isAvailable() async -> Bool { available }
    func generate(prompt: String, options: GenerationOptions) async throws -> String {
        lock.withLock { calls += 1 }
        return "ok"
    }
    func embed(text: String) async throws -> [Float] { throw ModelProviderError.unavailable(providerID: id) }
}

private nonisolated final class DD1Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T?
    var value: T? { lock.withLock { _value } }
    func set(_ v: T) { lock.withLock { _value = v } }
}

private struct DD1Injected: Error {}

private func dd1Temp(_ tag: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dd1-\(tag)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func dd1Hardware() -> HardwareProfile {
    HardwareProfile(totalRAMBytes: 16 * 1_073_741_824, availableRAMBytes: 8 * 1_073_741_824,
                    processorCount: 8, isAppleSilicon: true, chipName: "DD1Chip-\(UUID().uuidString)", hasNeuralEngine: true)
}

private func dd1Count(_ db: Database, _ sql: String, _ binds: [SQLValue] = []) async throws -> Int {
    Int(try await db.query(sql, binds).first?.int(0) ?? -1)
}

/// The Online provider over scripted seams: `setUp` decides whether Online could send at all; its own status sink.
private func dd1Online(setUp: Bool, log: OutboundLogRepository?) async -> (OnlineCloudProvider, OnlineStatus) {
    let snapshot = OnlineSnapshot(cloudAllowed: setUp, kind: .anthropic, model: setUp ? "test-model" : "", apiKey: setUp ? "test-key" : nil,
                                  confirmedDocumentTerms: nil, dailyByteCap: nil)
    var seams = OnlineCloudProvider.Seams(settings: { snapshot }, consent: { _ in true },
                                          transport: { _ in throw OnlineCloudProvider.OnlineError.declined })
    let status = await MainActor.run { OnlineStatus() }
    seams.status = { status }
    return (OnlineCloudProvider(outboundLog: log, knownNames: { [] }, seams: seams), status)
}

@Suite("Deep dive 2026-11-14 batch 1 — startup, concurrency, isolation", .serialized)
struct DeepDiveBatch1Tests {

    // MARK: 1 — no generation at registration (the CI root cause)

    @Test("1: registering providers generates nothing; the explicit benchmark never measures a cloud, unavailable or Fully-private provider")
    func registrationGeneratesNothing() async throws {
        let hw = dd1Hardware()
        let bench = PerformanceBenchmark(hardwareProfile: hw)
        let registry = CapabilityRegistry(hardware: hw, benchmark: bench)
        let local = DD1SpyProvider(privacy: .onDevice)
        let cloud = DD1SpyProvider(privacy: .cloud)
        await registry.register(local)
        await registry.register(cloud)
        #expect(local.generations == 0 && cloud.generations == 0, "registration made a generative call")

        await bench.benchmark(cloud)
        #expect(cloud.generations == 0, "a cloud provider is never measured")
        let unavailable = DD1SpyProvider(privacy: .onDevice, available: false)
        await bench.benchmark(unavailable)
        #expect(unavailable.generations == 0, "an unavailable provider is never measured")
        await PrivacyGate.TestOverride.$offlineNoLLM.withValue(true) { await bench.benchmark(local) }
        #expect(local.generations == 0, "Fully private: nothing is generated")
        await PrivacyGate.TestOverride.$offlineNoLLM.withValue(false) { await bench.benchmark(local) }
        #expect(local.generations == 1, "an available on-device provider is still measured on request")
        #expect(await bench.result(for: local.id) != nil)
    }

    @Test("1: a fresh boot with a cold benchmark cache and AI off records nothing outbound and reports no Online failure")
    @MainActor
    func freshBootRecordsNothing() async throws {
        let dir = try dd1Temp("boot")
        defer { try? FileManager.default.removeItem(at: dir) }
        let clearanceRefusal = OnlineCloudProvider.OnlineError.documentsNotCleared.localizedDescription
        try await PrivacyGate.TestOverride.$offlineNoLLM.withValue(true) {
            let state = AppState(bookmarks: BookmarkStore(ephemeral: true))
            await state.boot(databaseURL: dir.appendingPathComponent("fresh.sqlite"), suppressAutoReingest: true)
            guard case .ready = state.phase, let db = state.database else { Issue.record("ledger did not boot"); return }
            let outbound = try await dd1Count(db, "SELECT COUNT(*) FROM outbound_log;")
            #expect(outbound == 0, "a phantom outbound row was written at boot")
            #expect(OnlineStatus.shared.lastFailure != OnlineFailure.scrubbed(clearanceRefusal), "the boot reported a refused cloud send")
            await state.shutdown()
        }
    }

    // MARK: 2 — "blocked" only for a send that could otherwise go

    @Test("2: Online not set up — every route refuses with notAvailable and writes no outbound row and no failure")
    func notSetUpRecordsNothing() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        let (provider, status) = await dd1Online(setUp: false, log: OutboundLogRepository(database: db))
        let cleared = CloudSourceClearance(clearedObjectIDs: [UUID()], deniedCount: 0, checkedAt: Date(), purpose: "test")
        let image = OutboundImage(mediaType: "image/jpeg", data: Data([0xFF, 0xD8, 0xFF]), label: "page 1")
        func isNotAvailable(_ op: () async throws -> String) async -> Bool {
            do { _ = try await op(); return false } catch let e as OnlineCloudProvider.OnlineError {
                if case .notAvailable = e { return true }
                return false
            } catch { return false }
        }
        let general = await isNotAvailable { try await provider.generate(prompt: "p", options: GenerationOptions(maxTokens: 8)) }
        let documents = await isNotAvailable { try await provider.generateFromDocuments(prompt: "p", options: GenerationOptions(maxTokens: 8, sourceClearance: cleared)) }
        let pages = await isNotAvailable { try await provider.readPageImages([image], fileName: "scan.pdf") }
        let recording = await isNotAvailable { try await provider.transcribeRecording(image, fileName: "call.m4a") }
        #expect(general && documents && pages && recording)
        #expect(try await dd1Count(db, "SELECT COUNT(*) FROM outbound_log;") == 0)
        #expect(await MainActor.run { status.lastFailure } == nil)
        await db.close()
    }

    @Test("2: Online set up — a send whose sources were not cleared is still refused, recorded as blocked, and reported")
    func setUpStillRecordsBlocked() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        let (provider, status) = await dd1Online(setUp: true, log: OutboundLogRepository(database: db))
        await #expect(throws: OnlineCloudProvider.OnlineError.self) {
            _ = try await provider.generate(prompt: "Passage …", options: GenerationOptions(maxTokens: 8))
        }
        #expect(try await dd1Count(db, "SELECT COUNT(*) FROM outbound_log WHERE outcome = 'blocked' AND detail LIKE '%sources not cleared%';") == 1)
        #expect(await MainActor.run { status.lastFailure } != nil)
        await db.close()
    }

    // MARK: 3 — task-local test overrides

    @Test("3: the Fully-private and connectivity overrides are per task tree: concurrent tasks see their own, the stored preference is untouched")
    func overridesArePerTask() async {
        let storedNoLLM = AppDefaults.store.object(forKey: "kalsmritikosh.privacy.offlineNoLLM") as? Bool
        let storedMode = ConnectivityMode.stored
        async let on: Bool = PrivacyGate.TestOverride.$offlineNoLLM.withValue(true) {
            try? await Task.sleep(nanoseconds: 20_000_000)
            return PrivacyGate.shared.offlineNoLLM
        }
        async let off: Bool = PrivacyGate.TestOverride.$offlineNoLLM.withValue(false) {
            try? await Task.sleep(nanoseconds: 20_000_000)
            return PrivacyGate.shared.offlineNoLLM || EvidenceOnlyRelease.enforced
        }
        let (a, b) = await (on, off)
        #expect(a == true)
        #expect(b == EvidenceOnlyRelease.enforced)
        let online = ConnectivityMode.TestOverride.$stored.withValue(.online) { ConnectivityMode.stored }
        let priv = ConnectivityMode.TestOverride.$stored.withValue(.privateMode) { ConnectivityMode.stored }
        #expect(online == .online && priv == .privateMode)
        #expect(AppDefaults.store.object(forKey: "kalsmritikosh.privacy.offlineNoLLM") as? Bool == storedNoLLM, "no test wrote the preference")
        #expect(ConnectivityMode.stored == storedMode)
    }

    @Test("3: the converted suites no longer write the process-wide argument domain or the stored connectivity choice")
    func convertedSuitesUseOverrides() throws {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for name in ["ProceedingAnswererTests", "ProceedingSharedNamePartTests", "SupportEnvelopeTests", "JobOutcomeMatrixTests",
                     "InvestigationCaseSimulationTests", "VerifiedAnswerWiringTests", "NamedDocumentFocusTests", "CaseBenchRunner"] {
            let text = try String(contentsOf: tests.appendingPathComponent(name + ".swift"), encoding: .utf8)
            #expect(!text.contains("\"kalsmritikosh.privacy.offlineNoLLM\""), "\(name) still puts the switch in the argument domain")
            #expect(text.contains("PrivacyGate.TestOverride.$offlineNoLLM.withValue"), "\(name)")
        }
        let base = try String(contentsOf: tests.appendingPathComponent("BaseCaseJourneyTests.swift"), encoding: .utf8)
        #expect(!base.contains("ConnectivityMode.set(") && base.contains("ConnectivityMode.TestOverride.$stored.withValue"))
    }

    // MARK: 4 — the Online status sink

    @Test("4: each provider reports its failures to its own status sink; another provider's failure does not overwrite it")
    func statusSinkIsPerProvider() async throws {
        let (a, statusA) = await dd1Online(setUp: true, log: nil)
        let (b, statusB) = await dd1Online(setUp: true, log: nil)
        await #expect(throws: OnlineCloudProvider.OnlineError.self) {
            _ = try await a.generate(prompt: "x", options: GenerationOptions(maxTokens: 8))
        }
        #expect(await MainActor.run { statusA.lastFailure } != nil)
        #expect(await MainActor.run { statusB.lastFailure } == nil)
        await #expect(throws: OnlineCloudProvider.OnlineError.self) {
            _ = try await b.readPageImages([OutboundImage(mediaType: "image/png", data: Data([1]), label: "page 1")], fileName: "x.pdf")
        }
        let aReason = await MainActor.run { statusA.lastFailure }
        let bReason = await MainActor.run { statusB.lastFailure }
        #expect(aReason != bReason, "B's failure did not overwrite A's")
    }

    // MARK: 5 — fresh resource values in the vault copy

    @Test("5: a file rewritten during the vault copy is detected (fresh resource values off the main thread)")
    func vaultSeesRewriteDuringCopy() async throws {
        let dir = try dd1Temp("vault")
        defer { try? FileManager.default.removeItem(at: dir) }
        let vault = EvidenceVault(root: dir.appendingPathComponent("vault", isDirectory: true))
        let url = dir.appendingPathComponent("statement.txt")
        try Data(repeating: 0x41, count: 1_000).write(to: url)
        _ = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])   // a caller read them first (cached)
        do {
            _ = try await vault.storeStreaming(contentsOf: url, availableCapacity: { _ in
                // Rewritten after the "before" snapshot and the handle opened.
                try? Data(repeating: 0x42, count: 5_000).write(to: url, options: .atomic)
                return Int64(1) << 40
            })
            Issue.record("a source rewritten during the copy was stored")
        } catch SourceIntakeError.sourceChangedDuringCapture {
            // expected
        }
    }

    @Test("5: the free-space check uses the file's current size, not a size cached earlier")
    func vaultSizesFromFreshValues() async throws {
        let dir = try dd1Temp("vaultsize")
        defer { try? FileManager.default.removeItem(at: dir) }
        let vault = EvidenceVault(root: dir.appendingPathComponent("vault", isDirectory: true))
        let url = dir.appendingPathComponent("ledger.csv")
        try Data(repeating: 0x41, count: 1_000).write(to: url)
        _ = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])   // cached at 1 000 bytes
        try Data(repeating: 0x42, count: 50_000).write(to: url, options: .atomic)
        // Room for the small file (2 × 1 000 + margin) but not the current one (2 × 50 000 + margin).
        let room = DiskSpaceCheck.safetyMargin + 3_000
        do {
            _ = try await vault.storeStreaming(contentsOf: url, availableCapacity: { _ in room })
            Issue.record("the copy was sized from a stale cached size")
        } catch SourceIntakeError.managedCopyFailed(let reason) {
            #expect(reason.contains("not enough free space"))
        }
    }

    // MARK: 6 — an AI effect never outlives its unrecorded proposal

    @Test("6: configured execution — the recheck fails after the effect is applied: the effect is withdrawn and the proposal stays proposed")
    @MainActor
    func executeCompensatesFailedMark() async throws {
        let r = try await S10Rig.make()
        try await r.setAI(CaseAIPolicy(mode: .execute, automaticEffects: [.structuralLink]))
        let reply = s10Reply(proposals: [["kind": "link", "type": "derivedFrom", "from": "doc:1", "to": "doc:2", "reason": "The statement pays invoice 77"]])
        r.script.reply = { _, _ in reply }
        let db = r.db
        // Between the effect's write and the "applied" write, every document gets a newer version (the recheck then refuses).
        let report = try await CaseAIAssistTestHook.$afterEffect.withValue({
            try await db.exec("UPDATE source_versions SET is_current = 0;", [])
        }) {
            try await r.ai.run(caseID: r.caseID, task: CaseAIAssistTask(kind: .links), actor: "Ada")
        }
        #expect(report.proposals.count == 1 && report.applied.isEmpty, "\(report)")
        let p = try await r.proposal(try #require(report.proposals.first))
        #expect(p.state == .proposed && p.appliedID == nil)
        #expect(try await s10Count(db, "SELECT COUNT(*) FROM case_map_links WHERE case_id = ? AND withdrawn_at IS NULL;", [.uuid(r.caseID)]) == 0,
                "the applied link stayed in the case")
        #expect(try await s10Count(db, "SELECT COUNT(*) FROM case_map_links WHERE case_id = ? AND withdrawn_at IS NOT NULL AND withdrawn_reason LIKE 'Withdrawn: the AI proposal%';",
                                   [.uuid(r.caseID)]) == 1, "the withdrawal is on the record")
    }

    @Test("6: accepting — recording the decision fails after the effect is applied: the effect is withdrawn and the proposal stays proposed")
    @MainActor
    func acceptCompensatesFailedDecision() async throws {
        let reply = s10Reply(proposals: [["kind": "link", "type": "derivedFrom", "from": "doc:1", "to": "doc:2", "reason": "The statement pays invoice 77"]])
        let r = try await S10Rig.make { _, _ in reply }
        let run = try await r.ai.run(caseID: r.caseID, task: CaseAIAssistTask(kind: .links), actor: "Ada")
        let id = try #require(run.proposals.first)
        await #expect(throws: DD1Injected.self) {
            try await CaseAIAssistTestHook.$afterEffect.withValue({ throw DD1Injected() }) {
                _ = try await r.ai.accept(caseID: r.caseID, proposalID: id, actor: "Ada")
            }
        }
        let p = try await r.proposal(id)
        #expect(p.state == .proposed)
        #expect(try await s10Count(r.db, "SELECT COUNT(*) FROM case_map_links WHERE case_id = ? AND withdrawn_at IS NULL;", [.uuid(r.caseID)]) == 0)
        // Accepting again (nothing failing now) applies it once.
        let accepted = try await r.ai.accept(caseID: r.caseID, proposalID: id, actor: "Ada")
        #expect(accepted.state == .accepted && accepted.appliedKind == "mapLink")
        #expect(try await s10Count(r.db, "SELECT COUNT(*) FROM case_map_links WHERE case_id = ? AND withdrawn_at IS NULL;", [.uuid(r.caseID)]) == 1)
    }

    // MARK: 7 — XML delegates off the main actor

    @Test("7: every XMLParserDelegate in the app is nonisolated, and the DOCX and XML parsers run off the main thread")
    func xmlDelegatesAreNonisolated() async throws {
        let root = SmartMapS9Tests.repoRoot.appendingPathComponent("Kalsmritikosh")
        var offenders: [String] = []
        if let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
            for case let url as URL in en where url.pathExtension == "swift" {
                let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                for line in text.components(separatedBy: "\n") where line.contains("XMLParserDelegate") && line.contains("class ") {
                    if !line.contains("nonisolated") { offenders.append(url.lastPathComponent + ": " + line.trimmingCharacters(in: .whitespaces)) }
                }
            }
        }
        #expect(offenders.isEmpty, "\(offenders)")

        let xml = Data("<root><item>Payment of 10,000</item><item>Invoice 77</item></root>".utf8)
        let parsedXML = try await Task.detached {
            #expect(!Thread.isMainThread)
            return try await StructuredTextStructuralParser().parse(data: xml, filename: "x.xml", type: .xml, logicalSourceID: UUID(), sourceVersionID: UUID())
        }.value
        #expect(parsedXML.blocks.contains { $0.normalizedText.contains("Invoice 77") })

        var z = ZIPArchiveWriter()
        z.addFile(path: "[Content_Types].xml", text: #"<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"/>"#)
        z.addFile(path: "word/document.xml", text: """
            <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>\
            <w:p><w:r><w:t>Transfer to Dalmia Traders</w:t></w:r></w:p></w:body></w:document>
            """)
        let docx = z.build()
        let parsedDocx = try await Task.detached {
            try await DocxStructuralParser().parse(data: docx, filename: "x.docx", type: .docx, logicalSourceID: UUID(), sourceVersionID: UUID())
        }.value
        #expect(parsedDocx.blocks.contains { $0.normalizedText.contains("Dalmia Traders") })
    }

    // MARK: 8 — a failed boot can be retried and leaves one ledger open

    @Test("8: a boot failing after the ledger opened closes and clears it; retrying opens exactly one new ledger")
    @MainActor
    func failedBootClosesAndRetries() async throws {
        let dir = try dd1Temp("bootfail")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("retry.sqlite")
        let state = AppState(bookmarks: BookmarkStore(ephemeral: true))
        let opened = DD1Box<Database>()
        await AppStateBootTestHook.$failAfterOpen.withValue({ db in opened.set(db); throw DD1Injected() }) {
            await state.boot(databaseURL: url, suppressAutoReingest: true)
        }
        guard case .failed = state.phase else { Issue.record("the injected failure did not fail the boot: \(state.phase)"); return }
        #expect(state.database == nil, "the failed boot left its ledger in the app state")
        #expect(state.ingest == nil)
        let first = try #require(opened.value)
        await #expect(throws: (any Error).self) { _ = try await first.query("SELECT 1;", []) }   // closed

        await state.boot(databaseURL: url, suppressAutoReingest: true)
        guard case .ready = state.phase else { Issue.record("the retry did not boot"); return }
        let second = try #require(state.database)
        #expect(second !== first)
        #expect(state.bootRunCount == 2)
        await state.shutdown()
    }

    @Test("8: a launch that failed is cleared, so Try again (and a later window) runs it again; a running launch is not re-run")
    @MainActor
    func failedLaunchCanBeRetried() async throws {
        let dir = try dd1Temp("launch")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("launch.sqlite")
        let state = AppState(bookmarks: BookmarkStore(ephemeral: true))
        var attempts = 0
        let startup: @MainActor () async -> Void = {
            attempts += 1
            if attempts == 1 {
                await AppStateBootTestHook.$failAfterOpen.withValue({ _ in throw DD1Injected() }) {
                    await state.boot(databaseURL: url, suppressAutoReingest: true)
                }
            } else {
                await state.boot(databaseURL: url, suppressAutoReingest: true)
            }
        }
        await state.startOnce(startup)
        guard case .failed = state.phase else { Issue.record("the first launch did not fail"); return }
        await state.retryStartup()
        #expect(attempts == 2)
        guard case .ready = state.phase else { Issue.record("Try again did not start the app"); return }
        await state.retryStartup()       // not failed now: nothing runs
        await state.startOnce(startup)   // a later window attaches
        #expect(attempts == 2)
        await state.shutdown()
    }

    @Test("8: a concurrent boot asking for a different ledger is refused; only one ledger is opened")
    @MainActor
    func concurrentBootOfAnotherLedgerIsRefused() async throws {
        let dir = try dd1Temp("bootdiff")
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.sqlite"), b = dir.appendingPathComponent("b.sqlite")
        let state = AppState(bookmarks: BookmarkStore(ephemeral: true))
        async let first: Void = state.boot(databaseURL: a, suppressAutoReingest: true)
        async let second: Void = state.boot(databaseURL: b, suppressAutoReingest: true)
        _ = await (first, second)
        #expect(state.bootRunCount == 1)
        guard case .ready = state.phase, let db = state.database else { Issue.record("no ledger booted"); return }
        let openedPath = await db.url.standardizedFileURL.path
        let other = openedPath == a.standardizedFileURL.path ? b : a
        #expect(!FileManager.default.fileExists(atPath: other.path), "a second ledger was created")
        await state.shutdown()
    }

    // MARK: 9 — scratch space reserved across parallel parses

    @Test("9: two concurrent scratch reservations that together exceed the free space — one is refused; released space is reusable")
    func scratchReservationsShareTheDisk() async throws {
        let pool = DiskSpaceCheck.ScratchPool()
        let free = DiskSpaceCheck.safetyMargin + 1_000
        try await DiskSpaceCheck.$scratchCapacityOverride.withValue(free) {
            let results = await withTaskGroup(of: DiskSpaceCheck.ScratchReservation?.self) { group -> [DiskSpaceCheck.ScratchReservation?] in
                for _ in 0..<2 {
                    group.addTask { try? DiskSpaceCheck.reserveScratch(600, for: "a file being read", pool: pool) }
                }
                var out: [DiskSpaceCheck.ScratchReservation?] = []
                for await r in group { out.append(r) }
                return out
            }
            let granted = results.compactMap { $0 }
            #expect(granted.count == 1, "both copies were allowed onto a disk that holds one")
            #expect(pool.reserved == 600)
            // The check alone (requireScratch) also counts the copy in progress.
            #expect(throws: DiskSpaceCheck.ScratchRefusal.self) { try DiskSpaceCheck.requireScratch(600, for: "a file being read", pool: pool) }
            granted.forEach { $0.release() }
            #expect(pool.reserved == 0)
            let again = try DiskSpaceCheck.reserveScratch(600, for: "a file being read", pool: pool)
            #expect(pool.reserved == 600)
            again.release()
            again.release()   // once only
            #expect(pool.reserved == 0)
        }
    }
}
