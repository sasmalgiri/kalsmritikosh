//
//  PersonaJobCatalogProductionTests.swift
//  KalsmritikoshTests
//
//  #142 — proves the test-only PersonaJobCatalog gap is CLOSED: there is now a real production composition
//  and a live consumer that (1) DISCOVERS the Investigator persona, (2) ENUMERATES its real jobs, and
//  (3) ROUTES a selected job into the REAL implementation (the shipped case-scoped services). Composition
//  tests are pure; the routing test drives real services against a seeded case. Synthetic only.
//

import Testing
import Foundation
@testable import Kalsmritikosh

@Suite("#142 — production PersonaJobCatalog + live consumer", .serialized)
struct PersonaJobCatalogProductionTests {

    private let t0 = Date(timeIntervalSince1970: 1_768_400_000)

    // MARK: - Composition + discovery + enumeration (pure)

    @Test("The production catalog composes once and makes the Investigator persona discoverable")
    func productionCatalogDiscoversInvestigator() throws {
        let catalog = try PersonaJobCatalogComposer.composeProduction()
        // Discoverable as an application AND as a resolved package (fully validated).
        #expect(catalog.latestApplication(id: InvestigatorPersonaPackage.applicationID) != nil)
        #expect(catalog.resolvedPackage(applicationID: InvestigatorPersonaPackage.applicationID) != nil)
        #expect(catalog.allApplications.contains { $0.id == InvestigatorPersonaPackage.applicationID })
        #expect(catalog.latestApplication(id: InvestigatorPersonaPackage.applicationID)?.label == "Investigator")
    }

    @Test("The Investigator persona enumerates all 16 real jobs, one per kind, with unique ids")
    func enumeratesAllRealJobs() throws {
        let jobs = PersonaJobCatalogComposer.jobs(forPersona: InvestigatorPersonaPackage.applicationID)
        #expect(jobs.count == 16)
        // Every job kind appears exactly once.
        #expect(Set(jobs.map(\.kind)) == Set(PersonaJobKind.allCases))
        #expect(jobs.count == PersonaJobKind.allCases.count)
        // Ids are unique, prefixed, and all owned by the Investigator persona.
        #expect(Set(jobs.map(\.id)).count == jobs.count)
        #expect(jobs.allSatisfy { $0.id.hasPrefix("inv.") })
        #expect(jobs.allSatisfy { $0.persona == InvestigatorPersonaPackage.applicationID.rawValue })
        // Single source of truth: the composer's enumeration IS the package's job list.
        #expect(jobs.map(\.id) == InvestigatorPersonaPackage.jobs.map(\.id))
    }

    @Test("An unknown persona enumerates no jobs")
    func unknownPersonaEnumeratesNothing() throws {
        #expect(PersonaJobCatalogComposer.jobs(forPersona: ApplicationDefinitionID(rawValue: "com.unknown")).isEmpty)
    }

    // MARK: - Live routing into the real implementation

    private struct Rig {
        let db: Database
        let workspaces: WorkspaceRepository
        let genericFacts: GenericFactRepository
        let producer: ClaimProducer
        let cases: InvestigationCaseRepository
        let service: PersonaJobService
    }

