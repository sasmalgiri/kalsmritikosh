//
//  InvestigationMethodServiceTests.swift
//  KalsmritikoshTests
//
//  INV-01-C2 — case-scoped professional methods. Proves recommendations are SHARED catalog definitions
//  (no persona duplicates); the case-authorization decision (sourceVersion in/out of scope; unresolvable
//  kinds rejected fail-closed); that unauthorized evidence is REJECTED before any MethodRun is created
//  (atomic §14); the case∩SensitiveScope composition (§16, neither weakens the other); and that an
//  authorized run persists through the SHARED MethodRunRepository and reopens with its evidence (§15).
//  Uses the real shared registry (ProfessionalMethodCatalog.standard) + MethodRunRepository; the canonical
//  evidence gate is stubbed to drive the composition (the real gate is covered by the method-engine tests).
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("INV-01-C2 — case-scoped professional methods")
struct InvestigationMethodServiceTests {

    private let t0 = Date(timeIntervalSince1970: 1_763_000_000)
    private let vA = UUID(); private let vB = UUID()

    private struct StubGate: WorkflowEvidenceReferenceGating {
        let permit: Bool
        func verdict(kind: WorkflowEvidenceObjectKind, canonicalObjectID: UUID, workspaceID: UUID) async -> WorkflowEvidenceGateVerdict {
            permit ? .permitted : .denied(reason: "sensitive-scope-denied (test)")
        }
    }

    private struct Rig {
        let service: InvestigationMethodService
        let cases: InvestigationCaseRepository
        let methodRuns: MethodRunRepository
        let db: Database
        let ws: UUID
        let caseID: UUID
    }

    /// A ledger with one workspace + a case authorizing ONLY source version vA (an exact-version binding),
    /// and a service over the shared registry/run-repo with a stubbed gate (permit configurable).
    private func makeRig(gatePermits: Bool = true) async throws -> Rig {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let ws = UUID()
        try await db.exec("INSERT INTO workspaces (id, title, created_at, updated_at) VALUES (?,?,?,?);",
                          [.uuid(ws), .text("Matter"), .real(1), .real(1)])
        let cases = InvestigationCaseRepository(database: db)
        let evidence = EvidenceStore(database: db)
        let methodRuns = MethodRunRepository(database: db)
        let catalog = try await ProfessionalMethodCatalog.standard()
        var c = try await cases.createCase(workspaceID: ws, title: "Payment discrepancy", actor: "analyst", at: t0)
        c = try await cases.includeSource(caseID: c.id, expectedRevision: c.revision,
                                          sourceRef: vA.uuidString, sourceKind: .sourceVersion, actor: "analyst", at: t0)
        let service = InvestigationMethodService(
            cases: cases, resolver: CaseRetrievalScopeResolver(evidence: evidence), evidence: evidence,
            methodRuns: methodRuns, registry: catalog.methods, gate: StubGate(permit: gatePermits))
        return Rig(service: service, cases: cases, methodRuns: methodRuns, db: db, ws: ws, caseID: c.id)
    }

    private func methodRunCount(_ db: Database) async throws -> Int {
        Int(try await db.query("SELECT COUNT(*) FROM method_runs;", []).first?.int(0) ?? -1)
    }
    private func sv(_ id: UUID, ordinal: Int = 0) -> InvestigationMethodEvidenceSpec {
        InvestigationMethodEvidenceSpec(targetKind: .sourceVersion, targetID: id, role: .supporting, ordinal: ordinal)
    }

    // MARK: - Recommendations & shared identity

    @Test("Recommended methods are SHARED registered definitions (no persona-specific duplicates)")
    func recommendationsAreSharedDefinitions() async throws {
        let rig = try await makeRig()
        let defs = try await rig.service.recommendedMethods(caseID: rig.caseID)
        #expect(!defs.isEmpty)
        let ids = Set(defs.map(\.id.rawValue))
        #expect(ids.isSubset(of: Set(InvestigationMethodService.inv01RecommendedMethodIDs)))
        #expect(ids.contains("com.kalsmritikosh.method.timeline-analysis"))
        await #expect(throws: InvestigationMethodError.self) { _ = try await rig.service.recommendedMethods(caseID: UUID()) }
    }

    // MARK: - Authorization decision

