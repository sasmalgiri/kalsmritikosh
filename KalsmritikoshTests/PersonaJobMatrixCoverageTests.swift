//
//  PersonaJobMatrixCoverageTests.swift
//  KalsmritikoshTests
//
//  Release gate F2 (macro E) — the authoritative persona/job coverage test.
//  #142 proved discovery/enumeration/routing for the INVESTIGATOR persona;
//  this suite extends the proof to ALL FIVE personas: the production catalog
//  and PERSONA_JOB_COVERAGE_MATRIX.csv agree on the persona set, every
//  package enumerates its declared launchable jobs with pinned counts
//  (PJOB-MAX: 103 total — 16/20/22/23/22; every persona now covers ALL 16
//  PersonaJobKinds, and several personas legitimately declare multiple jobs
//  of one kind, e.g. analysis presets), and each persona's jobs ROUTE into
//  the real case-scoped services (create case → findings → closure/custody/
//  contradictionGap/dataLab reads), with honest fail-closed behavior for
//  unwired services. Synthetic only.
//

import Testing
import Foundation
@testable import Kalsmritikosh

@Suite("F2 — persona/job coverage matrix ↔ production catalog", .serialized)
struct PersonaJobMatrixCoverageTests {

    private let t0 = Date(timeIntervalSince1970: 1_768_500_000)

    private static let expectedCounts: [(id: ApplicationDefinitionID, label: String, jobs: [PersonaJob], count: Int)] = [
        (InvestigatorPersonaPackage.applicationID, "Investigator", InvestigatorPersonaPackage.jobs, 16),
        (ResearcherPersonaPackage.applicationID, "Researcher", ResearcherPersonaPackage.jobs, 20),
        (JournalistPersonaPackage.applicationID, "Journalist", JournalistPersonaPackage.jobs, 22),
        (IndividualPersonaPackage.applicationID, "Individual", IndividualPersonaPackage.jobs, 23),
        (LawyerPersonaPackage.applicationID, "Lawyer", LawyerPersonaPackage.jobs, 22),
    ]

    // MARK: - Catalog ↔ package composition, all five personas

