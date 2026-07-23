//
//  EvidenceAssessmentModelTests.swift
//  Kalsmritikosh Tests
//
//  S0.5 item 2, Commit C — the models now carry a canonical EvidenceAssessment (with a
//  deprecated status/evidenceStatus shim), and the repositories write from the assessment
//  and read it back through the per-field decoder. These tests prove: legacy and canonical
//  constructors agree; HistoryItem's review is reconciled to reviewStatus; assessments
//  round-trip through the DB; repository writes never synthesise a human review status into
//  the evidence basis; and a row with an unknown dimension still loads.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("S0.5 item 2 C — assessment on models + repository round-trip")
struct EvidenceAssessmentModelTests {

    private func freshDB() async throws -> Database {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("am-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try Database(url: dir.appendingPathComponent("t.sqlite"))
        try await SchemaMigrations.migrate(db)
        return db
    }

    @Test("Legacy and canonical GenericFact constructors agree")
    func genericFactConstructorsAgree() {
        let legacy = GenericFact(subjectLabel: "S", field: "employer", value: "Orchid",
                                 status: .sourceAsserted, confidence: 0.7, sourceBlockIDs: [UUID()])
        let canonical = GenericFact(subjectLabel: "S", field: "employer", value: "Orchid",
                                    assessment: LegacyEvidenceStatusAdapter.decode(.sourceAsserted),
                                    confidence: 0.7, sourceBlockIDs: [UUID()])
        #expect(legacy.assessment == canonical.assessment)
        #expect(legacy.assessment.basis == .sourceAsserted)
    }

    @Test("HistoryItem reconciles assessment.review to its reviewStatus (both init paths)")
    func historyItemReviewReconciled() {
        let subject = UUID()
        let legacy = HistoryItem(subject: .person(subject), kind: .event, title: "e",
                                 evidenceStatus: .sourceAsserted, confidence: 0.8, reviewStatus: .accepted)
        #expect(legacy.assessment.review == .confirmed)          // accepted → confirmed, reconciled
        #expect(legacy.assessment.basis == .sourceAsserted)
        // Canonical path also reconciles review from reviewStatus.
        let canonical = HistoryItem(subject: .person(subject), kind: .event, title: "e",
                                    assessment: EvidenceAssessment(basis: .directlyObserved, review: .unreviewed, origin: .sourceExtraction),
                                    confidence: 0.8, reviewStatus: .rejected)
        #expect(canonical.assessment.review == .rejected)        // reviewStatus wins for consistency
    }

    @Test("GenericFact assessment round-trips through the repository")
    func genericFactRoundTrip() async throws {
        let db = try await freshDB()
        let repo = GenericFactRepository(database: db)
        let subject = UUID()
        // A corroborated, human-confirmed-over-known-basis fact.
        let a = EvidenceAssessment(basis: .directlyObserved, review: .confirmed, origin: .sourceExtraction,
                                   availability: .present, conflict: .none)
        try await repo.upsert(GenericFact(subjectID: subject, subjectLabel: "S", field: "employer",
                                          value: "Orchid", assessment: a, confidence: 0.9, sourceBlockIDs: [UUID()]))
        let back = try #require(try await repo.facts(subjectID: subject).first)
        #expect(back.assessment.basis == .directlyObserved)      // dimensions preserved, not re-derived from status
        #expect(back.assessment.review == .confirmed)
    }

    @Test("Repository writes never place a human review status into the evidence basis")
    func noHumanReviewAsBasis() async throws {
        let db = try await freshDB()
        let repo = GenericFactRepository(database: db)
        let subject = UUID()
        // Confirmed over a source-asserted basis.
        let a = EvidenceAssessment(basis: .sourceAsserted, review: .confirmed, origin: .sourceExtraction)
        try await repo.upsert(GenericFact(subjectID: subject, subjectLabel: "S", field: "employer",
                                          value: "Orchid", assessment: a, confidence: 0.8, sourceBlockIDs: [UUID()]))
        let r = try #require(try await db.query(
            "SELECT status, evidence_basis, review_disposition FROM generic_facts WHERE subject_id = ?;",
            [.uuid(subject)]).first)
        // The compatibility status column must NOT be a human status (basis wins in encode).
        #expect(r.string(0) == "SOURCE_ASSERTED")
        #expect(r.string(0) != "HUMAN_CONFIRMED")
        #expect(r.string(1) == "sourceAsserted")     // basis unaffected by the confirmation
        #expect(r.string(2) == "confirmed")           // review recorded in its own dimension
    }

    @Test("A stored row with an unknown dimension still loads (row not dropped)")
    func unknownDimensionRowLoads() async throws {
        let db = try await freshDB()
        let repo = GenericFactRepository(database: db)
        let subject = UUID(), id = UUID()
        // Raw insert with a malformed evidence_basis but a valid legacy status.
        try await db.exec("""
        INSERT INTO generic_facts (id, subject_id, subject_label, field, value, status, confidence, source_blocks_json, created_at, evidence_basis, legacy_status)
        VALUES (?, ?, 'S', 'employer', 'Orchid', 'SOURCE_ASSERTED', 0.7, '[]', 0, 'FUTURE_BASIS', 'SOURCE_ASSERTED');
        """, [.uuid(id), .uuid(subject)])
        let facts = try await repo.facts(subjectID: subject)
        #expect(facts.count == 1)                                 // not dropped
        #expect(facts.first?.assessment.basis == .sourceAsserted) // recovered from legacy status
    }

    @Test("TemporalClaim assessment round-trips through the repository")
    func temporalClaimRoundTrip() async throws {
        let db = try await freshDB()
        let repo = TemporalClaimRepository(database: db)
        let subject = UUID()
        let a = EvidenceAssessment(basis: .sourceAsserted, review: .disputed, origin: .sourceExtraction)
        try await repo.insert(TemporalClaim(subjectID: subject, predicate: "worked_for", object: .literal("Orchid"),
                                            assessment: a, confidence: 0.6,
                                            extractorID: "x", extractorVersion: "1", createdAt: Date(timeIntervalSince1970: 0)))
        let back = try #require(try await repo.claims(subjectID: subject).first)
        #expect(back.assessment.basis == .sourceAsserted)
        #expect(back.assessment.review == .disputed)
    }
}
