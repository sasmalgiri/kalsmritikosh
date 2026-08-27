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

    @Test("Artifact observations require case, CURRENT revision, computed scope, and artifact ORIGIN; staleness un-observes")
    func artifactLedgerObserved() async throws {
        let h = try await PersonaAcceptanceHarness.make(seed: "phaseobs-artifacts")
        let repo = CasePhaseArtifactRepository(database: h.db)
        let emptyScope = RetrievalSourceScope(isActive: true, authorizedSourceVersionIDs: [])
        // A REAL case (with revision) in a real workspace — the binding target.
        let wsID = UUID()
        try await h.workspaces.upsert(Workspace(id: wsID, title: "Obs WS", template: .investigation))
        let created = try await h.cases.createCase(workspaceID: wsID, title: "Obs Case", actor: "me", at: t0)
        let caseID = created.id
        let revision = created.revision
        // ELEVENTH AUDIT — a NONEXISTENT case is refused outright.
        await #expect(throws: CasePhaseArtifactRepository.CasePhaseArtifactError.self) {
            try await repo.record(caseID: UUID(), caseRevision: 1, scope: emptyScope,
                                  phase: .ask, artifactID: UUID(), detail: "x", at: t0)
        }
        // TENTH AUDIT — an ask observation pointing at a nonexistent answer
        // (or one never locked verifiedFinal) is REFUSED.
        await #expect(throws: CasePhaseArtifactRepository.CasePhaseArtifactError.self) {
            try await repo.record(caseID: caseID, caseRevision: revision, scope: emptyScope,
                                  phase: .ask, artifactID: UUID(), detail: "question=abcd1234", at: t0)
        }
        // TWELFTH AUDIT — a GLOBAL answer (no origin) can never be case phase
        // evidence, even though it is durably committed.
        let ledger = AnswerLedgerRepository(database: h.db)
        func makeFinalAnswer(origin: UUID?) async throws -> UUID {
            let id = try await ledger.beginAnswer(question: "obs q \(UUID())", mission: nil,
                                                  originScopeID: origin, at: t0)
            _ = try await ledger.appendWorkingResult(
                answerID: id, body: "grounded body",
                citations: [], answerState: .unknown, confidence: 0.8, at: t0)
            try await ledger.markReviewReady(answerID: id, at: t0)
            try await ledger.lockVerifiedFinal(answerID: id, at: t0)
            return id
        }
        let globalAnswer = try await makeFinalAnswer(origin: nil)
        await #expect(throws: CasePhaseArtifactRepository.CasePhaseArtifactError.self) {
            try await repo.record(caseID: caseID, caseRevision: revision, scope: emptyScope,
                                  phase: .ask, artifactID: globalAnswer, detail: "q", at: t0)
        }
        // TWELFTH AUDIT — a case-A answer offered FIRST to case B is refused:
        // artifact ORIGIN determines the case, not binding order.
        let answerID = try await makeFinalAnswer(origin: caseID)
        let other = try await h.cases.createCase(workspaceID: wsID, title: "Other Case", actor: "me", at: t0)
        await #expect(throws: CasePhaseArtifactRepository.CasePhaseArtifactError.self) {
            try await repo.record(caseID: other.id, caseRevision: other.revision, scope: emptyScope,
                                  phase: .ask, artifactID: answerID, detail: "q", at: t0)
        }
        // ELEVENTH AUDIT — a STALE case revision is refused.
        await #expect(throws: CasePhaseArtifactRepository.CasePhaseArtifactError.self) {
            try await repo.record(caseID: caseID, caseRevision: revision + 7, scope: emptyScope,
                                  phase: .ask, artifactID: answerID, detail: "q", at: t0)
        }
        _ = try await repo.record(caseID: caseID, caseRevision: revision, scope: emptyScope,
                                  phase: .ask, artifactID: answerID,
                                  detail: "question=abcd1234", at: t0)
        // Same case + same state is idempotent; a DIFFERENT scope for the
        // same binding is refused (bindings are immutable).
        _ = try await repo.record(caseID: caseID, caseRevision: revision, scope: emptyScope,
                                  phase: .ask, artifactID: answerID, detail: "q", at: t0)
        await #expect(throws: CasePhaseArtifactRepository.CasePhaseArtifactError.self) {
            try await repo.record(caseID: caseID, caseRevision: revision,
                                  scope: RetrievalSourceScope(isActive: true, authorizedSourceVersionIDs: [UUID()]),
                                  phase: .ask, artifactID: answerID, detail: "q", at: t0)
        }
        // NINTH AUDIT — a dataLab observation pointing at a nonexistent
        // dataset is REFUSED (referential truth, not a bare UUID column).
        await #expect(throws: CasePhaseArtifactRepository.CasePhaseArtifactError.self) {
            try await repo.record(caseID: caseID, caseRevision: revision, scope: emptyScope,
                                  phase: .dataLab, artifactID: UUID(),
                                  detail: "preset=source-inventory", at: t0)
        }
        // TWELFTH/THIRTEENTH AUDIT — dataset origin is the CASE (v119), not
        // the workspace. A workspace-global dataset (origin NULL) is refused;
        // a dataset produced FOR case A is refused as phase evidence for a
        // SAME-WORKSPACE sibling case and for a foreign case alike.
        let foreignWS = UUID()
        try await h.workspaces.upsert(Workspace(id: foreignWS, title: "Foreign WS", template: .investigation))
        let foreignCase = try await h.cases.createCase(workspaceID: foreignWS, title: "Foreign", actor: "me", at: t0)
        let globalDataset = UUID()
        try await h.db.exec("""
        INSERT INTO workbench_datasets (id, workspace_id, title, mode, revision, created_at, updated_at)
        VALUES (?, ?, 'Global DS', 'advanced', 1, ?, ?);
        """, [.uuid(globalDataset), .uuid(wsID), .real(t0.timeIntervalSince1970), .real(t0.timeIntervalSince1970)])
        await #expect(throws: CasePhaseArtifactRepository.CasePhaseArtifactError.self) {
            try await repo.record(caseID: caseID, caseRevision: revision, scope: emptyScope,
                                  phase: .dataLab, artifactID: globalDataset, detail: "preset=x", at: t0)
        }
        let datasetID = UUID()
        try await h.db.exec("""
        INSERT INTO workbench_datasets (id, workspace_id, title, mode, revision, created_at, updated_at, origin_case_id)
        VALUES (?, ?, 'Obs DS', 'advanced', 1, ?, ?, ?);
        """, [.uuid(datasetID), .uuid(wsID), .real(t0.timeIntervalSince1970), .real(t0.timeIntervalSince1970),
              .uuid(caseID)])
        await #expect(throws: CasePhaseArtifactRepository.CasePhaseArtifactError.self) {
            try await repo.record(caseID: foreignCase.id, caseRevision: foreignCase.revision, scope: emptyScope,
                                  phase: .dataLab, artifactID: datasetID, detail: "preset=x", at: t0)
        }
        // The same-workspace sibling case ('other', created above) can NOT
        // claim case A's dataset — the workspace check alone would pass here.
        await #expect(throws: CasePhaseArtifactRepository.CasePhaseArtifactError.self) {
            try await repo.record(caseID: other.id, caseRevision: other.revision, scope: emptyScope,
                                  phase: .dataLab, artifactID: datasetID, detail: "preset=x", at: t0)
        }
        _ = try await repo.record(caseID: caseID, caseRevision: revision, scope: emptyScope,
                                  phase: .dataLab, artifactID: datasetID,
                                  detail: "preset=source-inventory", at: t0)
        let service = PhaseObservationService(artifacts: repo)
        let obs = await service.observations(caseID: caseID)
        #expect(obs[.ask]?.artifactCount == 1)
        #expect(obs[.dataLab]?.artifactCount == 1)
        #expect(await service.observations(caseID: other.id).isEmpty)
        // TWELFTH AUDIT — a scope change (revision bump) UN-observes the
        // evidence recorded under the superseded state: only current-revision
        // bindings count.
        try await h.db.exec("UPDATE investigation_cases SET revision = revision + 1 WHERE id = ?;",
                            [.uuid(caseID)])
        #expect(await service.observations(caseID: caseID).isEmpty,
                "evidence recorded under a superseded scope must not count as current")
    }

    @Test("A moved source-version set un-observes evidence and refuses new records — no revision bump needed")
    func scopeFingerprintStaleness() async throws {
        let h = try await PersonaAcceptanceHarness.make(seed: "phaseobs-fpstale")
        let repo = CasePhaseArtifactRepository(database: h.db)
        let wsID = UUID()
        try await h.workspaces.upsert(Workspace(id: wsID, title: "FP WS", template: .investigation))
        let seeded = try await h.seedFact(value: "FP fact \(UUID().uuidString)", hashChar: "c")
        var created = try await h.cases.createCase(workspaceID: wsID, title: "FP Case", actor: "me", at: t0)
        // Bind the LOGICAL source: the scope resolves to its CURRENT version
        // (V1) — a resolution that can move underneath the case WITHOUT a
        // case-revision bump (the thirteenth-audit reproduction).
        created = try await h.cases.includeSource(caseID: created.id, expectedRevision: created.revision,
                                                  sourceRef: seeded.fileID.uuidString, sourceKind: .logicalSource,
                                                  actor: "me", at: t0)
        let caseID = created.id
        let scopeV1 = RetrievalSourceScope.authorizing([seeded.svID])
        let ledger = AnswerLedgerRepository(database: h.db)
        func makeFinalAnswer() async throws -> UUID {
            let id = try await ledger.beginAnswer(question: "fp q \(UUID())", mission: nil,
                                                  originScopeID: caseID, at: t0)
            _ = try await ledger.appendWorkingResult(answerID: id, body: "grounded body",
                                                     citations: [], answerState: .unknown, confidence: 0.8, at: t0)
            try await ledger.markReviewReady(answerID: id, at: t0)
            try await ledger.lockVerifiedFinal(answerID: id, at: t0)
            return id
        }
        let answerID = try await makeFinalAnswer()
        _ = try await repo.record(caseID: caseID, caseRevision: created.revision, scope: scopeV1,
                                  phase: .ask, artifactID: answerID, detail: "q", at: t0)
        let service = PhaseObservationService(artifacts: repo)
        #expect(await service.observations(caseID: caseID)[.ask]?.artifactCount == 1)
        // THIRTEENTH AUDIT — the logical source's CURRENT version moves; the
        // case revision does NOT change. The recorded evidence must stop
        // counting (fingerprint no longer matches the authoritative current
        // scope), and a record under the superseded resolution is refused.
        try await h.db.exec("UPDATE source_versions SET is_current = 0 WHERE id = ?;", [.uuid(seeded.svID)])
        #expect(await service.observations(caseID: caseID).isEmpty,
                "evidence fingerprinted under a moved source-version set must not count")
        let answer2 = try await makeFinalAnswer()
        await #expect(throws: CasePhaseArtifactRepository.CasePhaseArtifactError.self) {
            try await repo.record(caseID: caseID, caseRevision: created.revision, scope: scopeV1,
                                  phase: .ask, artifactID: answer2, detail: "q", at: t0)
        }
    }
}
