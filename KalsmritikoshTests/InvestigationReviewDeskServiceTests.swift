//
//  InvestigationReviewDeskServiceTests.swift
//  KalsmritikoshTests
//
//  INV-08 (Source reliability) + INV-12 (Contradiction & gap desk). Proves both desks REUSE the shared
//  canonical authorities bounded to the case scope: the reliability schedule spans only authorized source
//  versions and flags a single-source case; a rating is recorded through the shared assessment repo and is
//  never a fact; contradictions/gaps are included only when their evidence is in-scope (both sides of a
//  contradiction preserved); a case confirm/dismiss is recorded WITHOUT mutating the shared item's global
//  status; the "conflicting accounts" gold case; and the architecture boundary. Synthetic only.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("INV-08/12 — reliability + contradiction/gap desks", .serialized)
struct InvestigationReviewDeskServiceTests {

    private let t0 = Date(timeIntervalSince1970: 1_767_500_000)

    private struct Rig {
        let db: Database
        let cases: InvestigationCaseRepository
        let reliabilitySvc: InvestigationReliabilityService
        let deskSvc: InvestigationContradictionGapService
        let contradictions: ContradictionsRepository
        let caseID: UUID
        let vA: UUID, koA: UUID, koA2: UUID
        let vB: UUID, koB: UUID
    }

    private func rig(authorizeBoth: Bool = false) async throws -> Rig {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let ws = UUID()
        try await db.exec("INSERT INTO workspaces (id, title, created_at, updated_at) VALUES (?,?,?,?);", [.uuid(ws), .text("Matter"), .real(1), .real(1)])
        let (vA, logicalA) = try await seedSourceVersion(db)
        let koA = try await seedKO(db, logical: logicalA)
        let koA2 = try await seedKO(db, logical: logicalA)
        let (vB, logicalB) = try await seedSourceVersion(db)
        let koB = try await seedKO(db, logical: logicalB)
        let cases = InvestigationCaseRepository(database: db)
        let evidence = EvidenceStore(database: db)
        let reviews = InvestigationDeskReviewRepository(database: db)
        var c = try await cases.createCase(workspaceID: ws, title: "Conflicting accounts", actor: "analyst", at: t0)
        c = try await cases.includeSource(caseID: c.id, expectedRevision: c.revision, sourceRef: vA.uuidString, sourceKind: .sourceVersion, actor: "analyst", at: t0)
        if authorizeBoth {
            c = try await cases.includeSource(caseID: c.id, expectedRevision: c.revision, sourceRef: vB.uuidString, sourceKind: .sourceVersion, actor: "analyst", at: t0)
        }
        let resolver = CaseRetrievalScopeResolver(evidence: evidence)
        let reliabilitySvc = InvestigationReliabilityService(cases: cases, resolver: resolver,
                                                             reliability: SourceReliabilityAssessmentRepository(database: db), reviews: reviews)
        let contradictions = ContradictionsRepository(database: db)
        let gaps = GapNodeRepository(database: db)
        let deskSvc = InvestigationContradictionGapService(cases: cases, resolver: resolver, evidence: evidence,
                                                           contradictions: contradictions, gaps: gaps, reviews: reviews)
        return Rig(db: db, cases: cases, reliabilitySvc: reliabilitySvc, deskSvc: deskSvc, contradictions: contradictions,
                   caseID: c.id, vA: vA, koA: koA, koA2: koA2, vB: vB, koB: koB)
    }

    // MARK: - INV-08 reliability

    @Test("The reliability schedule spans only authorized sources, flags single-source, and starts unrated")
    func scheduleScopedAndSingleSource() async throws {
        let rig = try await rig()
        let schedule = try await rig.reliabilitySvc.schedule(caseID: rig.caseID)
        #expect(schedule.map(\.sourceVersionID) == [rig.vA])       // only the authorized source
        #expect(schedule.allSatisfy { $0.isSingleSource })         // one authorized source → single-source case
        #expect(schedule.first?.assessment == nil)                 // a rating is never invented
        #expect(schedule.first?.review == nil)
    }

