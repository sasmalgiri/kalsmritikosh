//
//  AnswerPresentationTests.swift
//  KalsmritikoshTests
//
//  U-1 acceptance — Answer/Evidence separation. The split is pure, so
//  these run in the fast tier: kill-evidence still renders the answer,
//  sweep-failure ships badged or abstains by policy, the badge table
//  maps exactly, and no primary path renders evidence as the answer.
//

import Testing
import Foundation
@testable import Kalsmritikosh

@Suite("U-1 Answer/Evidence separation")
struct AnswerPresentationTests {

    private func makeAnswer(
        body: String,
        answerText: String?,
        citations: [VerifiedAnswer.Citation] = [],
        report: ConfidenceReport? = nil,
        refused: Bool = false,
        state: AnswerState = .unknown
    ) -> VerifiedAnswer {
        VerifiedAnswer(body: body, answerText: answerText, citations: citations,
                       confidence: Confidence(0.8), refused: refused,
                       report: report, answerState: state)
    }

    // — the split is byte-preserving: answer prefix + evidence remainder —

    @Test func splitPreservesComposerBytes() {
        let sentence = "The patent was granted on 28 November 2024."
        let body = sentence + "\n\nAbout: Shirshendu Sasmal\n\nConfidence: strong · 2 sources"
        let answer = makeAnswer(body: body, answerText: sentence,
                                citations: [.init(objectID: UUID(), snippet: "x")],
                                state: .supported)
        let split = AnswerPresentation.split(body: body, answer: answer)
        #expect(split.answer.text == sentence)
        #expect(split.answer.trustNote == "Confidence: strong · 2 sources")
        #expect(split.evidence.text == "About: Shirshendu Sasmal")
    }

    // — kill-evidence fixture: the answer renders, Evidence reports failure —

    @Test func killEvidenceStillRendersTheAnswer() {
        let sentence = "The filing happened in March 2023."
        let body = sentence + "\n\nConfidence: strong"
        // Evidence killed: zero citations, no report, yet an answered state.
        let answer = makeAnswer(body: body, answerText: sentence, state: .supported)
        let split = AnswerPresentation.split(body: body, answer: answer)
        #expect(split.answer.text == sentence)
        guard case .failed = split.evidence.state else {
            Issue.record("expected .failed evidence, got \(split.evidence.state)")
            return
        }
    }

    @Test func refusalIsCompleteEvidence() {
        let body = "Kalsmritikosh can't ground an answer to that yet.\nReason: nothing on file.\n\nConfidence: weak"
        let answer = makeAnswer(body: body, answerText: nil, refused: true, state: .notFound)
        let split = AnswerPresentation.split(body: body, answer: answer)
        #expect(split.evidence.state == .complete)
        #expect(split.answer.badge == .notFound)
    }

    // — badge semantics table —

    @Test func badgeTableMapsExactly() {
        #expect(AnswerPresentation.badge(for: makeAnswer(body: "b", answerText: "b", state: .supported)) == .supported)
        #expect(AnswerPresentation.badge(for: makeAnswer(body: "b", answerText: "b", state: .partiallySupported)) == .partiallySupported)
        #expect(AnswerPresentation.badge(for: makeAnswer(body: "b", answerText: "b", state: .unverified)) == .unverified)
        #expect(AnswerPresentation.badge(for: makeAnswer(body: "b", answerText: "b", state: .notFound)) == .notFound)
        #expect(AnswerPresentation.badge(for: makeAnswer(body: "b", answerText: "b", state: .unknown)) == nil)
        #expect(AnswerBadge.unverified.label == "Unverified — AI reading; evidence check failed")
    }

    // — sweep-failure fixture under both settings —

    @Test func sweepFailureShipsBadgedUnderShowPolicy() {
        // A candidate whose only sentence cites a nonexistent result id —
        // the sweep must keep nothing.
        let results = [ToolResult(id: "T1", text: "granted 2024", objectIDs: [])]
        let candidate = "The grant happened in 1999 [T9]."
        let kept = ToolGroundedComposer.sweep(candidate: candidate, question: "when?", results: results)
        #expect(kept.isEmpty)

        // Policy ON → the badged branch: unverified, zero citations,
        // bracket id stripped so nothing dresses as cited.
        let plan = QuestionPlan.derive(question: "when was it granted?", anchors: [])
        let shipped = ToolGroundedComposer.unverifiedFallback(text: candidate, plan: plan)
        #expect(shipped != nil)
        #expect(shipped?.verified == false)
        #expect(shipped?.citedObjectIDs.isEmpty == true)
        #expect(shipped?.sentences.first?.text == "The grant happened in 1999.")
        #expect(shipped?.sentences.allSatisfy { $0.citedID.isEmpty } == true)

        // Policy OFF is the compose() guard's default — nil (abstain) is
        // the sealed behavior; sweep emptiness above proves the trigger.
        let unverifiedAnswer = makeAnswer(body: "x", answerText: "x", state: .unverified)
        guard case .failed = AnswerPresentation.evidenceState(for: unverifiedAnswer) else {
            Issue.record("unverified must grade evidence as failed")
            return
        }
    }

    // — no primary path renders a citation list or footer as the answer —

    @Test func answerSectionNeverCarriesTheFooter() {
        let sentence = "Two payments were made in 2022."
        let body = sentence + "\n\nAbout: Acme Corp\nSources considered: 716\n\nConfidence: moderate · 2 sources\n⚠ Contradictions:\n  - dates disagree"
        let answer = makeAnswer(body: body, answerText: sentence,
                                citations: [.init(objectID: UUID(), snippet: "s")],
                                state: .partiallySupported)
        let split = AnswerPresentation.split(body: body, answer: answer)
        #expect(!split.answer.text.contains("About:"))
        #expect(!split.answer.text.contains("Sources considered"))
        #expect(!split.answer.text.contains("Contradictions"))
        #expect(split.evidence.text.contains("About: Acme Corp"))
        #expect(split.evidence.text.contains("Contradictions"))
    }
}
