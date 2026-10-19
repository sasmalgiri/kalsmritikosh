//
//  NameKindCorrectorTests.swift
//  KalsmritikoshTests
//
//  Case bench 2026-10-18: aircraft makers and airports were tagged as people.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Name kinds — corrected only on strong signals")
struct NameKindCorrectorTests {

    @Test("Makers before a model code, facilities and departments are re-typed",
          arguments: [("Piper", Entity.Kind.person, " PA 28-180 low-wing airplane", Entity.Kind.organization),
                      ("Cessna", .person, " 182B, Canadian registration", .organization),
                      ("Boeing", .person, " 737-300, N648SW", .organization),
                      ("Wiley Post Airport", .person, ", Oklahoma City", .location),
                      ("Oklahoma City Police Department", .location, " responded", .organization),
                      ("Sonoma County", .person, " Airport", .location)])
    func retyped(name: String, tagged: Entity.Kind, following: String, expected: Entity.Kind) {
        #expect(NameKindCorrector.kind(for: name, tagged: tagged, following: Substring(following)) == expected)
    }

    @Test("People stay people", arguments: [("John Smith", " said that"), ("Field", " testified"),
                                             ("Maria", " to share the invoice"), ("Asha Rao", " on 12 March 2024"),
                                             ("John Smith", " 42 years old")])
    func peopleStay(name: String, following: String) {
        #expect(NameKindCorrector.kind(for: name, tagged: .person, following: Substring(following)) == .person)
    }
}
