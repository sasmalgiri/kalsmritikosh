//
//  ProfessionalMethodValidationTests.swift
//  KalsmritikoshTests
//
//  PM-004 — the deterministic validator runtime: immutable registry, definition-
//  order execution, one atomic batch tied to the exact content revision, the
//  completion validation gate, and relaunch persistence.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PM-004 — professional-method validation", .serialized)
struct ProfessionalMethodValidationTests {

    private let t0 = PM004Fixtures.t0

    // MARK: - Registry (no DB)

    @Test("The validator registry is immutable and independent after freeze")
    func immutableRegistry() throws {
        var builder = ProfessionalMethodValidatorRegistryBuilder()
        try builder.register(PM004PassingValidator())
        let frozen = builder.freeze()
        #expect(frozen.validator(id: "v.structure") != nil)
        #expect(frozen.validator(id: "v.absent") == nil)
    }

    @Test("Blank / non-trim-stable / blank-version / duplicate validator ids are rejected")
    func registrationValidation() throws {
        struct Blank: ProfessionalMethodValidating { let validatorID=""; let validatorVersion="1"
            func validate(context: ProfessionalMethodValidationContext) async throws -> [ProfessionalMethodValidationIssue] { [] } }
        struct Untrimmed: ProfessionalMethodValidating { let validatorID=" v "; let validatorVersion="1"
            func validate(context: ProfessionalMethodValidationContext) async throws -> [ProfessionalMethodValidationIssue] { [] } }
        struct BlankVer: ProfessionalMethodValidating { let validatorID="v"; let validatorVersion=" "
            func validate(context: ProfessionalMethodValidationContext) async throws -> [ProfessionalMethodValidationIssue] { [] } }
        var b1 = ProfessionalMethodValidatorRegistryBuilder()
        #expect(throws: ProfessionalMethodValidatorRegistryError.blankID) { try b1.register(Blank()) }
        var b2 = ProfessionalMethodValidatorRegistryBuilder()
        #expect(throws: ProfessionalMethodValidatorRegistryError.notTrimStableID(" v ")) { try b2.register(Untrimmed()) }
        var b3 = ProfessionalMethodValidatorRegistryBuilder()
        #expect(throws: ProfessionalMethodValidatorRegistryError.blankVersion("v")) { try b3.register(BlankVer()) }
        var b4 = ProfessionalMethodValidatorRegistryBuilder()
        try b4.register(PM004PassingValidator())
        #expect(throws: ProfessionalMethodValidatorRegistryError.duplicateID("v.structure")) { try b4.register(PM004PassingValidator()) }
    }

    // MARK: - Validate operation

    @Test("Validation persists one atomic batch at the current content revision, +1 revision, content unchanged")
    func validateOneBatch() async throws {
        let rig = try await PM004Fixtures.makeRig()
        let runID = try await PM004Fixtures.seedRun(rig)
        let before = try #require(try await rig.repo.run(id: runID))
        let agg = try await rig.engine.validate(runID: runID, actor: .human("analyst"), now: t0)
        #expect(agg.run.revision == before.revision + 1)
        #expect(agg.run.contentRevision == before.contentRevision)
        #expect(agg.validationResults.count == 1)
        #expect(agg.validationResults[0].evaluatedContentRevision == before.contentRevision)
        #expect(agg.validationResults[0].validatorVersion == "1")
        #expect(agg.lifecycleEvents.contains { $0.action == .validationRecorded })
    }

