//
//  WorkProductValidatorTests.swift
//  KalsmritikoshTests
//
//  EXP-002 — a work product is valid only if every claim-bearing section has claims, each
//  material claim meets the blueprint's evidence requirement with an assertable status, and
//  every cited source is in the manifest.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("EXP-002 WorkProductValidator")
struct WorkProductValidatorTests {

    private let validator = WorkProductValidator()
    private let s1 = UUID(), s2 = UUID()

    private func blueprint(min: Int) -> WorkProductBlueprint {
        WorkProductBlueprint(name: "bp", persona: .legalMatter, sections: [
            BlueprintSection(title: "Memo", kind: .narrative, requiresEvidence: true, minEvidencePerClaim: min)
        ])
    }

    @Test("A well-evidenced, manifest-complete product is valid")
    func valid() {
        let wp = ComposedWorkProduct(blueprint: blueprint(min: 2),
            sections: [ComposedSection(blueprint: blueprint(min: 2).sections[0],
                claims: [ComposedClaim(text: "X", sourceBlockIDs: [s1, s2], status: .sourceAsserted)])],
            manifestSourceIDs: [s1, s2])
        #expect(validator.validate(wp).isValid)
    }

    @Test("Under-evidenced claim is flagged")
    func underEvidenced() {
        let wp = ComposedWorkProduct(blueprint: blueprint(min: 2),
            sections: [ComposedSection(blueprint: blueprint(min: 2).sections[0],
                claims: [ComposedClaim(text: "X", sourceBlockIDs: [s1], status: .sourceAsserted)])],
            manifestSourceIDs: [s1])
        #expect(!validator.validate(wp).isValid)
    }

    @Test("Cited source missing from the manifest is flagged")
    func citedNotInManifest() {
        let wp = ComposedWorkProduct(blueprint: blueprint(min: 1),
            sections: [ComposedSection(blueprint: blueprint(min: 1).sections[0],
                claims: [ComposedClaim(text: "X", sourceBlockIDs: [s1], status: .sourceAsserted)])],
            manifestSourceIDs: [])   // s1 not listed
        let r = validator.validate(wp)
        #expect(!r.isValid)
    }

    @Test("Unsupported-status claim in a material section is flagged")
    func unsupportedStatus() {
        let wp = ComposedWorkProduct(blueprint: blueprint(min: 1),
            sections: [ComposedSection(blueprint: blueprint(min: 1).sections[0],
                claims: [ComposedClaim(text: "X", sourceBlockIDs: [s1], status: .inferred)])],
            manifestSourceIDs: [s1])
        #expect(!validator.validate(wp).isValid)
    }

    @Test("Empty material section is flagged")
    func emptySection() {
        let wp = ComposedWorkProduct(blueprint: blueprint(min: 1),
            sections: [ComposedSection(blueprint: blueprint(min: 1).sections[0], claims: [])],
            manifestSourceIDs: [])
        #expect(!validator.validate(wp).isValid)
    }
}
