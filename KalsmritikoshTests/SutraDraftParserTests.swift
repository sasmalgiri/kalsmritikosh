//
//  SutraDraftParserTests.swift
//  KalsmritikoshTests
//
//  The AI SOP→Sūtra draft: the model may only map onto known job-kinds; the
//  ENGINE assigns tooling. These lock that safety boundary.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("SutraDraftParser — a draft can't invent tooling")
struct SutraDraftParserTests {

    @Test("A well-formed draft maps kinds and the engine assigns tier/method/surface")
    func wellFormed() throws {
        let json = """
        {"title":"Field study","phases":[
          {"kind":"caseIntake","title":"Frame","obligations":["Set the question"]},
          {"kind":"analysis","title":"Weigh explanations","obligations":["Rate each"]},
          {"kind":"findings","title":"Write it up","humanDecisions":["Sign off"]}
        ],"reportSections":["Intro","Findings"]}
        """
        let s = try #require(SutraDraftParser.decode(json))
        #expect(s.title == "Field study")
        #expect(s.phases.count == 3)
        // The analysis phase's tooling is engine-assigned, never from the model.
        let analysis = s.phases.first { $0.kind == .analysis }
        #expect(analysis?.method == .ach)
        #expect(analysis?.surface == "hypotheses")
        #expect(analysis?.tier == .analyze)
    }

    @Test("Unknown kinds are dropped; too few valid phases → nil")
    func unknownDropped() {
        // One valid + one bogus kind → only one valid phase → below the minimum.
        let json = #"{"title":"x","phases":[{"kind":"analysis","obligations":["a"]},{"kind":"telepathy","obligations":["b"]}]}"#
        #expect(SutraDraftParser.decode(json) == nil)
        #expect(SutraDraftParser.decode("not json") == nil)
    }

    @Test("A drafted Sūtra survives a JSON round-trip (so it can persist)")
    func codable() throws {
        let json = #"{"title":"Two-step","phases":[{"kind":"caseIntake","obligations":["a"]},{"kind":"findings","obligations":["b"]}]}"#
        let drafted = try #require(SutraDraftParser.decode(json))
        let data = try JSONEncoder().encode([drafted])
        #expect(try JSONDecoder().decode([Sutra].self, from: data) == [drafted])
    }
}
