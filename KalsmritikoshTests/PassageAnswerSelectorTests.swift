//
//  PassageAnswerSelectorTests.swift
//  KalsmritikoshTests
//
//  Answer-quality uplift W1+W4 — proves the selector flips the live diagnostic.
//  The candidate texts are the ACTUAL strings from the owner's archive
//  (/tmp snapshot, 2026-09-17): the boilerplate heading + subject-field facts
//  that the app wrongly surfaced, and the real passage that answers. With the
//  selector, "who drafted the claims?" now chooses the drafting passage, and a
//  pool with no answering passage abstains instead of dumping boilerplate.
//

import Testing
@testable import Kalsmritikosh

@Suite("Answer-quality — passage selection over dumps")
struct PassageAnswerSelectorTests {

    private let boilerplate = AnswerCandidate(
        text: "AND IN THE MATTER OF PATENT ACT, 1970 AS AMENDED BY THE PATENTS [AMENDMENT] ACT, 2005",
        kind: .boilerplate, sourceID: "doc-heading")
    private let applicantFact = AnswerCandidate(
        text: "applicant: Shirshendu Sasmal", kind: .fieldFact, sourceID: "fact-applicant")
    private let appNoFact = AnswerCandidate(
        text: "application number: 202331019665", kind: .fieldFact, sourceID: "fact-appno")
    private let draftPassage = AnswerCandidate(
        text: "Pursuant to your instruction, we have prepared a draft response along with the proposed amendment in claims, abstract.",
        kind: .passage, sourceID: "email-khurana-1")
    private let filePassage = AnswerCandidate(
        text: "Thank you for your approval. We shall proceed to finalize and file the FER response. @Khurana & Khurana- Docketing.",
        kind: .passage, sourceID: "email-khurana-2")

    @Test func whoDraftedTheClaims_picksTheDraftingPassageNotBoilerplateOrFields() {
        let sel = PassageAnswerSelector()
        let result = sel.select(
            question: "who has drafted the claims?",
            candidates: [boilerplate, applicantFact, appNoFact, draftPassage, filePassage])
        guard case let .passage(text, sourceID) = result else {
            Issue.record("Expected a passage, got \(result)"); return
        }
        #expect(sourceID == "email-khurana-1")
        #expect(text.contains("prepared a draft"))
        #expect(text.contains("amendment in claims"))
    }

    @Test func noAnsweringPassage_abstainsInsteadOfDumping() {
        let sel = PassageAnswerSelector()
        // Only boilerplate + subject-field facts available — the exact wrong
        // pool the app used. An actor question must abstain, not pad.
        let result = sel.select(
            question: "who has drafted the claims?",
            candidates: [boilerplate, applicantFact, appNoFact])
        guard case .abstain = result else {
            Issue.record("Expected abstain, got \(result)"); return
        }
    }

    @Test func fieldQuestionStillAnsweredByFieldFact() {
        let sel = PassageAnswerSelector()
        // A genuine field question is NOT an actor question, so a field-fact may answer.
        let result = sel.select(
            question: "what is the application number?",
            candidates: [boilerplate, appNoFact, filePassage])
        guard case let .passage(text, sourceID) = result else {
            Issue.record("Expected a passage, got \(result)"); return
        }
        #expect(sourceID == "fact-appno")
        #expect(text.contains("202331019665"))
    }

    @Test func boilerplateAloneAbstains() {
        let sel = PassageAnswerSelector()
        let result = sel.select(question: "who signed the agreement?", candidates: [boilerplate])
        guard case .abstain = result else {
            Issue.record("Expected abstain, got \(result)"); return
        }
    }
}
