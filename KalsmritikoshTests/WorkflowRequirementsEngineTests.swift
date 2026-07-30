//
//  WorkflowRequirementsEngineTests.swift
//  KalsmritikoshTests
//
//  PJE-005 — WorkflowRequirementsEngine: 35 tests covering outcome types,
//  requirement evaluators, validator protocol, attention-item lifecycle, and
//  lifecycle engine integration (advance + chooseBranch).
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PJE-005 — WorkflowRequirementsEngine")
struct WorkflowRequirementsEngineTests {

    private let t0 = Date(timeIntervalSince1970: 1_753_000_000)

    // MARK: - DB / engine factories

    private func makeDB() async throws -> Database {
        try await MigrationFixtureBuilder.database(atVersion: 77)
    }

    private func makeReqEngine(db: Database) -> WorkflowRequirementsEngine {
        WorkflowRequirementsEngine(repository: WorkflowRunRepository(database: db))
    }

    private func makeLifecycleEngine(
        db: Database,
        reqEngine: WorkflowRequirementsEngine? = nil
    ) -> WorkflowLifecycleEngine {
        WorkflowLifecycleEngine(
            repository: WorkflowRunRepository(database: db),
            requirementsEngine: reqEngine)
    }

    // MARK: - Workflow package helpers

    private func makePackage(
        appID: ApplicationDefinitionID,
        wfID: WorkflowDefinitionID,
        steps: [PersonaWorkflowStepDefinition]
    ) throws -> (ResolvedPersonaApplicationPackage, WorkflowDefinitionID) {
        let termID = TerminologyDefinitionID(rawValue: "com.req.test.term")
        let app = PersonaApplicationDefinition(id: appID, version: 1, label: "Req Test App")
        let wfDef = PersonaWorkflowDefinition(
            id: wfID, version: 1, schemaVersion: 1, label: "Req Test WF", steps: steps)
        let validated = try WorkflowDefinitionCompiler().compile(wfDef)
        let term = PersonaTerminologyDefinition(
            id: termID, version: 1, applicationID: appID, labels: [:])
        let pkg = ResolvedPersonaApplicationPackage(
            applicationKey: RegistryKey(id: appID, version: 1),
            application: app,
            toolKeys: [], tools: [],
            workflowKeys: [RegistryKey(id: wfID, version: 1)],
            workflows: [validated],
            terminologyKey: RegistryKey(id: termID, version: 1),
            terminology: term,
            objectSchemaKeys: [], objectSchemas: [],
            workProductKeys: [], workProducts: [],
            validatorKeys: [], validators: [],
            automationKeys: [], automations: [])
        return (pkg, wfID)
    }

    private func insertWorkspace(_ db: Database, id: UUID) async throws {
        try await db.exec("""
        INSERT INTO workspaces (id, title, template_type, created_at, updated_at)
        VALUES (?,?,?,?,?);
        """, [.uuid(id), .text("Test WS"), .text("general"),
              .real(t0.timeIntervalSince1970), .real(t0.timeIntervalSince1970)])
    }

    /// Create + start a run. Returns the post-start aggregate and the repo.
    private func createAndStartRun(
        db: Database,
        steps: [PersonaWorkflowStepDefinition],
        suffix: String
    ) async throws -> (ReopenedWorkflowRun, WorkflowRunRepository) {
        let appID = ApplicationDefinitionID(rawValue: "com.req.test.\(suffix)")
        let wfID  = WorkflowDefinitionID(rawValue: "com.req.test.wf.\(suffix)")
        let (pkg, _) = try makePackage(appID: appID, wfID: wfID, steps: steps)
        let repo = WorkflowRunRepository(database: db)
        let wsID = UUID()
        try await insertWorkspace(db, id: wsID)
        let created = try await repo.createRun(
            package: pkg, selectedWorkflowID: wfID,
            workspaceID: wsID, title: nil, parentRunID: nil,
            actorKind: .system, actorIdentifier: nil, now: t0)
        let lce = WorkflowLifecycleEngine(repository: repo)
        let started = try await lce.start(runID: created.run.id, actor: .system, now: t0)
        return (started, repo)
    }

    /// entry (.form) → closure, parameterised.
    private func twoSteps(
        reqs: [PersonaWorkflowRequirement] = [],
        vals: [PersonaWorkflowValidation] = [],
        arts: [PersonaWorkflowArtifactDefinition] = [],
        scopeReq: WorkflowSensitiveScopeRequirement? = nil
    ) -> [PersonaWorkflowStepDefinition] {
        let doneID = StepDefinitionID(rawValue: "step.done")
        let entry = PersonaWorkflowStepDefinition(
            id: StepDefinitionID(rawValue: "step.entry"),
            kind: .form, label: "Entry", isEntry: true,
            transitions: [WorkflowTransitionDefinition(label: "next", targetStepID: doneID)],
            requirements: reqs, validations: vals, artifacts: arts, sensitiveScope: scopeReq)
        let done = PersonaWorkflowStepDefinition(
            id: doneID, kind: .closure, label: "Done", isTerminal: true)
        return [entry, done]
    }

