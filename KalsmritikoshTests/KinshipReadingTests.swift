//
//  KinshipReadingTests.swift
//  KalsmritikoshTests
//
//  Practitioner review 2026-11-02, Genealogist blocker: a relationship is drawn as sourced only when the
//  sentence binds it to the person — never another person's relationship in the same sentence.
//

import Testing
@testable import Kalsmritikosh

@Suite("Family lines: kinship is read only where the sentence states it of that person")
struct KinshipReadingTests {
    typealias E = LineageExecutor

    @Test("Appositive and copula forms are read")
    func stated() {
        #expect(E.relation(in: "Meera Rao, daughter of Asha Rao, was born in 1901.", from: "Meera Rao", to: "Asha Rao") == "daughter of")
        #expect(E.relation(in: "Dev Sharma was the eldest son of the late Ram Sharma.", from: "Dev Sharma", to: "Ram Sharma") == "son of")
        #expect(E.relation(in: "Asha Rao married Dev Sharma in 1920.", from: "Asha Rao", to: "Dev Sharma") == "married")
        #expect(E.relation(in: "Asha Rao was married to Dev Sharma.", from: "Asha Rao", to: "Dev Sharma") == "married")
    }

    @Test("Another person's relationship in the same sentence is never moved onto the first person")
    func notMoved() {
        let s = "Ravi Rao, son of Asha Rao and husband of Meera Rao, signed the deed."
        #expect(E.relation(in: s, from: "Ravi Rao", to: "Asha Rao") == "son of")
        #expect(E.relation(in: s, from: "Asha Rao", to: "Meera Rao") == nil, "Asha is not Meera's husband")
        #expect(E.relation(in: s, from: "Ravi Rao", to: "Meera Rao") == nil, "conservative: a second appositive after \"and\" is not read (it would need a reviewer); nothing is invented")
        #expect(E.relation(in: "Asha Rao was present when Meera Rao married Dev Sharma.", from: "Asha Rao", to: "Dev Sharma") == nil)
        #expect(E.relation(in: "Asha Rao was present when Meera Rao married Dev Sharma.", from: "Meera Rao", to: "Dev Sharma") == "married")
    }

    @Test("Re-review 2026-11-02: a possessive names someone else — 'married Dev Sharma's sister' is not 'married Dev Sharma'")
    func possessive() {
        #expect(E.relation(in: "Asha Rao married Dev Sharma's sister in 1920.", from: "Asha Rao", to: "Dev Sharma") == nil)
        #expect(E.relation(in: "Meera Rao, daughter of Asha Rao's brother, was born in 1901.", from: "Meera Rao", to: "Asha Rao") == nil)
    }
}

