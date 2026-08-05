//
//  InvestigationCAPAServiceTests.swift
//  KalsmritikoshTests
//
//  INV-16 (CAPA register) + INV-17 (Effectiveness review) as a CASE-SCOPED wrapper over the SHARED
//  professional-method engine (no persona tables). Proves: the capa / effectiveness-review methods are the
//  recommended set from the shared registry; the shared definitions carry the persona invariants (each emits
//  NO findings and requires a human review — capaClosure so a CAPA is never closed autonomously,
//  effectivenessDecision so effectiveness is never declared without a decision); runs are case-scoped
//  (unauthorized evidence rejected, non-CAPA id refused); the "process deviation" gold case; and the
//  boundary. Uses the real shared ProfessionalMethodCatalog + MethodRunRepository. Synthetic only.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("INV-16/17 — CAPA + effectiveness over the shared engine")
struct InvestigationCAPAServiceTests {

    private let t0 = Date(timeIntervalSince1970: 1_767_900_000)
    private let vA = UUID(); private let vB = UUID()

    private struct StubGate: WorkflowEvidenceReferenceGating {
        func verdict(kind: WorkflowEvidenceObjectKind, canonicalObjectID: UUID, workspaceID: UUID) async -> WorkflowEvidenceGateVerdict { .permitted }
    }

    private struct Rig {
        let capa: InvestigationCAPAService
        let methodRuns: MethodRunRepository
        let caseID: UUID
    }

    private func rig() async throws -> Rig {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let ws = UUID()
        try await db.exec("INSERT INTO workspaces (id, title, created_at, updated_at) VALUES (?,?,?,?);", [.uuid(ws), .text("Matter"), .real(1), .real(1)])
        let cases = InvestigationCaseRepository(database: db)
        let evidence = EvidenceStore(database: db)
        let methodRuns = MethodRunRepository(database: db)
        let catalog = try await ProfessionalMethodCatalog.standard()
        var c = try await cases.createCase(workspaceID: ws, title: "Process deviation", actor: "analyst", at: t0)
        c = try await cases.includeSource(caseID: c.id, expectedRevision: c.revision, sourceRef: vA.uuidString, sourceKind: .sourceVersion, actor: "analyst", at: t0)
        let methodSvc = InvestigationMethodService(cases: cases, resolver: CaseRetrievalScopeResolver(evidence: evidence), evidence: evidence,
                                                   methodRuns: methodRuns, registry: catalog.methods, gate: StubGate())
        let capa = InvestigationCAPAService(cases: cases, registry: catalog.methods, methods: methodSvc)
        return Rig(capa: capa, methodRuns: methodRuns, caseID: c.id)
    }

    private func sv(_ id: UUID, ordinal: Int = 0) -> InvestigationMethodEvidenceSpec {
        InvestigationMethodEvidenceSpec(targetKind: .sourceVersion, targetID: id, role: .supporting, ordinal: ordinal)
    }

    @Test("The recommended CAPA methods are the SHARED capa / effectiveness-review definitions")
    func recommendationsAreSharedCAPAMethods() async throws {
        let rig = try await rig()
        let ids = Set(try await rig.capa.recommendedCAPAMethods(caseID: rig.caseID).map(\.id.rawValue))
        #expect(ids == Set(InvestigationCAPAService.capaMethodIDs))
        #expect(ids.contains("com.kalsmritikosh.method.capa"))
        #expect(ids.contains("com.kalsmritikosh.method.effectiveness-review"))
        await #expect(throws: InvestigationCAPAError.self) { _ = try await rig.capa.recommendedCAPAMethods(caseID: UUID()) }
    }

    @Test("Each CAPA method emits no findings and requires its human review (capaClosure / effectivenessDecision)")
    func capaInvariants() async throws {
        let rig = try await rig()
        let defs = Dictionary(uniqueKeysWithValues: try await rig.capa.recommendedCAPAMethods(caseID: rig.caseID).map { ($0.id.rawValue, $0) })
        let expected = [
            "com.kalsmritikosh.method.capa": "capaClosure",
            "com.kalsmritikosh.method.effectiveness-review": "effectivenessDecision",
        ]
        for (id, reviewKey) in expected {
            let def = try #require(defs[id])
            #expect(def.outputContract.allowedFindingKinds.isEmpty, "\(id) must emit no findings")
            #expect(def.requiredReviews.contains { $0.reviewKey == reviewKey }, "\(id) must require \(reviewKey)")
        }
    }

    @Test("A CAPA run authorizes evidence against the case scope; unauthorized evidence is rejected; a non-CAPA id is refused")
    func capaRunIsCaseScoped() async throws {
        let rig = try await rig()
        let started = try await rig.capa.startCAPAMethod(caseID: rig.caseID, methodDefinitionID: "com.kalsmritikosh.method.capa",
                                                         evidenceSpecs: [sv(vA)], createdBy: "analyst", now: t0)
        #expect(started.run.methodDefinitionID.rawValue == "com.kalsmritikosh.method.capa")
        #expect(started.scope.authorizedSourceVersionIDs == [vA])
        await #expect(throws: InvestigationMethodError.self) {
            _ = try await rig.capa.startCAPAMethod(caseID: rig.caseID, methodDefinitionID: "com.kalsmritikosh.method.effectiveness-review",
                                                   evidenceSpecs: [sv(vB)], createdBy: "analyst", now: t0)
        }
        await #expect(throws: InvestigationCAPAError.self) {
            _ = try await rig.capa.startCAPAMethod(caseID: rig.caseID, methodDefinitionID: "com.kalsmritikosh.method.five-whys",
                                                   evidenceSpecs: [sv(vA)], createdBy: "analyst", now: t0)
        }
    }

    @Test("Process deviation gold case: a CAPA run and an effectiveness-review run start case-scoped and persist")
    func processDeviationGoldCase() async throws {
        let rig = try await rig()
        for id in InvestigationCAPAService.capaMethodIDs {
            let run = try await rig.capa.startCAPAMethod(caseID: rig.caseID, methodDefinitionID: id, evidenceSpecs: [sv(vA)], createdBy: "analyst", now: t0)
            #expect(run.run.methodDefinitionID.rawValue == id)
            #expect(try await rig.methodRuns.run(id: run.run.id)?.id == run.run.id)
        }
    }

    @Test("The CAPA service forks no run store and names no models; it reuses the shared method engine")
    func boundary() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Kalsmritikosh/Personas/Investigator/InvestigationCAPAService.swift")
        let src = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        #expect(!src.isEmpty)
        for banned in ["CREATE TABLE", "INSERT INTO", "MethodRunRepository"] {
            #expect(!src.contains(banned), "CAPA service forks state: \(banned)")
        }
        #expect(src.contains("InvestigationMethodService"))
        #expect(src.contains("com.kalsmritikosh.method.capa"))
        let lower = src.lowercased()
        for m in ["qwen", "gemma", "deepseek", "mistral", "nomic", "llama", "gpt"] { #expect(!lower.contains(m)) }
    }
}
