//
//  UsabilityFixesTests.swift
//  KalsmritikoshTests
//
//  Findings of the agent user evaluation of 2026-11-02 (docs/agent-reviews/user-evaluation-2026-11-02.md)
//  that can be checked without driving the UI.
//

import Testing
import Foundation
import PDFKit
@testable import Kalsmritikosh

@Suite("Usability evaluation 2026-11-02 fixes")
struct UsabilityFixesTests {

    @Test("M2: a copied answer is plain text and names its sources by file name")
    func copiedAnswer() {
        let body = "## Agreement\n**Effective Date:** March 1, 2024\n\n"
        let one = AnswerCopyText.make(body: body, sourceNames: ["contract.md"])
        #expect(!one.contains("**") && !one.contains("##"))
        #expect(one.hasPrefix("Agreement\nEffective Date: March 1, 2024"))
        #expect(one.hasSuffix("Source: contract.md"))
        let two = AnswerCopyText.make(body: "Yes.", sourceNames: ["b.pdf", "a.pdf", "b.pdf"])
        #expect(two == "Yes.\n\nSources:\n• a.pdf\n• b.pdf")
        #expect(AnswerCopyText.make(body: "Yes.", sourceNames: []) == "Yes.")
    }

    private func chunk(_ text: String) -> RetrievedChunk {
        RetrievedChunk(chunk: Chunk(objectID: UUID(), ordinal: 0, text: text, characterRange: 0..<text.count),
                       score: 1, viaLayer: .metadata)
    }

    private func fixture(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Kalsmritikosh/Resources/Fixtures/ProjectDelta/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("M3: 'Who signed the master supply agreement?' quotes the agreement's signing sentence, never a heading")
    func whoSigned() throws {
        let chunks = [chunk(try fixture("amendment-7.md")), chunk(try fixture("contract.md"))]
        let q = try #require(SentenceQuoteComposer.compose(question: "Who signed the master supply agreement?", chunks: chunks))
        #expect(q.sentence.contains("John Carter") && q.sentence.contains("Maria Lopez"), "\(q.sentence)")
        #expect(q.sentence.contains("12th day of January 2024"), "the agreement's own signing, not the amendment's: \(q.sentence)")
    }

    @Test("M3: a title's dash is not a field separator")
    func titleDash() {
        #expect(OpenFieldExtractor.fields(in: "Amendment No. 7 — Project Delta Master Supply Agreement", kind: .documentTitle).isEmpty)
        #expect(OpenFieldExtractor.fields(in: "Invoice: 432", kind: .documentTitle).count == 1)
    }

    @Test("M3: 'Was invoice 432 paid?' — only clauses about 432 count; the unpaid record is quoted, never 'invoice 401 paid'")
    func invoiceState() throws {
        let asked = try #require(StateQuestionAnswerer.parse("Was invoice 432 paid?"))
        #expect(asked == .init(noun: "invoice", number: "432", state: "paid"))
        #expect(StateQuestionAnswerer.parse("Has invoice #432 been paid?")?.number == "432")
        #expect(StateQuestionAnswerer.parse("Was the meeting good?") == nil)
        let chunks = [chunk(try fixture("supplier_abc_25.eml")), chunk(try fixture("invoice-432.eml")), chunk(try fixture("invoice-401.eml"))]
        let outcome = try #require(StateQuestionAnswerer.answer(asked, chunks: chunks))
        let text = StateQuestionAnswerer.render(outcome, asked)
        #expect(text.hasPrefix("No document found records invoice 432 as paid"), "\(text)")
        #expect(text.contains("remains unpaid") && !text.contains("401"), "\(text)")
        // Paid on record: Yes, quoted.
        let paid = [chunk("Invoice 432 was paid in full on July 2, 2024 by wire transfer.")]
        guard case .stated(let c)? = StateQuestionAnswerer.answer(asked, chunks: paid) else { Issue.record("expected stated"); return }
        #expect(c.text.contains("paid in full"))
        // "will be paid" is not paid.
        #expect(StateQuestionAnswerer.answer(asked, chunks: [chunk("Invoice 432 will be paid next week.")]).map { _ in true } == nil)
    }

    @Test("U-B1: 'hasn't been paid', 'wasn't paid', 'nobody paid' and a question about payment are never a Yes; disagreement shows both")
    func invoiceNegations() throws {
        let asked = try #require(StateQuestionAnswerer.parse("Was invoice 432 paid?"))
        for text in ["Invoice 432 hasn't been paid yet.", "Invoice 432 wasn't paid by the due date.", "Nobody paid invoice 432 before the audit."] {
            let outcome = StateQuestionAnswerer.answer(asked, chunks: [chunk(text)])
            guard case .onlyOpposite? = outcome else { Issue.record("\(text) → \(String(describing: outcome))"); continue }
        }
        #expect(StateQuestionAnswerer.answer(asked, chunks: [chunk("Has invoice 432 been paid? Please confirm.")]).map { _ in true } == nil)
        let both = [chunk("Invoice 432 was paid in full on July 2, 2024."), chunk("Invoice 432 remains unpaid as of June 14, 2024.")]
        let outcome = try #require(StateQuestionAnswerer.answer(asked, chunks: both))
        #expect(StateQuestionAnswerer.render(outcome, asked).hasPrefix("The documents disagree"), "\(StateQuestionAnswerer.render(outcome, asked))")
        // A label after the clause is not part of it.
        let digest = [chunk("- Financial: invoice 401 paid; invoice 432 issued for milestone 2 and overdue as of 2024-06-29. Risk: schedule slip")]
        let d = try #require(StateQuestionAnswerer.answer(asked, chunks: digest))
        #expect(!StateQuestionAnswerer.render(d, asked).contains("Risk"))
    }

    @Test("A no-model answer is not labelled AI-assisted")
    func noModelFooter() {
        let a = VerifiedAnswer(body: "No document found records invoice 432 as paid.\n\n(Quoted verbatim from the cited documents; no model was consulted.)",
                               citations: [], confidence: Confidence(0.75), refused: false, refusalReason: nil)
        #expect(QualityStrip.usedNoModel(a))
        #expect(!QualityStrip.usedNoModel(VerifiedAnswer(body: "Prose.", citations: [], confidence: Confidence(0.75), refused: false, refusalReason: nil)))
    }

    @Test("Print preview (owner decision 2026-11-02): the text is drawn as PDF pages in the app, no printing system")
    @MainActor func printPreviewPages() throws {
        let long = (1...400).map { "Line \($0): the quoted passage and its source." }.joined(separator: "\n")
        let data = try #require(AppPrinting.pdfData(AppPrinting.textView(long, monospace: true, fontSize: 9)))
        let doc = try #require(PDFDocument(data: data))
        #expect(doc.pageCount > 1)
        #expect(doc.string?.contains("Line 400") == true)
        #expect(AppPrinting.Outcome.savedAsPDF.released && !AppPrinting.Outcome.cancelled.released)
    }
}
