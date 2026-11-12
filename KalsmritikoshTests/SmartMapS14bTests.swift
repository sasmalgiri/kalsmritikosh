//
//  SmartMapS14bTests.swift
//  KalsmritikoshTests
//
//  Smart-map slice S14 part 2 (docs/IME_Full_Smart_Map_Implementation_TODO_2026-11-08.md):
//  - test isolation: module switches are per task (ProductModuleFlags.TestOverride), so a parallel suite's
//    save-and-put-back of the shared preference store cannot switch another suite's packs back on;
//  - ACCESS-10: who built a findings run is recorded with the run; an approval by its builder is labelled self-approval,
//    refused when the case requires an independent reviewer, and the strict (atomic) approval path applies the same
//    role and self-review checks as the classic one;
//  - SEC-10: the remaining CSV writers (ledger tables / timeline / batch screening, work-product export, privilege log,
//    Data Lab, Convert, Query) write formula-like cells as text;
//  - PERF-08: a stored copy of an original that would not fit is refused before a byte is staged;
//  - SRC-01: the remaining source openers go through the pinned path (source scan).
//  Synthetic data only; no network.
//

import Foundation
import Testing
@testable import Kalsmritikosh

private let s14bFP = String(repeating: "f", count: 64)   // a scope fingerprint is 64 hex digits
private let s14bRepoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

@Suite("Smart map S14 part 2 — isolation, findings builder, CSV, disk, openers", .serialized)
struct SmartMapS14bTests {

    // MARK: Test isolation

    @Test("Module switches set for a test's own task tree hold while another task writes and restores the shared store, and never leak out")
    func moduleOverrideIsPerTask() async throws {
        let key = ProductModuleFlags.storageKey(.importQueue)
        let saved = AppDefaults.store.object(forKey: key)
        defer { if let saved { AppDefaults.store.set(saved, forKey: key) } else { AppDefaults.store.removeObject(forKey: key) } }
        AppDefaults.store.removeObject(forKey: key)
        let outside = ProductModuleFlags.isEnabled(.importQueue)

        await ProductModuleFlags.TestOverride.$modules.withValue([.importQueue: !outside]) {
            // A "parallel suite" flips the shared store back and forth (what the old save-and-put-back did).
            let writer = Task.detached {
                for i in 0..<200 { AppDefaults.store.set(i % 2 == 0, forKey: key) }
                AppDefaults.store.removeObject(forKey: key)
            }
            for _ in 0..<200 { #expect(ProductModuleFlags.isEnabled(.importQueue) == !outside) }
            await writer.value
            // A child task inherits the override (the app's own work started from the test sees it too).
            let child = await Task { ProductModuleFlags.isEnabled(.importQueue) }.value
            #expect(child == !outside)
            #expect(ProductModuleFlags.explicitChoice(.importQueue) == !outside)
        }
        // Outside the scope the shared store answers again, untouched by the override.
        #expect(ProductModuleFlags.isEnabled(.importQueue) == outside)
        #expect(AppDefaults.store.object(forKey: key) == nil)
    }

    // MARK: ACCESS-10

    private func policyRequiringIndependence(_ f: CaseFileTests.Fixture) async throws {
        let auto = CaseAutomationService(database: f.db, caseFiles: f.svc, aiPermitted: { _ in false })
        var p = CaseAutomationPolicy.standard; p.requireIndependentReview = true
        _ = try await auto.setPolicy(caseID: f.caseID, p, actor: "Ada")
    }

    private func recordBuilder(_ f: CaseFileTests.Fixture, run: UUID, by: String) async throws {
        try await f.db.withSavepoint("s14b_build_\(UUID().uuidString.prefix(8))") { db in
            try FindingsBuilds.record(db, runID: run, caseID: f.caseID, builtBy: by, at: Date(timeIntervalSince1970: 1_790_000_000))
        }
    }

    @Test("Findings approval: by the builder is self-approval (labelled), by someone else independent, with no recorded builder 'not recorded'; the builder row is fixed")
    func findingsSelfApprovalDetected() async throws {
        let f = try await CaseFileTests.fixture()
        let approvals = InvestigationFindingsApprovalRepository(database: f.db)
        let fp = CaseScopeFingerprint(value: s14bFP)
        let mine = UUID(), legacy = UUID()
        try await recordBuilder(f, run: mine, by: "Ada Lovelace")

        let selfApproved = try await approvals.approve(caseID: f.caseID, workProductRunID: mine, receiptSeal: "seal", scopeFingerprint: fp,
                                                       rationale: "Checked", actor: "ada  lovelace", at: Date())
        #expect(selfApproved.reviewKind == .selfReview, "the same person, spelled differently, is still the builder")
        #expect(selfApproved.reviewLabel.hasPrefix("Self-approved"))
        let other = try await approvals.approve(caseID: f.caseID, workProductRunID: mine, receiptSeal: "seal", scopeFingerprint: fp,
                                                rationale: "Second look", actor: "Ben", at: Date())
        #expect(other.reviewKind == .independent && other.reviewLabel.hasPrefix("Independent"))
        let unknown = try await approvals.approve(caseID: f.caseID, workProductRunID: legacy, receiptSeal: "seal", scopeFingerprint: fp,
                                                  rationale: "Old run", actor: "Ada Lovelace", at: Date())
        #expect(unknown.reviewKind == nil && unknown.reviewLabel.contains("not recorded"), "never guessed")
        // Read back from the ledger with the same kinds.
        let kinds = try await approvals.approvals(caseID: f.caseID).map(\.reviewKind)
        #expect(kinds == [.selfReview, .independent, nil])
        // A withdrawal carries no review kind.
        let withdrawn = try await approvals.withdraw(caseID: f.caseID, workProductRunID: mine, receiptSeal: "seal", scopeFingerprint: fp,
                                                     rationale: "Reopened", actor: "Ada Lovelace", at: Date())
        #expect(withdrawn.reviewKind == nil)
        // Who built a run is fixed once written.
        await #expect(throws: (any Error).self) {
            try await f.db.exec("UPDATE investigation_findings_builds SET built_by = 'Ben' WHERE run_id = ?;", [.uuid(mine)])
        }
    }

