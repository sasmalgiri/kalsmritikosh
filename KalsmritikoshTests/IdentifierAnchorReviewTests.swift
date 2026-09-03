//
//  IdentifierAnchorReviewTests.swift
//  KalsmritikoshTests
//
//  V3 3d (I-5) — the anchor split-suspect detector: OCR-near-duplicate anchors
//  under one field get a REVERSIBLE proposed-merge (a system FactReview), never
//  an auto-fold; genuinely-distinct identifiers (a non-OCR difference, a
//  coincidence across two fields) do not; date-inconsistent anchors are flagged;
//  and a split-suspect never threads a milestone chain.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("V3 3d — IdentifierAnchorReview (I-5)")
struct IdentifierAnchorReviewTests {

    // MARK: - Pure detector

    @Test("OCR-near-duplicate: only OCR-confusable, same-length, ≤2 substitutions")
    func ocrNearDuplicate() {
        let f = IdentifierAnchorReview.isOCRNearDuplicate
        #expect(f("555489", "S55489", 2))                 // 5↔S, 1 edit
        #expect(f("202211045678", "2022ll045678", 2))     // 1↔l, 2 edits
        #expect(f("B8", "88", 2))                          // 8↔B
        #expect(!f("555489", "555480", 2))                 // 9↔0 is NOT a confusion class → distinct
        #expect(!f("555489", "555489", 2))                 // identical → already one anchor, not a suspect
        #expect(!f("555489", "SSS489", 2))                 // 3 confusable edits > max
        #expect(!f("555489", "55548", 2))                  // length change → distinct (OCR substitutes, never drops)
    }

    @Test("Date inconsistency: a grant before its filing is a split-suspect")
    func dateInconsistency() {
        let filing = Date(timeIntervalSince1970: 1_600_000_000)
        let grant  = Date(timeIntervalSince1970: 1_500_000_000)   // earlier than filing
        #expect(IdentifierAnchorReview.isDateInconsistent(filing: filing, grant: grant))
        #expect(!IdentifierAnchorReview.isDateInconsistent(filing: grant, grant: filing))
        #expect(!IdentifierAnchorReview.isDateInconsistent(filing: filing, grant: nil))
    }

    private func anchor(_ field: String, _ value: String) -> Entity {
        IdentifierAnchor.makeAnchor(field: field, value: value, sourceObjectID: UUID())
    }

    @Test("proposedMerges: OCR-alike under one field → one reversible proposal (digit form is the target)")
    func proposedMergesDirectionAndCoincidence() {
        let patentReal = anchor("patentNumber", "555489")
        let patentOCR  = anchor("patentNumber", "S55489")
        let props = IdentifierAnchorReview.proposedMerges(among: [patentOCR, patentReal])
        #expect(props.count == 1)
        #expect(props.first?.toAnchorID == patentReal.id, "the clean digit form should be the merge target")
        #expect(props.first?.fromAnchorID == patentOCR.id, "the OCR-corrupt form should be the suspect")

        // Coincidence (D2): same digits under DIFFERENT fields is NOT a merge —
        // patent 555489 and invoice 555489 are legitimately two things.
        let invoice = anchor("invoiceNumber", "555489")
        #expect(IdentifierAnchorReview.proposedMerges(among: [patentReal, invoice]).isEmpty)

        // Genuinely distinct numbers under one field → no proposal.
        let other = anchor("patentNumber", "555480")
        #expect(IdentifierAnchorReview.proposedMerges(among: [patentReal, other]).isEmpty)
    }

    @Test("splitSuspectAnchorIDs returns the suspect (from) side")
    func splitSuspects() {
        let real = anchor("patentNumber", "555489")
        let ocr  = anchor("patentNumber", "S55489")
        #expect(IdentifierAnchorReview.splitSuspectAnchorIDs(among: [real, ocr]) == [ocr.id])
    }

    // MARK: - Repo integration: proposal persists, anchors are NOT folded

    private func freshDBWithKO() async throws -> (Database, UUID) {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("i5-\(UUID().uuidString).sqlite")
        let db = try Database(url: tmp)
        try await SchemaMigrations.migrate(db)
        let fileID = UUID(), koID = UUID()
        try await db.exec("INSERT INTO files (id, url, source_type) VALUES (?, ?, ?);",
                          [.uuid(fileID), .text("file:///i5"), .text("text")])
        try await db.exec("""
        INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at)
        VALUES (?, ?, ?, ?, 0, 0);
        """, [.uuid(koID), .uuid(fileID), .text("text"), .text("i5 body")])
        return (db, koID)
    }

    @Test("Two OCR-alike anchors persist as TWO rows; the proposal is a reversible system FactReview; no auto-fold")
    func proposalPersistsWithoutFolding() async throws {
        let (db, ko) = try await freshDBWithKO()
        let entities = EntitiesRepository(database: db)
        let reviews = FactReviewsRepository(database: db)

        let realID = try await entities.resolveOrCreateAnchor(field: "patentNumber", value: "555489", sourceObjectID: ko)
        let ocrID  = try await entities.resolveOrCreateAnchor(field: "patentNumber", value: "S55489", sourceObjectID: ko)
        #expect(realID != ocrID, "OCR-corrupt identifier must be a SEPARATE anchor (no fuzzy fold at resolve)")
        #expect(try await entities.count(of: .identifierAnchor) == 2)

        // Run the I-5 detector over the persisted anchors and record proposals
        // exactly as AppState.reviewAnchorSplitSuspects does.
        let anchors = try await entities.allAnchors()
        let proposals = IdentifierAnchorReview.proposedMerges(among: anchors)
        #expect(proposals.count == 1)
        for p in proposals {
            _ = try await reviews.record(FactReview(
                subjectKind: .entity, subjectID: p.fromAnchorID, action: .merge,
                priorValue: p.fromValue, newValue: p.toAnchorID.uuidString,
                reviewer: "system", reason: p.evidence))
        }

        // The proposal is on the record, reversible, and points at the target —
        // but the anchors were NOT folded (still two rows).
        let history = try await reviews.history(forSubject: ocrID)
        let proposal = history.first { $0.action == .merge }
        #expect(proposal != nil, "no proposed-merge review recorded for the suspect")
        #expect(proposal?.newValue == realID.uuidString, "proposal must target the clean anchor")
        #expect(proposal?.reviewer == "system", "I-5 proposals are system-authored, awaiting human review")
        #expect(try await entities.count(of: .identifierAnchor) == 2, "the proposal must NOT auto-fold the anchors")
    }
}