    private func rig() async throws -> Rig {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pjc-\(UUID().uuidString).sqlite")
        let db = try Database(url: tmp)
        try await SchemaMigrations.migrate(db)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let workspaces = WorkspaceRepository(database: db)
        let gf = GenericFactRepository(database: db)
        let events = EventsRepository(database: db)
        let store = EvidenceStore(database: db)
        let producer = ClaimProducer(
            genericFacts: gf, assertions: AssertionsRepository(database: db),
            temporalClaims: TemporalClaimRepository(database: db), events: events,
            claims: ClaimRepository(database: db), evidence: store)
        let cases = InvestigationCaseRepository(database: db)
        func resolver() -> CaseRetrievalScopeResolver { CaseRetrievalScopeResolver(evidence: store) }
        let findings = InvestigationFindingsService(
            cases: cases, resolver: resolver(), workspaces: workspaces,
            assembly: try WorkProductAssemblyService(
                database: db, events: events, contradictions: ContradictionsRepository(database: db),
                gaps: GapNodeRepository(database: db), workspaces: workspaces),
            runs: WorkProductRunRepository(database: db),
            approvals: InvestigationFindingsApprovalRepository(database: db))
        let closure = InvestigationClosureService(cases: cases, resolver: resolver(),
                                                  closures: InvestigationClosureRepository(database: db))
        let custody = InvestigationCustodyService(cases: cases, resolver: resolver(),
                                                  evidence: store, custody: CustodyRepository(database: db), database: db)
        let contradictionGap = InvestigationContradictionGapService(
            cases: cases, resolver: resolver(), evidence: store,
            contradictions: ContradictionsRepository(database: db), gaps: GapNodeRepository(database: db),
            reviews: InvestigationDeskReviewRepository(database: db))
        let dataLab = InvestigationDataLabService(cases: cases, resolver: resolver(),
                                                  datasets: WorkbenchDatasetRepository(database: db),
                                                  scopes: SensitiveScopeRepository(database: db))
        // Heavier services (answers/subjectDossier/identity/analysis/reliability) intentionally nil here — the
        // rig proves BOTH real routing (wired) and honest fail-closed (nil). Production AppState wires them all.
        let service = PersonaJobService(
            catalog: try PersonaJobCatalogComposer.composeProduction(),
            cases: cases, answers: nil, subjectDossier: nil, identityResolution: nil, analysis: nil,
            reliability: nil, contradictionGap: contradictionGap, custody: custody, closure: closure,
            findings: findings, dataLab: dataLab)
        return Rig(db: db, workspaces: workspaces, genericFacts: gf, producer: producer, cases: cases, service: service)
    }

    @discardableResult
    private func seedFact(_ r: Rig, value: String) async throws -> (fileID: UUID, svID: UUID) {
        let fileID = UUID(), koID = UUID(), svID = UUID(), blockID = UUID(), docID = UUID()
        try await r.db.exec("INSERT INTO files (id, url, source_type) VALUES (?,?,?);",
                            [.uuid(fileID), .text("file:///\(fileID).txt"), .text("text")])
        try await r.db.exec("""
            INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at) VALUES (?,?,?,?,?,?);
            """, [.uuid(koID), .uuid(fileID), .text("txt"), .text(value), .real(0), .real(0)])
        try await r.db.exec("""
            INSERT INTO source_versions (id, logical_source_id, document_id, content_hash, valid_from, is_current, created_at)
            VALUES (?,?,?,?,?,1,?);
            """, [.uuid(svID), .uuid(fileID), .uuid(docID), .text(String(repeating: "d", count: 64)), .real(0), .real(0)])
        try await r.db.exec("""
            INSERT INTO evidence_blocks (id, document_id, source_version_id, ordinal, kind, raw_text, normalized_text, extraction_method, extraction_confidence)
            VALUES (?,?,?,?,?,?,?,?,?);
            """, [.uuid(blockID), .uuid(docID), .uuid(svID), .integer(0), .text("paragraph"),
                  .text(value), .text(value), .text("native"), .real(1.0)])
        try await r.db.exec("INSERT INTO evidence_block_objects (evidence_block_id, knowledge_object_id, linked_at) VALUES (?,?,?);",
                            [.uuid(blockID), .uuid(koID), .real(0)])
        try await r.genericFacts.upsert(GenericFact(
            id: UUID(), subjectID: nil, subjectLabel: "Doc", field: "event", value: value,
            assessment: EvidenceAssessment(basis: .sourceAsserted, origin: .sourceExtraction),
            confidence: 0.9, sourceBlockIDs: [blockID]))
        return (fileID, svID)
    }

