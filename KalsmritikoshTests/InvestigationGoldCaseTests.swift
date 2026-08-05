//
//  InvestigationGoldCaseTests.swift
//  KalsmritikoshTests
//
//  INV-01-D — the INV-01 gold-case end-to-end acceptance. Where the C1–C4 suites each proved ONE seam in
//  isolation, this proves the whole Investigator INV-01 chain COMPOSES coherently over a single synthetic
//  case, driven only through the real shared services — and that every case-produced artifact is governed
//  by the ONE case-scope fingerprint (no per-engine scope system).
//
//  Scenario (process deviation): a case authorizes Source A only. Source B is a real workspace source that
//  is NOT in scope and holds the "direct answer". The journey:
//    intake → scope(fingerprint fp1)
//      → Ask         : the answer never cites / surfaces Source B
//      → Methods     : a run over A is created; a run touching B is rejected atomically (nothing created)
//      → DataLab     : the Source Inventory binds only A; B is structurally absent (no workspace fallback)
//      → record each artifact under fp1 in the ONE scope ledger; none is stale under fp1
//    scope change (authorize B) → fp2 ≠ fp1
//      → every prior artifact is now STALE, yet each retains its original fp1 (history is never rewritten)
//      → an explicit rerun uses the NEW scope (both A+B) and produces a NEW, non-stale artifact; the old
//        dataset is untouched
//    reopen : a fresh set of repositories over the same database sees the case at its new revision, all
//        recorded artifacts, and the historical A-only dataset unchanged.
//
//  Everything runs through InvestigationCaseRepository / InvestigationAnswerService / InvestigationMethodService
//  / InvestigationDataLabService / InvestigationScopeLedger + CaseScopeFingerprinter over the SHARED
//  MasterBrain / MethodRunRepository / WorkbenchDatasetRepository / EvidenceStore. Synthetic only.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("INV-01-D — Investigator gold-case end-to-end", .serialized)
struct InvestigationGoldCaseTests {

    private let t0 = Date(timeIntervalSince1970: 1_766_000_000)

    // Source A (authorized, exact version vA) holds weak/partial evidence; Source B (unauthorized) holds
    // the direct answer tagged with a unique phrase we can search for.
    private let vA = UUID(); private let vB = UUID()
    private let koA = UUID(); private let koB = UUID()
    private let bDirectAnswer = "DEVIATION-APPROVED-OUTSIDE-CHANGE-WINDOW-XYZ"
    private let intent = UserIntent(kind: .factualLookup, scope: .global, rawQuestion: "was the change approved?")

    private func chunk(_ version: UUID, object: UUID, text: String) -> RetrievedChunk {
        RetrievedChunk(chunk: Chunk(objectID: object, ordinal: 0, text: text, characterRange: 0..<text.count,
                                    sourceVersionID: version),
                       score: 1, viaLayer: .vector)
    }
    /// A base retriever returning BOTH A and B — stands in for the shared HybridRetriever.
    private var baseAB: RetrievalResult {
        RetrievalResult(chunks: [
            chunk(vA, object: koA, text: "A change request was filed for the configuration."),
            chunk(vB, object: koB, text: bDirectAnswer)])
    }
    private struct StubRetriever: Retriever {
        let result: RetrievalResult
        func retrieve(for intent: UserIntent, layers: [RetrievalLayer]) async throws -> RetrievalResult { result }
        func retrieve(for intent: UserIntent, layers: [RetrievalLayer], access: SensitiveAccessContext) async throws -> AuthorizedRetrievalResult {
            AuthorizedRetrievalResult(result: result, accessContext: access)
        }
    }
    /// A permissive canonical gate — the case scope + SensitiveScope are exercised via the real services;
    /// the gate stands in for the workspace/existence/SensitiveScope verdict (covered by the engine tests).
    private struct StubGate: WorkflowEvidenceReferenceGating {
        func verdict(kind: WorkflowEvidenceObjectKind, canonicalObjectID: UUID, workspaceID: UUID) async -> WorkflowEvidenceGateVerdict { .permitted }
    }

    private struct Rig {
        let db: Database
        let ws: UUID
        let cases: InvestigationCaseRepository
        let evidence: EvidenceStore
        let answers: InvestigationAnswerService
        let methods: InvestigationMethodService
        let datalab: InvestigationDataLabService
        let ledger: InvestigationScopeLedger
        let methodRuns: MethodRunRepository
        let datasets: WorkbenchDatasetRepository
    }

