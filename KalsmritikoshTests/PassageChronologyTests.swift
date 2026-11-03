//
//  PassageChronologyTests.swift
//  KalsmritikoshTests
//
//  G1 — "Add to case chronology" from a source passage: the entry carries the passage as its
//  citation (version, document, block, quote) and the source version as its evidence reference;
//  the same passage twice is refused; a source outside the case's scope is refused by the case;
//  a date is offered only when the passage states exactly one full date.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("G1 — add a source passage to the case chronology", .serialized)
struct PassageChronologyTests {

    static let text = "The board approved the payment on 3 March 2026. The treasurer resigned without notice."
    static let quote = "The board approved the payment on 3 March 2026."

    @Test("The entry carries the passage as its citation, the quote and the source version; the same passage twice is refused")
    func entryAndDuplicate() async throws {
        let f = try await CaseFileTests.fixture()
        let src = try await CaseFileTestSources.seedPassage(f.db, cases: f.cases, caseID: f.caseID, name: "minutes.txt", text: Self.text)

        // From a citation: only the document and the words are known; version and block are resolved.
        let r = try await PassageChronology.add(caseID: f.caseID, objectID: src.object, quote: Self.quote, text: "Board approved the payment",
                                                eventDate: nil, caseFiles: f.svc, actor: "Ada")
        #expect(r.sourceVersionID == src.version)
        #expect(r.support.isDocumentary, "\(r.support.label)")
        let entries = try await f.file.journal(caseID: f.caseID, kind: .chronology)
        #expect(entries.count == 1)
        let e = try #require(entries.first)
        #expect(e.text == "Board approved the payment")
        #expect(e.evidenceRef == src.version.uuidString)
        #expect(e.quote == Self.quote)
        #expect(e.citations == [StudioEvidenceRef(sourceVersionID: src.version, objectID: src.object, blockID: src.blocks[0], quote: Self.quote)])
        #expect(e.origin == PassageChronology.origin(caseID: f.caseID, sourceVersionID: src.version, blockID: src.blocks[0], quote: Self.quote))
        #expect(e.support.isDocumentary)
        #expect(e.eventDate == nil)

        // The entry opens at its passage.
        let target = try #require(PassageChronology.openTarget(for: e, objectForVersion: [:]))
        #expect(target.objectID == src.object && target.quote == Self.quote)

        // The same passage again (even worded differently) is refused, with a clear message.
        await #expect(throws: PassageChronologyError.alreadyInChronology) {
            _ = try await PassageChronology.add(caseID: f.caseID, objectID: src.object, quote: Self.quote, text: "Approval recorded",
                                                eventDate: nil, caseFiles: f.svc, actor: "Ada")
        }
        #expect(PassageChronologyError.alreadyInChronology.errorDescription?.contains("already in that case's chronology") == true)
        #expect(try await f.file.journal(caseID: f.caseID, kind: .chronology).count == 1)
    }

    @Test("A source outside the chosen case's scope is refused by the case; nothing is added and the scope is not widened")
    func outOfScopeRefused() async throws {
        let f = try await CaseFileTests.fixture()
        let src = try await CaseFileTestSources.seedPassage(f.db, cases: f.cases, caseID: f.caseID, name: "minutes.txt", text: Self.text)
        let other = try await f.cases.createCase(workspaceID: f.workspaceID, title: "Another matter", actor: "Ada", at: Date())

        await #expect(throws: PassageChronologyError.outOfScope("the source is not in this case's scope")) {
            _ = try await PassageChronology.add(caseID: other.id, objectID: src.object, quote: Self.quote, text: "Board approved the payment",
                                                eventDate: nil, caseFiles: f.svc, actor: "Ada")
        }
        // The same refusal when the caller names the exact version and block.
        await #expect(throws: PassageChronologyError.outOfScope("the source is not in this case's scope")) {
            _ = try await PassageChronology.add(caseID: other.id, objectID: src.object, sourceVersionID: src.version, blockID: src.blocks[0],
                                                quote: Self.quote, text: "Board approved the payment",
                                                eventDate: nil, caseFiles: f.svc, actor: "Ada")
        }
        #expect(try await f.file.journal(caseID: other.id, kind: .chronology).isEmpty)
        let scope = try await f.db.query("SELECT 1 FROM investigation_case_sources WHERE case_id = ?;", [.uuid(other.id)])
        #expect(scope.isEmpty, "the source was not added to the other case")
        // A document with no source version at all cannot be cited.
        await #expect(throws: PassageChronologyError.noSourceVersion) {
            _ = try await PassageChronology.add(caseID: f.caseID, objectID: UUID(), quote: Self.quote, text: "x",
                                                eventDate: nil, caseFiles: f.svc, actor: "Ada")
        }
    }

    /// A source whose parsed blocks are given one by one (as the structural parsers make them) and whose
    /// stored document text is the file as written — the two lay the same words out differently.
    static func seedBlocks(_ f: CaseFileTests.Fixture, name: String, content: String, blocks texts: [String]) async throws -> (version: UUID, object: UUID, blocks: [UUID]) {
        let db = f.db
        let fileID = UUID(), koID = UUID(), version = UUID(), docID = UUID()
        let hex = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        try await db.exec("INSERT INTO files (id, url, source_type, availability, content_hash) VALUES (?,?,?,?,?);",
                          [.uuid(fileID), .text("file:///case-test/\(name)"), .text("txt"), .text("available"), .text(hex + hex)])
        try await db.exec("INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at) VALUES (?,?,?,?,?,?);",
                          [.uuid(koID), .uuid(fileID), .text("txt"), .text(content), .real(0), .real(0)])
        try await db.exec("""
            INSERT INTO source_versions (id, logical_source_id, document_id, content_hash, valid_from, is_current, created_at,
                filename, detected_type, detection_basis, size_bytes, custody_mode, preservation_status, intake_recorded_at, original_url)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);
            """, [.uuid(version), .uuid(fileID), .uuid(docID), .text(hex + hex), .real(100), .integer(1), .real(100),
                  .text(name), .text("txt"), .text("magicBytes"), .integer(Int64(content.utf8.count)), .text("referenced"), .text("referenceRecorded"), .real(100),
                  .text("file:///case-test/\(name)")])
        var ids: [UUID] = []
        for (i, text) in texts.enumerated() {
            let blockID = UUID()
            try await db.exec("""
                INSERT INTO evidence_blocks (id, document_id, source_version_id, ordinal, kind, raw_text, normalized_text, extraction_method, extraction_confidence)
                VALUES (?,?,?,?,?,?,?,?,?);
                """, [.uuid(blockID), .uuid(docID), .uuid(version), .integer(Int64(i)), .text("paragraph"), .text(text), .text(EvidenceBlock.normalize(text)), .text("native"), .real(1.0)])
            try await db.exec("INSERT INTO evidence_block_objects (evidence_block_id, knowledge_object_id, linked_at) VALUES (?,?,?);", [.uuid(blockID), .uuid(koID), .real(0)])
            ids.append(blockID)
        }
        let header = try await f.cases.fetch(caseID: f.caseID)?.caseHeader
        _ = try await f.cases.includeSource(caseID: f.caseID, expectedRevision: header?.revision ?? 1, sourceRef: version.uuidString,
                                            sourceKind: .sourceVersion, actor: "Ada", at: Date())
        return (version, koID, ids)
    }

    /// Add `quote` as a search hit does (document and words only), then re-verify the case as the case
    /// file and the report do; returns the support at add time and as stored afterwards.
    static func addAndReverify(_ f: CaseFileTests.Fixture, object: UUID, quote: String) async throws -> (added: CaseEvidenceSupport, stored: CaseEvidenceSupport, entry: CaseJournalEntry) {
        let r = try await PassageChronology.add(caseID: f.caseID, objectID: object, quote: quote, text: "Entry",
                                                eventDate: nil, caseFiles: f.svc, actor: "Ada")
        try await f.svc.reverifyCarriedItems(caseID: f.caseID)
        let e = try #require(try await f.file.journal(caseID: f.caseID, kind: .chronology).first { $0.id == r.entryID })
        return (r.support, e.support, e)
    }

    static let digestEML = """
        From: program-office@northwind.example
        To: program-leads@northwind.example
        Subject: Project Delta status — weekly digest
        Date: Fri, 24 May 2024 16:00:00 +0000

        Team,

        Project Delta status as of 2024-05-24:
        """
    static let digestBlocks = ["program-office@northwind.example", "program-leads@northwind.example",
                               "Project Delta status — weekly digest", "Fri, 24 May 2024 16:00:00 +0000",
                               "Team,\n\nProject Delta status as of 2024-05-24:"]

    @Test("UI check C5: an e-mail's header lines, joined as a search hit joins them, verify — at add time and in the report alike")
    func multiLineEmailHeaderVerifies() async throws {
        let f = try await CaseFileTests.fixture()
        let src = try await Self.seedBlocks(f, name: "supplier_abc_25.eml", content: Self.digestEML, blocks: Self.digestBlocks)
        // The search hit's text: the header blocks joined with line breaks (no "From:" / "To:" labels).
        let quote = Self.digestBlocks[0..<4].joined(separator: "\n")
        let r = try await Self.addAndReverify(f, object: src.object, quote: quote)
        #expect(r.added.isDocumentary, "\(r.added.label)")
        #expect(r.stored.isDocumentary, "\(r.stored.label)")
        #expect(r.added.label == r.stored.label, "the label at add time is the one the report prints")
        let c = try #require(r.entry.citations.first)
        #expect(c.objectID == src.object && c.sourceVersionID == src.version)
        #expect(c.blockID == nil, "no single block holds the words, so none is named")

        // Words that are not in the source never verify — at add time or afterwards.
        let wrong = Self.digestBlocks[0] + "\n" + "program-board@northwind.example"
        let w = try await Self.addAndReverify(f, object: src.object, quote: wrong)
        #expect(!w.added.isDocumentary && !w.stored.isDocumentary)
        #expect(w.added.label == w.stored.label, "\(w.added.label) / \(w.stored.label)")
    }

    static let contractMD = """
        # Master Supply Agreement — Project Delta

        ## Pricing

        Total contract value: USD 1,800,000. Invoiced in three installments — 30% on signing, 30% on first lot delivery, 40% on final acceptance.

        ## Signatures

        This agreement is signed this 12th day of January 2024 by John Carter and Maria Lopez.
        """
    static let contractBlocks = ["Master Supply Agreement — Project Delta", "Pricing",
                                 "Total contract value: USD 1,800,000. Invoiced in three installments — 30% on signing, 30% on first lot delivery, 40% on final acceptance.",
                                 "Signatures", "This agreement is signed this 12th day of January 2024 by John Carter and Maria Lopez."]

    @Test("UI check C5: a markdown heading packed with its paragraph (\"## Pricing\" and a blank line in the file) verifies at add time and later")
    func markdownHeadingAndBlankLineVerify() async throws {
        let f = try await CaseFileTests.fixture()
        let src = try await Self.seedBlocks(f, name: "contract.md", content: Self.contractMD, blocks: Self.contractBlocks)
        let quote = Self.contractBlocks[1] + "\n" + Self.contractBlocks[2]
        let r = try await Self.addAndReverify(f, object: src.object, quote: quote)
        #expect(r.added.isDocumentary, "\(r.added.label)")
        #expect(r.stored.isDocumentary, "\(r.stored.label)")
        #expect(r.added.label == r.stored.label)

        // A changed amount is not in the source: unverified, the same before and after.
        let wrong = "Pricing\nTotal contract value: USD 2,800,000."
        let w = try await Self.addAndReverify(f, object: src.object, quote: wrong)
        #expect(!w.added.isDocumentary && !w.stored.isDocumentary)
        #expect(w.added.label == w.stored.label, "\(w.added.label) / \(w.stored.label)")

        // A heading's last words run into the next paragraph only across the blocks in order: words from
        // two blocks that are not next to each other do not make a passage.
        let skipped = "Pricing\nThis agreement is signed"
        let s = try await Self.addAndReverify(f, object: src.object, quote: skipped)
        #expect(!s.added.isDocumentary && !s.stored.isDocumentary)
    }

    @Test("A search hit made of one block is pinned to that block")
    func searchHitPinnedToItsBlock() async throws {
        let f = try await CaseFileTests.fixture()
        let src = try await Self.seedBlocks(f, name: "contract.md", content: Self.contractMD, blocks: Self.contractBlocks)
        let r = try await PassageChronology.add(caseID: f.caseID, objectID: src.object, blockID: src.blocks[4], quote: Self.contractBlocks[4],
                                                text: "Signed", eventDate: nil, caseFiles: f.svc, actor: "Ada")
        #expect(r.support.isDocumentary)
        #expect(r.citation.blockID == src.blocks[4] && r.citation.sourceVersionID == src.version)
    }

    @Test("UI check: an undated chronology entry shows \"No date\" in the tab, never the day it was added (the report prints \"—\")")
    func undatedEntryShowsNoDate() async throws {
        let f = try await CaseFileTests.fixture()
        let src = try await CaseFileTestSources.seedPassage(f.db, cases: f.cases, caseID: f.caseID, name: "minutes.txt", text: Self.text)
        _ = try await PassageChronology.add(caseID: f.caseID, objectID: src.object, quote: Self.quote, text: "Undated",
                                            eventDate: nil, caseFiles: f.svc, actor: "Ada")
        let dated = try await f.file.addJournal(caseID: f.caseID, kind: .chronology, text: "Dated", eventDate: Date(timeIntervalSince1970: 1_772_000_000),
                                                evidenceRef: nil, actor: "Ada")
        let entries = try await f.file.journal(caseID: f.caseID, kind: .chronology)
        let undated = try #require(entries.first { $0.text == "Undated" })
        #expect(CaseChronologyTab.dateColumn(undated) == "No date")
        #expect(CaseFileDocuments.d(undated.eventDate) == "—")
        let withDate = try #require(entries.first { $0.id == dated })
        #expect(CaseChronologyTab.dateColumn(withDate) == CaseFileDocuments.d(withDate.eventDate))
    }

    @Test("A date is read only when the passage states exactly one full date; otherwise it is left empty")
    @MainActor
    func suggestedDate() throws {
        #expect(PassageChronology.suggestedDate(in: "The treasurer resigned without notice.") == nil)
        #expect(PassageChronology.suggestedDate(in: "The payment was approved in March 2026.") == nil, "a month is not a date")
        #expect(PassageChronology.suggestedDate(in: "Approved on 3 March.") == nil, "no year: not guessed")
        #expect(PassageChronology.suggestedDate(in: "Work ran from 3 March 2026 to 5 March 2026.") == nil, "a range is not one date")
        #expect(PassageChronology.suggestedDate(in: "Approved on 3 March 2026; paid on 9 April 2026.") == nil, "two dates: the person chooses")
        let d = try #require(PassageChronology.suggestedDate(in: Self.quote))
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        #expect(c.year == 2026 && c.month == 3 && c.day == 3)
    }
}