    private func exportAccess(_ wsID: UUID) -> SensitiveAccessContext {
        SensitiveAccessContext(scope: SensitiveScope(
            workspaceID: wsID, maximumSensitivity: .restricted, permitsPrivilegedMaterial: false, purpose: .export))
    }

    @Test("The live consumer routes a selected job into the real implementation, and fails closed honestly")
    func liveConsumerRoutesRealJobs() async throws {
        let r = try await rig()
        // DISCOVER + ENUMERATE through the live consumer.
        #expect(await r.service.personas().contains { $0.id == InvestigatorPersonaPackage.applicationID })
        let jobs = await r.service.jobs(forPersona: InvestigatorPersonaPackage.applicationID)
        #expect(jobs.count == 16)
        func job(_ kind: PersonaJobKind) -> PersonaJob { jobs.first { $0.kind == kind }! }

        // Seed a workspace with an authorized source + a case authorizing it.
        let a = try await seedFact(r, value: "authorized fact \(UUID().uuidString)")
        let wsID = UUID()
        try await r.workspaces.upsert(Workspace(id: wsID, title: "Matter", template: .general))
        try await r.workspaces.addSource(a.fileID, to: wsID)
        try await WorkspaceMembershipDeriver(database: r.db, workspaces: r.workspaces).deriveMembership(for: wsID)
        _ = try await r.producer.backfill(at: t0)

        // ROUTE caseIntake (create) → a REAL case is created.
        let intakeCtx = PersonaJobLaunchContext(workspaceID: wsID, title: "Payment discrepancy", actor: "lead", at: t0)
        let created = try await r.service.launch(job(.caseIntake), context: intakeCtx)
        let caseID = try #require(created.producedID)
        let rec = try #require(try await r.cases.fetch(caseID: caseID))
        _ = try await r.cases.includeSource(caseID: caseID, expectedRevision: rec.caseHeader.revision,
                                            sourceRef: a.svID.uuidString, sourceKind: .sourceVersion, actor: "lead", at: t0)

        let base = PersonaJobLaunchContext(caseID: caseID, access: exportAccess(wsID), actor: "lead", at: t0)

        // ROUTE findings → the REAL findings builder produces a run.
        let f = try await r.service.launch(job(.findings), context: base)
        #expect(f.producedID != nil)
        // ROUTE closure → real read (no decision yet).
        let cl = try await r.service.launch(job(.closure), context: base)
        #expect(cl.summary.contains("No closure decision yet"))
        // ROUTE custody / contradictionGap / dataLab → real case-scoped reads.
        _ = try await r.service.launch(job(.evidenceCustody), context: base)
        _ = try await r.service.launch(job(.contradictionGap), context: base)
        _ = try await r.service.launch(job(.dataLab), context: base)

        // FAIL CLOSED — a wired-but-nil service (answers) and the unbooted method-engine jobs.
        await #expect(throws: PersonaJobError.self) {
            _ = try await r.service.launch(job(.ask), context: PersonaJobLaunchContext(caseID: caseID, access: exportAccess(wsID), actor: "lead", question: "?", at: t0))
        }
        for kind in [PersonaJobKind.methods, .causalAnalysis, .linkage, .capaRegister, .effectivenessReview] {
            await #expect(throws: PersonaJobError.self) { _ = try await r.service.launch(job(kind), context: base) }
        }

        // FAIL CLOSED — an unknown persona and a job the persona does not declare.
        let foreign = PersonaJob(persona: "com.unknown", id: "x", title: "X", detail: "", kind: .findings)
        await #expect(throws: PersonaJobError.self) { _ = try await r.service.launch(foreign, context: base) }
        let fabricated = PersonaJob(persona: InvestigatorPersonaPackage.applicationID.rawValue, id: "inv.not-a-real-job", title: "X", detail: "", kind: .findings)
        await #expect(throws: PersonaJobError.self) { _ = try await r.service.launch(fabricated, context: base) }
    }
}
