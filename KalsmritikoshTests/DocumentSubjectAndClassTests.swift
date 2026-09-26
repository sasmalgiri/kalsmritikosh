//
//  DocumentSubjectAndClassTests.swift
//  KalsmritikoshTests
//
//  L3 — a document's CLASS is scored from whole-word markers (the substring
//  "vat" inside "private" filed 16 résumés as invoices on the owner's archive),
//  a person-headed document's SUBJECT is that person, and a history rebuild
//  supersedes the subject's previous build instead of standing beside it.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("L3 — scored, word-bounded document classification")
struct DocumentClassScoringTests {
    private func ko(_ text: String) -> KnowledgeObject {
        KnowledgeObject(sourceFile: URL(fileURLWithPath: "/tmp/x.pdf"), sourceType: .pdf, content: text)
    }

    @Test("A résumé mentioning 'private' and 'motivated' is a résumé, not an invoice")
    func resumeNotInvoice() {
        let cv = """
        RESUME
        Shirshendu Sasmal.
        Current CTC : 2.70 lac. A self-motivated executive with experience in private pharma.
        Education: M.Sc Organic Chemistry. Skills: HPLC, cGMP. Date of Birth: 08/06/1981.
        Marital status: Married. Nationality: Indian. References available on request.
        """
        #expect(DocumentClassifier().classify(ko(cv)) == .resume)
        #expect(DocumentClassifier().classify(ko("CURRICULAM-VITAE\nTRILOCHAN BEJ\nEducation: B.Sc\nSkills: QA")) == .resume,
                "the misspelt heading seen in the owner's archive still classifies")
    }

    @Test("Whole-word matching: 'vat' does not hit 'private'; a real VAT line does")
    func wordBoundaries() {
        #expect(!DocumentClassifier.containsPhrase("a private note", "vat"))
        #expect(DocumentClassifier.containsPhrase("subtotal 100, vat 18", "vat"))
        #expect(DocumentClassifier.containsPhrase("total amount: 500", "total amount"))
    }

    @Test("The four historical golds still hold (legal beats commercial on a tie)")
    func historicalGolds() {
        let c = DocumentClassifier()
        #expect(c.classify(ko("Hearing notice issued by the Controller of Patents under the Patents Act. Fee payable to the office; subtotal enclosed.")) == .legalDocument)
        #expect(c.classify(ko("This is to certify that Patent No. 555489 stands granted.")) == .certificate)
        #expect(c.classify(ko("Invoice number INV-42. Amount due: ₹20,000. Bill to: Orchid.")) == .invoice)
        #expect(c.classify(ko("Lunch notes and a shopping list.")) == .other)
    }
}

@Suite("L3 — a person-headed document's subject is the person")
struct DocumentSubjectTests {
    private func block(_ kind: EvidenceBlockKind, _ text: String, ordinal: Int) -> EvidenceBlock {
        EvidenceBlock(documentID: UUID(), ordinal: ordinal, kind: kind, rawText: text)
    }
    let url = URL(fileURLWithPath: "/tmp/Resume_pm-14e7b929.docx")

    @Test("RESUME → 'Shirshendu Sasmal.' → the subject is the person, not the file stem")
    func resumeSubject() {
        let blocks = [block(.sectionHeading, "RESUME", ordinal: 0),
                      block(.paragraph, "Shirshendu Sasmal.", ordinal: 1),
                      block(.paragraph, "Current CTC : 2.70 lac.", ordinal: 2)]
        #expect(FactSubjectPartitioner.documentLabel(blocks: blocks, fileURL: url) == "Shirshendu Sasmal")
        let allCaps = [block(.sectionHeading, "CURRICULAM-VITAE", ordinal: 0), block(.paragraph, "TRILOCHAN BEJ", ordinal: 1)]
        #expect(FactSubjectPartitioner.documentLabel(blocks: allCaps, fileURL: url) == "TRILOCHAN BEJ")
        let header = [block(.pageHeader, "Prasenjit Maity", ordinal: 0), block(.pageHeader, "E-mail: pmaity1989@gmail.com", ordinal: 1)]
        #expect(FactSubjectPartitioner.documentLabel(blocks: header, fileURL: url) == "Prasenjit Maity")
    }

    @Test("A document that does not open with a name keeps its title or file stem")
    func nonNameKeepsLabel() {
        let letter = [block(.paragraph, "Dr.Tapas Maity Senior Research Associate +91-9951234567", ordinal: 0),
                      block(.paragraph, "Work Experience", ordinal: 1)]
        #expect(FactSubjectPartitioner.documentLabel(blocks: letter, fileURL: url) == "Resume_pm-14e7b929")
        let titled = [block(.documentTitle, "Hearing Notice of Patent Application-202331019665", ordinal: 0),
                      block(.paragraph, "Shirshendu Sasmal", ordinal: 1)]
        #expect(FactSubjectPartitioner.documentLabel(blocks: titled, fileURL: url) == "Hearing Notice of Patent Application-202331019665",
                "a real title outranks a name below it")
        let objective = [block(.sectionHeading, "OBJECTIVE :", ordinal: 0),
                         block(.paragraph, "To work in an organization where I have opportunity to grow.", ordinal: 1)]
        #expect(FactSubjectPartitioner.documentLabel(blocks: objective, fileURL: url) == "Resume_pm-14e7b929")
        #expect(FactSubjectPartitioner.nameShaped("Name: Jane Roe") == nil, "a label with a colon is not a name")
    }
}

@Suite("L3 — a history rebuild supersedes the previous build", .serialized)
@MainActor
struct HistorySupersedeTests {
    @Test("Two current artifacts for one subject → the older is superseded by the newer")
    func supersedePrevious() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hist-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try Database(url: dir.appendingPathComponent("db.sqlite"))
        try await SchemaMigrations.migrate(db)
        let old = UUID(), new = UUID(), other = UUID()
        for (id, key, stamp, t) in [(old, "anchor-A", "s1", 1.0), (new, "anchor-A", "s2", 2.0), (other, "anchor-B", "s2", 2.0)] {
            try await db.exec("""
            INSERT INTO history_artifacts (id, subject_kind, subject_label, engine_version, request_json, title, summary, coverage_json, quality_json, created_at, review_state, anchor_key, request_shape, ledger_stamp)
            VALUES (?, 'entity', 'Application No. 1', 1, '{}', 'History', '', '{}', '{}', ?, 'unreviewed', ?, 'story', ?);
            """, [.uuid(id), .real(t), .text(key), .text(stamp)])
        }
        let repo = HistoryArtifactRepository(database: db)
        let n = try await repo.supersedePrevious(anchorKey: "anchor-A", requestShape: "story", keeping: new, at: Date())
        #expect(n == 1)
        let rows = try await db.query("SELECT id, superseded_by FROM history_artifacts ORDER BY created_at;", [])
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.uuid(0)!, $0.uuid(1)) })
        #expect((byID[old] ?? nil) == new, "the older build points at its replacement")
        #expect((byID[new] ?? nil) == nil, "the new build is current")
        #expect((byID[other] ?? nil) == nil, "another subject is untouched")
    }
}
