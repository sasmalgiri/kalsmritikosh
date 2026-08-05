//
//  PersonaAcceptanceInvestigatorTests.swift
//  KalsmritikoshTests
//
//  #143 — the FINAL Investigator persona acceptance. Drives the five required gold archetypes through the REAL
//  production PersonaJobService path (discover → enumerate → route into the real implementation), with the
//  shared ProfessionalMethod engine BOOTED live (so the method / causal / linkage / CAPA jobs route into the
//  real engine — no serviceUnavailable). Collectively proves: persona discovery, job discovery, job launch,
//  case intake, scope (authorized-only ∩ SensitiveScope), Methods, DataLab, subject dossier, identity, leads/
//  hypotheses, source reliability, contradictions/gaps, causal analysis, linkage, CAPA/effectiveness, custody,
//  findings, human approval, closure decision, sealed receipt, and close/reopen — end to end. Synthetic only.
//

import Testing
import Foundation
@testable import Kalsmritikosh

@Suite("#143 — Investigator persona final acceptance (production path)", .serialized)
struct PersonaAcceptanceInvestigatorTests {

    static let archetypes = ["process deviation", "payment discrepancy", "project delay",
                             "identity ambiguity", "conflicting accounts"]

    private let t0 = Date(timeIntervalSince1970: 1_768_500_000)
    private var invID: ApplicationDefinitionID { InvestigatorPersonaPackage.applicationID }

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
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pacc-\(UUID().uuidString).sqlite")
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

        // Findings / closure / custody / desks / dataLab.
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

