//
//  PersonaAcceptanceHarness.swift
//  KalsmritikoshTests
//
//  Shared production-mirror harness for persona acceptance suites. Builds ONE PersonaJobService wired to the
//  real shared services (matter scope, DataLab, entity authority, source reliability, timeline/relationship
//  methods, interpretation desk, custody, findings, closure) + the SHARED ProfessionalMethod engine booted
//  live — exactly as AppState boots it, minus the brain (Ask is covered separately). One place, reused by
//  every persona acceptance test so a new persona proves out through the real production path with no rig copy.
//

import Foundation
import Testing
@testable import Kalsmritikosh

struct PersonaAcceptanceHarness {
    let db: Database
    let workspaces: WorkspaceRepository
    let genericFacts: GenericFactRepository
    let producer: ClaimProducer
    let cases: InvestigationCaseRepository
    let findings: InvestigationFindingsService
    let closure: InvestigationClosureService
    let service: PersonaJobService

    static func make(seed: String) async throws -> PersonaAcceptanceHarness {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pah-\(UUID().uuidString).sqlite")
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
        return PersonaAcceptanceHarness(db: db, workspaces: workspaces, genericFacts: gf, producer: producer,
                                        cases: cases, findings: findings, closure: closure, service: service)
    }

    /// Seed one authorized fact-bearing source. Returns (fileID, svID).
    @discardableResult
    func seedFact(value: String, hashChar: Character) async throws -> (fileID: UUID, svID: UUID) {
        let fileID = UUID(), koID = UUID(), svID = UUID(), blockID = UUID(), docID = UUID()
        try await db.exec("INSERT INTO files (id, url, source_type) VALUES (?,?,?);",
                          [.uuid(fileID), .text("file:///\(fileID).txt"), .text("text")])
        try await db.exec("""
            INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at) VALUES (?,?,?,?,?,?);
            """, [.uuid(koID), .uuid(fileID), .text("txt"), .text(value), .real(0), .real(0)])
        try await db.exec("""
            INSERT INTO source_versions (id, logical_source_id, document_id, content_hash, valid_from, is_current, created_at)
            VALUES (?,?,?,?,?,1,?);
            """, [.uuid(svID), .uuid(fileID), .uuid(docID), .text(String(repeating: hashChar, count: 64)), .real(0), .real(0)])
        try await db.exec("""
            INSERT INTO evidence_blocks (id, document_id, source_version_id, ordinal, kind, raw_text, normalized_text, extraction_method, extraction_confidence)
            VALUES (?,?,?,?,?,?,?,?,?);
            """, [.uuid(blockID), .uuid(docID), .uuid(svID), .integer(0), .text("paragraph"),
                  .text(value), .text(value), .text("native"), .real(1.0)])
        try await db.exec("INSERT INTO evidence_block_objects (evidence_block_id, knowledge_object_id, linked_at) VALUES (?,?,?);",
                          [.uuid(blockID), .uuid(koID), .real(0)])
        try await genericFacts.upsert(GenericFact(
            id: UUID(), subjectID: nil, subjectLabel: "Doc", field: "event", value: value,
            assessment: EvidenceAssessment(basis: .sourceAsserted, origin: .sourceExtraction),
            confidence: 0.9, sourceBlockIDs: [blockID]))
        return (fileID, svID)
    }

    func exportAccess(_ wsID: UUID) -> SensitiveAccessContext {
        SensitiveAccessContext(scope: SensitiveScope(
            workspaceID: wsID, maximumSensitivity: .restricted, permitsPrivilegedMaterial: false, purpose: .export))
    }

    func status(_ caseID: UUID) async throws -> String? {
        try await db.query("SELECT status FROM investigation_cases WHERE id = ? LIMIT 1;", [.uuid(caseID)]).first?.string(0)
    }