    @Test("A validator returning no result fails and persists nothing")
    func emptyResultRejected() async throws {
        let rig = try await PM004Fixtures.makeRig(validator: PM004EmptyValidator())
        let runID = try await PM004Fixtures.seedRun(rig)
        let before = try await PM004Fixtures.revision(rig, runID)
        await #expect(throws: ProfessionalMethodLifecycleError.validatorReturnedNoResult("v.structure")) {
            _ = try await rig.engine.validate(runID: runID, actor: .human("a"), now: self.t0)
        }
        #expect(try await PM004Fixtures.revision(rig, runID) == before)
        #expect(try await rig.repo.validationResults(runID: runID).isEmpty)
    }

    @Test("A throwing validator fails closed with no persistence")
    func throwingValidatorRollsBack() async throws {
        let rig = try await PM004Fixtures.makeRig(validator: PM004ThrowingValidator())
        let runID = try await PM004Fixtures.seedRun(rig)
        let before = try await PM004Fixtures.revision(rig, runID)
        await #expect(throws: ProfessionalMethodLifecycleError.self) {
            _ = try await rig.engine.validate(runID: runID, actor: .human("a"), now: self.t0)
        }
        #expect(try await PM004Fixtures.revision(rig, runID) == before)
        #expect(try await rig.repo.validationResults(runID: runID).isEmpty)
    }

    @Test("A draft run cannot be validated")
    func draftCannotValidate() async throws {
        let rig = try await PM004Fixtures.makeRig()
        let runID = try await PM004Fixtures.seedRun(rig, start: false, addContent: false)
        await #expect(throws: ProfessionalMethodLifecycleError.self) {
            _ = try await rig.engine.validate(runID: runID, actor: .human("a"), now: self.t0)
        }
    }

    @Test("A missing required validator fails closed")
    func missingValidatorRejected() async throws {
        // Definition requires v.structure but the registry holds a different id.
        struct Other: ProfessionalMethodValidating { let validatorID="v.other"; let validatorVersion="1"
            func validate(context: ProfessionalMethodValidationContext) async throws -> [ProfessionalMethodValidationIssue] {
                [.init(severity: .info, code: "OK", message: "ok", subjectKind: .run)] } }
        let rig = try await PM004Fixtures.makeRig(validator: Other())
        let runID = try await PM004Fixtures.seedRun(rig)
        await #expect(throws: ProfessionalMethodLifecycleError.validatorNotRegistered("v.structure")) {
            _ = try await rig.engine.validate(runID: runID, actor: .human("a"), now: self.t0)
        }
    }

    // MARK: - Validation gate on completion

    @Test("A blocking validation result fails the completion gate")
    func blockingResultBlocksCompletion() async throws {
        let rig = try await PM004Fixtures.makeRig(validator: PM004BlockingValidator())
        let runID = try await PM004Fixtures.seedRun(rig)
        _ = try await rig.engine.validate(runID: runID, actor: .human("a"), now: t0)
        _ = try await rig.engine.recordReview(runID: runID, reviewKey: "final", nodeID: nil, findingID: nil,
            action: .acceptForWorkflow, comment: nil, actor: .human("boss"), now: t0)
        await #expect(throws: ProfessionalMethodLifecycleError.blockingValidation(code: "NO_ROOT")) {
            _ = try await rig.engine.complete(runID: runID, actor: .human("a"), now: self.t0)
        }
    }

    @Test("Completion without a current validation batch fails the gate")
    func missingBatchFailsCompletion() async throws {
        let rig = try await PM004Fixtures.makeRig()
        let runID = try await PM004Fixtures.seedRun(rig)
        _ = try await rig.engine.recordReview(runID: runID, reviewKey: "final", nodeID: nil, findingID: nil,
            action: .acceptForWorkflow, comment: nil, actor: .human("boss"), now: t0)
        await #expect(throws: ProfessionalMethodLifecycleError.staleValidationBatch) {
            _ = try await rig.engine.complete(runID: runID, actor: .human("a"), now: self.t0)
        }
    }

    @Test("A validation batch from a prior content revision is stale after new content")
    func staleBatchAfterContentChange() async throws {
        let rig = try await PM004Fixtures.makeRig()
        let runID = try await PM004Fixtures.seedRun(rig)
        _ = try await rig.engine.validate(runID: runID, actor: .human("a"), now: t0)
        _ = try await rig.engine.recordReview(runID: runID, reviewKey: "final", nodeID: nil, findingID: nil,
            action: .acceptForWorkflow, comment: nil, actor: .human("boss"), now: t0)
        // Add new content — content_revision advances, invalidating the batch + review.
        let rev = try await PM004Fixtures.revision(rig, runID)
        let extra = MethodNode(methodRunID: runID, nodeDefinitionKey: "k2",
            nodeKind: MethodNodeKind(rawValue: "cause"), label: "another", ordinal: 1, createdAt: t0, updatedAt: t0)
        _ = try await rig.repo.addNode(extra, expectedRevision: rev, now: t0)
        await #expect(throws: ProfessionalMethodLifecycleError.staleValidationBatch) {
            _ = try await rig.engine.complete(runID: runID, actor: .human("a"), now: self.t0)
        }
    }

    @Test("A validation batch persists exactly across a database reopen; a version drift makes it stale")
    func validationReopenAndVersionDrift() async throws {
        let rig = try await PM004Fixtures.makeRig()
        let runID = try await PM004Fixtures.seedRun(rig)
        _ = try await rig.engine.validate(runID: runID, actor: .human("a"), now: t0)
        // Reopen with a registry whose validator is the SAME id but version "2".
        let db2 = try MigrationFixtureBuilder.reopen(at: rig.url)
        let repo2 = MethodRunRepository(database: db2)
        let persisted = try await repo2.validationResults(runID: runID)
        #expect(persisted.count == 1 && persisted[0].validatorVersion == "1")   // exact persistence
        var mB = ProfessionalMethodRegistryBuilder(); try mB.register(PM004Fixtures.definition())
        var vB = ProfessionalMethodValidatorRegistryBuilder(); try vB.register(PM004UpgradedValidator())
        let engine2 = ProfessionalMethodLifecycleEngine(repository: repo2, registry: mB.freeze(), validators: vB.freeze())
        _ = try await engine2.recordReview(runID: runID, reviewKey: "final", nodeID: nil, findingID: nil,
            action: .acceptForWorkflow, comment: nil, actor: .human("boss"), now: t0)
        await #expect(throws: ProfessionalMethodLifecycleError.staleValidationBatch) {
            _ = try await engine2.complete(runID: runID, actor: .human("a"), now: self.t0)
        }
    }

    @Test("A validation subject that is not in the run fails closed")
    func validationSubjectOwnership() async throws {
        struct ForeignSubject: ProfessionalMethodValidating { let validatorID="v.structure"; let validatorVersion="1"
            func validate(context: ProfessionalMethodValidationContext) async throws -> [ProfessionalMethodValidationIssue] {
                [.init(severity: .info, code: "OK", message: "ok", subjectKind: .node, subjectID: UUID())] } }
        let rig = try await PM004Fixtures.makeRig(validator: ForeignSubject())
        let runID = try await PM004Fixtures.seedRun(rig)
        await #expect(throws: ProfessionalMethodLifecycleError.self) {
            _ = try await rig.engine.validate(runID: runID, actor: .human("a"), now: self.t0)
        }
        #expect(try await rig.repo.validationResults(runID: runID).isEmpty)
    }
}
