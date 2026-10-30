//
//  PersonaJobsModelTests.swift
//  KalsmritikoshTests
//
//  Cross-persona UI model (owner Decision 1). Proves the production UI surface's model DISCOVERS the shipped
//  personas from the ONE catalog, ENUMERATES each persona's real jobs, opens a matter by launching the intake
//  job (a REAL case is created), and RUNS a job into the real shared service — the same production path the
//  acceptance suites drive, now reachable from the UI. Synthetic only.
//

import Testing
import Foundation
@testable import Kalsmritikosh

@MainActor
@Suite("Cross-persona UI model", .serialized)
struct PersonaJobsModelTests {

    private let t0 = Date(timeIntervalSince1970: 1_769_000_000)

    /// Build the model over a live production-mirror service + a seeded workspace with one authorized source.
    private func makeModel() async throws -> (PersonaJobsModel, harness: PersonaAcceptanceHarness) {
        let h = try await PersonaAcceptanceHarness.make(seed: "ui")
        let a = try await h.seedFact(value: "authorized fact \(UUID().uuidString)", hashChar: "u")
        let wsID = UUID()
        try await h.workspaces.upsert(Workspace(id: wsID, title: "UI Matter", template: .general))
        try await h.workspaces.addSource(a.fileID, to: wsID)
        try await WorkspaceMembershipDeriver(database: h.db, workspaces: h.workspaces).deriveMembership(for: wsID)
        _ = try await h.producer.backfill(at: t0)
        let model = PersonaJobsModel(service: h.service,
                                     catalog: try PersonaJobCatalogComposer.composeProduction(),
                                     workspaces: h.workspaces)
        return (model, h)
    }