    /// Drive one persona matter fully through the production PersonaJobService path: discover → enumerate →
    /// intake job creates a real matter → authorize source A (B unauthorized) → EVERY job routes into a real
    /// service → findings/edition build (B excluded) → approval → no-auto-close → close → reopen.
    func runFullPersonaMatter(personaID: ApplicationDefinitionID, expectedJobCount: Int, intakeJobID: String,
                              template: WorkspaceTemplate, title: String, actor: String, at t0: Date) async throws {
        #expect(await service.personas().contains { $0.id == personaID })
        let jobs = await service.jobs(forPersona: personaID)
        #expect(jobs.count == expectedJobCount)
        func job(_ id: String) -> PersonaJob { jobs.first { $0.id == id }! }

        let sentinelA = "AUTHORIZED-A-\(UUID().uuidString)"
        let sentinelB = "UNAUTHORIZED-B-\(UUID().uuidString)"
        let a = try await seedFact(value: sentinelA, hashChar: "a")
        let b = try await seedFact(value: sentinelB, hashChar: "b")
        let wsID = UUID()
        try await workspaces.upsert(Workspace(id: wsID, title: title, template: template))
        try await workspaces.addSource(a.fileID, to: wsID)
        try await workspaces.addSource(b.fileID, to: wsID)
        try await WorkspaceMembershipDeriver(database: db, workspaces: workspaces).deriveMembership(for: wsID)
        _ = try await producer.backfill(at: t0)

        let created = try await service.launch(job(intakeJobID),
            context: PersonaJobLaunchContext(workspaceID: wsID, title: title, actor: actor, at: t0))
        let caseID = try #require(created.producedID)
        let rec = try #require(try await cases.fetch(caseID: caseID))
        _ = try await cases.includeSource(caseID: caseID, expectedRevision: rec.caseHeader.revision,
                                          sourceRef: a.svID.uuidString, sourceKind: .sourceVersion, actor: actor, at: t0)

        let base = PersonaJobLaunchContext(caseID: caseID, access: exportAccess(wsID), actor: actor, at: t0)
        for j in jobs where j.id != intakeJobID && j.kind != .ask {
            let out = try await service.launch(j, context: base)
            #expect(out.producedID != nil, "\(j.id) must route into a real service")
        }
        // PJOB-MAX — every persona now carries an .ask job. Ask needs the brain
        // (wired in production; nil in this rig) → honest serviceUnavailable,
        // the same fail-closed contract the Investigator acceptance pins.
        if let askJob = jobs.first(where: { $0.kind == .ask }) {
            await #expect(throws: PersonaJobError.self) {
                _ = try await service.launch(askJob, context: PersonaJobLaunchContext(
                    caseID: caseID, access: exportAccess(wsID), actor: actor, question: "what happened?", at: t0))
            }
        }

        let f = try await findings.buildFindings(caseID: caseID, access: exportAccess(wsID), actor: actor, at: t0)
        let text = f.assembled.workProduct.sections.flatMap(\.claims).map(\.text).joined(separator: "\n")
        #expect(text.contains(sentinelA) && !text.contains(sentinelB))
        _ = try await findings.approveFindings(caseID: caseID, findings: f, rationale: "ready: \(title)", actor: actor, at: t0)
        #expect(try await status(caseID) == "open")
        let recNow = try #require(try await cases.fetch(caseID: caseID))
        _ = try await closure.closeCase(caseID: caseID, expectedRevision: recNow.caseHeader.revision,
                                        rationale: "closing \(title)", unresolvedItems: ["B outside authorized scope"],
                                        workProductRunID: f.run.id, receiptSeal: f.receipt.seal, actor: actor, at: t0)
        #expect(try await status(caseID) == "closed")
        let recClosed = try #require(try await cases.fetch(caseID: caseID))
        _ = try await closure.reopenCase(caseID: caseID, expectedRevision: recClosed.caseHeader.revision,
                                         rationale: "new material", actor: actor, at: t0)
        #expect(try await status(caseID) == "open")
        #expect(try await closure.closureHistory(caseID: caseID).map(\.decision) == [.closed, .reopened])
    }
}