        // The SHARED ProfessionalMethod engine, booted live (the #143 production requirement).
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
            """, [.uuid(svID), .uuid(fileID), .uuid(docID), .text(String(repeating: "e", count: 64)), .real(0), .real(0)])
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

    @Test("Each gold archetype processes through the production PersonaJobService path with the method engine LIVE",
          arguments: PersonaAcceptanceInvestigatorTests.archetypes)
    func archetypeThroughProductionPath(_ archetype: String) async throws {
        let r = try await rig()

        // DISCOVER + ENUMERATE through the live consumer.
        #expect(await r.service.personas().contains { $0.id == invID })
        let jobs = await r.service.jobs(forPersona: invID)
        #expect(jobs.count == 16)
        func job(_ kind: PersonaJobKind) -> PersonaJob { jobs.first { $0.kind == kind }! }

        // Seed a workspace with an authorized source A and an UNauthorized source B.
        let sentinelA = "AUTHORIZED-A-\(UUID().uuidString)"
        let sentinelB = "UNAUTHORIZED-B-\(UUID().uuidString)"
        let a = try await seedFact(r, value: sentinelA)
        let b = try await seedFact(r, value: sentinelB)
        let wsID = UUID()
        try await r.workspaces.upsert(Workspace(id: wsID, title: archetype.capitalized, template: .general))
        try await r.workspaces.addSource(a.fileID, to: wsID)
        try await r.workspaces.addSource(b.fileID, to: wsID)
        try await WorkspaceMembershipDeriver(database: r.db, workspaces: r.workspaces).deriveMembership(for: wsID)
        _ = try await r.producer.backfill(at: t0)

        // JOB LAUNCH — case intake creates a REAL case.
        let created = try await r.service.launch(job(.caseIntake),
            context: PersonaJobLaunchContext(workspaceID: wsID, title: archetype, actor: "lead", at: t0))
        let caseID = try #require(created.producedID)
        // SCOPE — authorize ONLY A.
        let rec = try #require(try await r.cases.fetch(caseID: caseID))
        _ = try await r.cases.includeSource(caseID: caseID, expectedRevision: rec.caseHeader.revision,
                                            sourceRef: a.svID.uuidString, sourceKind: .sourceVersion, actor: "lead", at: t0)

        let base = PersonaJobLaunchContext(caseID: caseID, access: exportAccess(wsID), actor: "lead", at: t0)

        // ROUTE EVERY non-Ask job into its real implementation. NONE may throw serviceUnavailable — in
        // particular the method engine is LIVE, so methods / causal / linkage / capa / effectiveness route real.
        let routable: [PersonaJobKind] = [
            .methods, .causalAnalysis, .linkage, .capaRegister, .effectivenessReview,   // method engine (was serviceUnavailable)
            .dataLab, .subjectDossier, .identityResolution, .analysis, .sourceReliability,
            .contradictionGap, .evidenceCustody, .findings, .closure]
        for kind in routable {
            let out = try await r.service.launch(job(kind), context: base)
            #expect(out.producedID != nil, "\(kind) must route into a real service and return a real outcome")
        }
        // Ask needs the brain (wired in production; nil in this rig) → honest serviceUnavailable.
        await #expect(throws: PersonaJobError.self) {
            _ = try await r.service.launch(job(.ask),
                context: PersonaJobLaunchContext(caseID: caseID, access: exportAccess(wsID), actor: "lead", question: "what happened?", at: t0))
        }

        // FINDINGS → human APPROVAL → CLOSURE decision → sealed receipt → close/reopen, with scope preserved.
        let f = try await r.findings.buildFindings(caseID: caseID, access: exportAccess(wsID), actor: "lead", at: t0)
        // Scope: unauthorized B is absent from the findings; authorized A is present.
        let text = f.assembled.workProduct.sections.flatMap(\.claims).map(\.text).joined(separator: "\n")
        #expect(text.contains(sentinelA) && !text.contains(sentinelB))
        #expect(!f.manifest.sourceVersionIDs.contains(b.svID.uuidString))
        _ = try await r.findings.approveFindings(caseID: caseID, findings: f, rationale: "objectives met for \(archetype)", actor: "lead", at: t0)
        // No auto-close: still open until an explicit human ClosureDecision.
        #expect(try await status(r.db, caseID) == "open")
        let recNow = try #require(try await r.cases.fetch(caseID: caseID))
        _ = try await r.closure.closeCase(caseID: caseID, expectedRevision: recNow.caseHeader.revision,
                                          rationale: "closing \(archetype) with documented limitations",
                                          unresolvedItems: ["Source B outside authorized scope — not reviewed"],
                                          workProductRunID: f.run.id, receiptSeal: f.receipt.seal, actor: "lead", at: t0)
        #expect(try await status(r.db, caseID) == "closed")
        // The closure job now reports the real closed decision through the live consumer.
        let closureLaunch = try await r.service.launch(job(.closure), context: base)
        #expect(closureLaunch.summary.contains("closed"))
        // Reopen preserves genealogy.
        let recClosed = try #require(try await r.cases.fetch(caseID: caseID))
        _ = try await r.closure.reopenCase(caseID: caseID, expectedRevision: recClosed.caseHeader.revision,
                                           rationale: "new evidence", actor: "lead", at: t0)
        #expect(try await status(r.db, caseID) == "open")
        let history = try await r.closure.closureHistory(caseID: caseID)
        #expect(history.map(\.decision) == [.closed, .reopened])
        #expect(history.first?.unresolvedItems.isEmpty == false)   // honest closure limitation retained
    }

    @Test("Simple and Advanced journeys route the Investigator persona to the SAME shared destinations")
    func simpleAndAdvancedRouteIdentically() throws {
        // Reuse the ONE ShellRouter (SHELL-002): a persona reaches the same destination in both modes; the
        // mode only changes presentation, never the underlying route/state.
        for surface in ShellSurface.allCases {
            let simple = ShellRouter.route(template: .investigation, mode: .simple, surface: surface)
            let advanced = ShellRouter.route(template: .investigation, mode: .advanced, surface: surface)
            #expect(simple.destination == advanced.destination,
                    "Investigator \(surface) must reach the same destination in Simple and Advanced")
        }
    }
}
