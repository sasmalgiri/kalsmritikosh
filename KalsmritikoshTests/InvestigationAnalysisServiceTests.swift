//
//  InvestigationAnalysisServiceTests.swift
//  KalsmritikoshTests
//
//  INV-04..07 — the Investigator analytical spine over the shared engines. Proves: a lead is captured as a
//  proposal and PROMOTED by a human (INV-04); a hypothesis is scored by its COUNTED for/against evidence
//  profile and can be CONFIRMED only when supported — an unsupported one stays a proposal (INV-07); every
//  citation must be inside the case scope AND belong to the cited version (INV-05/07); a 5W1H cell either
//  cites in-scope evidence or is marked unknown, never fabricated (INV-05); evidence requests link to
//  hypotheses (INV-06); and the "conflicting accounts" gold case + architecture boundary. Synthetic only.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("INV-04..07 — analytical spine", .serialized)
struct InvestigationAnalysisServiceTests {

    private let t0 = Date(timeIntervalSince1970: 1_767_400_000)

    private struct Rig {
        let db: Database
        let cases: InvestigationCaseRepository
        let service: InvestigationAnalysisService
        let caseID: UUID
        let vA: UUID, koA: UUID, koA2: UUID
        let vB: UUID, koB: UUID   // unauthorized
    }

    private func rig() async throws -> Rig {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let ws = UUID()
        try await db.exec("INSERT INTO workspaces (id, title, created_at, updated_at) VALUES (?,?,?,?);", [.uuid(ws), .text("Matter"), .real(1), .real(1)])
        let (vA, logicalA) = try await seedSourceVersion(db)
        let koA = try await seedKO(db, logical: logicalA)
        let koA2 = try await seedKO(db, logical: logicalA)
        let (vB, logicalB) = try await seedSourceVersion(db)   // real, unauthorized
        let koB = try await seedKO(db, logical: logicalB)
        let cases = InvestigationCaseRepository(database: db)
        let evidence = EvidenceStore(database: db)
        var c = try await cases.createCase(workspaceID: ws, title: "Conflicting accounts", actor: "analyst", at: t0)
        c = try await cases.includeSource(caseID: c.id, expectedRevision: c.revision, sourceRef: vA.uuidString, sourceKind: .sourceVersion, actor: "analyst", at: t0)
        let service = InvestigationAnalysisService(cases: cases, resolver: CaseRetrievalScopeResolver(evidence: evidence),
                                                   evidence: evidence, analysis: InvestigationAnalysisRepository(database: db))
        return Rig(db: db, cases: cases, service: service, caseID: c.id, vA: vA, koA: koA, koA2: koA2, vB: vB, koB: koB)
    }

    // MARK: - INV-04 Brainstorm board

