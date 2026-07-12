//
//  MBOXParserTests.swift
//  KalsmritikoshTests
//
//  A3 — MBOXStructuralParser: mailbox framing (split on "From " separators) and
//  per-message structural extraction via the shared EML message builder. Add to
//  the test target to run.
//

import Testing
import Foundation
@testable import Kalsmritikosh

struct MBOXParserTests {

    private let mbox = """
    From alice@example.com Mon Jan 01 00:00:00 2024
    From: Alice <alice@example.com>
    To: Bob <bob@example.com>
    Subject: First

    Hello Bob.
    From bob@example.com Mon Jan 02 00:00:00 2024
    From: Bob <bob@example.com>
    Subject: Second

    Reply here.
    """

    @Test func splitsOnFromSeparators() {
        let messages = MBOXStructuralParser.splitMessages(mbox)
        #expect(messages.count == 2)
        #expect(messages[0].contains("Subject: First"))
        #expect(messages[1].contains("Subject: Second"))
        // Separator lines are dropped.
        #expect(!messages[0].hasPrefix("From alice@"))
    }

    @Test func eachMessageBecomesTypedBlocks() async throws {
        let doc = try await MBOXStructuralParser().parse(
            data: Data(mbox.utf8), filename: "inbox.mbox", type: .mbox,
            logicalSourceID: UUID(), sourceVersionID: UUID()
        )
        // Two subjects → two subject header blocks, each tagged with its index.
        let subjects = doc.blocks.filter { $0.locator.emailHeaderField == "subject" }
        #expect(subjects.count == 2)
        #expect(subjects.contains { $0.rawText == "First" })
        #expect(subjects.contains { $0.rawText == "Second" })
        // messageIndex stamped so messages stay distinguishable.
        let indices = Set(subjects.compactMap { block -> Int64? in
            if case .int(let n)? = block.attributes["messageIndex"]?.value { return n }
            return nil
        })
        #expect(indices == [0, 1])
        // Ordinals are globally strictly increasing across messages.
        #expect(doc.blocks.map(\.ordinal) == Array(0..<doc.blocks.count))
    }
}
