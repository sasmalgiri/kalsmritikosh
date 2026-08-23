//
//  NonWorkflowFeaturePureTests.swift
//  KalsmritikoshTests
//
//  Pure-logic tests for the non-workflow features that don't need the ledger:
//  PDF burn-in redaction, file authenticity signals, Evidence Explained
//  citations, and email dedup/threading.
//

import Foundation
import Testing
import PDFKit
import CoreGraphics
import CoreText
@testable import Kalsmritikosh

@Suite("Non-workflow features — pure logic")
struct NonWorkflowFeaturePureTests {

    // MARK: - Helpers

    /// Render a one-page text PDF (selectable text) to a temp file.
    private func makeTextPDF(_ text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kx-test-\(UUID().uuidString).pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else {
            throw NSError(domain: "test", code: 1)
        }
        let font = CTFontCreateWithName("Helvetica" as CFString, 24, nil)
        let attr = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0, green: 0, blue: 0, alpha: 1)
        ])
        let fs = CTFramesetterCreateWithAttributedString(attr)
        let path = CGPath(rect: CGRect(x: 54, y: 54, width: 504, height: 684), transform: nil)
        ctx.beginPDFPage(nil)
        CTFrameDraw(CTFramesetterCreateFrame(fs, CFRange(location: 0, length: 0), path, nil), ctx)
        ctx.endPDFPage(); ctx.closePDF()
        try (data as Data).write(to: url)
        return url
    }

    // MARK: - Redaction

    @Test("Redaction removes the secret from the output (fail-closed verified)")
    func redactionRemovesSecret() throws {
        let secret = "SECRETTOKENXYZ"
        let url = try makeTextPDF("Public heading. \(secret) — confidential middle. Public footer.")
        defer { try? FileManager.default.removeItem(at: url) }

        // Precondition: the source really contains the extractable secret.
        let src = PDFDocument(url: url)
        #expect(!(src?.findString(secret, withOptions: [.caseInsensitive]).isEmpty ?? true))

        let result = try PDFRedactionService().redact(source: url, terms: [secret])
        #expect(result.matchCount >= 1)
        #expect(result.redactedPageCount == 1)
        #expect(result.verified)

        // The critical guarantee: the secret is gone from the produced bytes.
        let out = PDFDocument(data: result.data)
        #expect(out?.findString(secret, withOptions: [.caseInsensitive]).isEmpty ?? false)
    }

    @Test("Redaction throws noMatches when the term is absent")
    func redactionNoMatchThrows() throws {
        let url = try makeTextPDF("Nothing sensitive here at all.")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: PDFRedactionError.self) {
            _ = try PDFRedactionService().redact(source: url, terms: ["absent-term-zzz"])
        }
    }

    // MARK: - Authenticity

    @Test("Authenticity yields a 64-char SHA-256 and no false /AA on a plain PDF")
    func authenticitySignals() throws {
        let url = try makeTextPDF("An ordinary document with no scripts or actions.")
        defer { try? FileManager.default.removeItem(at: url) }
        let report = try FileAuthenticityInspector().analyze(url: url)
        #expect(report.sha256.count == 64)
        #expect(report.sizeBytes > 0)
        // The /AA raw-byte check was removed; a plain PDF must not warn about it.
        #expect(!report.signals.contains { $0.title.localizedCaseInsensitiveContains("auto-action") })
        // A once-saved PDF should be reported as a single save.
        #expect(report.signals.contains { $0.title.localizedCaseInsensitiveContains("single save") })
    }

    // MARK: - Evidence Explained citations

    @Test("Book citation is well-formed and free of double punctuation")
    func citationBook() {
        let c = EvidenceExplainedFormatter.format(.book, values: [
            "author": "Jane A. Smith", "title": "The Smiths of Kent",
            "place": "Baltimore", "publisher": "Genealogical Publishing",
            "year": "1998", "page": "142"
        ])
        #expect(!c.first.contains(".."))
        #expect(!c.sourceList.contains(".."))
        #expect(c.first.contains("Jane A. Smith"))
        #expect(c.first.contains("p. 142"))
        #expect(c.sourceList.hasPrefix("Smith, Jane A."))
    }

    @Test("Empty fields collapse cleanly without stray separators")
    func citationSparse() {
        let c = EvidenceExplainedFormatter.format(.newspaper, values: [
            "headline": "Reunion", "paper": "The Gazette"
        ])
        #expect(!c.first.contains(" ,"))
        #expect(!c.first.contains(".."))
        #expect(c.first.contains("Reunion"))
    }
}
