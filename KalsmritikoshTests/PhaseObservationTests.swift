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

    @Test("Every built-in phase kind is machine-observable; the review protocol is selectable")
    func allPhasesObservable() async throws {
        // Phase B-2 closed the last two gaps (ask via answer artifacts,
        // dataLab via dataset artifacts) — the observable set is TOTAL, so
        // no built-in protocol can be refused for unobservable phases.
        #expect(PhaseObservationService.observableKinds == Set(PersonaJobKind.allCases))

        // The systematic-review discipline (requires dataLab) now freezes as
        // a governing protocol instead of being refused.
        let review = SutraCompiler.systematicReview()
        #expect(review.requiredPhaseKinds?.contains(.dataLab) == true)

        let h = try await PersonaAcceptanceHarness.make(seed: "phaseobs-select")
        let a = try await h.seedFact(value: "SELECT finding \(UUID().uuidString)", hashChar: "a")
        let wsID = UUID()
        try await h.workspaces.upsert(Workspace(id: wsID, title: "Select Matter", template: .investigation))
        try await h.workspaces.addSource(a.fileID, to: wsID)
        try await WorkspaceMembershipDeriver(database: h.db, workspaces: h.workspaces).deriveMembership(for: wsID)
        _ = try await h.producer.backfill(at: t0)
        var created = try await h.cases.createCase(workspaceID: wsID, title: "Select Matter", actor: "me", at: t0)
        created = try await h.cases.includeSource(caseID: created.id, expectedRevision: created.revision,
                                                  sourceRef: a.svID.uuidString, sourceKind: .sourceVersion,
                                                  actor: "me", at: t0)
        let store = EvidenceStore(database: h.db)
        let custody = InvestigationCustodyService(
            cases: h.cases, resolver: CaseRetrievalScopeResolver(evidence: store),
            evidence: store, custody: CustodyRepository(database: h.db), database: h.db)
        let handoff = WorkProductHandoffService(cases: h.cases, findings: h.findings, closure: h.closure, custody: custody)
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
        #expect(model.built != nil, "\(model.lastError ?? "nil")")
        #expect(model.frozenSutra?.id == review.id, "the review protocol governs the run")
    }

    @Test("The v115 artifact ledger surfaces ask and dataLab observations; a dataLab row must point at a REAL dataset")
    func artifactLedgerObserved() async throws {
        let h = try await PersonaAcceptanceHarness.make(seed: "phaseobs-artifacts")
        let repo = CasePhaseArtifactRepository(database: h.db)
        let caseID = UUID()
        _ = try await repo.record(caseID: caseID, phase: .ask,
                                  artifactID: CasePhaseArtifactRepository.askArtifactID(caseID: caseID, question: "q"),
                                  detail: "question=abcd1234", at: t0)
        // NINTH AUDIT — a dataLab observation pointing at a nonexistent
        // dataset is REFUSED (referential truth, not a bare UUID column).
        await #expect(throws: CasePhaseArtifactRepository.CasePhaseArtifactError.self) {
            try await repo.record(caseID: caseID, phase: .dataLab, artifactID: UUID(),
                                  detail: "preset=source-inventory", at: t0)
        }
        // A REAL dataset row records normally.
        let wsID = UUID()
        try await h.workspaces.upsert(Workspace(id: wsID, title: "Obs WS", template: .investigation))
        let datasetID = UUID()
        try await h.db.exec("""
        INSERT INTO workbench_datasets (id, workspace_id, title, mode, revision, created_at, updated_at)
        VALUES (?, ?, 'Obs DS', 'advanced', 1, ?, ?);
        """, [.uuid(datasetID), .uuid(wsID), .real(t0.timeIntervalSince1970), .real(t0.timeIntervalSince1970)])
        _ = try await repo.record(caseID: caseID, phase: .dataLab, artifactID: datasetID,
                                  detail: "preset=source-inventory", at: t0)
        let service = PhaseObservationService(artifacts: repo)
        let obs = await service.observations(caseID: caseID)
        #expect(obs[.ask]?.artifactCount == 1)
        #expect(obs[.dataLab]?.artifactCount == 1)
        #expect(await service.observations(caseID: UUID()).isEmpty)
    }
}