    @Test("Rating a source records it through the shared repo + a case confirmation; an out-of-scope source is refused")
    func assessAndConfirmScoped() async throws {
        let rig = try await rig()
        let (assessment, review) = try await rig.reliabilitySvc.assessAndConfirm(
            caseID: rig.caseID, sourceVersionID: rig.vA, reliability: .high, independence: .independent,
            rationale: "primary custodian", actor: "lead", at: t0)
        #expect(assessment.reliability == .high && assessment.independence == .independent)
        #expect(review.decision == .confirmed && review.itemKind == .reliability)
        let schedule = try await rig.reliabilitySvc.schedule(caseID: rig.caseID)
        #expect(schedule.first?.assessment?.reliability == .high)
        #expect(schedule.first?.review?.decision == .confirmed)
        // An unauthorized source cannot be rated in this case.
        await #expect(throws: InvestigationDeskError.self) {
            _ = try await rig.reliabilitySvc.assessAndConfirm(caseID: rig.caseID, sourceVersionID: rig.vB, reliability: .low,
                                                              independence: .unknown, rationale: nil, actor: "lead", at: t0)
        }
    }

    @Test("Rating on the Admiralty scale maps to the canonical rating and stamps the code into the rationale")
    func admiraltyScaleStampsCode() async throws {
        let rig = try await rig()
        let code = AdmiraltyCode(reliability: .b, credibility: .two)   // B2
        let (assessment, review) = try await rig.reliabilitySvc.assessAndConfirm(
            caseID: rig.caseID, sourceVersionID: rig.vA, admiralty: code, independence: .independent,
            rationale: "primary custodian", actor: "lead", at: t0)
        #expect(assessment.reliability == .high)   // B → high (the canonical stored rating)
        #expect(review.decision == .confirmed)
        #expect(assessment.rationale?.hasPrefix(code.rationaleLine) == true)
        #expect(assessment.rationale?.contains("B2") == true)
        #expect(assessment.rationale?.contains("primary custodian") == true)
    }

    // MARK: - INV-12 contradiction & gap desk

    @Test("Only in-scope contradictions appear; both sides are preserved; confirm/dismiss is case-scoped and leaves global status untouched")
    func contradictionsScopedAndBothSidesPreserved() async throws {
        let rig = try await rig()
        let inScope = UUID(), outScope = UUID()
        try await seedContradiction(rig.db, id: inScope, evidenceA: rig.koA, evidenceB: rig.koA2, status: "open")   // both in vA
        try await seedContradiction(rig.db, id: outScope, evidenceA: rig.koB, evidenceB: nil, status: "open")        // vB unauthorized
        let items = try await rig.deskSvc.contradictions(caseID: rig.caseID)
        #expect(items.map(\.contradiction.id) == [inScope])                     // only the in-scope one
        #expect(items.first?.contradiction.claimA.isEmpty == false && items.first?.contradiction.claimB.isEmpty == false)  // both sides kept
        // Dismiss it in this case; the shared contradiction's global status stays 'open'.
        let review = try await rig.deskSvc.dismissContradiction(caseID: rig.caseID, contradictionID: inScope, note: "not material to this case", actor: "lead", at: t0)
        #expect(review.decision == .dismissed)
        #expect(try await rig.contradictions.findByIDs([inScope]).first?.status == .open)   // global status UNTOUCHED
        // A case cannot dispose an out-of-scope contradiction.
        await #expect(throws: InvestigationDeskError.self) {
            _ = try await rig.deskSvc.confirmContradiction(caseID: rig.caseID, contradictionID: outScope, note: nil, actor: "lead", at: t0)
        }
    }

    @Test("Only in-scope gaps appear and can be dispositioned; an out-of-scope gap is refused")
    func gapsScoped() async throws {
        let rig = try await rig()
        let inScope = UUID(), outScope = UUID()
        try await seedGap(rig.db, id: inScope, evidence: rig.koA)
        try await seedGap(rig.db, id: outScope, evidence: rig.koB)
        let items = try await rig.deskSvc.gaps(caseID: rig.caseID)
        #expect(items.map(\.gap.id) == [inScope])
        let review = try await rig.deskSvc.confirmGap(caseID: rig.caseID, gapID: inScope, note: "must obtain", actor: "lead", at: t0)
        #expect(review.decision == .confirmed)
        await #expect(throws: InvestigationDeskError.self) {
            _ = try await rig.deskSvc.dismissGap(caseID: rig.caseID, gapID: outScope, note: nil, actor: "lead", at: t0)
        }
    }

    // MARK: - Gold case: conflicting accounts

    @Test("Conflicting accounts gold case: rate the source, review the in-scope contradiction (both sides kept) + a gap, reopen persists")
    func conflictingAccountsGoldCase() async throws {
        let rig = try await rig()
        let contradiction = UUID(), gap = UUID()
        try await seedContradiction(rig.db, id: contradiction, evidenceA: rig.koA, evidenceB: rig.koA2, status: "open")
        try await seedGap(rig.db, id: gap, evidence: rig.koA)
        // 1. Rate the single authorized source (a judgement, not a fact).
        _ = try await rig.reliabilitySvc.assessAndConfirm(caseID: rig.caseID, sourceVersionID: rig.vA, reliability: .medium,
                                                          independence: .affiliated, rationale: "single custodian", actor: "lead", at: t0)
        #expect(try await rig.reliabilitySvc.schedule(caseID: rig.caseID).first?.isSingleSource == true)
        // 2. The contradiction is in scope with both sides; confirm it for the case (global status untouched).
        _ = try await rig.deskSvc.confirmContradiction(caseID: rig.caseID, contradictionID: contradiction, note: nil, actor: "lead", at: t0)
        // 3. The gap is in scope; dismiss it for the case (absence is not proof).
        _ = try await rig.deskSvc.dismissGap(caseID: rig.caseID, gapID: gap, note: "explained elsewhere", actor: "lead", at: t0)
        // Reopen: the case dispositions persist; the shared items keep their own state.
        let reopenedReviews = InvestigationDeskReviewRepository(database: rig.db)
        #expect(try await reopenedReviews.reviews(caseID: rig.caseID).count == 3)   // reliability + contradiction + gap
        #expect(try await rig.contradictions.findByIDs([contradiction]).first?.status == .open)
    }

    // MARK: - Architecture boundary

    @Test("The desk services reuse the shared authorities and never mutate their global status; no model names; AppState wires them")
    func boundary() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Kalsmritikosh/Personas/Investigator")
        let desk = (try? String(contentsOf: dir.appendingPathComponent("InvestigationContradictionGapService.swift"), encoding: .utf8)) ?? ""
        #expect(!desk.isEmpty)
        // Never mutate shared global status from the case desk.
        #expect(!desk.contains("contradictions.setStatus("))
        #expect(!desk.contains("gaps.dismiss("))
        #expect(!desk.contains("gaps.reopen("))
        for name in ["InvestigationReliabilityService.swift", "InvestigationContradictionGapService.swift", "InvestigationDeskReview.swift"] {
            let lower = ((try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)) ?? "").lowercased()
            for m in ["qwen", "gemma", "deepseek", "mistral", "nomic", "llama", "gpt"] { #expect(!lower.contains(m)) }
        }
        let app = (try? String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Kalsmritikosh/App/AppState.swift"), encoding: .utf8)) ?? ""
        #expect(app.contains("InvestigationReliabilityService("))
        #expect(app.contains("InvestigationContradictionGapService("))
        #expect(app.contains("investigationReliability") && app.contains("investigationContradictionGap"))
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
            """, [.uuid(version), .uuid(logical), .text(String(repeating: "e", count: 64)), .real(100), .integer(1), .real(100),
                  .text("f.txt"), .text("txt"), .text("magicBytes"), .integer(1), .text("referenced"), .text("referenceRecorded"), .real(100)])
        return (version, logical)
    }
    private func seedKO(_ db: Database, logical: UUID) async throws -> UUID {
        let ko = UUID()
        try await db.exec("INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at) VALUES (?,?,?,?,?,?);",
                          [.uuid(ko), .uuid(logical), .text("txt"), .text("body"), .real(1), .real(1)])
        return ko
    }
    private func seedContradiction(_ db: Database, id: UUID, evidenceA: UUID?, evidenceB: UUID?, status: String) async throws {
        try await db.exec("""
            INSERT INTO contradictions (id, description, claim_a, claim_b, evidence_a, evidence_b, severity, status, detected_at, kind)
            VALUES (?,?,?,?,?,?,?,?,?,?);
            """, [.uuid(id), .text("Amounts disagree"), .text("paid 500"), .text("paid 600"),
                  evidenceA.map { SQLValue.uuid($0) } ?? .null, evidenceB.map { SQLValue.uuid($0) } ?? .null,
                  .text("high"), .text(status), .real(1), .text("amount")])
    }
    private func seedGap(_ db: Database, id: UUID, evidence: UUID?) async throws {
        try await db.exec("""
            INSERT INTO gap_nodes (id, kind, description, reason, confidence, near_entity, before_event, after_event, evidence_object_id, detected_at, dismissed)
            VALUES (?,?,?,?,?,?,?,?,?,?,?);
            """, [.uuid(id), .text("paymentProof"), .text("Missing receipt"), .text("payment referenced but no proof attached"),
                  .real(0.3), .null, .null, .null, evidence.map { SQLValue.uuid($0) } ?? .null, .real(1), .integer(0)])
    }
}
