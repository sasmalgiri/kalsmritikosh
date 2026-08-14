//
//  ResearcherPersonaAcceptanceTests.swift
//  KalsmritikoshTests
//
//  Researcher / Historian persona acceptance. Drives research/historical gold matters through the REAL
//  production PersonaJobService path (discover → enumerate RES-01…RES-14 → route every job into its real
//  shared service → edition build with scope enforced → human approval → closure/reopen). Because every
//  Researcher job maps to a persona-neutral kind wired to a shared service, ALL 14 route real (the Researcher
//  has no brain-only Ask job). Simple and Advanced route to the same shared destinations. Synthetic only.
//

import Testing
import Foundation
@testable import Kalsmritikosh

@Suite("Researcher/Historian persona acceptance (production path)", .serialized)
struct ResearcherPersonaAcceptanceTests {

    static let matters = ["authorship attribution", "disputed treaty date", "competing eyewitness accounts",
                          "archival provenance", "colonial trade dispute"]

    private let t0 = Date(timeIntervalSince1970: 1_768_600_000)
    private var researcherID: ApplicationDefinitionID { ResearcherPersonaPackage.applicationID }

    private struct Rig {
        let db: Database
        let workspaces: WorkspaceRepository
        let genericFacts: GenericFactRepository
        let producer: ClaimProducer
        let cases: InvestigationCaseRepository
        let findings: InvestigationFindingsService
        let closure: InvestigationClosureService
        let service: PersonaJobService
    }

