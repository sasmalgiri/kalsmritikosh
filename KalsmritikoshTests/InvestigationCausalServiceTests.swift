//
//  InvestigationCausalServiceTests.swift
//  KalsmritikoshTests
//
//  INV-13/14/15 — the causal triad as a CASE-SCOPED wrapper over the SHARED professional-method engine (no
//  persona causal tables — the architecture forbids concrete-method-named schema). Proves: the five-whys /
//  fishbone / root-cause methods are the recommended causal set resolved from the shared registry; the
//  shared definitions carry the persona invariants (five-whys + fishbone emit NO findings → a step/bone is
//  never a confirmed cause; root-cause admits a confirmed finding ONLY behind a human rootCauseDecision
//  review → a candidate ≠ a confirmed root cause); a causal run is started case-scoped so unauthorized
//  evidence is rejected and a non-causal id is refused; the "process deviation" gold case; and the boundary
//  (no forked run store). Uses the real shared ProfessionalMethodCatalog + MethodRunRepository. Synthetic only.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("INV-13/14/15 — causal triad over the shared method engine")
struct InvestigationCausalServiceTests {

    private let t0 = Date(timeIntervalSince1970: 1_767_700_000)
    private let vA = UUID(); private let vB = UUID()

    private struct StubGate: WorkflowEvidenceReferenceGating {
        func verdict(kind: WorkflowEvidenceObjectKind, canonicalObjectID: UUID, workspaceID: UUID) async -> WorkflowEvidenceGateVerdict { .permitted }
    }

    private struct Rig {
        let causal: InvestigationCausalService
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
        let causal = InvestigationCausalService(cases: cases, registry: catalog.methods, methods: methodSvc)
        return Rig(causal: causal, methodRuns: methodRuns, caseID: c.id)
    }

    private func sv(_ id: UUID, ordinal: Int = 0) -> InvestigationMethodEvidenceSpec {
        InvestigationMethodEvidenceSpec(targetKind: .sourceVersion, targetID: id, role: .supporting, ordinal: ordinal)
    }

    // MARK: - Recommendations are the shared causal set

    @Test("The recommended causal methods are the SHARED five-whys / fishbone / root-cause definitions")
    func recommendationsAreSharedCausalMethods() async throws {
        let rig = try await rig()
        let defs = try await rig.causal.recommendedCausalMethods(caseID: rig.caseID)
        let ids = Set(defs.map(\.id.rawValue))
        #expect(ids == Set(InvestigationCausalService.causalMethodIDs))
        #expect(ids.contains("com.kalsmritikosh.method.five-whys"))
        #expect(ids.contains("com.kalsmritikosh.method.fishbone"))
        #expect(ids.contains("com.kalsmritikosh.method.root-cause"))
        await #expect(throws: InvestigationCausalError.self) { _ = try await rig.causal.recommendedCausalMethods(caseID: UUID()) }
    }

    // MARK: - The shared definitions carry the invariants

    @Test("Five Whys and Fishbone emit no findings (a step/bone is never a confirmed cause)")
    func fiveWhysAndFishboneEmitNoFindings() async throws {
        let rig = try await rig()
        let defs = try await rig.causal.recommendedCausalMethods(caseID: rig.caseID)
        let byID = Dictionary(uniqueKeysWithValues: defs.map { ($0.id.rawValue, $0) })
        #expect(byID["com.kalsmritikosh.method.five-whys"]?.outputContract.allowedFindingKinds.isEmpty == true)
        #expect(byID["com.kalsmritikosh.method.fishbone"]?.outputContract.allowedFindingKinds.isEmpty == true)
    }

    @Test("Root-Cause admits a confirmed finding only behind a human rootCauseDecision review (candidate ≠ confirmed root cause)")
    func rootCauseRequiresHumanDecision() async throws {
        let rig = try await rig()
        let root = try #require(await rig.causal.rootCauseMethod())
        #expect(root.requiredReviews.contains { $0.reviewKey == "rootCauseDecision" })
        #expect(root.outputContract.allowedFindingKinds.map(\.rawValue).contains("confirmedRootCause"))
    }

    // MARK: - Case-scoped runs

    @Test("A causal run authorizes evidence against the case scope; unauthorized evidence is rejected; a non-causal id is refused")
    func causalRunIsCaseScoped() async throws {
        let rig = try await rig()
        let started = try await rig.causal.startCausalMethod(caseID: rig.caseID, methodDefinitionID: "com.kalsmritikosh.method.five-whys",
                                                             evidenceSpecs: [sv(vA)], createdBy: "analyst", now: t0)
        #expect(started.run.methodDefinitionID.rawValue == "com.kalsmritikosh.method.five-whys")
        #expect(started.scope.authorizedSourceVersionIDs == [vA])
        // Unauthorized evidence (out of the case scope) is rejected before any run is created.
        await #expect(throws: InvestigationMethodError.self) {
            _ = try await rig.causal.startCausalMethod(caseID: rig.caseID, methodDefinitionID: "com.kalsmritikosh.method.fishbone",
                                                       evidenceSpecs: [sv(vB)], createdBy: "analyst", now: t0)
        }
        // A non-causal method id is refused by this entry.
        await #expect(throws: InvestigationCausalError.self) {
            _ = try await rig.causal.startCausalMethod(caseID: rig.caseID, methodDefinitionID: "com.kalsmritikosh.method.timeline-analysis",
                                                       evidenceSpecs: [sv(vA)], createdBy: "analyst", now: t0)
        }
    }

    // MARK: - Gold case: process deviation

    @Test("Process deviation gold case: a Five Whys run and a Root-Cause run start case-scoped and persist through the shared repo")
    func processDeviationGoldCase() async throws {
        let rig = try await rig()
        let whys = try await rig.causal.startCausalMethod(caseID: rig.caseID, methodDefinitionID: "com.kalsmritikosh.method.five-whys",
                                                          evidenceSpecs: [sv(vA)], createdBy: "analyst", now: t0)
        let root = try await rig.causal.startCausalMethod(caseID: rig.caseID, methodDefinitionID: "com.kalsmritikosh.method.root-cause",
                                                          evidenceSpecs: [sv(vA)], createdBy: "analyst", now: t0)
        // Both runs persist through the SHARED method run repository.
        #expect(try await rig.methodRuns.run(id: whys.run.id)?.id == whys.run.id)
        #expect(try await rig.methodRuns.run(id: root.run.id)?.id == root.run.id)
        // The confirmed root cause remains a human determination — the shared definition requires the review.
        let rootDef = try #require(await rig.causal.rootCauseMethod())
        #expect(rootDef.requiredReviews.contains { $0.reviewKey == "rootCauseDecision" })
    }

    // MARK: - Architecture boundary

    @Test("The causal service forks no run store and names no models; it reuses the shared method engine")
    func boundary() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Kalsmritikosh/Personas/Investigator/InvestigationCausalService.swift")
        let src = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        #expect(!src.isEmpty)
        for banned in ["CREATE TABLE", "INSERT INTO", "MethodRunRepository", "five_whys", "root_cause", "fishbone_"] {
            #expect(!src.contains(banned), "causal service forks state / names concrete-method schema: \(banned)")
        }
        #expect(src.contains("InvestigationMethodService"))                       // reuses the shared case-scoped entry
        #expect(src.contains("com.kalsmritikosh.method.root-cause"))
        let lower = src.lowercased()
        for m in ["qwen", "gemma", "deepseek", "mistral", "nomic", "llama", "gpt"] { #expect(!lower.contains(m)) }
    }
}
