//
//  CandidateUIFixesTests.swift
//  KalsmritikoshTests
//
//  Candidate f766b035 UI run (2026-11-02) — A4: a "conflict" paired invoice 401 with invoice 432;
//  B35/B36: the workspace report repeated facts (221 rows, 79 distinct) and cited subject entities,
//  and no receipt entry named a document.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Candidate UI fixes — same-subject conflicts, document-cited deduplicated reports")
struct CandidateUIFixesTests {

    // MARK: A4 — same identified subject

    private func invoiceEvent(_ day: String, ref: String?, source: UUID = UUID()) -> Event {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withFullDate]
        var attrs: [String: AnyCodable] = [:]
        if let ref { attrs[SubjectReference.attributeKey] = AnyCodable(.string(ref)) }
        return Event(kind: .invoiceIssued, date: f.date(from: day)!, title: "Invoice issued",
                     summary: "invoice issued", sourceObjectID: source, dateConfidence: 0.9,
                     attributes: attrs, datePrecision: .day)
    }

    @Test func differentInvoicesAreNotADateConflict() {
        let found = ContradictionDetector().detectEventDateConflicts([
            invoiceEvent("2024-01-22", ref: "invoice 401"),
            invoiceEvent("2024-05-30", ref: "invoice 432"),
        ])
        #expect(found.isEmpty)
    }

    @Test func theSameInvoiceDatedTwiceIsAConflict() {
        let found = ContradictionDetector().detectEventDateConflicts([
            invoiceEvent("2024-05-01", ref: "invoice 432"),
            invoiceEvent("2024-05-30", ref: "invoice 432"),
        ])
        #expect(found.count == 1)
    }

    @Test func differentInvoicesAreNotAnAmountConflict() {
        func withAmount(_ e: Event, _ v: Double) -> Event {
            e.addingAttributes(["amount": AnyCodable(.double(v)), "currency": AnyCodable(.string("USD"))])
        }
        let found = ContradictionDetector().detectEventAmountConflicts([
            withAmount(invoiceEvent("2024-01-22", ref: "invoice 401"), 540_000),
            withAmount(invoiceEvent("2024-05-30", ref: "invoice 432"), 120_000),
        ])
        #expect(found.isEmpty)
    }

    @Test func referenceIsReadFromTheSourceText() {
        let body = """
        Invoice number 432 was issued on 2024-05-30 for milestone 2.
        Invoice issued: 2024-05-30.
        """
        #expect(SubjectReference.reference(for: .invoiceIssued, marker: "invoice issued", in: body) == "invoice 432")
        // A summary naming two invoices in the event's own sentence names neither.
        #expect(SubjectReference.reference(for: .invoiceIssued, marker: "invoice 432 issued",
                                           in: "invoice 401 paid, invoice 432 issued for milestone 2") == nil)
        // A date or a quantity is never an identifier; a kind without a document noun has none.
        #expect(SubjectReference.reference(for: .invoiceIssued, marker: nil, in: "Invoice dated 2024-05-30") == nil)
        #expect(SubjectReference.reference(for: .deliveryDelayed, marker: nil, in: "order 5 units today") == nil)
        #expect(SubjectReference.reference(for: .meetingHeld, marker: nil, in: "Invoice No. 7") == nil)
        #expect(SubjectReference.reference(for: .contractModified, marker: nil, in: "Amendment No. 7 to the agreement") == "contract 7")
    }

    @Test func ruleExtractorStampsTheReference() async throws {
        let invoice401 = """
        Please find attached invoice number 401 for Project Delta.
        Amount due: USD 540,000.
        Invoice issued: 2024-01-22.
        """
        let ko = KnowledgeObject(sourceFile: URL(fileURLWithPath: "/tmp/a.txt"), sourceType: .txt,
                                 content: invoice401, metadata: [:])
        let events = try await RuleEventExtractor().extractEvents(from: ko, chunks: [], entities: [], blocks: [])
        let issued = events.first { $0.kind == .invoiceIssued }
        #expect(issued.flatMap(SubjectReference.reference(of:)) == "invoice 401")
    }

    @Test func claimPassageFindsTheSourceLine() {
        let src = "Invoice number 432 was issued on 2024-05-30.\nInvoice issued: 2024-05-30.\nRegards"
        #expect(CitedPassageLocator.claimPassage("Invoice issued on May 30, 2024", in: src) == "Invoice issued: 2024-05-30.")
        #expect(CitedPassageLocator.claimPassage("Nothing like this", in: src) == nil)
    }

    // MARK: B35/B36 — dedupe + document citations

    private func cite(_ v: UUID, title: String) -> CitationRecord {
        CitationRecord(sourceVersionID: v, displayLabel: "[1]", sourceTitle: title, sourceHash: String(repeating: "a", count: 64))
    }

    @Test func reportStatesEachFactOnceAndCitesDocuments() throws {
        let v1 = UUID(), v2 = UUID()
        let text = "Source-reported: Email about “Invoice No. 401”."
        let section = WorkProductSection(title: "Sourced summary", claims: [
            WorkProductClaim(text: text, status: .sourceAssertion, supporting: [cite(v1, title: "Project Delta")]),
            WorkProductClaim(text: text, status: .sourceAssertion, supporting: [cite(v1, title: "ABC")]),
            WorkProductClaim(text: "source-reported:  email about “invoice no. 401”.", status: .sourceAssertion,
                             supporting: [cite(v2, title: "ap@northwind.example")]),
            WorkProductClaim(text: "Another fact.", status: .sourceAssertion, supporting: [cite(v2, title: "John")]),
        ])
        let wp = WorkProduct(template: .generalSummary, title: "General", sections: [section])
        let out = WorkProductAssemblyService.deduplicatingFacts(
            WorkProductAssemblyService.citingDocuments(wp, names: [v1: "invoice-401.eml", v2: "supplier_abc_25.eml"]))

        let claims = out.sections[0].claims
        #expect(claims.count == 2)
        #expect(claims[0].text == text)
        // The merged row keeps every distinct source version, named by document.
        #expect(claims[0].supporting.map(\.sourceTitle) == ["invoice-401.eml", "supplier_abc_25.eml"])
        #expect(claims[1].supporting.map(\.sourceTitle) == ["supplier_abc_25.eml"])
        #expect(out.allCitations.allSatisfy { $0.sourceTitle.hasSuffix(".eml") })

        // The receipt built from it names a document in every entry.
        let manifest = ExportManifest(exportedAt: Date(), appVersion: "test", schemaVersion: 1)
        let receipt = try WorkProductReceiptBuilder().build(from: AssembledWorkProduct(workProduct: out, manifest: manifest))
        #expect(receipt.entries.count == 2)
        #expect(receipt.entries.allSatisfy { $0.source.hasSuffix(".eml") })

        // The rendered row names each document once.
        let doc = WorkProductComposer.exportable(out, citationStyle: .footnote, manifest: manifest)
        let row = doc.sections[0].paragraphs.first { $0.contains("Invoice No. 401") } ?? ""
        #expect(row.contains("(sources: invoice-401.eml; supplier_abc_25.eml)"))
    }
}
