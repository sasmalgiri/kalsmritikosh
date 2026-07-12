//
//  EMLXParserTests.swift
//  KalsmritikoshTests
//
//  A3 — EMLXStructuralParser: peels the Apple Mail emlx byte-length wrapper and
//  produces the same typed blocks as the .eml path. Add to the test target to
//  run.
//

import Testing
import Foundation
@testable import Kalsmritikosh

struct EMLXParserTests {

    // "<byte length>\n<RFC822>\n<plist trailer>". Length counts the message bytes.
    private var emlx: Data {
        let message = "From: Alice <alice@example.com>\nSubject: Hi\n\nBody text.\n"
        let trailer = "<?xml version=\"1.0\"?><plist><dict/></plist>"
        let count = message.utf8.count
        return Data("\(count)\n\(message)\(trailer)".utf8)
    }

    @Test func peelReturnsExactMessageBytes() {
        let message = EMLXStructuralParser.peelMessage(emlx)
        #expect(message != nil)
        #expect(message?.contains("Subject: Hi") == true)
        // Trailer is excluded by the byte-count.
        #expect(message?.contains("plist") == false)
    }

    @Test func producesEmailBlocks() async throws {
        let doc = try await EMLXStructuralParser().parse(
            data: emlx, filename: "1.emlx", type: .appleMail,
            logicalSourceID: UUID(), sourceVersionID: UUID()
        )
        let subject = doc.blocks.first { $0.locator.emailHeaderField == "subject" }
        #expect(subject?.rawText == "Hi")
        #expect(doc.blocks.contains { $0.kind == .emailBody })
        #expect(doc.extractionStatus == .complete)
    }

    @Test func invalidPrefixIsCorrupt() async throws {
        let doc = try await EMLXStructuralParser().parse(
            data: Data("not-a-number\nFrom: x\n".utf8), filename: "bad.emlx", type: .appleMail,
            logicalSourceID: UUID(), sourceVersionID: UUID()
        )
        #expect(doc.extractionStatus == .corrupt)
    }
}