    /// decision → closure, parameterised.
    private func decisionSteps(
        reqs: [PersonaWorkflowRequirement] = [],
        vals: [PersonaWorkflowValidation] = [],
        arts: [PersonaWorkflowArtifactDefinition] = []
    ) -> [PersonaWorkflowStepDefinition] {
        let decID  = StepDefinitionID(rawValue: "step.dec")
        let doneID = StepDefinitionID(rawValue: "step.done")
        let dec = PersonaWorkflowStepDefinition(
            id: decID, kind: .decision, label: "Decide", isEntry: true,
            transitions: [
                WorkflowTransitionDefinition(label: "yes", targetStepID: doneID),
                WorkflowTransitionDefinition(label: "no", targetStepID: doneID)],
            requirements: reqs, validations: vals, artifacts: arts,
            decisionBranches: ["yes", "no"])
        let done = PersonaWorkflowStepDefinition(
            id: doneID, kind: .closure, label: "Done", isTerminal: true)
        return [dec, done]
    }

    // MARK: - Stub validators

    private struct PassingValidator: WorkflowValidatorExecuting, Sendable {
        let validatorID: String
        func execute(context: WorkflowValidationContext) async throws -> WorkflowValidationResult { .pass }
    }

    private struct FailingValidator: WorkflowValidatorExecuting, Sendable {
        let validatorID: String
        let detail: String?
        func execute(context: WorkflowValidationContext) async throws -> WorkflowValidationResult {
            .fail(detail: detail)
        }
    }

    private struct ThrowingValidator: WorkflowValidatorExecuting, Sendable {
        let validatorID: String
        func execute(context: WorkflowValidationContext) async throws -> WorkflowValidationResult {
            throw WorkflowLifecycleError.invalidJSONPayload
        }
    }

    // MARK: - Group 1: Outcome type tests (10 tests)