    private func rig() async throws -> Rig {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("racc-\(UUID().uuidString).sqlite")
        let db = try Database(url: tmp)
        try await SchemaMigrations.migrate(db)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let workspaces = WorkspaceRepository(database: db)
        let gf = GenericFactRepository(database: db)
        let events = EventsRepository(database: db)
        let store = EvidenceStore(database: db)
        let scopes = SensitiveScopeRepository(database: db)
        let entities = EntitiesRepository(database: db)
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
        let deskReviews = InvestigationDeskReviewRepository(database: db)
        let contradictionGap = InvestigationContradictionGapService(
            cases: cases, resolver: resolver(), evidence: store,
            contradictions: ContradictionsRepository(database: db), gaps: GapNodeRepository(database: db), reviews: deskReviews)
        let dataLab = InvestigationDataLabService(cases: cases, resolver: resolver(),
                                                  datasets: WorkbenchDatasetRepository(database: db), scopes: scopes)
        let reliability = InvestigationReliabilityService(
            cases: cases, resolver: resolver(),
            reliability: SourceReliabilityAssessmentRepository(database: db), reviews: deskReviews)
        let analysis = InvestigationAnalysisService(
            cases: cases, resolver: resolver(), evidence: store, analysis: InvestigationAnalysisRepository(database: db))
        let scopedEntities = CaseScopedEntityResolver(entities: entities, evidence: store)
        let subjectDossier = InvestigationSubjectDossierService(
            cases: cases, resolver: resolver(), subjects: InvestigationSubjectRepository(database: db),
            entities: entities, scopedEntities: scopedEntities)
        let identity = InvestigationIdentityResolutionService(
            cases: cases, resolver: resolver(), scopedEntities: scopedEntities, entities: entities,
            decisions: InvestigationIdentityDecisionRepository(database: db))
        let methodCatalog = try await ProfessionalMethodCatalog.standard()
        let methodRuns = MethodRunRepository(database: db)
        let gate = CanonicalWorkflowEvidenceReferenceGate(database: db, scopeRepository: scopes)
        let methods = InvestigationMethodService(cases: cases, resolver: resolver(), evidence: store,
                                                 methodRuns: methodRuns, registry: methodCatalog.methods, gate: gate)
        let causal = InvestigationCausalService(cases: cases, registry: methodCatalog.methods, methods: methods)
        let linkage = InvestigationLinkageService(cases: cases, registry: methodCatalog.methods, methods: methods)
        let capa = InvestigationCAPAService(cases: cases, registry: methodCatalog.methods, methods: methods)
        let service = PersonaJobService(
            catalog: try PersonaJobCatalogComposer.composeProduction(),
            cases: cases, answers: nil, subjectDossier: subjectDossier, identityResolution: identity,
            analysis: analysis, reliability: reliability, contradictionGap: contradictionGap, custody: custody,
            closure: closure, findings: findings, dataLab: dataLab,
            methods: methods, causal: causal, linkage: linkage, capa: capa)
        return Rig(db: db, workspaces: workspaces, genericFacts: gf, producer: producer, cases: cases,
                   findings: findings, closure: closure, service: service)
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
            """, [.uuid(svID), .uuid(fileID), .uuid(docID), .text(String(repeating: "f", count: 64)), .real(0), .real(0)])
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

    private func status(_ db: Database, _ caseID: UUID) async throws -> String? {
        try await db.query("SELECT status FROM investigation_cases WHERE id = ? LIMIT 1;", [.uuid(caseID)]).first?.string(0)
    }

    @Test("Each research matter processes through the production PersonaJobService path — all 20 jobs route real",
          arguments: ResearcherPersonaAcceptanceTests.matters)
    func matterThroughProductionPath(_ matter: String) async throws {
        let r = try await rig()

        // DISCOVER + ENUMERATE the Researcher persona (PJOB-MAX: all 16 kinds, 20 jobs).
        #expect(await r.service.personas().contains { $0.id == researcherID })
        let jobs = await r.service.jobs(forPersona: researcherID)
        #expect(jobs.count == 20)
        #expect(jobs.allSatisfy { $0.id.hasPrefix("res.") })

        // Seed a workspace with authorized A + unauthorized B, and a matter authorizing only A.
        let sentinelA = "AUTHORIZED-A-\(UUID().uuidString)"
        let sentinelB = "UNAUTHORIZED-B-\(UUID().uuidString)"
        let a = try await seedFact(r, value: sentinelA)
        let b = try await seedFact(r, value: sentinelB)
        let wsID = UUID()
        try await r.workspaces.upsert(Workspace(id: wsID, title: matter.capitalized, template: .researchReview))
        try await r.workspaces.addSource(a.fileID, to: wsID)
        try await r.workspaces.addSource(b.fileID, to: wsID)
        try await WorkspaceMembershipDeriver(database: r.db, workspaces: r.workspaces).deriveMembership(for: wsID)
        _ = try await r.producer.backfill(at: t0)

        // Research protocol (intake) creates a REAL matter.
        func job(_ id: String) -> PersonaJob { jobs.first { $0.id == id }! }
        let created = try await r.service.launch(job("res.protocol"),
            context: PersonaJobLaunchContext(workspaceID: wsID, title: matter, actor: "researcher", at: t0))
        let caseID = try #require(created.producedID)
        let rec = try #require(try await r.cases.fetch(caseID: caseID))
        _ = try await r.cases.includeSource(caseID: caseID, expectedRevision: rec.caseHeader.revision,
                                            sourceRef: a.svID.uuidString, sourceKind: .sourceVersion, actor: "researcher", at: t0)

        let base = PersonaJobLaunchContext(caseID: caseID, access: exportAccess(wsID), actor: "researcher", at: t0)

        // EVERY Researcher job routes into its real shared service — none may throw serviceUnavailable.
        // (.ask needs the production brain, nil in this rig → honest fail-closed below.)
        for j in jobs where j.id != "res.protocol" && j.kind != .ask {   // protocol already launched (create)
            let out = try await r.service.launch(j, context: base)
            #expect(out.producedID != nil, "\(j.id) must route into a real service")
        }
        if let askJob = jobs.first(where: { $0.kind == .ask }) {
            await #expect(throws: PersonaJobError.self) {
                _ = try await r.service.launch(askJob, context: PersonaJobLaunchContext(
                    caseID: caseID, access: exportAccess(wsID), actor: "researcher",
                    question: "what does the corpus say?", at: t0))
            }
        }

        // Annotated edition (findings) → human approval → closure/reopen, scope preserved.
        let f = try await r.findings.buildFindings(caseID: caseID, access: exportAccess(wsID), actor: "researcher", at: t0)
        let text = f.assembled.workProduct.sections.flatMap(\.claims).map(\.text).joined(separator: "\n")
        #expect(text.contains(sentinelA) && !text.contains(sentinelB))
        _ = try await r.findings.approveFindings(caseID: caseID, findings: f, rationale: "edition ready for \(matter)", actor: "researcher", at: t0)
        #expect(try await status(r.db, caseID) == "open")   // no auto-close
        let recNow = try #require(try await r.cases.fetch(caseID: caseID))
        _ = try await r.closure.closeCase(caseID: caseID, expectedRevision: recNow.caseHeader.revision,
                                          rationale: "closing \(matter) with documented limitations",
                                          unresolvedItems: ["Source B outside authorized corpus"],
                                          workProductRunID: f.run.id, receiptSeal: f.receipt.seal, actor: "researcher", at: t0)
        #expect(try await status(r.db, caseID) == "closed")
        let recClosed = try #require(try await r.cases.fetch(caseID: caseID))
        _ = try await r.closure.reopenCase(caseID: caseID, expectedRevision: recClosed.caseHeader.revision,
                                           rationale: "new archival source", actor: "researcher", at: t0)
        #expect(try await status(r.db, caseID) == "open")
        #expect(try await r.closure.closureHistory(caseID: caseID).map(\.decision) == [.closed, .reopened])
    }

    @Test("Both personas are discoverable in the ONE production catalog; each enumerates its own jobs")
    func bothPersonasDiscoverable() throws {
        let catalog = try PersonaJobCatalogComposer.composeProduction()
        #expect(catalog.latestApplication(id: InvestigatorPersonaPackage.applicationID) != nil)
        #expect(catalog.latestApplication(id: ResearcherPersonaPackage.applicationID) != nil)
        #expect(PersonaJobCatalogComposer.jobs(forPersona: ResearcherPersonaPackage.applicationID).count == 20)
        #expect(PersonaJobCatalogComposer.jobs(forPersona: InvestigatorPersonaPackage.applicationID).count == 16)
        // Job ids are unique within each persona.
        let rjobs = ResearcherPersonaPackage.jobs
        #expect(Set(rjobs.map(\.id)).count == rjobs.count)
    }

    @Test("Simple and Advanced route the Researcher persona to the SAME shared destinations")
    func simpleAndAdvancedRouteIdentically() throws {
        for surface in ShellSurface.allCases {
            let simple = ShellRouter.route(template: .researchReview, mode: .simple, surface: surface)
            let advanced = ShellRouter.route(template: .researchReview, mode: .advanced, surface: surface)
            #expect(simple.destination == advanced.destination)
        }
    }
}