    @Test("The model discovers all registered personas and enumerates each persona's real jobs")
    func discoversAndEnumerates() async throws {
        let (model, _) = try await makeModel()
        await model.load()
        // Five core personas + four buyer-research personas (2026-08-19). The Content Creator
        // (2026-08-20) is hidden unless its module is on (A5, 2026-10-23).
        #expect(model.personas.count == (ProductModuleFlags.isEnabled(.contentCreatorPersona) ? 10 : 9))
        #expect(model.personas.contains { $0.id == InvestigatorPersonaPackage.applicationID })
        #expect(model.personas.contains { $0.id == SIUPersonaPackage.applicationID })
        #expect(model.personas.contains { $0.id == GenealogistPersonaPackage.applicationID })
        #expect(model.personas.contains { $0.id == ContentCreatorPersonaPackage.applicationID }
                == ProductModuleFlags.isEnabled(.contentCreatorPersona))
        // Default selection enumerates a real, non-empty job set with an intake job.
        #expect(!model.jobs.isEmpty)
        // Switching persona re-enumerates. (PJOB-MAX: Researcher now covers
        // all 16 PersonaJobKinds across 20 jobs.)
        await model.select(persona: ResearcherPersonaPackage.applicationID)
        #expect(model.jobs.count == 20)
        #expect(model.intakeJob != nil)
        await model.select(persona: InvestigatorPersonaPackage.applicationID)
        #expect(model.jobs.count == 16)
    }

    @Test("Starting a matter launches the intake job (creates a real case); running a job reaches a real service")
    func startMatterAndRunJob() async throws {
        let (model, _) = try await makeModel()
        await model.load()
        await model.select(persona: InvestigatorPersonaPackage.applicationID)
        // Open a matter — the intake job creates a REAL case in the seeded workspace.
        model.matterTitle = "Payment discrepancy"
        await model.startMatter(actor: "me", at: t0)
        #expect(model.activeCaseID != nil)
        #expect(model.lastError == nil)
        #expect(model.activeMatterTitle == "Payment discrepancy")
        // Run a representative wired job — it routes into the real service and reports a real outcome.
        let custody = try #require(model.runnableJobs.first { $0.kind == .evidenceCustody })
        await model.run(custody, actor: "me", at: t0)
        #expect(model.lastError == nil)
        #expect(model.lastOutcome != nil)
        // A findings job also routes real (produces a run).
        let findings = try #require(model.runnableJobs.first { $0.kind == .findings })
        await model.run(findings, actor: "me", at: t0)
        #expect(model.lastError == nil)
    }

    @Test("I1: reopening a matter never widens its scope; the review shows the new document and approving it through the control includes it once; results saved earlier are marked as from an earlier scope")
    func documentsEnterOnlyThroughReview() async throws {
        let h = try await PersonaAcceptanceHarness.make(seed: "scope")
        let a = try await h.seedFact(value: "authorized fact \(UUID().uuidString)", hashChar: "s")
        // The coverage walk resolves a workspace file through its content hash.
        try await h.db.exec("UPDATE files SET content_hash = ? WHERE id = ?;", [.text(String(repeating: "s", count: 64)), .uuid(a.fileID)])
        let wsID = UUID()
        try await h.workspaces.upsert(Workspace(id: wsID, title: "Scope Matter", template: .general))
        try await h.workspaces.addSource(a.fileID, to: wsID)
        try await WorkspaceMembershipDeriver(database: h.db, workspaces: h.workspaces).deriveMembership(for: wsID)
        _ = try await h.producer.backfill(at: t0)
        let intake = InvestigationWorkspaceIntake(cases: h.cases, workspaces: h.workspaces, coverage: CaseCoverageRepository(database: h.db))
        let model = PersonaJobsModel(service: h.service, catalog: try PersonaJobCatalogComposer.composeProduction(),
                                     workspaces: h.workspaces, cases: h.cases, results: JobResultRepository(database: h.db), intake: intake)
        await model.load()
        model.selectedWorkspace = wsID
        await model.select(persona: InvestigatorPersonaPackage.applicationID)
        model.matterTitle = "Scope discipline"
        // This harness's job service has no intake wired, so the matter opens with nothing in scope —
        // exactly the recovery path the review describes.
        await model.startMatter(actor: "me", at: t0)
        let caseID = try #require(model.activeCaseID)
        #expect(model.lastOutcome?.contains("Review new documents") == true, "the empty-scope hint must point at the control")
        #expect(model.scopePreview?.inScope == 0 && model.scopePreview?.pending.count == 1)
        // A result saved now is over the empty scope.
        let custody = try #require(model.runnableJobs.first { $0.kind == .evidenceCustody })
        await model.run(custody, actor: "me", at: t0.addingTimeInterval(10))

        // Reopen the matter: nothing is included by that alone.
        let matter = try #require(try await h.cases.fetch(caseID: caseID)).caseHeader
        model.openMatter(matter)
        try await Task.sleep(for: .milliseconds(300))
        #expect(try #require(try await h.cases.fetch(caseID: caseID)).sources.filter(\.inScope).isEmpty, "reopening widened the scope")
        #expect(model.scopePreview?.pending.count == 1)

        // Review, then approve through the control.
        await model.reviewNewDocuments()
        let review = try #require(model.inclusionReview)
        #expect(review.pending.count == 1 && review.excluded.isEmpty)
        await model.approveInclusion(Set(review.pending.map(\.id)), actor: "me", at: t0.addingTimeInterval(60))
        #expect(model.lastError == nil && model.inclusionReview == nil)
        let record = try #require(try await h.cases.fetch(caseID: caseID))
        #expect(record.sources.filter(\.inScope).count == 1)
        #expect(record.events.filter { $0.action == .sourceIncluded }.count == 1)
        #expect(model.scopePreview?.inScope == 1 && model.scopePreview?.pending.isEmpty == true)
        #expect(model.workLog.contains { $0.jobTitle == "Documents added to case" })
        // The earlier result is now marked as from the earlier scope; re-running clears the mark.
        if model.results[custody.id] != nil {
            #expect(model.isFromEarlierScope(custody) && model.status(of: custody)?.contains("earlier scope") == true)
            await model.run(custody, actor: "me", at: t0.addingTimeInterval(120))
            #expect(!model.isFromEarlierScope(custody))
        }
        // Approving again adds nothing twice.
        await model.reviewNewDocuments()
        #expect(model.inclusionReview?.pending.isEmpty == true)
        await model.approveInclusion([], actor: "me", at: t0.addingTimeInterval(180))
        #expect(try #require(try await h.cases.fetch(caseID: caseID)).sources.count == 1)
    }

    @Test("Running a job before a matter is open fails closed with a clear message, not a crash")
    func runBeforeMatterFailsClosed() async throws {
        let (model, _) = try await makeModel()
        await model.load()
        await model.select(persona: LawyerPersonaPackage.applicationID)
        let job = try #require(model.runnableJobs.first)
        await model.run(job, actor: "me", at: t0)
        #expect(model.lastError != nil)   // "Open a matter first."
        #expect(model.activeCaseID == nil)
    }
}
