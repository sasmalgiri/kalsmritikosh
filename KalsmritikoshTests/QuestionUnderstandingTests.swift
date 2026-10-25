//
//  QuestionUnderstandingTests.swift
//  KalsmritikoshTests
//
//  Owner decision 2026-10-25: rules first; the on-device model only for questions the rules could
//  not place (or placed on a weak generic field); the cloud only for what both missed. Each step may
//  only choose a field the retrieved facts carry, and gated questions never reach a model.
//

import Testing
import Foundation
@testable import Kalsmritikosh

@Suite("Question understanding cascade", .serialized)
struct QuestionUnderstandingTests {

    /// A scripted interpreter that records whether it was asked.
    final class Scripted: QuestionInterpreting, @unchecked Sendable {
        let answer: String?
        private(set) var asked = 0
        init(_ answer: String?) { self.answer = answer }
        func field(askedBy question: String, among fields: [String]) async -> String? { asked += 1; return answer }
    }

    let fields: Set<String> = ["disposition", "court", "opinionauthor", "decisiondate", "casenumber"]

    @Test("Rules that place a question keep it; no model is asked")
    func rulesFirst() async {
        let device = Scripted("court"), cloud = Scripted("court")
        let q = "Who wrote the majority opinion in Pinching v. Wurdeman?"
        let step = await QuestionUnderstanding.interpret(question: q, fields: fields, onDevice: device, cloud: cloud)
        #expect(step == "rules")
        #expect(device.asked == 0 && cloud.asked == 0)
        #expect(SlotFieldResolver.resolve(in: q, knownFields: fields).first?.fieldID == "opinionauthor")
    }

    @Test("A wording the rules miss goes to the on-device model, and its field is used")
    func onDeviceSecond() async {
        let device = Scripted("disposition"), cloud = Scripted("court")
        let q = "What was the verdict-like conclusion reached in Pinching v. Wurdeman?"
        let step = await QuestionUnderstanding.interpret(question: q, fields: fields, onDevice: device, cloud: cloud)
        #expect(step == "interpreted:disposition")
        #expect(cloud.asked == 0)
        #expect(SlotFieldResolver.resolve(in: q, knownFields: fields).first?.fieldID == "disposition")
    }

    @Test("The cloud is asked only when both earlier steps missed")
    func cloudLast() async {
        let device = Scripted(nil), cloud = Scripted("decisiondate")
        let q = "Tell me the day the judges handed this down for Pinching v. Wurdeman"
        let step = await QuestionUnderstanding.interpret(question: q, fields: fields, onDevice: device, cloud: cloud)
        #expect(step == "interpreted:decisiondate")
        #expect(device.asked == 1 && cloud.asked == 1)
    }

    @Test("A model may only choose a field the facts carry; gated questions never reach a model")
    func boundaries() async {
        let invented = Scripted("prisonname")
        let q = "What was the verdict-like conclusion reached in Pinching v. Wurdeman?"
        _ = await QuestionUnderstanding.interpret(question: q, fields: fields, onDevice: invented, cloud: nil)
        #expect(QuestionUnderstanding.interpretedField(for: q) == nil)
        let device = Scripted("court")
        for gated in ["Who made the announcement in the case \"X\"?", "Give me a summary of the case \"X\".",
                      "How many employees were injured in OSHA investigation 1?"] {
            _ = await QuestionUnderstanding.interpret(question: gated, fields: fields, onDevice: device, cloud: nil)
        }
        #expect(device.asked == 0)
    }

    @Test("When the model says no field holds the answer, a weak rule match is set aside")
    func noneSetsAsideWeakRule() async {
        let device = Scripted("none")
        let q = "What was wrong with the product in FDA recall Z-1?"
        let onlyCourt: Set<String> = ["product", "casenumber"]
        _ = await QuestionUnderstanding.interpret(question: q, fields: onlyCourt, onDevice: device, cloud: nil)
        #expect(SlotFieldResolver.resolve(in: q, knownFields: onlyCourt).isEmpty)
    }

    @Test("The cloud reply is used only when it is exactly one listed field")
    func cloudParse() {
        let f = ["disposition", "court"]
        #expect(CloudQuestionInterpreter.parse(" disposition\n", fields: f) == "disposition")
        #expect(CloudQuestionInterpreter.parse("`court`", fields: f) == "court")
        #expect(CloudQuestionInterpreter.parse("The field is disposition.", fields: f) == nil)
        #expect(CloudQuestionInterpreter.parse("none", fields: f) == "none")
        #expect(!CloudQuestionInterpreter.prompt(question: "Q?", fields: f).contains("documents:"))
    }
}
