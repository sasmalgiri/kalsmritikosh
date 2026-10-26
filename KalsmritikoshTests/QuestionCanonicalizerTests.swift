//
//  QuestionCanonicalizerTests.swift
//  KalsmritikoshTests
//
//  Any wording → one canonical form, only from the question's own text, only when no rule
//  understands it (closed-case simulation with Claude-written rewordings, 2026-10-26).
//

import Testing
import Foundation
@testable import Kalsmritikosh

@Suite("Question canonicalizer")
struct QuestionCanonicalizerTests {

    struct Scripted: QuestionRewriting {
        let choice: CanonicalChoice?
        func choose(for question: String, among forms: [CanonicalForm]) async -> CanonicalChoice? { choice }
    }

    @Test("A wording no rule understands becomes the canonical form, with the question's own spelling")
    func rewrites() async {
        let q = "Can you tell me the date on which brandy mize was sentenced?"
        #expect(!QuestionCanonicalizer.recognizedByRules(q))
        let out = await QuestionCanonicalizer.canonicalize(q, onDevice: nil,
            cloud: Scripted(choice: .init(formID: "person-sentenced-when", slots: ["person": "Brandy Mize"])), modelsAllowed: true)
        #expect(out == "When was Brandy Mize sentenced?")
        let email = await QuestionCanonicalizer.canonicalize("Tell me the people the email \"May-Sep Capacity\" went to.", onDevice: nil,
            cloud: Scripted(choice: .init(formID: "email-recipients", slots: ["subject": "May-Sep Capacity"])), modelsAllowed: true)
        #expect(email == "Who received the email \"May-Sep Capacity\"?")
    }

    @Test("Nothing invented: a slot the question does not hold, an unknown form, or a model-free regime keeps the question")
    func guards() async {
        let q = "Can you tell me the date on which Brandy Mize was sentenced?"
        #expect(await QuestionCanonicalizer.canonicalize(q, onDevice: nil,
            cloud: Scripted(choice: .init(formID: "person-sentenced-when", slots: ["person": "Brandy Smith"])), modelsAllowed: true) == nil)
        #expect(await QuestionCanonicalizer.canonicalize(q, onDevice: nil,
            cloud: Scripted(choice: .init(formID: "made-up", slots: [:])), modelsAllowed: true) == nil)
        #expect(await QuestionCanonicalizer.canonicalize(q, onDevice: nil,
            cloud: Scripted(choice: .init(formID: "person-sentenced-when", slots: ["person": "Brandy Mize"])), modelsAllowed: false) == nil)
        // A question the rules already understand never reaches a model.
        #expect(QuestionCanonicalizer.recognizedByRules("When was Brandy Mize sentenced?"))
    }

    @Test("The cloud reply is read as JSON; none is no choice")
    func parse() {
        #expect(QuestionCanonicalizer.parse("{\"form\": \"email-sender\", \"slots\": {\"subject\": \"X\"}}")
                == CanonicalChoice(formID: "email-sender", slots: ["subject": "X"]))
        #expect(QuestionCanonicalizer.parse("Sure! {\"form\": \"none\"}") == nil)
        // The menu holds the question and the forms — never a document.
        let prompt = QuestionCanonicalizer.prompt(question: "Q?")
        #expect(prompt.hasSuffix("Question: Q?") && prompt.contains("email-sender"))
    }
}

@Suite("Question normalizer")
struct QuestionNormalizerTests {
    @Test("Courtesy wrappers go; what is asked stays")
    func wrappers() {
        #expect(QuestionCanonicalizer.normalize("Can you tell me the date on which Brandy Mize was sentenced?") == "When Brandy Mize was sentenced?")
        #expect(QuestionCanonicalizer.normalize("Could you tell me what Miguel Arias Velasquez was charged with?") == "What Miguel Arias Velasquez was charged with?")
        #expect(QuestionCanonicalizer.normalize("Can you tell me who sent the email titled \"California Contract Meeting\"?") == "Who sent the email titled \"California Contract Meeting\"?")
        #expect(QuestionCanonicalizer.normalize("I need to know the probable cause listed for NTSB case ERA15LA366 — what was it?") == "The probable cause listed for NTSB case ERA15LA366?")
        #expect(QuestionCanonicalizer.normalize("When was Mayo v. United States decided?") == "When was Mayo v. United States decided?")
        #expect(ProceedingAnswerer.parse("What Miguel Arias Velasquez was charged with?")?.ask == .chargedWith)
        #expect(ProceedingAnswerer.parse("When Brandy Mize was sentenced?")?.ask == .when(.sentenced))
    }
}
