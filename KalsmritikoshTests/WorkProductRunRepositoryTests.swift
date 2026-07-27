//
//  WorkProductRunRepositoryTests.swift
//  KalsmritikoshTests
//
//  OPS-004 — WorkProductRunRepository persistence (schema v72).
//  Covers: save round-trip, reopen fidelity (sections/claims + manifest), list order,
//  delete cascade + fail-closed reopen, workspace isolation, multi-run list,
//  section/finding count match, canonical claim isolation after delete.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("OPS-004 — WorkProductRunRepository")
struct WorkProductRunRepositoryTests {

    private let t0 = Date(timeIntervalSince1970: 1_750_000_000)

    // MARK: - Rig helpers

    private func makeDB() async throws -> Database {
        try await MigrationFixtureBuilder.database(atVersion: 72)
    }

    private func seedWorkspace(_ db: Database, id: UUID) async throws {
        try await db.exec(
            "INSERT INTO workspaces (id, title, template_type, created_at, updated_at) VALUES (?,?,?,?,?);",
            [.uuid(id), .text("Test WS"), .text("general"),
             .real(t0.timeIntervalSince1970), .real(t0.timeIntervalSince1970)])
    }

    private func makeAssembled(
        template: WorkProductTemplate = .generalSummary,
        title: String = "Test Report",
        sections: [WorkProductSection] = [],
        composedAt: Date? = nil,
        findingCount: Int = 0,
        workspaceTitle: String? = nil
    ) -> AssembledWorkProduct {
        let at = composedAt ?? t0
        let wp = WorkProduct(template: template, title: title, sections: sections)
        let manifest = ExportManifest(
            exportedAt: at, appVersion: "1.0-test", schemaVersion: 72,
            workspaceTitle: workspaceTitle,
            selectedFindingCount: findingCount)
        return AssembledWorkProduct(workProduct: wp, manifest: manifest)
    }

    private func makeSection(
        title: String = "Section A",
        preamble: [String] = [],
        claims: [WorkProductClaim] = []
    ) -> WorkProductSection {
        WorkProductSection(title: title, preamble: preamble, claims: claims)
    }

    private func makeClaim(
        text: String = "A fact.",
        status: EpistemicStatus = .directEvidence
    ) -> WorkProductClaim {
        WorkProductClaim(text: text, status: status)
    }

    // MARK: - Test 1: save round-trip

    @Test("save returns a WorkProductRun with matching header fields")
    func saveRoundTrip() async throws {
        let db = try await makeDB()
        let wsID = UUID()
        try await seedWorkspace(db, id: wsID)
        let repo = WorkProductRunRepository(database: db)

        let assembled = makeAssembled(
            template: .factMemo, title: "My Report",
            composedAt: t0, findingCount: 3)
        let run = try await repo.save(assembled, workspaceID: wsID, subjectLabel: "Alice")

        #expect(run.workspaceID == wsID)
        #expect(run.template == .factMemo)
        #expect(run.title == "My Report")
        #expect(run.subjectLabel == "Alice")
        #expect(run.findingCount == 3)
        #expect(abs(run.composedAt.timeIntervalSince1970 - t0.timeIntervalSince1970) < 0.001)
        #expect(run.schemaVersion == 72)
        #expect(run.appVersion == "1.0-test")
    }

    // MARK: - Test 2: reopen fidelity — sections and claims

    @Test("reopen reconstructs sections and claims with exact text and epistemic status")
    func reopenFidelity_sectionsAndClaims() async throws {
        let db = try await makeDB()
        let wsID = UUID()
        try await seedWorkspace(db, id: wsID)
        let repo = WorkProductRunRepository(database: db)

        let c1 = makeClaim(text: "Smith worked at ACME from 2018.", status: .directEvidence)
        let c2 = makeClaim(text: "No contradicting evidence found.", status: .humanNote)
        let section = makeSection(
            title: "Employment",
            preamble: ["Scope: employment history."],
            claims: [c1, c2])
        let assembled = makeAssembled(title: "Bio Report", sections: [section])

        let run = try await repo.save(assembled, workspaceID: wsID, subjectLabel: "Smith")
        let reopened = try await repo.reopen(run.id)

        #expect(reopened.workProduct.title == "Bio Report")
        #expect(reopened.workProduct.sections.count == 1)
        let rSec = reopened.workProduct.sections[0]
        #expect(rSec.title == "Employment")
        #expect(rSec.preamble == ["Scope: employment history."])
        #expect(rSec.claims.count == 2)
        #expect(rSec.claims[0].text == "Smith worked at ACME from 2018.")
        #expect(rSec.claims[0].status == .directEvidence)
        #expect(rSec.claims[1].text == "No contradicting evidence found.")
        #expect(rSec.claims[1].status == .humanNote)
    }

