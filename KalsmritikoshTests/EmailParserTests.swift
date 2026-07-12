//
//  EmailParserTests.swift
//  KalsmritikoshTests
//
//  A3 — EmailStructuralParser: typed header/body blocks with message-id
//  locators. Add to the test target to run.
//

import Testing
import Foundation
@testable import Kalsmritikosh

struct EmailParserTests {

    private let sample = """
    From: Alice <alice@example.com>
    To: Bob <bob@example.com>
    Subject: Kickoff
    Date: Mon, 1 Apr 2026 12:00:00 +0000
    Message-ID: <abc123@example.com>

    Let's meet on Thursday.
    """

    @Test func headerAndBodyBlocks() throws {
        let doc = try EmailStructuralParser().parse(
            data: Data(sample.utf8), filename: "m.eml", type: .eml,
            logicalSourceID: UUID(), sourceVersionID: UUID()
        )
        let headerFields = doc.blocks.filter { $0.kind == .emailHeader }.compactMap { $0.locator.emailHeaderField }
        #expect(headerFields.contains("from"))
        #expect(headerFields.contains("subject"))
        #expect(headerFields.contains("message-id"))
        let body = doc.blocks.first { $0.kind == .emailBody }
        #expect(body?.rawText.contains("Thursday") == true)
        #expect(body?.locator.messageID == "<abc123@example.com>")
    }

    @Test func headerFoldingUnfolds() {
        let raw = "Subject: a very\n long subject\nFrom: x@y.com\n\nbody"
        let (headers, body) = EmailStructuralParser.splitHeadersAndBody(raw)
        #expect(headers["subject"] == "a very long subject")
        #expect(headers["from"] == "x@y.com")
        #expect(body == "body")
    }
}
