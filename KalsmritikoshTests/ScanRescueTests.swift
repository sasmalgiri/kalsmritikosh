//
//  ScanRescueTests.swift
//  KalsmritikoshTests
//
//  A4 — Read with AI: page images are rendered, sent as a previewed document send with every image
//  listed in the outbound record, and the transcription is a separate document that says what it is.
//

import Testing
import Foundation
import AppKit
import PDFKit
@testable import Kalsmritikosh

@Suite("Read with AI (A4)")
struct ScanRescueTests {

    /// A three-page PDF drawn here (an image-only scan is not needed: the renderer reads any page).
    static func pdf(pages: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("scan-\(UUID().uuidString).pdf")
        let doc = PDFDocument()
        for i in 0..<pages {
            let image = NSImage(size: NSSize(width: 612, height: 792), flipped: false) { r in
                NSColor.white.setFill(); r.fill()
                ("Invoice 432 — page \(i + 1)" as NSString).draw(at: NSPoint(x: 72, y: 700), withAttributes: [.font: NSFont.systemFont(ofSize: 24)])
                return true
            }
            if let page = PDFPage(image: image) { doc.insert(page, at: i) }
        }
        #expect(doc.write(to: url))
        return url
    }

    @Test("Pages render to JPEG within Claude's size, labelled by page; a non-document is refused")
    func rendering() throws {
        let url = try Self.pdf(pages: 3)
        defer { try? FileManager.default.removeItem(at: url) }
        let (images, total) = try ScanRescue.pageImages(of: url)
        #expect(total == 3 && images.map(\.label) == ["page 1", "page 2", "page 3"])
        for img in images {
            #expect(img.mediaType == "image/jpeg")
            let rep = try #require(NSBitmapImageRep(data: img.data))
            #expect(max(rep.pixelsWide, rep.pixelsHigh) <= Int(ScanRescue.maxPixels) + 1)
        }
        let junk = FileManager.default.temporaryDirectory.appendingPathComponent("x-\(UUID().uuidString).pdf")
        try Data("not a pdf".utf8).write(to: junk)
        defer { try? FileManager.default.removeItem(at: junk) }
        #expect(throws: ScanRescue.RescueError.notReadable(junk.lastPathComponent)) { try ScanRescue.pageImages(of: junk) }
    }

    @Test("The transcription says it is not the original, cites the file and its digest, the model, and unread pages")
    func documentHeader() {
        let text = ScanRescue.document(original: URL(fileURLWithPath: "/x/Ledger scan.pdf"), originalSHA256: "abc123",
                                       provider: "AI Included (Claude Opus 5)", model: "claude-opus-5",
                                       pagesRead: 40, totalPages: 52, at: Date(timeIntervalSince1970: 1_800_000_000), body: "=== page 1 ===\nPaid 3 May.\n")
        #expect(text.hasPrefix("AI TRANSCRIPTION — NOT THE ORIGINAL DOCUMENT"))
        #expect(text.contains("Original file: Ledger scan.pdf") && text.contains("Original SHA-256: abc123"))
        #expect(text.contains("claude-opus-5") && text.contains("Pages read: 40 of 52") && text.contains("Pages 41–52 were not read"))
        #expect(text.contains("check every quotation") && text.hasSuffix("Paid 3 May.\n"))
        #expect(ScanRescue.fileName(for: URL(fileURLWithPath: "/x/Ledger scan.pdf")) == "Ledger scan — AI transcription.txt")
    }

