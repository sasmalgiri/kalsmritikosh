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

    @Test("The model discovers all five personas and enumerates each persona's real jobs")
    func discoversAndEnumerates() async throws {
        let (model, _) = try await makeModel()
        await model.load()
        #expect(model.personas.count == 5)
        #expect(model.personas.contains { $0.id == InvestigatorPersonaPackage.applicationID })
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