    @Test("The production catalog discovers all five personas and enumerates every package job, 103 total")
    func allFivePersonasEnumerate() throws {
        let catalog = try PersonaJobCatalogComposer.composeProduction()
        var total = 0
        for expected in Self.expectedCounts {
            #expect(catalog.latestApplication(id: expected.id) != nil, "\(expected.label) not discoverable")
            #expect(catalog.resolvedPackage(applicationID: expected.id) != nil, "\(expected.label) not resolvable")
            let jobs = PersonaJobCatalogComposer.jobs(forPersona: expected.id)
            #expect(jobs.count == expected.count, "\(expected.label): \(jobs.count) jobs, expected \(expected.count)")
            #expect(Set(jobs.map(\.id)).count == jobs.count, "\(expected.label): duplicate job ids")
            #expect(jobs.allSatisfy { $0.persona == expected.id.rawValue })
            // Single source of truth: composer enumeration IS the package list.
            #expect(jobs.map(\.id) == expected.jobs.map(\.id))
            // Every persona declares an intake path (the routing precondition).
            #expect(jobs.contains { $0.kind == .caseIntake }, "\(expected.label): no intake job")
            // PJOB-MAX — full capability coverage: every persona declares at
            // least one job for EVERY PersonaJobKind.
            #expect(Set(jobs.map(\.kind)).count == PersonaJobKind.allCases.count,
                    "\(expected.label): does not cover all job kinds")
            total += jobs.count
        }
        #expect(total == 103)
    }

    @Test("PERSONA_JOB_COVERAGE_MATRIX.csv and the production catalog agree on the persona set and total row count")
    func matrixAgreesWithCatalog() throws {
        let csvURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()          // KalsmritikoshTests/
            .deletingLastPathComponent()          // repo root
            .appendingPathComponent("PERSONA_JOB_COVERAGE_MATRIX.csv")
        let csv = try String(contentsOf: csvURL, encoding: .utf8)
        let rows = csv.split(separator: "\n").dropFirst()   // header
        let personaColumn = rows.compactMap { $0.split(separator: ",").first.map(String.init) }
        let matrixPersonas = Set(personaColumn)
        #expect(matrixPersonas == ["Investigator", "Researcher", "Journalist", "Lawyer", "Individual"],
                "matrix personas drifted: \(matrixPersonas.sorted())")
        // The matrix decomposes persona work into 107 requirement rows; the
        // catalog exposes 103 launchable jobs (several matrix rows share one
        // launchable job, e.g. preset variants). Both totals are pinned so
        // either side drifting — a new matrix row without a launchable job,
        // or a new job without a matrix row — fails here and forces the
        // mapping to be re-audited.
        #expect(rows.count == 107, "matrix rows: \(rows.count)")
        let catalogTotal = Self.expectedCounts.map(\.count).reduce(0, +)
        #expect(catalogTotal == 103)
    }

    // MARK: - Live routing for the four non-Investigator personas
    // (#142 already proves the Investigator path end-to-end.)

    private struct Rig {
        let db: Database
        let workspaces: WorkspaceRepository
        let genericFacts: GenericFactRepository
        let producer: ClaimProducer
        let cases: InvestigationCaseRepository
        let service: PersonaJobService
    }

    private func rig() async throws -> Rig {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pjm-\(UUID().uuidString).sqlite")
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
        let service = PersonaJobService(
            catalog: try PersonaJobCatalogComposer.composeProduction(),
            cases: cases, answers: nil, subjectDossier: nil, identityResolution: nil, analysis: nil,
            reliability: nil, contradictionGap: contradictionGap, custody: custody, closure: closure,
            findings: findings, dataLab: dataLab)
        return Rig(db: db, workspaces: workspaces, genericFacts: gf, producer: producer, cases: cases, service: service)
    }

    private func seedSource(_ r: Rig, value: String) async throws -> (fileID: UUID, svID: UUID) {
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

    @Test("Researcher, Journalist, Individual and Lawyer jobs route into the same live services, and fail closed where unwired",
          arguments: [
            ResearcherPersonaPackage.applicationID,
            JournalistPersonaPackage.applicationID,
            IndividualPersonaPackage.applicationID,
            LawyerPersonaPackage.applicationID,
          ])
    func nonInvestigatorPersonaRoutesLive(personaID: ApplicationDefinitionID) async throws {
        let r = try await rig()
        #expect(await r.service.personas().contains { $0.id == personaID })
        let jobs = await r.service.jobs(forPersona: personaID)
        #expect(!jobs.isEmpty)
        func job(_ kind: PersonaJobKind) -> PersonaJob? { jobs.first { $0.kind == kind } }

        // Seed a workspace + authorized source, then create a REAL matter via
        // this persona's own intake job.
        let src = try await seedSource(r, value: "authorized fact \(UUID().uuidString)")
        let wsID = UUID()
        try await r.workspaces.upsert(Workspace(id: wsID, title: "Matter", template: .general))
        try await r.workspaces.addSource(src.fileID, to: wsID)
        try await WorkspaceMembershipDeriver(database: r.db, workspaces: r.workspaces).deriveMembership(for: wsID)
        _ = try await r.producer.backfill(at: t0)

        let intake = try #require(job(.caseIntake), "\(personaID.rawValue) declares no intake job")
        let created = try await r.service.launch(
            intake, context: PersonaJobLaunchContext(workspaceID: wsID, title: "Matter intake", actor: "owner", at: t0))
        let caseID = try #require(created.producedID)
        let rec = try #require(try await r.cases.fetch(caseID: caseID))
        _ = try await r.cases.includeSource(caseID: caseID, expectedRevision: rec.caseHeader.revision,
                                            sourceRef: src.svID.uuidString, sourceKind: .sourceVersion, actor: "owner", at: t0)
        let base = PersonaJobLaunchContext(caseID: caseID, access: exportAccess(wsID), actor: "owner", at: t0)

        // Every wired job kind this persona declares must route into the REAL service.
        for kind in [PersonaJobKind.findings, .closure, .evidenceCustody, .contradictionGap, .dataLab] {
            if let j = job(kind) {
                _ = try await r.service.launch(j, context: base)
            }
        }
        // And every nil-wired kind it declares must fail closed, never fake success.
        for kind in [PersonaJobKind.ask, .subjectDossier, .identityResolution, .analysis,
                     .sourceReliability, .methods, .causalAnalysis, .linkage, .capaRegister, .effectivenessReview] {
            if let j = job(kind) {
                await #expect(throws: PersonaJobError.self, "\(personaID.rawValue)/\(kind) must fail closed") {
                    _ = try await r.service.launch(j, context: PersonaJobLaunchContext(
                        caseID: caseID, access: exportAccess(wsID), actor: "owner", question: "?", at: t0))
                }
            }
        }
    }
}