    // MARK: - Test 3: reopen fidelity — manifest fields

    @Test("reopen reconstructs all ExportManifest fields faithfully")
    func reopenFidelity_manifestFields() async throws {
        let db = try await makeDB()
        let wsID = UUID()
        try await seedWorkspace(db, id: wsID)
        let repo = WorkProductRunRepository(database: db)

        let svID = UUID().uuidString
        let hash = "sha256-abc123"
        let limitation = "Only covers 2020–2023 documents."
        let citation = CitationMapEntry(label: "[1]", resolved: true)

        let manifest = ExportManifest(
            exportedAt: t0, appVersion: "2.0-test", schemaVersion: 72,
            workspaceTitle: "Case Alpha", workspaceTemplate: "investigation",
            sourceVersionIDs: [svID], sourceHashes: [hash],
            selectedFindingCount: 1,
            citationMap: [citation],
            knownLimitations: [limitation])
        let wp = WorkProduct(template: .investigationFindings, title: "Inv Report")
        let assembled = AssembledWorkProduct(workProduct: wp, manifest: manifest)

        let run = try await repo.save(assembled, workspaceID: wsID, subjectLabel: "S")
        let mf = try await repo.manifest(forRun: run.id)

        #expect(mf.appVersion == "2.0-test")
        #expect(mf.workspaceTitle == "Case Alpha")
        #expect(mf.workspaceTemplate == "investigation")
        #expect(mf.sourceVersionIDs == [svID])
        #expect(mf.sourceHashes == [hash])
        #expect(mf.selectedFindingCount == 1)
        #expect(mf.citationMap.count == 1)
        #expect(mf.citationMap[0].label == "[1]")
        #expect(mf.citationMap[0].resolved == true)
        #expect(mf.knownLimitations == [limitation])
    }

    // MARK: - Test 4: list order — most recent first

    @Test("runs(inWorkspace:) returns runs in most-recent-first order")
    func listOrder_mostRecentFirst() async throws {
        let db = try await makeDB()
        let wsID = UUID()
        try await seedWorkspace(db, id: wsID)
        let repo = WorkProductRunRepository(database: db)

        let older = makeAssembled(
            title: "First",
            composedAt: Date(timeIntervalSince1970: t0.timeIntervalSince1970 - 3600))
        let newer = makeAssembled(title: "Second", composedAt: t0)
        try await repo.save(older, workspaceID: wsID, subjectLabel: "S")
        try await repo.save(newer, workspaceID: wsID, subjectLabel: "S")

        let listed = try await repo.runs(inWorkspace: wsID)
        #expect(listed.count == 2)
        #expect(listed[0].title == "Second")
        #expect(listed[1].title == "First")
    }

    // MARK: - Test 5: delete + fail-closed reopen

