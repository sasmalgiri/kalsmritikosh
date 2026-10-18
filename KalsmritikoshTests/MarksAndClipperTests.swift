//
//  MarksAndClipperTests.swift
//  KalsmritikoshTests
//
//  X-3 rich-text notes and PDF marks; X-4 the Safari clipper's payload, its hand-over to the
//  inbox, and the Markdown copy.
//

import Foundation
import AppKit
import PDFKit
import CryptoKit
import Testing
@testable import Kalsmritikosh

@Suite("X-3 Rich text notes and PDF marks")
struct RichAndPDFMarksTests {
    /// A one-page PDF with real text, so PDFKit can find selections in it.
    private func textPDF(_ text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("marks-\(UUID().uuidString).pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let ctx = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        ctx.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        (text as NSString).draw(at: NSPoint(x: 72, y: 700), withAttributes: [.font: NSFont.systemFont(ofSize: 18)])
        NSGraphicsContext.restoreGraphicsState()
        ctx.endPDFPage()
        ctx.closePDF()
        return url
    }

    @Test("A rich-text note round-trips with its formatting and keeps versions")
    func richNote() throws {
        let base = try ParityFixture.tempFolder("rich")
        defer { try? FileManager.default.removeItem(at: base) }
        let store = NotesStore(base: base)
        let url = try store.create(title: "Plan", format: .richText)
        #expect(url.pathExtension == "rtf")
        #expect(NotesStore.format(of: url) == .richText)
        let text = NSMutableAttributedString(string: "Plan\n\nBold point")
        text.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 13), range: NSRange(location: 6, length: 10))
        #expect(try store.saveRich(text, to: url))
        let back = try store.readRich(url)
        #expect(back.string == "Plan\n\nBold point")
        let font = back.attribute(.font, at: 7, effectiveRange: nil) as? NSFont
        #expect(font.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } == true)
        #expect(store.versions(of: url).count == 1)
        // A title taken in the other format counts as taken.
        #expect(throws: NotesStore.NotesError.self) { _ = try store.create(title: "Plan", format: .markdown) }
    }

    @Test("Marks are kept beside the PDF; a text mark is also a plain highlight; removing stamps both")
    func marks() async throws {
        let dir = try ParityFixture.tempFolder("marks")
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try await ParityFixture.database(in: dir)
        let doc = try await ParityFixture.document(db, name: "m.pdf", text: "Clause seven applies").id
        let repo = PDFMarksRepository(database: db)
        let id = try await repo.add(objectID: doc, sourceURL: nil, page: 0, kind: .strikeout,
                                    rects: [CGRect(x: 72, y: 700, width: 120, height: 18)], color: "pink",
                                    quote: " Clause seven ", contents: "wrong")
        let marks = try await repo.marks(for: doc)
        #expect(marks.count == 1)
        #expect(marks.first?.quote == "Clause seven")
        let annotationID = try #require(marks.first?.annotationID)
        let stance = try await db.query("SELECT stance, note FROM annotations WHERE id = ?;", [.uuid(annotationID)]).first
        #expect(stance?.string(0) == "note")                    // a mark never confirms or corrects evidence
        #expect(stance?.string(1) == "wrong")
        try await repo.setContents(id, "corrected wording")
        #expect(try await db.query("SELECT note FROM annotations WHERE id = ?;", [.uuid(annotationID)]).first?.string(0) == "corrected wording")
        try await repo.remove(id)
        #expect(try await repo.marks(for: doc).isEmpty)
        #expect(try await db.query("SELECT removed_at IS NOT NULL FROM annotations WHERE id = ?;", [.uuid(annotationID)]).first?.int(0) == 1)
        #expect(try await db.query("SELECT COUNT(*) FROM pdf_marks;", []).first?.int(0) == 1)   // stamped, not deleted
        await #expect(throws: PDFMarksError.nothingToMark) {
            try await repo.add(objectID: doc, sourceURL: nil, page: 0, kind: .highlight, rects: [.zero], quote: "x", contents: nil)
        }
        // A note carries no annotation (it marks a place, not a quote).
        _ = try await repo.add(objectID: doc, sourceURL: nil, page: 0, kind: .note, rects: [CGRect(x: 10, y: 10, width: 22, height: 22)],
                               quote: nil, contents: "check")
        #expect(try await repo.marks(for: doc).first?.annotationID == nil)
    }

    @Test("Export writes an annotated copy and a list; the original's bytes are unchanged")
    @MainActor func export() throws {
        let original = try textPDF("The tenant shall pay rent monthly.")
        defer { try? FileManager.default.removeItem(at: original) }
        let before = try Data(contentsOf: original)
        let folder = try ParityFixture.tempFolder("export")
        defer { try? FileManager.default.removeItem(at: folder) }
        let marks = [
            PDFMark(id: UUID(), objectID: UUID(), page: 0, kind: .highlight, rects: [CGRect(x: 72, y: 700, width: 200, height: 20)],
                    color: "yellow", quote: "The tenant shall pay", contents: "key duty", annotationID: nil, createdAt: Date()),
            PDFMark(id: UUID(), objectID: UUID(), page: 0, kind: .note, rects: [CGRect(x: 40, y: 700, width: 22, height: 22)],
                    color: "blue", quote: nil, contents: "check the lease date", annotationID: nil, createdAt: Date()),
            PDFMark(id: UUID(), objectID: UUID(), page: 7, kind: .underline, rects: [CGRect(x: 1, y: 1, width: 5, height: 5)],
                    color: "green", quote: "off the end", contents: nil, annotationID: nil, createdAt: Date())
        ]
        let r = try PDFMarksController.exportAnnotatedCopy(of: original, marks: marks, into: folder)
        #expect(r.originalUnchanged)
        #expect(try Data(contentsOf: original) == before)
        let copy = try #require(PDFDocument(url: r.pdf))
        let drawn = copy.page(at: 0)?.annotations ?? []
        #expect(drawn.contains { $0.type == "Highlight" })
        #expect(drawn.contains { $0.type == "Text" && $0.contents == "check the lease date" })
        #expect(PDFDocument(url: original)?.page(at: 0)?.annotations.isEmpty == true)
        let md = try String(contentsOf: r.summary, encoding: .utf8)
        #expect(md.contains("Page 1 · Highlight: \u{201C}The tenant shall pay\u{201D} — key duty"))
        #expect(md.contains("Page 8 · Underline"))                // a mark beyond the last page is listed, not drawn
    }

    @Test("A locked PDF is refused with a sentence")
    @MainActor func lockedPDF() throws {
        let plain = try textPDF("Secret terms.")
        defer { try? FileManager.default.removeItem(at: plain) }
        let locked = plain.deletingLastPathComponent().appendingPathComponent("locked-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: locked) }
        let doc = try #require(PDFDocument(url: plain))
        #expect(doc.write(to: locked, withOptions: [.userPasswordOption: "pw", .ownerPasswordOption: "pw"]))
        let folder = try ParityFixture.tempFolder("export")
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(throws: CocoaError.self) {
            _ = try PDFMarksController.exportAnnotatedCopy(of: locked, marks: [], into: folder)
        }
    }
}