    @Test("When the case requires an independent reviewer, the builder's own approval is refused on both approval paths and nothing is written; another person may approve")
    func independentReviewRequiredForFindings() async throws {
        let f = try await CaseFileTests.fixture()
        try await policyRequiringIndependence(f)
        let run = UUID()
        try await recordBuilder(f, run: run, by: "Ada")
        let approvals = InvestigationFindingsApprovalRepository(database: f.db)
        let fp = CaseScopeFingerprint(value: s14bFP)
        await #expect(throws: CaseActionWorkError.independentReviewRequired) {
            _ = try await approvals.approve(caseID: f.caseID, workProductRunID: run, receiptSeal: "seal", scopeFingerprint: fp,
                                            rationale: "Mine", actor: "Ada", at: Date())
        }
        // The strict composite path: approval + assessment + governance event in one savepoint.
        let txn = ApprovalTransactionRepository(database: f.db)
        let assessment = ConformanceAssessment(sutraCitation: "test", sutraSnapshotJSON: "{}", sutraSHA256: String(repeating: "a", count: 64),
                                               evaluations: [], assessedAt: Date())
        func strict(_ actor: String) async throws -> StoredConformanceAssessment {
            try await txn.approveAtomically(write: AtomicApprovalWrite(caseID: f.caseID, workProductRunID: run, receiptSeal: "seal",
                                                                       scopeFingerprint: s14bFP, rationale: "Approved", actor: actor),
                                            assessment: assessment, seal: nil, sealedForRevision: 1, governanceDetail: "test", at: Date())
        }
        await #expect(throws: CaseActionWorkError.independentReviewRequired) { _ = try await strict("Ada") }
        #expect(try await f.db.query("SELECT COUNT(*) FROM investigation_findings_approvals;").first?.int(0) == 0)
        #expect(try await f.db.query("SELECT COUNT(*) FROM conformance_assessments;").first?.int(0) == 0)
        #expect(try await f.db.query("SELECT COUNT(*) FROM governance_events WHERE kind = 'findings.approved';").first?.int(0) == 0)
        // Someone else meets the requirement.
        _ = try await strict("Ben")
        #expect(try await approvals.latest(caseID: f.caseID)?.reviewKind == .independent)
    }

    @Test("The strict approval path refuses an investigator in a team case (the S9 role rule, now on both paths); a reviewer may approve and withdraw")
    func strictPathChecksRole() async throws {
        let f = try await CaseFileTests.fixture()
        _ = try await f.file.grantAccess(caseID: f.caseID, to: "Ben", role: .investigator, reason: "Works the case", actor: "Ada")
        _ = try await f.file.grantAccess(caseID: f.caseID, to: "Vera", role: .reviewer, reason: "Reviews", actor: "Ada")
        let run = UUID()
        try await recordBuilder(f, run: run, by: "Ben")
        let txn = ApprovalTransactionRepository(database: f.db)
        let assessment = ConformanceAssessment(sutraCitation: "test", sutraSnapshotJSON: "{}", sutraSHA256: String(repeating: "a", count: 64),
                                               evaluations: [], assessedAt: Date())
        let write = { (actor: String) in AtomicApprovalWrite(caseID: f.caseID, workProductRunID: run, receiptSeal: "seal", scopeFingerprint: s14bFP,
                                                             rationale: "Approved", actor: actor) }
        await #expect(throws: CaseAccessError.self) {
            _ = try await txn.approveAtomically(write: write("Ben"), assessment: assessment, seal: nil, sealedForRevision: 1, governanceDetail: "t", at: Date())
        }
        await #expect(throws: CaseAccessError.self) {
            try await txn.withdrawAtomically(write: write("Ben"), governanceDetail: "t", at: Date())
        }
        _ = try await txn.approveAtomically(write: write("Vera"), assessment: assessment, seal: nil, sealedForRevision: 1, governanceDetail: "t", at: Date())
        try await txn.withdrawAtomically(write: write("Vera"), governanceDetail: "t", at: Date())
        let rows = try await InvestigationFindingsApprovalRepository(database: f.db).approvals(caseID: f.caseID)
        #expect(rows.map(\.decision) == [.approved, .withdrawn] && rows.first?.reviewKind == .independent)
    }

    @Test("v189 from a v188 ledger: the findings-builds table exists (inventoried for case erasure), approvals gain review_kind, old approvals read as 'not recorded'")
    func migrationV189() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 188)
        try await SchemaMigrations.migrate(db)
        #expect(try await db.currentUserVersion() >= 189)
        #expect(try await MigrationFixtureBuilder.tableExists(db, "investigation_findings_builds"))
        #expect(CaseDataInventory.entry("investigation_findings_builds")?.lifecycle == .caseID)
        // An approval written the old way (no review kind) reads as "not recorded". A bare row with no case or run behind it.
        try await db.exec("PRAGMA foreign_keys = OFF;")
        try await db.exec("""
            INSERT INTO investigation_findings_approvals (id, case_id, sequence, decision, work_product_run_id, receipt_seal, scope_fingerprint, rationale, actor, created_at)
            VALUES ('a', 'c', 1, 'approved', 'r', 's', '\(s14bFP)', 'why', 'Ada', 1);
            """)
        let kind = try await db.query("SELECT review_kind FROM investigation_findings_approvals WHERE id = 'a';").first
        #expect(kind != nil && kind?.string(0) == nil, "an approval before v189 has no review kind")
        await #expect(throws: (any Error).self) {
            try await db.exec("INSERT INTO investigation_findings_approvals (id, case_id, sequence, decision, work_product_run_id, receipt_seal, scope_fingerprint, rationale, actor, created_at, review_kind) VALUES ('b', 'c', 2, 'approved', 'r', 's', '\(s14bFP)', 'why', 'Ada', 1, 'maybe');")
        }
        try await db.exec("DELETE FROM investigation_findings_approvals WHERE id = 'a';")
        try await db.exec("PRAGMA foreign_keys = ON;")
        #expect(try await MigrationFaultHarness.integrityOK(db))
    }

    // MARK: SEC-10

    @Test("Every remaining CSV writer writes a formula-like cell as text; plain and negative numbers are untouched")
    func remainingCSVWritersGuarded() throws {
        let hostile = ["=HYPERLINK(\"http://x\",\"y\")", "+SUM(A1)", "@cmd", "-2+3", "＝1+1"]
        // Ledger tables (also the timeline and batch-screening exports, which use the same escaper).
        let table = LedgerExportTable(title: "T", columns: ["a", "b"], rows: [hostile.prefix(2).map { $0 }, ["-12.50", "1,200"]],
                                      sources: ["s", "s"], passages: ["p", "p"])
        let ledger = LedgerExportRenderer.csv(table)
        for h in hostile.prefix(2) { #expect(!ledger.contains("," + h) && !ledger.contains("\r\n" + h) && !ledger.hasPrefix(h), "\(h) live in ledger CSV") }
        #expect(ledger.contains("-12.50") && !ledger.contains("'-12.50"))
        for h in hostile { #expect(LedgerExportRenderer.csvField(h).hasPrefix("'") || LedgerExportRenderer.csvField(h).hasPrefix("\"'"), "\(h)") }
        // Work-product CSV.
        let doc = ExportableDocument(
            title: "Report", sections: [ExportSection(title: "S", paragraphs: ["x"])],
            table: ExportTable(title: "Rows", columns: ["Name", "Amount"], rows: [["=cmd|' /C calc'!A0", "-500"]]),
            manifest: ExportManifest(exportedAt: Date(timeIntervalSince1970: 1_790_000_000), appVersion: "test", schemaVersion: 1,
                                     workspaceTitle: "W", sourceVersionIDs: [], sourceHashes: [], selectedFindingCount: 0, knownLimitations: []))
        let wp = String(decoding: try WorkProductExportService().data(for: doc, format: .csv), as: UTF8.self)
        #expect(wp.contains("'=cmd") && !wp.contains(",=cmd") && !wp.contains("\n=cmd"))
        #expect(wp.contains("-500") && !wp.contains("'-500"))
        // Privilege log, Data Lab.
        for h in hostile {
            #expect(CSVFormulaGuard.isFormulaLike(h))
            #expect(!CSVFormulaGuard.isFormulaLike(ProductionBuilder.csv(h).trimmingCharacters(in: CharacterSet(charactersIn: "\""))), "privilege log: \(h)")
            #expect(!CSVFormulaGuard.isFormulaLike(WorkbenchCSV.escape(h).trimmingCharacters(in: CharacterSet(charactersIn: "\""))), "Data Lab: \(h)")
        }
        #expect(WorkbenchCSV.escape("-7") == "-7" && ProductionBuilder.csv("plain") == "plain")
        // Convert and Query build their CSV in their views: the source must route every cell through the guard.
        for file in ["Kalsmritikosh/UI/ConvertView.swift", "Kalsmritikosh/UI/QueryView.swift"] {
            let text = try String(contentsOf: s14bRepoRoot.appendingPathComponent(file), encoding: .utf8)
            #expect(text.contains("CSVFormulaGuard.neutralised"), "\(file) writes CSV without the formula guard")
        }
    }

    // MARK: PERF-08

    @Test("A stored copy that would not fit is refused before a byte is staged (managed copy failed, with the reason); with room it is stored")
    func vaultCopyRefusedWhenDiskIsFull() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("s14b-vault-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = dir.appendingPathComponent("statement.txt")
        try Data(repeating: 0x41, count: 200_000).write(to: original)
        let vault = EvidenceVault(root: dir.appendingPathComponent("vault", isDirectory: true))
        do {
            _ = try await vault.storeStreaming(contentsOf: original, availableCapacity: { _ in 1_000_000 })
            Issue.record("a copy that does not fit was stored")
        } catch let e as SourceIntakeError {
            guard case .managedCopyFailed(let reason) = e else { Issue.record("wrong error \(e)"); return }
            #expect(reason.contains("not enough free space"), "\(reason)")
        }
        let staging = dir.appendingPathComponent("vault/staging", isDirectory: true)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? []
        #expect(leftovers.isEmpty, "nothing half-written is left behind: \(leftovers)")
        #expect(FileManager.default.fileExists(atPath: original.path), "the original is untouched")
        // With room (or when the capacity cannot be read) the copy is kept as before.
        let hash = try await vault.storeStreaming(contentsOf: original, availableCapacity: { _ in nil })
        #expect(await vault.contains(hash))
    }

    // MARK: SRC-01

    @Test("The remaining openers (watchlist, relationship graph, deep links, fact status, review, communication, job results) open through the pinned path, not the current file")
    func remainingOpenersArePinned() throws {
        let files = ["Kalsmritikosh/UI/WatchlistView.swift", "Kalsmritikosh/UI/RelationshipGraphView.swift", "Kalsmritikosh/App/DeepLink.swift",
                     "Kalsmritikosh/UI/FactStatusView.swift", "Kalsmritikosh/UI/ReviewView.swift", "Kalsmritikosh/UI/CommunicationView.swift",
                     "Kalsmritikosh/UI/JobResultView.swift"]
        for file in files {
            let text = try String(contentsOf: s14bRepoRoot.appendingPathComponent(file), encoding: .utf8)
            #expect(!text.contains("fetchSourceURL("), "\(file) still opens the object's current file")
            #expect(!text.contains("SourceViewer(url:"), "\(file) still shows a file without the pinned check")
            #expect(text.contains("CitedSourceOpening.resolve") || text.contains("PinnedSourceView("), "\(file) does not use the pinned path")
        }
    }
}