    @Test("A lead is captured as a proposal and PROMOTED to a hypothesis by a human")
    func captureAndPromote() async throws {
        let rig = try await rig()
        let lead = try await rig.service.captureLead(caseID: rig.caseID, statement: "Vendor overbilled deliberately", actor: "a", at: t0)
        #expect(lead.kind == .lead && lead.status == .proposed)
        let hyp = try await rig.service.promoteLead(hypothesisID: lead.id, expectedRevision: lead.revision, actor: "lead", at: t0)
        #expect(hyp.kind == .hypothesis && hyp.status == .proposed)
        // A hypothesis cannot be promoted again.
        await #expect(throws: InvestigationHypothesisError.self) {
            _ = try await rig.service.promoteLead(hypothesisID: hyp.id, expectedRevision: hyp.revision, actor: "lead", at: t0)
        }
    }

    // MARK: - INV-07 Hypothesis matrix

    @Test("A hypothesis is confirmed only when its counted evidence profile supports it; unsupported stays a proposal")
    func confirmRequiresSupport() async throws {
        let rig = try await rig()
        let hyp = try await rig.service.captureHypothesis(caseID: rig.caseID, statement: "Payment was duplicated", actor: "a", at: t0)
        // No supporting evidence yet → cannot confirm.
        await #expect(throws: InvestigationHypothesisError.self) {
            _ = try await rig.service.confirmHypothesis(hypothesisID: hyp.id, expectedRevision: hyp.revision, actor: "lead", at: t0)
        }
        #expect(try await rig.service.hypotheses(caseID: rig.caseID).first?.status == .proposed)   // still a proposal
        // Add against then for; profile = 1 for / 1 against → supported (for >= against, for > 0).
        try await rig.service.addEvidence(caseID: rig.caseID, hypothesisID: hyp.id, stance: .opposing, sourceVersionID: rig.vA, knowledgeObjectID: rig.koA, note: nil, actor: "a", at: t0)
        try await rig.service.addEvidence(caseID: rig.caseID, hypothesisID: hyp.id, stance: .supporting, sourceVersionID: rig.vA, knowledgeObjectID: rig.koA2, note: nil, actor: "a", at: t0)
        let profile = try await rig.service.profile(hypothesisID: hyp.id)
        #expect(profile.forCount == 1 && profile.againstCount == 1 && profile.isSupported)
        let confirmed = try await rig.service.confirmHypothesis(hypothesisID: hyp.id, expectedRevision: hyp.revision, actor: "lead", at: t0)
        #expect(confirmed.status == .confirmed)
    }

    @Test("A hypothesis with only opposing evidence is unsupported and cannot be confirmed")
    func opposingOnlyUnsupported() async throws {
        let rig = try await rig()
        let hyp = try await rig.service.captureHypothesis(caseID: rig.caseID, statement: "Theory X", actor: "a", at: t0)
        try await rig.service.addEvidence(caseID: rig.caseID, hypothesisID: hyp.id, stance: .opposing, sourceVersionID: rig.vA, knowledgeObjectID: rig.koA, note: nil, actor: "a", at: t0)
        #expect(try await rig.service.profile(hypothesisID: hyp.id).isSupported == false)
        await #expect(throws: InvestigationHypothesisError.self) {
            _ = try await rig.service.confirmHypothesis(hypothesisID: hyp.id, expectedRevision: hyp.revision, actor: "lead", at: t0)
        }
        // Rejecting is always allowed.
        let rejected = try await rig.service.rejectHypothesis(hypothesisID: hyp.id, expectedRevision: hyp.revision, actor: "lead", at: t0)
        #expect(rejected.status == .rejected)
    }

    // MARK: - Scope boundary on citations

    @Test("Evidence citations must be in the case scope and belong to the cited version")
    func citationScopeBoundary() async throws {
        let rig = try await rig()
        let hyp = try await rig.service.captureHypothesis(caseID: rig.caseID, statement: "H", actor: "a", at: t0)
        // Unauthorized source version.
        await #expect(throws: InvestigationHypothesisError.self) {
            try await rig.service.addEvidence(caseID: rig.caseID, hypothesisID: hyp.id, stance: .supporting, sourceVersionID: rig.vB, knowledgeObjectID: rig.koB, note: nil, actor: "a", at: t0)
        }
        // Authorized version but a knowledge object that belongs to a DIFFERENT version (mismatch).
        await #expect(throws: InvestigationHypothesisError.self) {
            try await rig.service.addEvidence(caseID: rig.caseID, hypothesisID: hyp.id, stance: .supporting, sourceVersionID: rig.vA, knowledgeObjectID: rig.koB, note: nil, actor: "a", at: t0)
        }
        #expect(try await rig.service.evidence(hypothesisID: hyp.id).isEmpty)   // nothing recorded
    }

    // MARK: - INV-05 5W1H worksheet

    @Test("A 5W1H cell either cites in-scope evidence or is marked unknown; an out-of-scope citation is refused")
    func worksheetCiteOrUnknown() async throws {
        let rig = try await rig()
        let answered = try await rig.service.answerCell(caseID: rig.caseID, dimension: .who, answer: "Alice Vendor",
                                                        sourceVersionID: rig.vA, knowledgeObjectID: rig.koA, actor: "a", at: t0)
        #expect(answered.status == .answered && answered.sourceVersionID == rig.vA)
        let unknown = try await rig.service.markCellUnknown(caseID: rig.caseID, dimension: .why, actor: "a", at: t0)
        #expect(unknown.status == .unknown && unknown.answerText == nil && unknown.sourceVersionID == nil)
        // An out-of-scope citation cannot answer a cell.
        await #expect(throws: InvestigationHypothesisError.self) {
            _ = try await rig.service.answerCell(caseID: rig.caseID, dimension: .what, answer: "X", sourceVersionID: rig.vB, knowledgeObjectID: rig.koB, actor: "a", at: t0)
        }
        #expect(try await rig.service.cells(caseID: rig.caseID).count == 2)
    }

    // MARK: - INV-06 Evidence collection plan

    @Test("An evidence request links to a hypothesis and is confirmed/fulfilled by a human")
    func evidenceRequestLifecycle() async throws {
        let rig = try await rig()
        let hyp = try await rig.service.captureHypothesis(caseID: rig.caseID, statement: "Need the vendor contract", actor: "a", at: t0)
        let req = try await rig.service.createEvidenceRequest(caseID: rig.caseID, hypothesisID: hyp.id, description: "Obtain the signed vendor contract", actor: "a", at: t0)
        #expect(req.status == .open && req.hypothesisID == hyp.id)
        let confirmed = try await rig.service.confirmRequest(requestID: req.id, expectedRevision: req.revision, actor: "lead", at: t0)
        #expect(confirmed.status == .confirmed)
        let fulfilled = try await rig.service.fulfillRequest(requestID: confirmed.id, expectedRevision: confirmed.revision, actor: "lead", at: t0)
        #expect(fulfilled.status == .fulfilled)
    }

    // MARK: - Gold case: conflicting accounts

    @Test("Conflicting accounts gold case: two rival hypotheses scored; only the supported one is confirmed; reopen persists")
    func conflictingAccountsGoldCase() async throws {
        let rig = try await rig()
        // Two rival hypotheses about a disputed event.
        let hA = try await rig.service.captureHypothesis(caseID: rig.caseID, statement: "The transfer was authorized", actor: "a", at: t0)
        let hB = try await rig.service.captureHypothesis(caseID: rig.caseID, statement: "The transfer was NOT authorized", actor: "a", at: t0)
        // Evidence from the ONE authorized source: supports A, opposes B.
        try await rig.service.addEvidence(caseID: rig.caseID, hypothesisID: hA.id, stance: .supporting, sourceVersionID: rig.vA, knowledgeObjectID: rig.koA, note: "approval email", actor: "a", at: t0)
        try await rig.service.addEvidence(caseID: rig.caseID, hypothesisID: hB.id, stance: .opposing, sourceVersionID: rig.vA, knowledgeObjectID: rig.koA, note: "same approval email", actor: "a", at: t0)
        // A is supported; B is not.
        #expect(try await rig.service.profile(hypothesisID: hA.id).isSupported)
        #expect(try await rig.service.profile(hypothesisID: hB.id).isSupported == false)
        let confirmedA = try await rig.service.confirmHypothesis(hypothesisID: hA.id, expectedRevision: hA.revision, actor: "lead", at: t0)
        #expect(confirmedA.status == .confirmed)
        await #expect(throws: InvestigationHypothesisError.self) {   // B stays a proposal — no autonomous winner
            _ = try await rig.service.confirmHypothesis(hypothesisID: hB.id, expectedRevision: hB.revision, actor: "lead", at: t0)
        }
        // A request to resolve the conflict; a 5W1H cell answered + one unknown.
        _ = try await rig.service.createEvidenceRequest(caseID: rig.caseID, hypothesisID: hB.id, description: "Interview the approver", actor: "a", at: t0)
        _ = try await rig.service.answerCell(caseID: rig.caseID, dimension: .who, answer: "Approver", sourceVersionID: rig.vA, knowledgeObjectID: rig.koA, actor: "a", at: t0)
        _ = try await rig.service.markCellUnknown(caseID: rig.caseID, dimension: .why, actor: "a", at: t0)
        // Reopen: everything persists.
        let reopened = InvestigationAnalysisRepository(database: rig.db)
        #expect(try await reopened.hypotheses(caseID: rig.caseID).filter { $0.status == .confirmed }.count == 1)
        #expect(try await reopened.requests(caseID: rig.caseID).count == 1)
        #expect(try await reopened.cells(caseID: rig.caseID).count == 2)
    }

    // MARK: - Architecture boundary

    @Test("The analytical services fork no Claim/gap/contradiction authority and name no models; AppState wires them")
    func boundary() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Kalsmritikosh/Personas/Investigator")
        for name in ["InvestigationAnalysisService.swift", "InvestigationAnalysisRepository.swift", "InvestigationHypothesis.swift"] {
            let src = (try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)) ?? ""
            #expect(!src.isEmpty, "\(name) missing")
            for banned in ["INSERT INTO claims", "INSERT INTO gap_nodes", "INSERT INTO contradictions"] {
                #expect(!src.contains(banned), "\(name) forks a canonical authority: \(banned)")
            }
            let lower = src.lowercased()
            for m in ["qwen", "gemma", "deepseek", "mistral", "nomic", "llama", "gpt"] { #expect(!lower.contains(m)) }
        }
        let app = (try? String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Kalsmritikosh/App/AppState.swift"), encoding: .utf8)) ?? ""
        #expect(app.contains("InvestigationAnalysisService("))
        #expect(app.contains("investigationAnalysis"))
    }

    // MARK: - Seed helpers

    private func seedSourceVersion(_ db: Database) async throws -> (version: UUID, logical: UUID) {
        let version = UUID(), logical = UUID()
        try await db.exec("INSERT INTO files (id, url, source_type, availability) VALUES (?,?,?,?);",
                          [.uuid(logical), .text("file:///x/\(logical.uuidString)"), .text("txt"), .text("available")])
        try await db.exec("""
            INSERT INTO source_versions (id, logical_source_id, content_hash, valid_from, is_current, created_at,
                filename, detected_type, detection_basis, size_bytes, custody_mode, preservation_status, intake_recorded_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?);
            """, [.uuid(version), .uuid(logical), .text(String(repeating: "d", count: 64)), .real(100), .integer(1), .real(100),
                  .text("f.txt"), .text("txt"), .text("magicBytes"), .integer(1), .text("referenced"), .text("referenceRecorded"), .real(100)])
        return (version, logical)
    }
    private func seedKO(_ db: Database, logical: UUID) async throws -> UUID {
        let ko = UUID()
        try await db.exec("INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at) VALUES (?,?,?,?,?,?);",
                          [.uuid(ko), .uuid(logical), .text("txt"), .text("body"), .real(1), .real(1)])
        return ko
    }
}