    @Test("Images go first as base64 blocks for Claude and AI Included, inline data for Gemini; OpenAI is refused")
    func requestWithImages() throws {
        let img = OutboundImage(mediaType: "image/jpeg", data: Data([0xFF, 0xD8, 0xFF]), label: "page 1")
        for kind in [OnlineProviderKind.anthropic, .included] {
            let r = try OnlineRequestBuilder.build(kind: kind, model: "claude-opus-5", apiKey: "eyJhbGciOiJFUzI1NiJ9.eyJ0ZXN0Ijp0cnVlfQ.dGVzdC1zaWduYXR1cmU", system: nil,
                                                   prompt: "Transcribe", maxTokens: 8000, images: [img])
            let body = try #require(try JSONSerialization.jsonObject(with: r.body) as? [String: Any])
            let content = try #require(((body["messages"] as? [[String: Any]])?.first?["content"]) as? [[String: Any]])
            #expect(content.first?["type"] as? String == "image" && content.last?["text"] as? String == "Transcribe")
            #expect(((content.first?["source"] as? [String: Any])?["data"] as? String) == img.data.base64EncodedString())
        }
        let g = try OnlineRequestBuilder.build(kind: .gemini, model: "gemini-x", apiKey: "k", system: nil, prompt: "Transcribe", maxTokens: 8000, images: [img])
        let gBody = try #require(try JSONSerialization.jsonObject(with: g.body) as? [String: Any])
        let parts = try #require(((gBody["contents"] as? [[String: Any]])?.first?["parts"]) as? [[String: Any]])
        #expect(parts.first?["inline_data"] != nil && parts.last?["text"] as? String == "Transcribe")
        #expect(throws: OnlineRequestBuilder.BuildError.imagesNotSupported(OnlineProviderKind.openai.displayName)) {
            try OnlineRequestBuilder.build(kind: .openai, model: "m", apiKey: "k", system: nil, prompt: "p", maxTokens: 10, images: [img])
        }
        // A text-only request is unchanged.
        let plain = try OnlineRequestBuilder.build(kind: .anthropic, model: "m", apiKey: "k", system: nil, prompt: "Q", maxTokens: 10)
        let pb = try #require(try JSONSerialization.jsonObject(with: plain.body) as? [String: Any])
        #expect(((pb["messages"] as? [[String: Any]])?.first?["content"]) as? String == "Q")
    }

    nonisolated final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var _previews: [OutboundPreview] = []
        private var _requests: [OutboundHTTPRequest] = []
        func add(_ p: OutboundPreview) { lock.withLock { _previews.append(p) } }
        func add(_ r: OutboundHTTPRequest) { lock.withLock { _requests.append(r) } }
        var previews: [OutboundPreview] { lock.withLock { _previews } }
        var requests: [OutboundHTTPRequest] { lock.withLock { _requests } }
    }

    @Test("Through the real provider path: a previewed document send listing every image; declined sends nothing; an ineligible provider is refused")
    func providerPath() async throws {
        let f = try await CaseErasureTests.boot()
        defer { try? FileManager.default.removeItem(at: f.temp) }
        let box = Box()
        let reply = Data(#"{"content":[{"type":"text","text":"=== page 1 ===\nInvoice 432"}]}"#.utf8)
        func provider(kind: OnlineProviderKind = .anthropic, confirmed: Bool = true, allow: Bool = true) -> OnlineCloudProvider {
            let snapshot = OnlineSnapshot(cloudAllowed: true, kind: kind, model: "claude-opus-5", apiKey: "test-key",
                                          confirmedDocumentTerms: confirmed ? kind.documentTermsVersion : nil, dailyByteCap: nil)
            return OnlineCloudProvider(outboundLog: OutboundLogRepository(database: f.db), knownNames: { [] },
                                       seams: .init(settings: { snapshot },
                                                    consent: { box.add($0); return allow },
                                                    transport: { box.add($0); return OutboundHTTPResponse(status: 200, body: reply) }))
        }
        let images = [OutboundImage(mediaType: "image/jpeg", data: Data(repeating: 7, count: 1000), label: "page 1"),
                      OutboundImage(mediaType: "image/jpeg", data: Data(repeating: 8, count: 2000), label: "page 2")]
        let text = try await provider().readPageImages(images, fileName: "Ledger scan.pdf")
        #expect(text.contains("Invoice 432") && box.requests.count == 1)
        let preview = try #require(box.previews.first)
        #expect(preview.carriesDocuments && preview.bytes >= 3000)
        #expect(preview.text.contains("[image page 1: image/jpeg, 1000 bytes, SHA-256") && preview.text.contains("[image page 2"))
        #expect(preview.providerTerms?.contains("cannot be masked") == true)
        let log = try await OutboundLogRepository(database: f.db).recent()
        #expect(log.contains { $0.outcome == "sent" && $0.payloadText.contains("[image page 2") })
        // Declined: nothing dispatched.
        await #expect(throws: OnlineCloudProvider.OnlineError.self) { _ = try await provider(allow: false).readPageImages(images, fileName: "x.pdf") }
        #expect(box.requests.count == 1)
        // Terms not confirmed, or a provider not reviewed for documents: refused before any preview.
        let shown = box.previews.count
        await #expect(throws: OnlineCloudProvider.OnlineError.self) { _ = try await provider(confirmed: false).readPageImages(images, fileName: "x.pdf") }
        await #expect(throws: OnlineCloudProvider.OnlineError.self) { _ = try await provider(kind: .openai).readPageImages(images, fileName: "x.pdf") }
        #expect(box.previews.count == shown && box.requests.count == 1)
    }
}