    /// Seed a real source version (files + source_versions) so `.sourceVersion` bindings validate.
    @discardableResult
    private func seedSourceVersion(_ db: Database, id: UUID) async throws -> UUID {
        let logical = UUID()
        try await db.exec("INSERT INTO files (id, url, source_type, availability) VALUES (?,?,?,?);",
                          [.uuid(logical), .text("file:///x/\(logical.uuidString)"), .text("txt"), .text("available")])
        try await db.exec("""
            INSERT INTO source_versions (id, logical_source_id, content_hash, valid_from, is_current, created_at,
                filename, detected_type, detection_basis, size_bytes, custody_mode, preservation_status, intake_recorded_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?);
            """, [.uuid(id), .uuid(logical), .text(String(repeating: "a", count: 64)), .real(100), .integer(1), .real(100),
                  .text("f.txt"), .text("txt"), .text("magicBytes"), .integer(1), .text("referenced"), .text("referenceRecorded"), .real(100)])
        return id
    }

    private func rig() async throws -> Rig {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let ws = UUID()
        try await db.exec("INSERT INTO workspaces (id, title, created_at, updated_at) VALUES (?,?,?,?);",
                          [.uuid(ws), .text("Matter"), .real(t0.timeIntervalSince1970), .real(t0.timeIntervalSince1970)])
        try await seedSourceVersion(db, id: vA)
        try await seedSourceVersion(db, id: vB)   // a REAL workspace source — but not authorized for the case
        let cases = InvestigationCaseRepository(database: db)
        let evidence = EvidenceStore(database: db)
        let methodRuns = MethodRunRepository(database: db)
        let datasets = WorkbenchDatasetRepository(database: db)
        let catalog = try await ProfessionalMethodCatalog.standard()
        let resolver = CaseRetrievalScopeResolver(evidence: evidence)
        let answers = InvestigationAnswerService(cases: cases, resolver: resolver, baseRetriever: StubRetriever(result: baseAB),
                                                 evidence: evidence, makeBrain: { MasterBrain(retriever: $0) })
        let methods = InvestigationMethodService(cases: cases, resolver: resolver, evidence: evidence,
                                                 methodRuns: methodRuns, registry: catalog.methods, gate: StubGate())
        let datalab = InvestigationDataLabService(cases: cases, resolver: resolver, datasets: datasets,
                                                  scopes: SensitiveScopeRepository(database: db))
        let ledger = InvestigationScopeLedger(database: db)
        return Rig(db: db, ws: ws, cases: cases, evidence: evidence, answers: answers, methods: methods,
                   datalab: datalab, ledger: ledger, methodRuns: methodRuns, datasets: datasets)
    }

    private func methodRunCount(_ db: Database) async throws -> Int {
        Int(try await db.query("SELECT COUNT(*) FROM method_runs;", []).first?.int(0) ?? -1)
    }

    // MARK: - The gold case

    @Test("Full INV-01 journey: intake → scope → Ask → Methods → DataLab → scope-change → staleness → reopen")
    func goldCaseEndToEnd() async throws {
        let rig = try await rig()

        // 1. Intake — a case authorizing Source A only.
        var c = try await rig.cases.createCase(workspaceID: rig.ws, title: "Process deviation — config change outside window",
                                               actor: "investigator", at: t0)
        c = try await rig.cases.includeSource(caseID: c.id, expectedRevision: c.revision,
                                              sourceRef: vA.uuidString, sourceKind: .sourceVersion, actor: "investigator", at: t0)
        let caseID = c.id

        // 2. Scope — the ONE fingerprint for this scope (fp1).
        let ctx1 = try await rig.answers.scopeContext(caseID: caseID)
        #expect(ctx1.scope.authorizedSourceVersionIDs == [vA])
        let fp1 = ctx1.fingerprint
        #expect(fp1 == CaseScopeFingerprinter.fingerprint(caseID: caseID, caseRevision: ctx1.caseRevision, scope: ctx1.scope))

        // 3. Ask — Source B holds the direct answer but is out of scope; it must never surface or be cited.
        let answered = try await rig.answers.answer(caseID: caseID, question: intent.rawQuestion, access: .testUnrestricted())
        #expect(answered.context.fingerprint == fp1)
        #expect(answered.context.scope.authorizedSourceVersionIDs == [vA])
        #expect(answered.verified.citations.allSatisfy { $0.objectID != koB })
        #expect(!answered.verified.citations.contains { $0.snippet.contains(bDirectAnswer) })
        #expect(!answered.verified.body.contains(bDirectAnswer))
        _ = try await rig.ledger.record(caseID: caseID, kind: .ask, artifactID: "ask-approval-question",
                                        fingerprint: fp1, caseRevision: ctx1.caseRevision, at: t0)

        // 4. Methods — a run over A is created; a run touching B is rejected atomically.
        let started = try await rig.methods.startMethod(caseID: caseID, methodDefinitionID: "com.kalsmritikosh.method.timeline-analysis",
            evidenceSpecs: [InvestigationMethodEvidenceSpec(targetKind: .sourceVersion, targetID: vA, ordinal: 0)],
            createdBy: "investigator", now: t0)
        #expect(started.scope.authorizedSourceVersionIDs == [vA])
        await #expect(throws: InvestigationMethodError.self) {
            _ = try await rig.methods.startMethod(caseID: caseID, methodDefinitionID: "com.kalsmritikosh.method.timeline-analysis",
                evidenceSpecs: [InvestigationMethodEvidenceSpec(targetKind: .sourceVersion, targetID: vA, ordinal: 0),
                                InvestigationMethodEvidenceSpec(targetKind: .sourceVersion, targetID: vB, ordinal: 1)],
                createdBy: "investigator", now: t0)
        }
        #expect(try await methodRunCount(rig.db) == 1)   // the rejected run created nothing
        _ = try await rig.ledger.record(caseID: caseID, kind: .methodRun, artifactID: started.run.id.uuidString,
                                        fingerprint: fp1, caseRevision: ctx1.caseRevision, at: t0)

