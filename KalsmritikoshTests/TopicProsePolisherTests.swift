//
//  TopicProsePolisherTests.swift
//  KalsmritikoshTests
//
//  Topic-Ledger U6 — the AI polish adds connective grammar ONLY, never changes
//  facts, and degrades to the deterministic spine when no model is available.
//

import Testing
@testable import Kalsmritikosh

@Suite("Topic-Ledger U6 — fact-preserving prose polish")
struct TopicProsePolisherTests {

    let spine = "Topic: Patent 202331019665.\n\nWhat the sources record:\n• Applicant: Shirshendu Sasmal"

    @Test func noModelReturnsSpineUnchanged() async {
        let p = TopicProsePolisher(reason: { _ in nil })      // no reasoning model
        #expect(await p.polish(spine: spine) == spine)
    }

    @Test func factPreservingPolishIsAccepted() async {
        let polished = "The patent application 202331019665 was filed by Shirshendu Sasmal."
        let p = TopicProsePolisher(reason: { _ in polished })
        #expect(await p.polish(spine: spine) == polished)
    }

    @Test func polishThatDropsANumberIsRejected() async {
        let bad = "The patent application was filed by Shirshendu Sasmal."   // lost 202331019665
        let p = TopicProsePolisher(reason: { _ in bad })
        #expect(await p.polish(spine: spine) == spine, "dropping a fact → keep the spine")
    }

    @Test func polishThatInventsANumberIsRejected() async {
        let bad = "Application 202331019665 was filed in 1999 by Shirshendu Sasmal."  // invented 1999
        let p = TopicProsePolisher(reason: { _ in bad })
        #expect(await p.polish(spine: spine) == spine, "inventing a number → keep the spine")
    }

    @Test func polishThatDropsAProperNounIsRejected() async {
        let bad = "Application 202331019665 was filed by the applicant."   // lost "Shirshendu"/"Sasmal"
        let p = TopicProsePolisher(reason: { _ in bad })
        #expect(await p.polish(spine: spine) == spine)
    }
}
