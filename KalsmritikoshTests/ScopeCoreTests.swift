//
//  ScopeCoreTests.swift
//  KalsmritikoshTests
//
//  Package S — the 2026-11-06 scope decision (docs/IME_Core_and_Add_On_Scope_2026-11-06.md):
//   * the capability inventory (docs/CAPABILITY_INVENTORY.json) is generated from the module specs and
//     cannot drift; every disposition matches the decision table; every claimed verification level has
//     its test evidence;
//   * no accidental core dependency: with every optional pack off, intake, search, opening a source,
//     export, saved searches, holds, backup and erasure still work (service level, in the test host);
//   * a prior install keeps its choices and never gains a privacy-sensitive connection;
//   * retired surfaces are off the beginner path, but their routes still resolve;
//   * the reworded surfaces (source counts, review priority, document-date filter, evidence canvas)
//     never say what the decision forbids.
//  Deterministic; no network.
//

import Foundation
import Testing
@testable import Kalsmritikosh

private let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

@Suite("S — capability inventory drift")
struct ScopeInventoryDriftTests {

    @Test func committedInventoryMatchesTheCode() throws {
        let rendered = CapabilityInventoryDocument.render()
        #expect(!rendered.isEmpty)
        Attachment.record(rendered, named: "CAPABILITY_INVENTORY.json")
        let committed = (try? String(contentsOf: repoRoot.appendingPathComponent("docs/CAPABILITY_INVENTORY.json"), encoding: .utf8)) ?? ""
        if committed != rendered { print("===SCOPE_DOC_BEGIN docs/CAPABILITY_INVENTORY.json===\n" + rendered + "===SCOPE_DOC_END===") }
        #expect(committed == rendered, "docs/CAPABILITY_INVENTORY.json is stale — regenerate it from CapabilityInventoryDocument.render()")
    }

    /// The decision table in the scope document is the source; the code must say the same for every module.
    @Test func dispositionsMatchTheDecisionTable() throws {
        let doc = try String(contentsOf: repoRoot.appendingPathComponent(CapabilityInventoryDocument.sourceDecision), encoding: .utf8)
        var table: [String: String] = [:]
        for line in doc.split(separator: "\n") where line.hasPrefix("| ") {
            let cells = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            guard cells.count >= 2, ProductModule(rawValue: cells[0]) != nil else { continue }
            table[cells[0]] = cells[1]
        }
        #expect(table.count == ProductModule.allCases.count, "the table lists \(table.count) of \(ProductModule.allCases.count) modules")
        for m in ProductModule.allCases {
            #expect(table[m.rawValue] == m.disposition.rawValue, "\(m.rawValue): table \(table[m.rawValue] ?? "—"), code \(m.disposition.rawValue)")
        }
    }

    @Test func everySplitModuleNamesItsCorePart() {
        for m in ProductModule.allCases where m.disposition == .split || m.disposition == .merge {
            #expect(!(m.coreRetained ?? "").isEmpty, "\(m.rawValue) has no core part")
        }
    }

    @Test func noCoreModuleDependsOnAnOptionalOne() {
        for m in ProductModule.allCases where m.disposition == .core || m.disposition == .merge {
            for dep in m.spec.dependsOn {
                // An Online safeguard depends on Online itself, which is the person's choice — not a core gap.
                if m.spec.requiresOnline && dep == .onlineAnswers { continue }
                #expect(dep.disposition == .core || dep.disposition == .merge, "\(m.rawValue) depends on \(dep.rawValue) (\(dep.disposition.rawValue))")
            }
        }
    }

    @Test func verificationClaimsHaveTheirTests() throws {
        let fm = FileManager.default
        var tests = ""
        let root = repoRoot.appendingPathComponent("KalsmritikoshTests")
        for case let url as URL in fm.enumerator(at: root, includingPropertiesForKeys: nil)! where url.pathExtension == "swift" {
            tests += (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }
        for m in ProductModule.allCases {
            #expect(m.verification != .signedAppVerified && m.verification != .integrationTested,
                    "\(m.rawValue) claims \(m.verification.rawValue) without a recorded run")
            if m.verification == .unitTested {
                for token in m.verificationEvidence {
                    #expect(tests.contains(token), "\(m.rawValue): no test mentions “\(token)”")
                }
            }
        }
    }