        // 5. DataLab — the Source Inventory binds only A; B is structurally absent.
        let prepared = try await rig.datalab.prepareSourceInventory(caseID: caseID, access: .testUnrestricted(), actor: "investigator", at: t0)
        #expect(prepared.includedSourceVersionIDs == [vA])
        let firstDatasetID = prepared.dataset.dataset.id
        let bindings1 = try await rig.datasets.bindings(datasetID: firstDatasetID)
        #expect(bindings1.count == 1 && bindings1.first?.sourceVersionID == vA)
        #expect(!bindings1.contains { $0.sourceVersionID == vB })
        _ = try await rig.ledger.record(caseID: caseID, kind: .workbenchDataset, artifactID: firstDatasetID.uuidString,
                                        fingerprint: fp1, caseRevision: ctx1.caseRevision, at: t0)

        // 6. Under fp1, nothing is stale.
        #expect(try await rig.ledger.isStale(caseID: caseID, kind: .ask, artifactID: "ask-approval-question", currentFingerprint: fp1) == false)
        #expect(try await rig.ledger.isStale(caseID: caseID, kind: .methodRun, artifactID: started.run.id.uuidString, currentFingerprint: fp1) == false)
        #expect(try await rig.ledger.isStale(caseID: caseID, kind: .workbenchDataset, artifactID: firstDatasetID.uuidString, currentFingerprint: fp1) == false)

        // 7. Scope change — authorize Source B. The case revision advances; the fingerprint changes.
        c = try await rig.cases.includeSource(caseID: caseID, expectedRevision: c.revision,
                                              sourceRef: vB.uuidString, sourceKind: .sourceVersion, actor: "investigator", at: t0)
        let ctx2 = try await rig.answers.scopeContext(caseID: caseID)
        let fp2 = ctx2.fingerprint
        #expect(Set(ctx2.scope.authorizedSourceVersionIDs) == Set([vA, vB]))
        #expect(fp2 != fp1)
        #expect(ctx2.caseRevision > ctx1.caseRevision)

        // 8. Every prior artifact is now STALE, yet each retains its original fp1 (history unchanged).
        #expect(try await rig.ledger.isStale(caseID: caseID, kind: .ask, artifactID: "ask-approval-question", currentFingerprint: fp2) == true)
        #expect(try await rig.ledger.isStale(caseID: caseID, kind: .methodRun, artifactID: started.run.id.uuidString, currentFingerprint: fp2) == true)
        #expect(try await rig.ledger.isStale(caseID: caseID, kind: .workbenchDataset, artifactID: firstDatasetID.uuidString, currentFingerprint: fp2) == true)
        #expect(try await rig.ledger.artifact(caseID: caseID, kind: .workbenchDataset, artifactID: firstDatasetID.uuidString)?.fingerprint == fp1)
        // The historical dataset itself was NOT rewritten — it still binds only A.
        #expect(try await rig.datasets.bindings(datasetID: firstDatasetID).map(\.sourceVersionID) == [vA])

