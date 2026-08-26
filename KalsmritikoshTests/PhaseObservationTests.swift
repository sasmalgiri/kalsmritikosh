//
//  PhaseObservationTests.swift
//  KalsmritikoshTests
//
//  PHASE B (seventh audit) — machine observation of SOP phase completion.
//  Proves: the v113 case↔method-run linkage surfaces method-family phases;
//  observed phases join the conformance facts as MACHINE-observed (the
//  signed observed/attested split); and a governing protocol requiring a
//  phase this build cannot observe is REFUSED at run start instead of
//  silently never conforming.
//

import Foundation
import Testing
import CryptoKit
@testable import Kalsmritikosh

@MainActor
@Suite("Phase observation (Phase B)", .serialized)
struct PhaseObservationTests {

    private let t0 = Date(timeIntervalSince1970: 1_769_200_000)

    @Test("case_method_runs linkage surfaces method-family phases, split by completion")
    func methodLinkageObserved() async throws {
        let h = try await PersonaAcceptanceHarness.make(seed: "phaseobs-methods")
        let wsID = UUID()
        try await h.workspaces.upsert(Workspace(id: wsID, title: "Obs WS", template: .investigation))
        let caseID = UUID()
        let runs = MethodRunRepository(database: h.db)
        let run = try await runs.createRun(workspaceID: wsID,
                                           methodDefinitionID: ProfessionalMethodDefinitionID(rawValue: "com.kalsmritikosh.method.5w1h"),
                                           methodDefinitionVersion: 1, title: "Five whys",
                                           createdBy: "me", now: t0)
        try await runs.linkCase(caseID, methodRunID: run.id, phaseKind: .causalAnalysis, at: t0)
        let activity = try await runs.casePhaseActivity(caseID: caseID)
        #expect(activity.count == 1)
        #expect(activity.first?.phase == .causalAnalysis)
        #expect(activity.first?.total == 1)
        #expect(activity.first?.completed == 0)   // still draft — honest split

        let service = PhaseObservationService(methodRuns: runs)
        let obs = await service.observations(caseID: caseID)
        let causal = try #require(obs[.causalAnalysis])
        #expect(causal.artifactCount == 1)
        #expect(causal.decidedCount == 0)
        // Another case sees nothing (case scoping holds).
        #expect(await service.observations(caseID: UUID()).isEmpty)
    }

    @Test("The certificate prints the observed/attested split from the signed facts")
    func certificateSplit() {
        var facts = ConformanceFacts(completedPhaseKinds: [.caseIntake, .findings, .causalAnalysis],
                                     standardOfProofDeclared: true,
                                     openItemsAcknowledged: true,
                                     humanDecisionsMade: [.caseIntake, .findings, .causalAnalysis])
        facts.observedPhaseKinds = [.caseIntake, .findings]   // causalAnalysis asserted only
        let assessment = SutraConformance.assess(facts: facts, against: SutraCompiler.shared(),
                                                 at: Date(timeIntervalSince1970: 1_769_200_000))
        #expect(assessment.certificate.contains("Phases machine-observed:"))
        #expect(assessment.certificate.contains("caseIntake"))
        #expect(assessment.certificate.contains("Phases asserted (not machine-observed):"))
        #expect(assessment.certificate.contains("causalAnalysis"))
    }

    @Test("A governing protocol requiring an unobservable phase is refused at run start")
    func unobservableRequiredPhaseRefused() async throws {
        // The systematic-review discipline requires dataLab — a phase this
        // build cannot machine-observe yet. Selecting it must refuse the run
        // START with the phase named, never produce a never-conforming run.
        let review = SutraCompiler.systematicReview()
        #expect(review.requiredPhaseKinds?.contains(.dataLab) == true)
        #expect(!PhaseObservationService.observableKinds.contains(.dataLab))

        let h = try await PersonaAcceptanceHarness.make(seed: "phaseobs-refuse")
        let a = try await h.seedFact(value: "REFUSE finding \(UUID().uuidString)", hashChar: "f")
        let wsID = UUID()
        try await h.workspaces.upsert(Workspace(id: wsID, title: "Refuse Matter", template: .investigation))
        try await h.workspaces.addSource(a.fileID, to: wsID)
        try await WorkspaceMembershipDeriver(database: h.db, workspaces: h.workspaces).deriveMembership(for: wsID)
        _ = try await h.producer.backfill(at: t0)
        var created = try await h.cases.createCase(workspaceID: wsID, title: "Refuse Matter", actor: "me", at: t0)
        created = try await h.cases.includeSource(caseID: created.id, expectedRevision: created.revision,
                                                  sourceRef: a.svID.uuidString, sourceKind: .sourceVersion,
                                                  actor: "me", at: t0)
        let store = EvidenceStore(database: h.db)
        let custody = InvestigationCustodyService(
            cases: h.cases, resolver: CaseRetrievalScopeResolver(evidence: store),
            evidence: store, custody: CustodyRepository(database: h.db), database: h.db)
        let handoff = WorkProductHandoffService(cases: h.cases, findings: h.findings, closure: h.closure, custody: custody)
        // Register + activate the review protocol, then govern the matter with it.
        let registry = ProtocolRegistryRepository(database: h.db)
        let pack = try ProtocolPacks.verify(try ProtocolPacks.export(
            sutra: review, publisher: "Test Org", assurance: "organization-approved",
            key: P256.Signing.PrivateKey(), at: t0)).pack
        let registered = try await registry.importPack(pack, at: t0)
        try await registry.activate(id: registered.id, at: t0)
        let model = WorkProductHandoffModel(handoff: handoff, findings: h.findings, closure: h.closure,
                                            protocols: registry)
        await model.load(caseID: created.id)
        model.selectProtocol(sutraID: review.id)
        await model.buildFindings(actor: "me", at: t0)
        #expect(model.built == nil, "the run must be refused, not built under a never-conforming protocol")
        #expect(model.frozenSutra == nil)
        #expect(model.lastError?.contains("cannot machine-observe") == true, "\(model.lastError ?? "nil")")
        #expect(model.lastError?.contains("dataLab") == true)
    }
}