    @Test func noModuleIsAPurchaseExceptTheAIPathAndInvariantsAreListed() {
        #expect(ProductModule.allCases.filter { $0.entitlement != .none } == [.onlineAnswers])
        let statements = ModuleInvariant.allCases.map(\.statement).joined(separator: " ")
        for word in ["Legal holds", "re-checks", "erasure", "recorded", "permission", "only switches modules on"] {
            #expect(statements.contains(word), "no invariant mentions “\(word)”")
        }
        #expect(ModuleMatrixDocument.render().contains("| Disposition |"))
    }
}

@Suite("S — presets keep the beginner path core")
struct ScopePresetTests {

    @Test func presetsNeverIncludeConnectionsRetiredOrDeferredModules() {
        for id in ["legal", "investigation", "journalism", "research", "devonthink", "general"] {
            let set = ModulePreset.modules(forPersona: id)
            for m in set {
                #expect(!ProductModule.neverSwitchedOnAutomatically.contains(m), "\(id) switches on \(m.rawValue)")
                #expect(m.disposition.isProductSurface, "\(id) switches on \(m.rawValue) (\(m.disposition.rawValue))")
            }
        }
        #expect(!ModulePreset.standalone.contains(.spotlightIndex))
        #expect(!ModulePreset.standalone.contains(.folderSync))
    }

    @Test func investigatorStartsWithTheCoreOnly() {
        let investigation = ModulePreset.modules(forPersona: "investigation")
        for m in investigation {
            #expect(m.disposition == .core || m.disposition == .merge, "investigator preset has specialist \(m.rawValue)")
        }
        #expect(!ModulePreset.everyone.contains(.devonthinkImport) && !ModulePreset.everyone.contains(.sendToDevonthink))
        #expect(ModulePreset.modules(forPersona: "devonthink").contains(.devonthinkImport))
    }