@Suite("X-4 Safari clipper")
struct ClipperTests {
    @Test("A clip message becomes a request; anything else is refused")
    func parse() throws {
        let r = try ClipRequest(message: ["action": "clip", "kind": "page", "title": " Lease ", "url": "https://example.org/a",
                                          "html": "<html><head></head><body>x</body></html>", "text": ""])
        #expect(r.kind == .page && r.title == "Lease")
        #expect(throws: ClipRequest.Refusal.notAClip) { _ = try ClipRequest(message: ["action": "other"]) }
        #expect(throws: ClipRequest.Refusal.notAClip) { _ = try ClipRequest(message: ["action": "clip", "kind": "video"]) }
        #expect(throws: ClipRequest.Refusal.notAClip) { _ = try ClipRequest(message: nil) }
    }

    @Test("A page keeps its address inside the file; a selection without HTML keeps its text")
    func payloads() throws {
        let page = try ClipRequest(kind: .page, title: "Rent: A/B guide", url: "https://e.org/x?a=1&b=2",
                                   html: "<html><head><title>t</title></head><body><p>Body</p></body></html>", text: "").payload()
        let html = String(decoding: page.data, as: UTF8.self)
        #expect(page.name == "Rent- A-B guide.html")
        #expect(html.hasPrefix("<!-- Clipped by Investigation Docs Made Easy from https://e.org/x?a=1&amp;b=2"))
        #expect(html.contains("<head><meta name=\"kalsmritikosh-source\" content=\"https://e.org/x?a=1&amp;b=2\">"))
        let sel = try ClipRequest(kind: .selection, title: "", url: "https://e.org/y", html: "", text: "a < b").payload()
        #expect(sel.name == "e.org (selection).html")
        #expect(String(decoding: sel.data, as: UTF8.self).contains("<pre>a &lt; b</pre>"))
        #expect(throws: ClipRequest.Refusal.empty) {
            _ = try ClipRequest(kind: .selection, title: "x", url: "", html: " ", text: "").payload()
        }
        #expect(throws: ClipRequest.Refusal.empty) { _ = try ClipRequest(kind: .page, title: "x", url: "", html: "", text: "").payload() }
        let big = String(repeating: "a", count: ClipperWire.maxBytes + 1)
        #expect(throws: ClipRequest.Refusal.tooLarge(25)) { _ = try ClipRequest(kind: .page, title: "x", url: "", html: big, text: "").payload() }
        #expect(ClipRequest.fileStem(title: ".hidden", url: "") == "-hidden")
    }

    @Test("A clip written to the inbox is imported unchanged, and a Markdown clip asks for its copy")
    func handOver() throws {
        let inbox = try ParityFixture.tempFolder("inbox")
        defer { try? FileManager.default.removeItem(at: inbox) }
        let html = "<html><head></head><body><h1>Lease</h1><p>Pay <b>monthly</b>.</p></body></html>"
        let p = try ClipRequest(kind: .markdown, title: "Lease", url: "https://e.org/lease", html: html, text: "").payload()
        _ = try ClipRequest.write(p, origin: "Safari clipper", url: "https://e.org/lease", into: inbox)
        let saved = try ParityFixture.tempFolder("saved")
        defer { try? FileManager.default.removeItem(at: saved) }
        var captured: [(Data, String, String)] = []
        let result = ShareInbox.drain(inbox) { data, name, origin in
            captured.append((data, name, origin))
            let file = saved.appendingPathComponent(name)
            try data.write(to: file)
            return CaptureIntake.Saved(file: file, sha256: CaptureIntake.sha256(data))
        }
        #expect(result.moved == 1)
        #expect(result.refused.isEmpty)
        #expect(captured.first?.1 == "Lease.html")
        #expect(captured.first?.2.hasPrefix("Safari clipper") == true)
        #expect(result.markdownRequests.first?.sourceURL == "https://e.org/lease")
        #expect(result.markdownRequests.first?.title == "Lease")
        #expect((try? FileManager.default.contentsOfDirectory(atPath: inbox.path))?.isEmpty == true)
    }

    @Test("A changed clip is refused, not imported")
    func tampered() throws {
        let inbox = try ParityFixture.tempFolder("inbox")
        defer { try? FileManager.default.removeItem(at: inbox) }
        let p = try ClipRequest(kind: .page, title: "T", url: "u", html: "<p>x</p>", text: "").payload()
        let item = try ClipRequest.write(p, origin: "Safari clipper", url: "u", into: inbox)
        try Data("changed".utf8).write(to: item.appendingPathComponent(p.name))
        let r = ShareInbox.drain(inbox) { _, _, _ in Issue.record("must not save"); throw CocoaError(.fileWriteUnknown) }
        #expect(r.moved == 0 && r.refused.count == 1)
    }

    @Test("Markdown copy: headings, emphasis, links and lists; scripts, navigation and images dropped")
    @MainActor func markdown() {
        let html = """
        <html><head><style>p{color:red}</style><script>var x=1</script></head><body>
        <nav><a href="/home">Home</a></nav>
        <article><h1>Lease terms</h1><p>The tenant pays <b>monthly</b> and <i>on time</i>.
        See <a href="https://e.org/rules">the rules</a>.</p><ul><li>First item</li><li>Second item</li></ul>
        <img src="https://tracker.example/p.png" alt="diagram"></article><footer>Copyright</footer></body></html>
        """
        let md = HTMLMarkdown.markdown(fromHTML: html, title: "Lease", sourceURL: "https://e.org/lease")
        #expect(md.hasPrefix("# Lease\n\nSource: <https://e.org/lease>"))
        #expect(md.contains("Lease terms"))
        #expect(md.contains("**monthly**"))
        #expect(md.contains("*on time*"))
        #expect(md.contains("[the rules](https://e.org/rules)"))
        #expect(md.contains("First item") && md.contains("Second item"))
        #expect(!md.contains("var x"))
        #expect(!md.contains("Home"))
        #expect(!md.contains("Copyright"))
        #expect(!md.contains("tracker.example"))
        #expect(HTMLMarkdown.readablePart(of: "<img src=\"http://x/y.png\">").contains("http") == false)
    }
}
