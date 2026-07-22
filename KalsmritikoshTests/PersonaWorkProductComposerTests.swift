//
//  PersonaWorkProductComposerTests.swift
//  KalsmritikoshTests
//
//  PER-003…007 — one composer builds a validatable work product for every persona from the
//  same evidence; claims carry their sources; the manifest covers every cited source.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PER-003..007 PersonaWorkProductComposer")
struct PersonaWorkProductComposerTests {

    private let composer = PersonaWorkProductComposer()
    private let validator = WorkProductValidator()
    private let b1 = UUID(), b2 = UUID(), ko = UUID()

    private func facts() -> [GenericFact] {
        [GenericFact(subjectLabel: "Sasmal", field: "employer", value: "Orchid Chemicals",
                     status: .sourceAsserted, confidence: 0.8, sourceBlockIDs: [b1, b2]),
         GenericFact(subjectLabel: "Sasmal", field: "role", value: "PPIC Executive",
                     status: .sourceAsserted, confidence: 0.7, sourceBlockIDs: [b1, b2])]
    }
    private func event() -> Event {
        var c = DateComponents(); c.year = 2004; c.month = 12; c.day = 1
        return Event(kind: Event.Kind.allCases.first!, date: Calendar(identifier: .gregorian).date(from: c)!,
                     title: "Joined Orchid", sourceObjectID: ko, dateConfidence: 0.9, datePrecision: .month)
    }

    @Test("Every persona composes a VALID work product from the same evidence")
    func allPersonasValid() {
        for persona in WorkspaceTemplate.allCases {
            let bp = WorkProductBlueprintRegistry.blueprints(for: persona).first!
            let wp = composer.compose(blueprint: bp, facts: facts(), events: [event()])
            #expect(validator.validate(wp).isValid, "\(persona.rawValue) should be valid")
            #expect(wp.sections.count == bp.sections.count)
        }
    }

    @Test("Chronology sections cite the event source")
    func chronologyCited() {
        let bp = WorkProductBlueprintRegistry.blueprints(for: .legalMatter).first!
        let wp = composer.compose(blueprint: bp, facts: facts(), events: [event()])
        let chrono = wp.sections.first { $0.blueprint.kind == .chronology }
        #expect(chrono?.claims.first?.sourceBlockIDs == [ko])
        #expect(chrono?.claims.first?.text.contains("2004") == true)
    }

    @Test("Manifest covers every cited source")
    func manifestComplete() {
        let bp = WorkProductBlueprintRegistry.blueprints(for: .investigation).first!
        let wp = composer.compose(blueprint: bp, facts: facts(), events: [event()])
        let cited = Set(wp.sections.flatMap { $0.claims.flatMap(\.sourceBlockIDs) })
        #expect(cited.isSubset(of: wp.manifestSourceIDs))
    }
}