    @Test("delete removes run from list and reopen throws runNotFound")
    func delete_removesRunAndFailClosedReopen() async throws {
        let db = try await makeDB()
        let wsID = UUID()
        try await seedWorkspace(db, id: wsID)
        let repo = WorkProductRunRepository(database: db)

        let assembled = makeAssembled(sections: [makeSection(claims: [makeClaim()])])
        let run = try await repo.save(assembled, workspaceID: wsID, subjectLabel: "S")

        try await repo.delete(run.id)

        let listed = try await repo.runs(inWorkspace: wsID)
        #expect(listed.isEmpty)
        await #expect(throws: WorkProductRunError.runNotFound(run.id)) {
            try await repo.reopen(run.id)
        }
    }

    // MARK: - Test 6: workspace isolation

    @Test("runs(inWorkspace:) returns only that workspace's runs")
    func workspaceIsolation() async throws {
        let db = try await makeDB()
        let ws1 = UUID(); let ws2 = UUID()
        try await seedWorkspace(db, id: ws1)
        try await seedWorkspace(db, id: ws2)
        let repo = WorkProductRunRepository(database: db)

        try await repo.save(makeAssembled(title: "WS1 run"), workspaceID: ws1, subjectLabel: "S")
        try await repo.save(makeAssembled(title: "WS2 run"), workspaceID: ws2, subjectLabel: "S")

        let ws1Runs = try await repo.runs(inWorkspace: ws1)
        let ws2Runs = try await repo.runs(inWorkspace: ws2)

        #expect(ws1Runs.count == 1 && ws1Runs[0].title == "WS1 run")
        #expect(ws2Runs.count == 1 && ws2Runs[0].title == "WS2 run")
    }

    // MARK: - Test 7: multiple runs in same workspace

    @Test("multiple runs in the same workspace are all returned by runs(inWorkspace:)")
    func multipleRuns_sameWorkspace() async throws {
        let db = try await makeDB()
        let wsID = UUID()
        try await seedWorkspace(db, id: wsID)
        let repo = WorkProductRunRepository(database: db)

        for i in 1...3 {
            let a = makeAssembled(
                title: "Run \(i)",
                composedAt: Date(timeIntervalSince1970: t0.timeIntervalSince1970 + Double(i)))
            try await repo.save(a, workspaceID: wsID, subjectLabel: "S")
        }

        let listed = try await repo.runs(inWorkspace: wsID)
        #expect(listed.count == 3)
    }

    // MARK: - Test 8: section count preserved across reopen

    @Test("reopen returns the same section count and per-section claim count that was saved")
    func sectionCount_matchesSaved() async throws {
        let db = try await makeDB()
        let wsID = UUID()
        try await seedWorkspace(db, id: wsID)
        let repo = WorkProductRunRepository(database: db)

        let sections = [
            makeSection(title: "S1", claims: [makeClaim(text: "C1")]),
            makeSection(title: "S2", claims: [makeClaim(text: "C2"), makeClaim(text: "C3")]),
            makeSection(title: "S3")
        ]
        let assembled = makeAssembled(sections: sections)
        let run = try await repo.save(assembled, workspaceID: wsID, subjectLabel: "S")
        let reopened = try await repo.reopen(run.id)

        #expect(reopened.workProduct.sections.count == 3)
        #expect(reopened.workProduct.sections[0].title == "S1")
        #expect(reopened.workProduct.sections[0].claims.count == 1)
        #expect(reopened.workProduct.sections[1].title == "S2")
        #expect(reopened.workProduct.sections[1].claims.count == 2)
        #expect(reopened.workProduct.sections[2].title == "S3")
        #expect(reopened.workProduct.sections[2].claims.count == 0)
    }

    // MARK: - Test 9: findingCount matches manifest

    @Test("WorkProductRun.findingCount equals the manifest's selectedFindingCount")
    func findingCount_matchesManifest() async throws {
        let db = try await makeDB()
        let wsID = UUID()
        try await seedWorkspace(db, id: wsID)
        let repo = WorkProductRunRepository(database: db)

        let assembled = makeAssembled(findingCount: 7)
        let run = try await repo.save(assembled, workspaceID: wsID, subjectLabel: "S")
        let mf = try await repo.manifest(forRun: run.id)

        #expect(run.findingCount == 7)
        #expect(mf.selectedFindingCount == 7)
    }

    // MARK: - Test 10: deleting a run does not touch canonical claims

    @Test("deleting a run does not remove rows from the canonical claims table")
    func deleteDoesNotTouchCanonicalClaims() async throws {
        let db = try await makeDB()
        let wsID = UUID()
        try await seedWorkspace(db, id: wsID)
        let repo = WorkProductRunRepository(database: db)

        // Seed a minimal canonical claim (claims is FK-free at subject level).
        let canonicalClaimID = UUID()
        try await db.exec("""
        INSERT INTO claims (id, subject_id, subject_label, statement, evidence_basis,
                            review_disposition, proposal_origin, availability_status,
                            conflict_status, created_at)
        VALUES (?,?,?,?,?,?,?,?,?,?);
        """, [.uuid(canonicalClaimID), .uuid(UUID()), .text("Alice"),
              .text("Alice was employed at ACME."), .text("directlyObserved"),
              .text("unreviewed"), .text("sourceExtraction"),
              .text("available"), .text("none"),
              .real(t0.timeIntervalSince1970)])

        let assembled = makeAssembled()
        let run = try await repo.save(assembled, workspaceID: wsID, subjectLabel: "S")
        try await repo.delete(run.id)

        let claimRows = try await db.query(
            "SELECT COUNT(*) FROM claims WHERE id = ?;", [.uuid(canonicalClaimID)])
        #expect(Int(claimRows.first?.int(0) ?? 0) == 1,
                "canonical claim must survive work-product run deletion")
    }
}
