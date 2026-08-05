//
//  InvestigationLinkageServiceTests.swift
//  KalsmritikoshTests
//
//  INV-09/10/11 — Investigation timeline + Relationship graph + Transaction & asset flow as a CASE-SCOPED
//  wrapper over the SHARED professional-method engine (no persona tables). Proves: the timeline /
//  relationship / transaction methods are the recommended set resolved from the shared registry; the shared
//  definitions carry the persona invariants (each emits NO findings and requires a human confirm review — a
//  timeline row cites its source or is labelled undated, a relationship edge cites evidence, a transaction
//  amount traces to a source); runs are case-scoped (unauthorized evidence rejected, non-linkage id refused);
//  the three gold cases; and the boundary (no forked run store). Uses the real shared ProfessionalMethodCatalog
//  + MethodRunRepository. Synthetic only.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("INV-09/10/11 — linkage methods over the shared engine")
struct InvestigationLinkageServiceTests {

    private let t0 = Date(timeIntervalSince1970: 1_767_800_000)
    private let vA = UUID(); private let vB = UUID()

    private struct StubGate: WorkflowEvidenceReferenceGating {
        func verdict(kind: WorkflowEvidenceObjectKind, canonicalObjectID: UUID, workspaceID: UUID) async -> WorkflowEvidenceGateVerdict { .permitted }
    }

    private struct Rig {
        let linkage: InvestigationLinkageService
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
        var c = try await cases.createCase(workspaceID: ws, title: "Linkage", actor: "analyst", at: t0)
        c = try await cases.includeSource(caseID: c.id, expectedRevision: c.revision, sourceRef: vA.uuidString, sourceKind: .sourceVersion, actor: "analyst", at: t0)
        let methodSvc = InvestigationMethodService(cases: cases, resolver: CaseRetrievalScopeResolver(evidence: evidence), evidence: evidence,
                                                   methodRuns: methodRuns, registry: catalog.methods, gate: StubGate())
        let linkage = InvestigationLinkageService(cases: cases, registry: catalog.methods, methods: methodSvc)
        return Rig(linkage: linkage, methodRuns: methodRuns, caseID: c.id)
    }

    private func sv(_ id: UUID, ordinal: Int = 0) -> InvestigationMethodEvidenceSpec {
        InvestigationMethodEvidenceSpec(targetKind: .sourceVersion, targetID: id, role: .supporting, ordinal: ordinal)
    }

    @Test("The recommended linkage methods are the SHARED timeline / relationship / transaction definitions")
    func recommendationsAreSharedLinkageMethods() async throws {
        let rig = try await rig()
        let ids = Set(try await rig.linkage.recommendedLinkageMethods(caseID: rig.caseID).map(\.id.rawValue))
        #expect(ids == Set(InvestigationLinkageService.linkageMethodIDs))
        #expect(ids.contains("com.kalsmritikosh.method.timeline-analysis"))
        #expect(ids.contains("com.kalsmritikosh.method.relationship-analysis"))
        #expect(ids.contains("com.kalsmritikosh.method.transaction-flow"))
        await #expect(throws: InvestigationLinkageError.self) { _ = try await rig.linkage.recommendedLinkageMethods(caseID: UUID()) }
    }

    @Test("Each linkage method emits no findings (proposal-layer) and requires a human confirm review")
    func linkageInvariants() async throws {
        let rig = try await rig()
        let defs = Dictionary(uniqueKeysWithValues: try await rig.linkage.recommendedLinkageMethods(caseID: rig.caseID).map { ($0.id.rawValue, $0) })
        let expectedReview = [
            "com.kalsmritikosh.method.timeline-analysis": "confirmInclusion",
            "com.kalsmritikosh.method.relationship-analysis": "confirmEdges",
            "com.kalsmritikosh.method.transaction-flow": "confirmFlow",
        ]
        for (id, reviewKey) in expectedReview {
            let def = try #require(defs[id])
            #expect(def.outputContract.allowedFindingKinds.isEmpty, "\(id) must emit no findings")
            #expect(def.requiredReviews.contains { $0.reviewKey == reviewKey }, "\(id) must require \(reviewKey)")
        }
    }

    @Test("A linkage run authorizes evidence against the case scope; unauthorized evidence is rejected; a non-linkage id is refused")
    func linkageRunIsCaseScoped() async throws {
        let rig = try await rig()
        let started = try await rig.linkage.startLinkageMethod(caseID: rig.caseID, methodDefinitionID: "com.kalsmritikosh.method.timeline-analysis",
                                                               evidenceSpecs: [sv(vA)], createdBy: "analyst", now: t0)
        #expect(started.run.methodDefinitionID.rawValue == "com.kalsmritikosh.method.timeline-analysis")
        #expect(started.scope.authorizedSourceVersionIDs == [vA])
        await #expect(throws: InvestigationMethodError.self) {
            _ = try await rig.linkage.startLinkageMethod(caseID: rig.caseID, methodDefinitionID: "com.kalsmritikosh.method.relationship-analysis",
                                                         evidenceSpecs: [sv(vB)], createdBy: "analyst", now: t0)
        }
        await #expect(throws: InvestigationLinkageError.self) {
            _ = try await rig.linkage.startLinkageMethod(caseID: rig.caseID, methodDefinitionID: "com.kalsmritikosh.method.five-whys",
                                                         evidenceSpecs: [sv(vA)], createdBy: "analyst", now: t0)
        }
    }

    @Test("Gold cases: a timeline, a relationship, and a transaction-flow run each start case-scoped and persist through the shared repo")
    func linkageGoldCases() async throws {
        let rig = try await rig()
        for id in InvestigationLinkageService.linkageMethodIDs {
            let run = try await rig.linkage.startLinkageMethod(caseID: rig.caseID, methodDefinitionID: id, evidenceSpecs: [sv(vA)], createdBy: "analyst", now: t0)
            #expect(run.run.methodDefinitionID.rawValue == id)
            #expect(try await rig.methodRuns.run(id: run.run.id)?.id == run.run.id)
        }
    }

    @Test("The linkage service forks no run store and names no models; it reuses the shared method engine")
    func boundary() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Kalsmritikosh/Personas/Investigator/InvestigationLinkageService.swift")
        let src = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        #expect(!src.isEmpty)
        for banned in ["CREATE TABLE", "INSERT INTO", "MethodRunRepository"] {
            #expect(!src.contains(banned), "linkage service forks state: \(banned)")
        }
        #expect(src.contains("InvestigationMethodService"))
        #expect(src.contains("com.kalsmritikosh.method.transaction-flow"))
        let lower = src.lowercased()
        for m in ["qwen", "gemma", "deepseek", "mistral", "nomic", "llama", "gpt"] { #expect(!lower.contains(m)) }
    }
}
