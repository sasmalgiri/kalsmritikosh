//
//  PM004Fixtures.swift
//  KalsmritikoshTests
//
//  PM-004 — shared helpers: a v80 rig (repository + method registry + validator
//  registry + lifecycle engine), a synthetic method definition, stub validators,
//  and content-seeding that satisfies the completion gates. No concrete method.
//

import Foundation
@testable import Kalsmritikosh

// MARK: - Stub validators (deterministic, pure)

struct PM004PassingValidator: ProfessionalMethodValidating {
    let validatorID = "v.structure"
    let validatorVersion = "1"
    func validate(context: ProfessionalMethodValidationContext) async throws -> [ProfessionalMethodValidationIssue] {
        [.init(severity: .info, code: "OK", message: "structure ok", subjectKind: .run)]
    }
}
struct PM004BlockingValidator: ProfessionalMethodValidating {
    let validatorID = "v.structure"
    let validatorVersion = "1"
    func validate(context: ProfessionalMethodValidationContext) async throws -> [ProfessionalMethodValidationIssue] {
        [.init(severity: .blocking, code: "NO_ROOT", message: "no terminal cause", subjectKind: .run)]
    }
}
struct PM004EmptyValidator: ProfessionalMethodValidating {
    let validatorID = "v.structure"
    let validatorVersion = "1"
    func validate(context: ProfessionalMethodValidationContext) async throws -> [ProfessionalMethodValidationIssue] { [] }
}
struct PM004ThrowingValidator: ProfessionalMethodValidating {
    let validatorID = "v.structure"
    let validatorVersion = "1"
    struct Boom: Error {}
    func validate(context: ProfessionalMethodValidationContext) async throws -> [ProfessionalMethodValidationIssue] { throw Boom() }
}
/// Same id, DIFFERENT version — proves the gate requires the exact current version.
struct PM004UpgradedValidator: ProfessionalMethodValidating {
    let validatorID = "v.structure"
    let validatorVersion = "2"
    func validate(context: ProfessionalMethodValidationContext) async throws -> [ProfessionalMethodValidationIssue] {
        [.init(severity: .info, code: "OK", message: "ok v2", subjectKind: .run)]
    }
}

struct PM004Rig {
    let db: Database
    let url: URL
    let repo: MethodRunRepository
    let engine: ProfessionalMethodLifecycleEngine
    let scopes: SensitiveScopeRepository
    let gate: CanonicalWorkflowEvidenceReferenceGate
    let ws: UUID
    let entity: UUID
}

enum PM004Fixtures {

    static let t0 = Date(timeIntervalSince1970: 1_753_900_000)
    static let methodDefID = "com.kalsmritikosh.method.pm004"

    static func definition(version: Int = 1) -> ProfessionalMethodDefinition {
        ProfessionalMethodDefinition(
            id: ProfessionalMethodDefinitionID(rawValue: methodDefID), version: version, label: "PM-004 synthetic",
            category: .causal,
            requiredInputRoles: [MethodInputRole(rawValue: "problemStatement")],
            allowedNodeKinds: [MethodNodeKind(rawValue: "cause")],
            allowedEdgeKinds: [MethodEdgeKind(rawValue: "leadsTo")],
            requiredReviews: [MethodRequiredReview(reviewKey: "final", label: "Final review")],
            validationIdentifiers: ["v.structure"],
            outputContract: MethodOutputContract(allowedFindingKinds: [MethodFindingKind(rawValue: "candidateCause")]))
    }

    static func makeRig(
        validator: any ProfessionalMethodValidating = PM004PassingValidator(),
        definitions: [ProfessionalMethodDefinition]? = nil
    ) async throws -> PM004Rig {
        let url = PJE006CFixtures.newDatabaseURL()
        let db = try await MigrationFixtureBuilder.database(atVersion: 81, at: url)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let repo = MethodRunRepository(database: db)
        let scopes = SensitiveScopeRepository(database: db)
        let gate = CanonicalWorkflowEvidenceReferenceGate(database: db, scopeRepository: scopes, scope: nil)
        var methodBuilder = ProfessionalMethodRegistryBuilder()
        for d in (definitions ?? [definition()]) { try methodBuilder.register(d) }
        var vBuilder = ProfessionalMethodValidatorRegistryBuilder()
        try vBuilder.register(validator)
        let engine = ProfessionalMethodLifecycleEngine(
            repository: repo, registry: methodBuilder.freeze(), validators: vBuilder.freeze())
        let ws = UUID(); try await PJE007Fixtures.seedWorkspace(db, id: ws)
        let entity = try await PJE007Fixtures.seedEntity(db, in: ws)
        return PM004Rig(db: db, url: url, repo: repo, engine: engine, scopes: scopes, gate: gate, ws: ws, entity: entity)
    }

    /// Create a run and seed the content that satisfies conformance + input-role +
    /// evidence gates (one cause node, one entity link fulfilling `problemStatement`).
    /// Returns the run id; the run is left in the requested status.
    @discardableResult
    static func seedRun(
        _ rig: PM004Rig, start: Bool = true, addContent: Bool = true
    ) async throws -> UUID {
        let run = try await rig.repo.createRun(
            workspaceID: rig.ws, methodDefinitionID: ProfessionalMethodDefinitionID(rawValue: methodDefID),
            methodDefinitionVersion: 1, createdBy: "analyst", now: t0)
        if start { _ = try await rig.engine.start(runID: run.id, actor: .human("analyst"), now: t0) }
        if addContent {
            let node = MethodNode(methodRunID: run.id, nodeDefinitionKey: "problem",
                nodeKind: MethodNodeKind(rawValue: "cause"), label: "Carrier handoff", ordinal: 0,
                createdAt: t0, updatedAt: t0)
            let afterNode = try await rig.repo.addNode(node, expectedRevision: run.revision + (start ? 1 : 0), now: t0)
            let link = MethodEvidenceLink(methodRunID: run.id, targetKind: .entity, targetID: rig.entity,
                role: .supporting, inputRole: MethodInputRole(rawValue: "problemStatement"),
                ordinal: 0, addedBy: "analyst", addedAt: t0)
            _ = try await rig.repo.addEvidenceLink(link, expectedRevision: afterNode.revision, gate: rig.gate, now: t0)
        }
        return run.id
    }

    /// Current revision of a run (for chaining expectedRevision).
    static func revision(_ rig: PM004Rig, _ runID: UUID) async throws -> Int {
        try await rig.repo.run(id: runID)?.revision ?? -1
    }
}