    @Test("A sourceVersion reference is authorized in-scope, unauthorized out-of-scope; other kinds are unresolvable")
    func authorizationDecision() async throws {
        let rig = try await makeRig()
        let scope = RetrievalSourceScope.authorizing([vA])
        #expect(await rig.service.authorization(for: sv(vA), scope: scope) == .authorized(sourceVersionID: vA))
        #expect(await rig.service.authorization(for: sv(vB), scope: scope) == .unauthorized)
        let entity = InvestigationMethodEvidenceSpec(targetKind: .entity, targetID: UUID(), ordinal: 0)
        #expect(await rig.service.authorization(for: entity, scope: scope) == .unresolvable)
        let unknownBlock = InvestigationMethodEvidenceSpec(targetKind: .evidenceBlock, targetID: UUID(), ordinal: 0)
        #expect(await rig.service.authorization(for: unknownBlock, scope: scope) == .unresolvable)  // no such block
    }

    // MARK: - Rejection before create (§14 atomic)

    @Test("Unauthorized evidence is rejected before any MethodRun is created")
    func unauthorizedEvidenceRejectedAtomically() async throws {
        let rig = try await makeRig()
        await #expect(throws: InvestigationMethodError.self) {
            _ = try await rig.service.startMethod(caseID: rig.caseID,
                methodDefinitionID: "com.kalsmritikosh.method.timeline-analysis",
                evidenceSpecs: [sv(vA), sv(vB)], createdBy: "analyst", now: t0)   // B out of scope
        }
        #expect(try await methodRunCount(rig.db) == 0)   // nothing created
    }

    @Test("An unresolvable reference kind is rejected before any MethodRun is created")
    func unresolvableEvidenceRejected() async throws {
        let rig = try await makeRig()
        let entity = InvestigationMethodEvidenceSpec(targetKind: .entity, targetID: UUID(), ordinal: 0)
        await #expect(throws: InvestigationMethodError.self) {
            _ = try await rig.service.startMethod(caseID: rig.caseID,
                methodDefinitionID: "com.kalsmritikosh.method.gap-analysis",
                evidenceSpecs: [entity], createdBy: "analyst", now: t0)
        }
        #expect(try await methodRunCount(rig.db) == 0)
    }

    // MARK: - case ∩ SensitiveScope (§16)

    @Test("case-allowed + SensitiveScope-denied is denied atomically (the shared gate is not weakened)")
    func caseAllowedGateDenied() async throws {
        let rig = try await makeRig(gatePermits: false)   // gate denies (stands in for SensitiveScope denial)
        await #expect(throws: InvestigationMethodError.self) {
            _ = try await rig.service.startMethod(caseID: rig.caseID,
                methodDefinitionID: "com.kalsmritikosh.method.timeline-analysis",
                evidenceSpecs: [sv(vA)], createdBy: "analyst", now: t0)   // A is case-authorized, gate denies
        }
        #expect(try await methodRunCount(rig.db) == 0)
    }

    @Test("case-denied + SensitiveScope-denied is denied (case checked first); nothing created")
    func bothDenied() async throws {
        let rig = try await makeRig(gatePermits: false)
        await #expect(throws: InvestigationMethodError.self) {
            _ = try await rig.service.startMethod(caseID: rig.caseID,
                methodDefinitionID: "com.kalsmritikosh.method.timeline-analysis",
                evidenceSpecs: [sv(vB)], createdBy: "analyst", now: t0)
        }
        #expect(try await methodRunCount(rig.db) == 0)
    }

    // MARK: - Authorized run persists + reopens (§15)

    @Test("An authorized case-scoped method run persists through the shared repo and reopens with its evidence")
    func authorizedRunPersistsAndReopens() async throws {
        let rig = try await makeRig(gatePermits: true)
        let started = try await rig.service.startMethod(caseID: rig.caseID,
            methodDefinitionID: "com.kalsmritikosh.method.timeline-analysis",
            evidenceSpecs: [sv(vA)], createdBy: "analyst", now: t0)
        #expect(started.scope.authorizedSourceVersionIDs == [vA])
        #expect(started.run.methodDefinitionID.rawValue == "com.kalsmritikosh.method.timeline-analysis")
        // Reopen through the SHARED repository — same run, same evidence, only the authorized source.
        let reopened = try await rig.methodRuns.run(id: started.run.id)
        #expect(reopened?.id == started.run.id)
        let links = try await rig.methodRuns.evidenceLinks(runID: started.run.id)
        #expect(links.count == 1)
        #expect(links.first?.targetKind == .sourceVersion && links.first?.targetID == vA)
        #expect(!links.contains { $0.targetID == vB })
        #expect(try await methodRunCount(rig.db) == 1)
    }

    @Test("An unknown method id is rejected")
    func unknownMethodRejected() async throws {
        let rig = try await makeRig()
        await #expect(throws: InvestigationMethodError.self) {
            _ = try await rig.service.startMethod(caseID: rig.caseID, methodDefinitionID: "com.kalsmritikosh.method.does-not-exist",
                                                  evidenceSpecs: [], createdBy: "analyst", now: t0)
        }
    }
}