        // 9. Explicit rerun under the NEW scope uses fp2 and produces a fresh, non-stale artifact (A+B).
        let rerun = try await rig.datalab.prepareSourceInventory(caseID: caseID, access: .testUnrestricted(), actor: "investigator", at: t0)
        #expect(Set(rerun.includedSourceVersionIDs) == Set([vA, vB]))
        let secondDatasetID = rerun.dataset.dataset.id
        #expect(secondDatasetID != firstDatasetID)
        _ = try await rig.ledger.record(caseID: caseID, kind: .workbenchDataset, artifactID: secondDatasetID.uuidString,
                                        fingerprint: fp2, caseRevision: ctx2.caseRevision, at: t0)
        #expect(try await rig.ledger.isStale(caseID: caseID, kind: .workbenchDataset, artifactID: secondDatasetID.uuidString, currentFingerprint: fp2) == false)

        // 10. Reopen — a fresh set of repositories over the same database sees the durable state.
        let reCases = InvestigationCaseRepository(database: rig.db)
        let reLedger = InvestigationScopeLedger(database: rig.db)
        let reDatasets = WorkbenchDatasetRepository(database: rig.db)
        let reopened = try await reCases.fetch(caseID: caseID)
        #expect(reopened?.caseHeader.revision == ctx2.caseRevision)
        #expect(Set(reopened?.sources.filter(\.inScope).map(\.sourceRef) ?? []) == Set([vA.uuidString, vB.uuidString]))
        #expect(try await reLedger.artifacts(caseID: caseID).count == 4)   // ask + methodRun + 2 datasets
        #expect(try await reDatasets.bindings(datasetID: firstDatasetID).map(\.sourceVersionID) == [vA])   // history intact after reopen
    }

    // MARK: - One fingerprint system, end to end

    @Test("Ask, Methods, and DataLab all resolve the SAME fingerprint for the same case scope")
    func oneFingerprintAcrossEngines() async throws {
        let rig = try await rig()
        var c = try await rig.cases.createCase(workspaceID: rig.ws, title: "Deviation", actor: "u", at: t0)
        c = try await rig.cases.includeSource(caseID: c.id, expectedRevision: c.revision,
                                              sourceRef: vA.uuidString, sourceKind: .sourceVersion, actor: "u", at: t0)
        // The Ask entry point exposes the resolved context; Methods/DataLab resolve the SAME scope via the
        // one CaseRetrievalScopeResolver, so the canonical fingerprint is identical across all three.
        let ctx = try await rig.answers.scopeContext(caseID: c.id)
        let started = try await rig.methods.startMethod(caseID: c.id, methodDefinitionID: "com.kalsmritikosh.method.timeline-analysis",
            evidenceSpecs: [InvestigationMethodEvidenceSpec(targetKind: .sourceVersion, targetID: vA, ordinal: 0)],
            createdBy: "u", now: t0)
        let prepared = try await rig.datalab.prepareSourceInventory(caseID: c.id, access: .testUnrestricted(), actor: "u", at: t0)
        let methodFP = CaseScopeFingerprinter.fingerprint(caseID: c.id, caseRevision: ctx.caseRevision, scope: started.scope)
        let datalabFP = CaseScopeFingerprinter.fingerprint(caseID: c.id, caseRevision: ctx.caseRevision, scope: prepared.scope)
        #expect(methodFP == ctx.fingerprint)
        #expect(datalabFP == ctx.fingerprint)
    }

    // MARK: - Closed case still honours the scope boundary

    @Test("A case with no authorized sources produces an honest-empty Ask/DataLab — never a workspace widen")
    func emptyScopeIsHonest() async throws {
        let rig = try await rig()
        let c = try await rig.cases.createCase(workspaceID: rig.ws, title: "No sources yet", actor: "u", at: t0)
        // Source B exists in the workspace and holds the direct answer, but the case authorizes nothing.
        let answered = try await rig.answers.answer(caseID: c.id, question: intent.rawQuestion, access: .testUnrestricted())
        #expect(answered.context.scope.authorizedSourceVersionIDs.isEmpty)
        #expect(!answered.verified.body.contains(bDirectAnswer))
        #expect(answered.verified.citations.allSatisfy { $0.objectID != koB && $0.objectID != koA })
        let prepared = try await rig.datalab.prepareSourceInventory(caseID: c.id, access: .testUnrestricted(), actor: "u", at: t0)
        #expect(prepared.includedSourceVersionIDs.isEmpty)
        #expect(try await rig.datasets.rows(datasetID: prepared.dataset.dataset.id).isEmpty)
    }
}