    @Test func newDefaultsFollowTheDecision() {
        #expect(!ProductModule.devonthinkImport.spec.defaultEnabled && !ProductModule.sendToDevonthink.spec.defaultEnabled)
        #expect(ProductModule.searchCoverageBadge.spec.defaultEnabled && ProductModule.writtenNotes.spec.defaultEnabled)
        for m in ProductModule.neverSwitchedOnAutomatically { #expect(!m.spec.defaultEnabled, "\(m.rawValue) defaults on") }
        for (m, old) in ModuleScopeMigration.previousDefaults { #expect(m.spec.defaultEnabled != old, "\(m.rawValue) did not change") }
    }
}

@Suite("S — prior installs keep their choices")
struct ModuleScopeMigrationTests {

    private func scratchStore() -> (UserDefaults, String) {
        let name = "kalsmritikosh.tests.scope.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    @Test func priorInstallKeepsOldDefaultsAndExplicitChoices() {
        let (store, name) = scratchStore()
        defer { store.removePersistentDomain(forName: name) }
        store.set(true, forKey: "kalsmritikosh.onboarding.shown")
        store.set(false, forKey: ProductModuleFlags.storageKey(.searchCoverageBadge))   // their explicit choice
        store.set(false, forKey: ProductModuleFlags.storageKey(.spotlightIndex))
        let pinned = ModuleScopeMigration.run(store)
        // The DEVONthink connectors they had by default stay on; notes stay as they were (off).
        #expect(store.object(forKey: ProductModuleFlags.storageKey(.devonthinkImport)) as? Bool == true)
        #expect(store.object(forKey: ProductModuleFlags.storageKey(.sendToDevonthink)) as? Bool == true)
        #expect(store.object(forKey: ProductModuleFlags.storageKey(.writtenNotes)) as? Bool == false)
        // An explicit choice is never rewritten.
        #expect(store.object(forKey: ProductModuleFlags.storageKey(.searchCoverageBadge)) as? Bool == false)
        #expect(!pinned.contains(.searchCoverageBadge))
        // Privacy-sensitive connections are never switched on.
        for m in ProductModule.neverSwitchedOnAutomatically {
            #expect(store.object(forKey: ProductModuleFlags.storageKey(m)) as? Bool != true, "\(m.rawValue) was switched on")
        }
        // Once only: a later launch changes nothing, even after the person flips a switch.
        store.set(false, forKey: ProductModuleFlags.storageKey(.devonthinkImport))
        #expect(ModuleScopeMigration.run(store).isEmpty)
        #expect(store.object(forKey: ProductModuleFlags.storageKey(.devonthinkImport)) as? Bool == false)
    }

    @Test func newInstallGetsTheNewDefaults() {
        let (store, name) = scratchStore()
        defer { store.removePersistentDomain(forName: name) }
        #expect(!ModuleScopeMigration.isPriorInstall(store))
        #expect(ModuleScopeMigration.run(store).isEmpty)
        for m in ProductModule.allCases { #expect(store.object(forKey: ProductModuleFlags.storageKey(m)) == nil, "\(m.rawValue) stored") }
    }

    @Test func aStoredRoleOrSwitchMarksAPriorInstall() {
        let (store, name) = scratchStore()
        defer { store.removePersistentDomain(forName: name) }
        store.set(true, forKey: ProductModuleFlags.storageKey(.watchlists))
        #expect(ModuleScopeMigration.isPriorInstall(store))
    }
}

@Suite("S — core parts stay with their module off", .serialized)
struct ScopeCoreTests {

    /// Every module that is not core, switched OFF for the duration of `body` — for this test's own task tree
    /// (`ProductModuleFlags.TestOverride`), never the host's shared preference store, which parallel suites
    /// also read (a save-and-put-back there switched other suites' packs back on mid-test, 2026-11-12).
    @MainActor
    private func withOptionalPacksOff(_ body: () async throws -> Void) async rethrows {
        var modules = ProductModuleFlags.TestOverride.modules ?? [:]
        for m in ProductModule.allCases where m.disposition != .core && m.disposition != .merge { modules[m] = false }
        try await ProductModuleFlags.TestOverride.$modules.withValue(modules) {
            for m in ProductModule.allCases where m.disposition != .core && m.disposition != .merge {
                #expect(!ProductModuleFlags.isEnabled(m))
            }
            try await body()
        }
    }

    @Test @MainActor func coreToolsAndFormatsRemain() async {
        await withOptionalPacksOff {
            let available = Set(ToolSheet.available)
            #expect(available.isSuperset(of: ToolSheet.core), "core tools missing: \(ToolSheet.core.subtracting(available))")
            #expect(!available.contains(.legalProduction) && !available.contains(.studio) && !available.contains(.teamReview))
            #expect(ToolSheet.legalHolds.title == "Legal holds" && ToolSheet.exportCenter.title == "Export"
                    && ToolSheet.smartCollections.title == "Saved searches")
            #expect(Set(LedgerExportFormat.offered(specialistOn: false)) == [.csv, .docx, .pdf])
            #expect(LedgerExportFormat.offered(specialistOn: true) == LedgerExportFormat.allCases)
            // Share-menu capture is core when the person never switched it off…
            #expect(ProductModuleFlags.explicitChoice(.captureExtensions) == false)
        }
        // …and an explicit "off" is respected.
        let key = ProductModuleFlags.storageKey(.captureExtensions)
        let saved = AppDefaults.store.object(forKey: key)
        defer { if let saved { AppDefaults.store.set(saved, forKey: key) } else { AppDefaults.store.removeObject(forKey: key) } }
        AppDefaults.store.removeObject(forKey: key)
        #expect(ProductModuleFlags.shareMenuCaptureAvailable)
        AppDefaults.store.set(false, forKey: key)
        #expect(!ProductModuleFlags.shareMenuCaptureAvailable)
    }

    @Test func caseReportFormatsDoNotDependOnAModule() throws {
        let doc = ExportableDocument(
            title: "Case report",
            sections: [ExportSection(title: "Findings", paragraphs: ["The invoice was paid on 4 March 2024."])],
            table: ExportTable(title: "Chronology", columns: ["Date", "Event"], rows: [["2024-03-04", "Invoice paid"]]),
            manifest: ExportManifest(exportedAt: Date(timeIntervalSince1970: 1_700_000_000), appVersion: "test", schemaVersion: 1,
                                     workspaceTitle: "Matter", sourceVersionIDs: ["v1"],
                                     sourceHashes: [String(repeating: "a", count: 64)],
                                     selectedFindingCount: 1, knownLimitations: []))
        for format in [ExportDeliverableFormat.pdf, .docx, .csv] {
            #expect(try !WorkProductExportService().data(for: doc, format: format).isEmpty, "\(format.rawValue) is empty")
        }
    }

    @Test("With every optional pack off: intake, search, source, export, saved search, hold, backup, erasure",
          .timeLimit(.minutes(5)))
    @MainActor func baseJourneyWithPacksOff() async throws {
        try await withOptionalPacksOff {
            let (state, dir) = try await RealArchivePipelineTests.bootState(label: "scope")
            guard case .ready = state.phase else {
                Issue.record("AppState did not boot — the core journey was NOT verified")
                await RealArchivePipelineTests.teardown(state, dir); return
            }
            let db = try #require(state.database)
            // Intake.
            let docs = dir.appendingPathComponent("docs", isDirectory: true)
            try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
            let note = docs.appendingPathComponent("Grant-notice.txt")   // sourceFilenames returns names percent-encoded ("%20"), a separate issue
            try Data("Grant notice. The examiner Dr. Meera Iyer approved invoice 4417 on 4 March 2024.".utf8).write(to: note)
            await state.ingestFiles([note])
            // Exact search finds it, and the source opens by name.
            let hits = try await #require(state.chunks).searchFTS("examiner", limit: 10)
            let objectID = try #require(hits.first?.objectID, "search found nothing")
            let names = try await #require(state.objects).sourceFilenames(for: [objectID])
            #expect(names[objectID] == "Grant-notice.txt")
            // Export: the source table renders in the core formats.
            let table = try #require(await state.exportTable(.sources, query: "examiner"))
            #expect(!table.rows.isEmpty)
            for format in LedgerExportFormat.offered(specialistOn: false) {
                var missing: [String] = []
                #expect(!LedgerExportRenderer.render(table, format: format, missing: &missing).isEmpty, "\(format.rawValue)")
            }
            // Saved search (core) works; rules (optional) are not reachable.
            let saved = try #require(state.savedSearches)
            try await saved.create(name: "Examiner", query: "examiner")
            #expect(try await saved.all().map(\.name) == ["Examiner"])
            #expect(state.smartCollections == nil)
            // A legal hold is placed with "Production sets" off, and it blocks erasure.
            let holds = LegalProductionRepository(database: db)
            let hold = try await holds.createHold(name: "Matter")
            try await holds.addToHold(hold, objects: [objectID])
            #expect(await state.deleteAllData() == 0)
            #expect(state.legalHoldBlock?.contains("Tools → Legal holds") == true)
            try await holds.release(hold)
            // Backup: a verified snapshot.
            let scratch = dir.appendingPathComponent("scratch", isDirectory: true)
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            let snapshot = scratch.appendingPathComponent("knowledge.sqlite")
            try await db.backupSnapshot(to: snapshot)
            let backup = dir.appendingPathComponent("backup", isDirectory: true)
            _ = try BackupService().createBackup(databaseURL: snapshot, originalURLs: [], destination: backup,
                                                 schemaVersion: SchemaMigrations.latestVersion, nowEpoch: 1_700_000_000)
            #expect(try BackupService().inspect(backupFolder: backup).verdict.ok)
            // Erasure, with the hold released, leaves nothing behind.
            #expect(await state.deleteAllData() > 0)
            #expect(state.eraseResidue.isEmpty, "residue: \(state.eraseResidue.map { "\($0.table)=\($0.rows)" })")
            await RealArchivePipelineTests.teardown(state, dir)
        }
    }
}

@Suite("S — retired and reworded surfaces")
struct ScopeRetiredSurfaceTests {

    @Test @MainActor func retiredScreensLeaveTheBeginnerPathButStillResolve() {
        let key = ProductModuleFlags.storageKey(.contentCreatorPersona)
        let saved = AppDefaults.store.object(forKey: key)
        defer { if let saved { AppDefaults.store.set(saved, forKey: key) } else { AppDefaults.store.removeObject(forKey: key) } }
        AppDefaults.store.set(false, forKey: key)
        #expect(!PaletteCatalog.visibleEntries().contains { $0.id == "go.ccStudio" })
        #expect(!Destination.Group.professional.items.contains(.ccStudio) && Destination.Group.professional.allItems.contains(.ccStudio))
        // The route still exists: a menu item or a saved route lands on the screen with the saved packages.
        #expect(PaletteCatalog.entries().contains { $0.id == "go.ccStudio" })
        // Retired tools are never listed, even switched on.
        let studioKey = ProductModuleFlags.storageKey(.studioOutputs)
        let studioSaved = AppDefaults.store.object(forKey: studioKey)
        defer { if let studioSaved { AppDefaults.store.set(studioSaved, forKey: studioKey) } else { AppDefaults.store.removeObject(forKey: studioKey) } }
        AppDefaults.store.set(true, forKey: studioKey)
        #expect(!ToolSheet.available.contains(.studio))
        #expect(ToolSheet.studio.isRetired && ToolSheet.teamReview.isRetired)
        for m in [ProductModule.studioOutputs, .contentCreatorPersona] { #expect(m.family == .retired) }
        #expect(ProductModule.teamReview.disposition == .deferred && ProductModuleFlags.disabledReason(.teamReview) != nil)
    }

    @Test func sourceCountsAreCountsNotAVerdict() {
        let a = UUID(), b = UUID(), c = UUID()
        let reading = CorroborationMeter.read(citedObjectIDs: [a, b, c], keys: [a: "h1", b: "h1", c: "h2"])
        #expect(reading.headline == "3 documents cited · 2 distinct origins after copies")
        #expect(reading.dependenceNote.contains("not proven independent"))
        #expect(CorroborationReading.reviewState.contains("Not assessed"))
        let single = CorroborationMeter.read(citedObjectIDs: [a], keys: [a: "h1"])
        for text in [reading.headline, single.headline] {
            #expect(!text.lowercased().contains("independent sources") && !text.lowercased().contains("corroborated"))
        }
        #expect(single.dependenceNote.contains("one origin"))
    }

    @Test func reviewPriorityListsSignalsForDocumentsOnly() {
        #expect(ReviewPriority.label([]) == nil)
        #expect(ReviewPriority.label(["2 contradictions", "added this week"]) == "Review priority: 2 contradictions; added this week")
        let spec = ProductModule.riskScore.spec
        #expect(spec.title == "Review priority (documents)")
        #expect(!spec.detail.lowercased().contains("score per document and person"))
        #expect(RiskScore(total: 7, parts: ["1 contradiction"]).reviewPriorityLabel == "Review priority: 1 contradiction")
    }

    @Test func dateFilterAndSelfTestAreWordedHonestly() {
        #expect(ProductModule.timeTravel.title == "Filter by document date")
        #expect(ProductModule.timeTravel.detail.contains("does not show what anyone knew"))
        #expect(ProductModule.archiveSelfScore.disposition == .internal)
        #expect(ProductModule.archiveSelfScore.detail.contains("not a measure of real-world accuracy"))
        for m in ProductModule.allCases where m.disposition.isProductSurface {
            #expect(!m.title.lowercased().contains("risk") && !m.title.lowercased().contains("accuracy"), "\(m.rawValue): \(m.title)")
        }
    }

    @Test func evidenceCanvasNeverSaysAllClaimsSupported() {
        typealias Card = EvidenceCanvasView.ClaimCard
        let noteOnly = [Card(statement: "A", evidenceCount: 0, userNote: "my reasoning"), Card(statement: "B", evidenceCount: 2)]
        let cited = [Card(statement: "A", evidenceCount: 1)]
        let missing = [Card(statement: "A", evidenceCount: 0)]
        for cards in [noteOnly, cited, missing, []] {
            #expect(EvidenceCanvasView.headerSummary(cards).text != "All claims supported")
        }
        #expect(EvidenceCanvasView.headerSummary(noteOnly).text == "1 cite evidence · 1 rest on your note only")
        #expect(EvidenceCanvasView.headerSummary(noteOnly).warning)
        #expect(EvidenceCanvasView.headerSummary(missing).text == "1 need evidence or a note")
    }
}