    @Test("WorkflowRequirementOutcome.requirementID returns correct ID for every case")
    func requirementOutcome_requirementID() {
        #expect(WorkflowRequirementOutcome.satisfied(requirementID: "r1").requirementID == "r1")
        #expect(WorkflowRequirementOutcome
            .failed(requirementID: "r2", label: "L", isBlocking: true, detail: nil).requirementID == "r2")
        #expect(WorkflowRequirementOutcome.skipped(requirementID: "r3", reason: nil).requirementID == "r3")
    }

    @Test("WorkflowRequirementOutcome.isFailed is true only for .failed")
    func requirementOutcome_isFailed() {
        #expect(WorkflowRequirementOutcome.satisfied(requirementID: "r").isFailed == false)
        #expect(WorkflowRequirementOutcome.skipped(requirementID: "r", reason: nil).isFailed == false)
        #expect(WorkflowRequirementOutcome
            .failed(requirementID: "r", label: "L", isBlocking: false, detail: nil).isFailed == true)
    }

    @Test("WorkflowRequirementOutcome.isBlockingFailed distinguishes blocking from advisory")
    func requirementOutcome_isBlockingFailed() {
        #expect(WorkflowRequirementOutcome
            .failed(requirementID: "r", label: "L", isBlocking: true, detail: nil).isBlockingFailed == true)
        #expect(WorkflowRequirementOutcome
            .failed(requirementID: "r", label: "L", isBlocking: false, detail: nil).isBlockingFailed == false)
        #expect(WorkflowRequirementOutcome.satisfied(requirementID: "r").isBlockingFailed == false)
    }

    @Test("WorkflowValidationOutcome accessors work for all three cases")
    func validationOutcome_accessors() {
        #expect(WorkflowValidationOutcome.passed(validationID: "v1").validationID == "v1")
        #expect(WorkflowValidationOutcome.passed(validationID: "v1").isFailed == false)
        #expect(WorkflowValidationOutcome.passed(validationID: "v1").isBlockingFailed == false)
        #expect(WorkflowValidationOutcome
            .failed(validationID: "v2", label: "L", isBlocking: true, detail: nil).isBlockingFailed == true)
        #expect(WorkflowValidationOutcome
            .failed(validationID: "v2", label: "L", isBlocking: false, detail: nil).isBlockingFailed == false)
        #expect(WorkflowValidationOutcome.skipped(validationID: "v3", reason: nil).isFailed == false)
    }

    @Test("WorkflowRequirementsEvaluation.hasBlockingFailure true on blocking requirement")
    func evaluation_hasBlockingFailure_blockingReq() {
        let eval = WorkflowRequirementsEvaluation(
            requirementOutcomes: [.failed(requirementID: "r", label: "L", isBlocking: true, detail: nil)],
            validationOutcomes: [])
        #expect(eval.hasBlockingFailure == true)
        #expect(eval.hasAnyFailure == true)
    }

    @Test("WorkflowRequirementsEvaluation.hasBlockingFailure true on blocking validation")
    func evaluation_hasBlockingFailure_blockingVal() {
        let eval = WorkflowRequirementsEvaluation(
            requirementOutcomes: [],
            validationOutcomes: [.failed(validationID: "v", label: "L", isBlocking: true, detail: nil)])
        #expect(eval.hasBlockingFailure == true)
    }

    @Test("WorkflowRequirementsEvaluation.hasBlockingFailure false for advisory failures")
    func evaluation_hasBlockingFailure_falseForAdvisory() {
        let eval = WorkflowRequirementsEvaluation(
            requirementOutcomes: [.failed(requirementID: "r", label: "L", isBlocking: false, detail: nil)],
            validationOutcomes: [.failed(validationID: "v", label: "L", isBlocking: false, detail: nil)])
        #expect(eval.hasBlockingFailure == false)
        #expect(eval.hasAnyFailure == true)
    }

    @Test("WorkflowRequirementsEvaluation is clean when all satisfied or skipped")
    func evaluation_clean_whenSatisfiedOrSkipped() {
        let eval = WorkflowRequirementsEvaluation(
            requirementOutcomes: [
                .satisfied(requirementID: "r1"),
                .skipped(requirementID: "r2", reason: nil)],
            validationOutcomes: [.passed(validationID: "v1")])
        #expect(eval.hasBlockingFailure == false)
        #expect(eval.hasAnyFailure == false)
    }

    @Test("WorkflowRequirementsEvaluation is clean when empty")
    func evaluation_clean_whenEmpty() {
        let eval = WorkflowRequirementsEvaluation(requirementOutcomes: [], validationOutcomes: [])
        #expect(eval.hasBlockingFailure == false)
        #expect(eval.hasAnyFailure == false)
    }

    @Test("WorkflowValidationResult static factories produce correct values")
    func validationResult_factories() {
        #expect(WorkflowValidationResult.pass.passed == true)
        #expect(WorkflowValidationResult.pass.detail == nil)
        #expect(WorkflowValidationResult.pass(detail: "ok").passed == true)
        #expect(WorkflowValidationResult.pass(detail: "ok").detail == "ok")
        #expect(WorkflowValidationResult.fail().passed == false)
        #expect(WorkflowValidationResult.fail(detail: "bad").detail == "bad")
    }

    // MARK: - Group 2: Pure evaluator tests (8 tests)

    @Test("evaluate() on step with no requirements/validations returns empty evaluation")
    func evaluate_emptyStep_empty() async throws {
        let db = try await makeDB()
        let engine = makeReqEngine(db: db)
        let steps = twoSteps()
        let (started, _) = try await createAndStartRun(db: db, steps: steps, suffix: "ev1")
        let eval = try await engine.evaluate(stepDefinition: steps[0], aggregate: started)
        #expect(eval.requirementOutcomes.isEmpty)
        #expect(eval.validationOutcomes.isEmpty)
    }

    @Test("humanDecisionRecorded fails when no decision has been recorded on current step")
    func evaluate_humanDecision_failsWithNoDecision() async throws {
        let db = try await makeDB()
        let engine = makeReqEngine(db: db)
        let req = PersonaWorkflowRequirement(
            id: "req.hd", kind: .humanDecisionRecorded, label: "Decision required", isBlocking: true)
        let steps = twoSteps(reqs: [req])
        let (started, _) = try await createAndStartRun(db: db, steps: steps, suffix: "ev2")
        let eval = try await engine.evaluate(stepDefinition: steps[0], aggregate: started)
        #expect(eval.requirementOutcomes.count == 1)
        #expect(eval.requirementOutcomes[0].isBlockingFailed == true)
    }

    @Test("humanDecisionRecorded satisfied after a humanDecision is recorded")
    func evaluate_humanDecision_satisfiedAfterRecording() async throws {
        let db = try await makeDB()
        let reqEngine = makeReqEngine(db: db)
        let req = PersonaWorkflowRequirement(
            id: "req.hd", kind: .humanDecisionRecorded, label: "Decision required", isBlocking: true)
        let steps = decisionSteps(reqs: [req])
        let (started, repo) = try await createAndStartRun(db: db, steps: steps, suffix: "ev3")
        let lce = WorkflowLifecycleEngine(repository: repo)
        _ = try await lce.requestHumanDecision(runID: started.run.id, actor: .system, now: t0)
        let afterDecision = try await lce.recordHumanDecision(
            runID: started.run.id,
            decisionKey: "choice", selectedOption: "yes", rationale: nil,
            actor: try WorkflowLifecycleActor.human(identifier: "tester"), now: t0)

        let eval = try await reqEngine.evaluate(stepDefinition: steps[0], aggregate: afterDecision)
        #expect(eval.requirementOutcomes.count == 1)
        if case .satisfied = eval.requirementOutcomes[0] { } else {
            Issue.record("Expected .satisfied, got \(eval.requirementOutcomes[0])")
        }
    }

    @Test("sensitiveScopeSatisfied satisfied when step declares no sensitive scope requirement")
    func evaluate_sensitiveScope_satisfiedWithNoScopeReq() async throws {
        let db = try await makeDB()
        let engine = makeReqEngine(db: db)
        let req = PersonaWorkflowRequirement(
            id: "req.sc", kind: .sensitiveScopeSatisfied, label: "Scope", isBlocking: true)
        let steps = twoSteps(reqs: [req], scopeReq: nil)
        let (started, _) = try await createAndStartRun(db: db, steps: steps, suffix: "ev4")
        let eval = try await engine.evaluate(stepDefinition: steps[0], aggregate: started, scope: nil)
        if case .satisfied = eval.requirementOutcomes[0] { } else {
            Issue.record("Expected .satisfied, got \(eval.requirementOutcomes[0])")
        }
    }

    @Test("sensitiveScopeSatisfied fails when step declares purpose but scope argument is nil")
    func evaluate_sensitiveScope_failsWhenScopeNil() async throws {
        let db = try await makeDB()
        let engine = makeReqEngine(db: db)
        let req = PersonaWorkflowRequirement(
            id: "req.sc", kind: .sensitiveScopeSatisfied, label: "Scope", isBlocking: true)
        let steps = twoSteps(reqs: [req],
                             scopeReq: WorkflowSensitiveScopeRequirement(purposes: [.retrieval]))
        let (started, _) = try await createAndStartRun(db: db, steps: steps, suffix: "ev5")
        let eval = try await engine.evaluate(stepDefinition: steps[0], aggregate: started, scope: nil)
        #expect(eval.requirementOutcomes[0].isBlockingFailed == true)
    }

    @Test("sensitiveScopeSatisfied satisfied when scope.purpose is in the declared set")
    func evaluate_sensitiveScope_satisfiedWhenPurposeMatches() async throws {
        let db = try await makeDB()
        let engine = makeReqEngine(db: db)
        let req = PersonaWorkflowRequirement(
            id: "req.sc", kind: .sensitiveScopeSatisfied, label: "Scope", isBlocking: true)
        let steps = twoSteps(reqs: [req],
                             scopeReq: WorkflowSensitiveScopeRequirement(purposes: [.retrieval]))
        let (started, _) = try await createAndStartRun(db: db, steps: steps, suffix: "ev6")
        let scope = SensitiveScope(
            workspaceID: started.run.workspaceID,
            maximumSensitivity: .publicLevel,
            permitsPrivilegedMaterial: false,
            purpose: .retrieval)
        let eval = try await engine.evaluate(stepDefinition: steps[0], aggregate: started, scope: scope)
        if case .satisfied = eval.requirementOutcomes[0] { } else {
            Issue.record("Expected .satisfied, got \(eval.requirementOutcomes[0])")
        }
    }

    @Test("artifactGenerated satisfied when no required artifacts are declared in the step")
    func evaluate_artifactGenerated_satisfiedWhenNoRequired() async throws {
        let db = try await makeDB()
        let engine = makeReqEngine(db: db)
        let req = PersonaWorkflowRequirement(
            id: "req.art", kind: .artifactGenerated, label: "Artifact", isBlocking: true)
        let optArt = PersonaWorkflowArtifactDefinition(id: "art.opt", label: "Optional", isRequired: false)
        let steps = twoSteps(reqs: [req], arts: [optArt])
        let (started, _) = try await createAndStartRun(db: db, steps: steps, suffix: "ev7")
        let eval = try await engine.evaluate(stepDefinition: steps[0], aggregate: started)
        if case .satisfied = eval.requirementOutcomes[0] { } else {
            Issue.record("Expected .satisfied, got \(eval.requirementOutcomes[0])")
        }
    }

    @Test("deferred requirement kinds return .skipped (workspace nil, executor-gated, retrieval-gated)")
    func evaluate_deferredKinds_returnSkipped() async throws {
        let db = try await makeDB()
        let engine = makeReqEngine(db: db)  // workspaces: nil
        let steps = twoSteps()
        let (started, _) = try await createAndStartRun(db: db, steps: steps, suffix: "ev8")

        let kinds: [(WorkflowRequirementKind, String)] = [
            (.evidenceReviewed, "req.er"),
            (.formFieldCompleted, "req.ff"),
            (.methodResultPresent, "req.mr"),
            (.canonicalObjectLinked, "req.col"),
            (.evidenceSelected, "req.es")
        ]
        for (kind, id) in kinds {
            let req = PersonaWorkflowRequirement(id: id, kind: kind, label: "L", isBlocking: true)
            let stepWithReq = PersonaWorkflowStepDefinition(
                id: StepDefinitionID(rawValue: "step.entry"),
                kind: .form, label: "Entry", isEntry: true,
                transitions: [WorkflowTransitionDefinition(
                    label: "next", targetStepID: StepDefinitionID(rawValue: "step.done"))],
                requirements: [req])
            let eval = try await engine.evaluate(stepDefinition: stepWithReq, aggregate: started)
            if case .skipped = eval.requirementOutcomes[0] { } else {
                Issue.record("Expected .skipped for \(kind), got \(eval.requirementOutcomes[0])")
            }
        }
    }

    // MARK: - Group 3: Validator protocol tests (5 tests)

    @Test("Unregistered validator produces .skipped outcome and does not throw")
    func validator_unregistered_producesSkipped() async throws {
        let db = try await makeDB()
        let engine = makeReqEngine(db: db)
        let val = PersonaWorkflowValidation(
            id: "val.1", validatorID: "v.missing", label: "V", isBlocking: true)
        let steps = twoSteps(vals: [val])
        let (started, _) = try await createAndStartRun(db: db, steps: steps, suffix: "vl1")
        let eval = try await engine.evaluate(stepDefinition: steps[0], aggregate: started)
        if case .skipped = eval.validationOutcomes[0] { } else {
            Issue.record("Expected .skipped, got \(eval.validationOutcomes[0])")
        }
        #expect(eval.hasBlockingFailure == false)
    }

    @Test("Registered passing validator produces .passed outcome")
    func validator_passing_producesPassed() async throws {
        let db = try await makeDB()
        let engine = makeReqEngine(db: db)
        await engine.registerExecutor(PassingValidator(validatorID: "v.pass"))
        let val = PersonaWorkflowValidation(
            id: "val.1", validatorID: "v.pass", label: "V", isBlocking: true)
        let steps = twoSteps(vals: [val])
        let (started, _) = try await createAndStartRun(db: db, steps: steps, suffix: "vl2")
        let eval = try await engine.evaluate(stepDefinition: steps[0], aggregate: started)
        if case .passed = eval.validationOutcomes[0] { } else {
            Issue.record("Expected .passed, got \(eval.validationOutcomes[0])")
        }
        #expect(eval.hasBlockingFailure == false)
    }

    @Test("Registered blocking-fail validator produces isBlockingFailed outcome")
    func validator_blockingFail_isBlockingFailed() async throws {
        let db = try await makeDB()
        let engine = makeReqEngine(db: db)
        await engine.registerExecutor(FailingValidator(validatorID: "v.failb", detail: nil))
        let val = PersonaWorkflowValidation(
            id: "val.1", validatorID: "v.failb", label: "V", isBlocking: true)
        let steps = twoSteps(vals: [val])
        let (started, _) = try await createAndStartRun(db: db, steps: steps, suffix: "vl3")
        let eval = try await engine.evaluate(stepDefinition: steps[0], aggregate: started)
        #expect(eval.validationOutcomes[0].isBlockingFailed == true)
        #expect(eval.hasBlockingFailure == true)
    }

    @Test("Registered non-blocking fail validator produces advisory failed outcome")
    func validator_nonBlockingFail_isAdvisory() async throws {
        let db = try await makeDB()
        let engine = makeReqEngine(db: db)
        await engine.registerExecutor(FailingValidator(validatorID: "v.faila", detail: "reason"))
        let val = PersonaWorkflowValidation(
            id: "val.1", validatorID: "v.faila", label: "V", isBlocking: false)
        let steps = twoSteps(vals: [val])
        let (started, _) = try await createAndStartRun(db: db, steps: steps, suffix: "vl4")
        let eval = try await engine.evaluate(stepDefinition: steps[0], aggregate: started)
        #expect(eval.validationOutcomes[0].isFailed == true)
        #expect(eval.validationOutcomes[0].isBlockingFailed == false)
        #expect(eval.hasAnyFailure == true)
        #expect(eval.hasBlockingFailure == false)
    }

    @Test("Throwing validator produces .failed outcome; evaluate() does not rethrow")
    func validator_throws_producesFailedNotRethrown() async throws {
        let db = try await makeDB()
        let engine = makeReqEngine(db: db)
        await engine.registerExecutor(ThrowingValidator(validatorID: "v.throw"))
        let val = PersonaWorkflowValidation(
            id: "val.1", validatorID: "v.throw", label: "V", isBlocking: true)
        let steps = twoSteps(vals: [val])
        let (started, _) = try await createAndStartRun(db: db, steps: steps, suffix: "vl5")
        let eval = try await engine.evaluate(stepDefinition: steps[0], aggregate: started)
        // evaluate() must not throw; validator error becomes .failed
        #expect(eval.validationOutcomes[0].isFailed == true)
    }

    // MARK: - Group 4: Lifecycle engine integration (12 tests)

    @Test("advance without requirementsEngine works unchanged (backwards compatible)")
    func lifecycle_noReqEngine_advanceUnchanged() async throws {
        let db = try await makeDB()
        let steps = twoSteps()
        let (started, repo) = try await createAndStartRun(db: db, steps: steps, suffix: "lc1")
        let engine = WorkflowLifecycleEngine(repository: repo)
        let result = try await engine.advance(
            runID: started.run.id, selector: .label("next"), actor: .system, now: t0)
        #expect(result.run.status == .completed)
    }

    @Test("advance throws blockingRequirementNotMet when blocking requirement fails; run does not advance")
    func lifecycle_blockingReq_throwsAndDoesNotAdvance() async throws {
        let db = try await makeDB()
        let req = PersonaWorkflowRequirement(
            id: "req.art", kind: .artifactGenerated, label: "Required artifact", isBlocking: true)
        let art = PersonaWorkflowArtifactDefinition(id: "art.1", label: "Art", isRequired: true)
        let steps = twoSteps(reqs: [req], arts: [art])
        let (started, repo) = try await createAndStartRun(db: db, steps: steps, suffix: "lc2")
        let reqEngine = makeReqEngine(db: db)
        let engine = makeLifecycleEngine(db: db, reqEngine: reqEngine)

        do {
            _ = try await engine.advance(
                runID: started.run.id, selector: .label("next"), actor: .system, now: t0)
            Issue.record("Expected blockingRequirementNotMet")
        } catch WorkflowLifecycleError.blockingRequirementNotMet(let stepID, let reqID, _) {
            #expect(stepID.rawValue == "step.entry")
            #expect(reqID == "req.art")
        }
        let after = try await repo.fetchRun(started.run.id)
        #expect(after.run.status == .active)
        #expect(after.run.revision == started.run.revision)
    }

    @Test("advance with advisory (non-blocking) requirement failure still completes the transition")
    func lifecycle_advisoryReq_advanceSucceeds() async throws {
        let db = try await makeDB()
        let req = PersonaWorkflowRequirement(
            id: "req.art", kind: .artifactGenerated, label: "Advisory artifact", isBlocking: false)
        let art = PersonaWorkflowArtifactDefinition(id: "art.1", label: "Art", isRequired: true)
        let steps = twoSteps(reqs: [req], arts: [art])
        let (started, _) = try await createAndStartRun(db: db, steps: steps, suffix: "lc3")
        let reqEngine = makeReqEngine(db: db)
        let engine = makeLifecycleEngine(db: db, reqEngine: reqEngine)

        let result = try await engine.advance(
            runID: started.run.id, selector: .label("next"), actor: .system, now: t0)
        #expect(result.run.status == .completed)
    }

    @Test("advance with advisory failure creates an attention item in the DB")
    func lifecycle_advisoryReq_createsAttentionItem() async throws {
        let db = try await makeDB()
        let req = PersonaWorkflowRequirement(
            id: "req.adv", kind: .artifactGenerated, label: "Advisory art", isBlocking: false)
        let art = PersonaWorkflowArtifactDefinition(id: "art.adv", label: "Art", isRequired: true)
        let steps = twoSteps(reqs: [req], arts: [art])
        let (started, repo) = try await createAndStartRun(db: db, steps: steps, suffix: "lc4")
        let reqEngine = makeReqEngine(db: db)
        let engine = makeLifecycleEngine(db: db, reqEngine: reqEngine)
        _ = try await engine.advance(
            runID: started.run.id, selector: .label("next"), actor: .system, now: t0)

        let after = try await repo.fetchRun(started.run.id)
        let items = after.attentionItems.filter { $0.sourceID == "req.adv" }
        #expect(items.count == 1)
        #expect(items[0].severity == .advisory)
        #expect(items[0].status == .open)
        #expect(items[0].sourceKind == .requirement)
    }

    @Test("advance throws blockingValidationNotPassed when blocking validator fails")
    func lifecycle_blockingVal_throws() async throws {
        let db = try await makeDB()
        let val = PersonaWorkflowValidation(
            id: "val.gate", validatorID: "v.gate", label: "Gate", isBlocking: true)
        let steps = twoSteps(vals: [val])
        let (started, _) = try await createAndStartRun(db: db, steps: steps, suffix: "lc5")
        let reqEngine = makeReqEngine(db: db)
        await reqEngine.registerExecutor(FailingValidator(validatorID: "v.gate", detail: "fail"))
        let engine = makeLifecycleEngine(db: db, reqEngine: reqEngine)

        do {
            _ = try await engine.advance(
                runID: started.run.id, selector: .label("next"), actor: .system, now: t0)
            Issue.record("Expected blockingValidationNotPassed")
        } catch WorkflowLifecycleError.blockingValidationNotPassed(_, let valID, _) {
            #expect(valID == "val.gate")
        }
    }

    @Test("blocking failure does NOT create attention items")
    func lifecycle_blockingFailure_noAttentionItem() async throws {
        let db = try await makeDB()
        let req = PersonaWorkflowRequirement(
            id: "req.block", kind: .artifactGenerated, label: "Block", isBlocking: true)
        let art = PersonaWorkflowArtifactDefinition(id: "art.b", label: "Art", isRequired: true)
        let steps = twoSteps(reqs: [req], arts: [art])
        let (started, repo) = try await createAndStartRun(db: db, steps: steps, suffix: "lc6")
        let reqEngine = makeReqEngine(db: db)
        let engine = makeLifecycleEngine(db: db, reqEngine: reqEngine)
        _ = try? await engine.advance(
            runID: started.run.id, selector: .label("next"), actor: .system, now: t0)

        let after = try await repo.fetchRun(started.run.id)
        let items = after.attentionItems.filter { $0.sourceID == "req.block" }
        #expect(items.isEmpty)
    }

    @Test("advisory attention item is not duplicated on repeated applyAttentionItems calls")
    func lifecycle_advisoryItem_deduplication() async throws {
        let db = try await makeDB()
        let repo = WorkflowRunRepository(database: db)
        let reqEngine = makeReqEngine(db: db)
        let steps = twoSteps()
        let (started, _) = try await createAndStartRun(db: db, steps: steps, suffix: "lc7")

        let failEval = WorkflowRequirementsEvaluation(
            requirementOutcomes: [.failed(requirementID: "req.dup", label: "Dup", isBlocking: false, detail: nil)],
            validationOutcomes: [])

        // First call — creates the item
        await reqEngine.applyAttentionItems(
            evaluation: failEval,
            runID: started.run.id,
            stepRunID: started.run.currentStepRunID,
            initialAggregate: started,
            actor: .system, now: t0)

        let after1 = try await repo.fetchRun(started.run.id)
        #expect(after1.attentionItems.filter { $0.sourceID == "req.dup" }.count == 1)

        // Second call with same failing evaluation — must NOT create a second item
        await reqEngine.applyAttentionItems(
            evaluation: failEval,
            runID: started.run.id,
            stepRunID: started.run.currentStepRunID,
            initialAggregate: after1,
            actor: .system, now: t0)

        let after2 = try await repo.fetchRun(started.run.id)
        #expect(after2.attentionItems.filter { $0.sourceID == "req.dup" }.count == 1)
    }

    @Test("attention item is resolved when a satisfied evaluation is applied for that requirement")
    func lifecycle_attentionItem_resolvedWhenSatisfied() async throws {
        let db = try await makeDB()
        let repo = WorkflowRunRepository(database: db)
        let reqEngine = makeReqEngine(db: db)
        let steps = twoSteps()
        let (started, _) = try await createAndStartRun(db: db, steps: steps, suffix: "lc8")

        // Create an open attention item
        let failEval = WorkflowRequirementsEvaluation(
            requirementOutcomes: [.failed(requirementID: "req.res", label: "Resolve", isBlocking: false, detail: nil)],
            validationOutcomes: [])
        await reqEngine.applyAttentionItems(
            evaluation: failEval,
            runID: started.run.id,
            stepRunID: started.run.currentStepRunID,
            initialAggregate: started,
            actor: .system, now: t0)

        let after1 = try await repo.fetchRun(started.run.id)
        #expect(after1.attentionItems.filter { $0.status == .open }.count == 1)

        // Apply satisfied evaluation — should resolve the item
        let satEval = WorkflowRequirementsEvaluation(
            requirementOutcomes: [.satisfied(requirementID: "req.res")],
            validationOutcomes: [])
        await reqEngine.applyAttentionItems(
            evaluation: satEval,
            runID: started.run.id,
            stepRunID: started.run.currentStepRunID,
            initialAggregate: after1,
            actor: .system, now: t0)

        let after2 = try await repo.fetchRun(started.run.id)
        let open     = after2.attentionItems.filter { $0.sourceID == "req.res" && $0.status == .open }
        let resolved = after2.attentionItems.filter { $0.sourceID == "req.res" && $0.status == .resolved }
        #expect(open.count == 0)
        #expect(resolved.count == 1)
    }

    @Test("chooseBranch throws blockingRequirementNotMet when blocking requirement fails")
    func lifecycle_chooseBranch_blockingReq_throws() async throws {
        let db = try await makeDB()
        let req = PersonaWorkflowRequirement(
            id: "req.cb", kind: .humanDecisionRecorded, label: "Decision required", isBlocking: true)
        let steps = decisionSteps(reqs: [req])
        let (started, _) = try await createAndStartRun(db: db, steps: steps, suffix: "lc9")
        let reqEngine = makeReqEngine(db: db)
        let engine = makeLifecycleEngine(db: db, reqEngine: reqEngine)

        do {
            _ = try await engine.chooseBranch(
                runID: started.run.id, branch: "yes", rationale: nil,
                actor: try WorkflowLifecycleActor.human(identifier: "user"), now: t0)
            Issue.record("Expected blockingRequirementNotMet")
        } catch WorkflowLifecycleError.blockingRequirementNotMet(_, let reqID, _) {
            #expect(reqID == "req.cb")
        }
    }

    @Test("chooseBranch with advisory requirement succeeds and creates attention item")
    func lifecycle_chooseBranch_advisoryReq_createsItem() async throws {
        let db = try await makeDB()
        let req = PersonaWorkflowRequirement(
            id: "req.cbadv", kind: .humanDecisionRecorded, label: "Advisory decision", isBlocking: false)
        let steps = decisionSteps(reqs: [req])
        let (started, repo) = try await createAndStartRun(db: db, steps: steps, suffix: "lc10")
        let reqEngine = makeReqEngine(db: db)
        let engine = makeLifecycleEngine(db: db, reqEngine: reqEngine)

        let result = try await engine.chooseBranch(
            runID: started.run.id, branch: "yes", rationale: nil,
            actor: try WorkflowLifecycleActor.human(identifier: "user"), now: t0)
        #expect(result.run.status == .completed)

        let after = try await repo.fetchRun(started.run.id)
        let items = after.attentionItems.filter { $0.sourceID == "req.cbadv" }
        #expect(items.count == 1)
        #expect(items[0].severity == .advisory)
    }

    @Test("advisory validation failure creates an attention item of kind .validation")
    func lifecycle_advisoryVal_createsValidationItem() async throws {
        let db = try await makeDB()
        let val = PersonaWorkflowValidation(
            id: "val.adv", validatorID: "v.adv", label: "Advisory validator", isBlocking: false)
        let steps = twoSteps(vals: [val])
        let (started, repo) = try await createAndStartRun(db: db, steps: steps, suffix: "lc11")
        let reqEngine = makeReqEngine(db: db)
        await reqEngine.registerExecutor(FailingValidator(validatorID: "v.adv", detail: "warn"))
        let engine = makeLifecycleEngine(db: db, reqEngine: reqEngine)
        _ = try await engine.advance(
            runID: started.run.id, selector: .label("next"), actor: .system, now: t0)

        let after = try await repo.fetchRun(started.run.id)
        let items = after.attentionItems.filter { $0.sourceID == "val.adv" }
        #expect(items.count == 1)
        #expect(items[0].sourceKind == .validation)
        #expect(items[0].severity == .advisory)
    }

    @Test("scope parameter passed to advance is forwarded to requirementsEngine.evaluate")
    func lifecycle_scopeParameter_forwarded() async throws {
        let db = try await makeDB()
        let req = PersonaWorkflowRequirement(
            id: "req.sc", kind: .sensitiveScopeSatisfied, label: "Scope", isBlocking: true)
        let steps = twoSteps(reqs: [req],
                             scopeReq: WorkflowSensitiveScopeRequirement(purposes: [.retrieval]))
        let (started, _) = try await createAndStartRun(db: db, steps: steps, suffix: "lc12")
        let reqEngine = makeReqEngine(db: db)
        let engine = makeLifecycleEngine(db: db, reqEngine: reqEngine)

        // Without scope: blocking fails
        do {
            _ = try await engine.advance(
                runID: started.run.id, selector: .label("next"),
                scope: nil, actor: .system, now: t0)
            Issue.record("Expected blockingRequirementNotMet (scope nil)")
        } catch WorkflowLifecycleError.blockingRequirementNotMet(_, let reqID, _) {
            #expect(reqID == "req.sc")
        }

        // With matching scope: advances successfully
        let db2 = try await makeDB()
        let steps2 = twoSteps(reqs: [req],
                              scopeReq: WorkflowSensitiveScopeRequirement(purposes: [.retrieval]))
        let (started2, _) = try await createAndStartRun(db: db2, steps: steps2, suffix: "lc12b")
        let engine2 = makeLifecycleEngine(db: db2, reqEngine: makeReqEngine(db: db2))
        let scope = SensitiveScope(
            workspaceID: started2.run.workspaceID,
            maximumSensitivity: .publicLevel,
            permitsPrivilegedMaterial: false,
            purpose: .retrieval)
        let result = try await engine2.advance(
            runID: started2.run.id, selector: .label("next"),
            scope: scope, actor: .system, now: t0)
        #expect(result.run.status == .completed)
    }
}
