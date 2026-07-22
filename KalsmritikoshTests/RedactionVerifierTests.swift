//
//  RedactionVerifierTests.swift
//  KalsmritikoshTests
//
//  RED-002 — the export redaction gate catches a protected value surviving through every
//  common leak channel (exact/case/whitespace/markup), and passes clean output.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Redaction verifier (RED-002)")
struct RedactionVerifierTests {

    private let v = RedactionVerifier()

    @Test("Properly redacted output is clean")
    func clean() {
        #expect(v.isClean("Payment of [REDACTED] to [REDACTED].", of: ["John Smith", "4111111111111111"]))
    }

    @Test("Exact and case leaks are caught")
    func exactAndCase() {
        #expect(v.leaks(in: "paid to John Smith", protectedTerms: ["John Smith"]).first?.channel == .exact)
        #expect(v.leaks(in: "paid to john smith", protectedTerms: ["John Smith"]).first?.channel == .caseInsensitive)
    }

    @Test("Whitespace-split leak is caught (entity split across spacing/newlines)")
    func whitespaceLeak() {
        let leaks = v.leaks(in: "J o h n\nS m i t h", protectedTerms: ["John Smith"])
        #expect(leaks.first?.channel == .whitespaceCollapsed)
    }

    @Test("Markup-interrupted leak is caught")
    func markupLeak() {
        let leaks = v.leaks(in: "Jo<b>hn</b> Sm<i>ith</i>", protectedTerms: ["JohnSmith"])
        #expect(!leaks.isEmpty)   // alphanumeric-only channel
    }

    @Test("Package verification flags the leaking artifact by name")
    func packageLeak() {
        let leaks = v.verifyPackage([
            "summary.txt": "All redacted here [REDACTED].",
            "appendix.txt": "oops account 4111111111111111 slipped through"
        ], protectedTerms: ["4111111111111111"])
        #expect(leaks.count == 1)
        #expect(leaks.first?.artifact == "appendix.txt")
    }

    @Test("Short/one-char terms don't false-positive")
    func shortTerms() {
        #expect(v.isClean("a normal sentence about apples", of: ["a", "x"]))
    }
}
