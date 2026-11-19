//
//  CaseInquiryTests.swift
//  KalsmritikoshTests
//
//  Case plan 2026-11-16 (REASON-15): a line of inquiry beside its explanation (predictions, discriminator, assumptions,
//  originating methods) and append-only decisions; no resurrection on unchanged evidence; a changed source raises it again
//  with the exact reason; a merge names another line of the case; v193 from v192.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Lines of inquiry — the record and its decisions", .serialized)
struct CaseInquiryTests {

    private func hypothesis(_ f: CaseFileTests.Fixture, _ statement: String) async throws -> UUID {
        let id = UUID()
        try await f.db.exec("""
            INSERT INTO investigation_hypotheses (id, case_id, kind, statement, status, revision, actor, created_at, updated_at)
            VALUES (?,?,'hypothesis',?,'proposed',1,'Ada',1,1);
            """, [.uuid(id), .uuid(f.caseID), .text(statement)])
        return id
    }

    @Test("A line keeps its predictions, discriminator, assumptions and methods; a revision is counted")
    func lineRoundTrip() async throws {
        let f = try await CaseFileTests.fixture(title: "Why did batch 42 fail?")
        let h = try await hypothesis(f, "Instrument drift")
        #expect(try await f.file.recordInquiryLine(caseID: f.caseID, hypothesisID: h, predictions: "Controls drift the same week",
                                                     discriminator: "The calibration log for HPLC-2", assumptions: "The control samples were stored correctly",
                                                     methods: ["com.kalsmritikosh.method.fishbone"], actor: "Ada") == 1)
        #expect(try await f.file.recordInquiryLine(caseID: f.caseID, hypothesisID: h, predictions: "Controls drift the same week",
                                                     discriminator: "The calibration log and the service record", assumptions: "", methods: [], actor: "Ada") == 2)
        let line = try #require(try await f.file.inquiryLines(caseID: f.caseID).first)
        #expect(line.hypothesisID == h && line.revision == 2 && line.discriminator.contains("service record"))
        await #expect(throws: (any Error).self) {
            _ = try await f.file.recordInquiryLine(caseID: f.caseID, hypothesisID: UUID(), predictions: "", discriminator: "", assumptions: "", methods: [], actor: "Ada")
        }
    }

    @Test("Decisions are append-only; unchanged evidence never resurrects a set-aside line; a changed source raises it with the reason")
    func decisionsAndResurfacing() async throws {
        let f = try await CaseFileTests.fixture(title: "Why did batch 42 fail?")
        let supplier = try await hypothesis(f, "Supplier variation"), drift = try await hypothesis(f, "Instrument drift")
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        _ = try await f.file.decideInquiry(caseID: f.caseID, hypothesisID: supplier, decision: .pursued, reason: "Certificate pending",
                                           basisFingerprint: "fp1", actor: "Ada", at: t0)
        _ = try await f.file.decideInquiry(caseID: f.caseID, hypothesisID: drift, decision: .rejected, reason: "Calibration current",
                                           basisFingerprint: "fp1", actor: "Ada", at: t0.addingTimeInterval(60))
        let decisions = try await f.file.inquiryDecisions(caseID: f.caseID)
        #expect(decisions.count == 2 && CaseInquiryState.current(decisions, line: drift)?.decision == .rejected)
        #expect(CaseInquiryState.resurface(decisions, line: drift, currentFingerprint: "fp1") == nil, "same evidence: stays set aside")
        let why = try #require(CaseInquiryState.resurface(decisions, line: drift, currentFingerprint: "fp2"))
        #expect(why.contains("Calibration current") && why.contains("has changed"))
        #expect(CaseInquiryState.resurface(decisions, line: supplier, currentFingerprint: "fp2") == nil, "a pursued line is not resurfaced")
        // A decision is never edited.
        await #expect(throws: (any Error).self) {
            try await f.db.exec("UPDATE case_inquiry_decisions SET reason = 'x';", [])
        }
        // A merge names another line of this case; it can be undone by reopening.
        await #expect(throws: (any Error).self) {
            _ = try await f.file.decideInquiry(caseID: f.caseID, hypothesisID: drift, decision: .merged, mergedInto: drift, reason: "same",
                                               basisFingerprint: nil, actor: "Ada")
        }
        _ = try await f.file.decideInquiry(caseID: f.caseID, hypothesisID: drift, decision: .merged, mergedInto: supplier, reason: "Same observation",
                                           basisFingerprint: "fp2", actor: "Ada", at: t0.addingTimeInterval(120))
        _ = try await f.file.decideInquiry(caseID: f.caseID, hypothesisID: drift, decision: .reopened, reason: "Different instrument after all",
                                           basisFingerprint: "fp2", actor: "Ada", at: t0.addingTimeInterval(180))
        let after = try await f.file.inquiryDecisions(caseID: f.caseID)
        #expect(after.count == 4 && CaseInquiryState.current(after, line: drift)?.decision == .reopened)
    }
}
