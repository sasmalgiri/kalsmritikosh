//
//  ProfessionalMethodRegistryTests.swift
//  KalsmritikoshTests
//
//  PM-003 — the immutable, code-backed professional-method registry: exact/latest/
//  versions lookup, deterministic ordering, frozen-snapshot independence, and the
//  full registration-validation vocabulary (mapped from the generic backbone).
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PM-003 — ProfessionalMethodRegistry")
struct ProfessionalMethodRegistryTests {

    private func def(
        id: String = "com.k.method.test", version: Int = 1, label: String = "Test",
        inputRoles: [String] = ["role.a"], nodeKinds: [String] = ["cause"],
        edgeKinds: [String] = ["leadsTo"],
        reviews: [MethodRequiredReview] = [MethodRequiredReview(reviewKey: "final", label: "Final")],
        validators: [String] = ["v.structure"], findingKinds: [String] = ["candidateCause"]
    ) -> ProfessionalMethodDefinition {
        ProfessionalMethodDefinition(
            id: ProfessionalMethodDefinitionID(rawValue: id), version: version, label: label,
            category: .analysis,
            requiredInputRoles: inputRoles.map(MethodInputRole.init(rawValue:)),
            allowedNodeKinds: nodeKinds.map(MethodNodeKind.init(rawValue:)),
            allowedEdgeKinds: edgeKinds.map(MethodEdgeKind.init(rawValue:)),
            requiredReviews: reviews, validationIdentifiers: validators,
            outputContract: MethodOutputContract(
                allowedFindingKinds: findingKinds.map(MethodFindingKind.init(rawValue:))))
    }

    private func registry(_ definitions: [ProfessionalMethodDefinition]) throws -> ProfessionalMethodRegistry {
        var builder = ProfessionalMethodRegistryBuilder()
        for definition in definitions { try builder.register(definition) }
        return builder.freeze()
    }

    // MARK: - Lookups

    @Test("Exact (id, version) lookup returns the registered definition")
    func exactLookup() throws {
        let r = try registry([def(id: "com.k.m.a", version: 1, label: "A1"),
                              def(id: "com.k.m.a", version: 2, label: "A2")])
        #expect(r.definition(id: ProfessionalMethodDefinitionID(rawValue: "com.k.m.a"), version: 2)?.label == "A2")
        #expect(r.definition(id: ProfessionalMethodDefinitionID(rawValue: "com.k.m.a"), version: 3) == nil)
        #expect(r.definition(id: ProfessionalMethodDefinitionID(rawValue: "com.k.m.z"), version: 1) == nil)
    }

    @Test("Latest lookup returns the highest registered version")
    func latestLookup() throws {
        let r = try registry([def(id: "com.k.m.a", version: 1), def(id: "com.k.m.a", version: 3),
                              def(id: "com.k.m.a", version: 2)])
        #expect(r.latest(id: ProfessionalMethodDefinitionID(rawValue: "com.k.m.a"))?.version == 3)
        #expect(r.latest(id: ProfessionalMethodDefinitionID(rawValue: "com.k.m.z")) == nil)
    }

    @Test("Versions lookup returns all versions for an id")
    func versionsLookup() throws {
        let r = try registry([def(id: "com.k.m.a", version: 2), def(id: "com.k.m.a", version: 1)])
        #expect(Set(r.versions(for: ProfessionalMethodDefinitionID(rawValue: "com.k.m.a"))) == [1, 2])
        #expect(r.versions(for: ProfessionalMethodDefinitionID(rawValue: "com.k.m.z")).isEmpty)
    }

    @Test("all and allKeys are deterministically ordered by (id, version)")
    func deterministicOrdering() throws {
        let r = try registry([def(id: "com.k.m.b", version: 1), def(id: "com.k.m.a", version: 2),
                              def(id: "com.k.m.a", version: 1)])
        #expect(r.all.map { "\($0.id.rawValue)@\($0.version)" } == ["com.k.m.a@1", "com.k.m.a@2", "com.k.m.b@1"])
        #expect(r.allKeys.map { "\($0.id.rawValue)@\($0.version)" } == ["com.k.m.a@1", "com.k.m.a@2", "com.k.m.b@1"])
    }

    // MARK: - Registration validation

    @Test("A duplicate (id, version) is rejected")
    func duplicateRegistrationRejected() throws {
        var builder = ProfessionalMethodRegistryBuilder()
        try builder.register(def(id: "com.k.m.a", version: 1))
        #expect(throws: ProfessionalMethodRegistryError.duplicateRegistration(id: "com.k.m.a", version: 1)) {
            try builder.register(self.def(id: "com.k.m.a", version: 1, label: "again"))
        }
    }

    @Test("A non-trim-stable id is rejected")
    func invalidID() throws {
        var builder = ProfessionalMethodRegistryBuilder()
        #expect(throws: ProfessionalMethodRegistryError.invalidID("  spaced  ")) {
            try builder.register(self.def(id: "  spaced  "))
        }
    }

    @Test("A version below 1 is rejected")
    func invalidVersion() throws {
        var builder = ProfessionalMethodRegistryBuilder()
        #expect(throws: ProfessionalMethodRegistryError.invalidVersion(id: "com.k.m.a", version: 0)) {
            try builder.register(self.def(id: "com.k.m.a", version: 0))
        }
    }

    @Test("A blank definition label is rejected via the method contract")
    func blankLabel() throws {
        var builder = ProfessionalMethodRegistryBuilder()
        #expect(throws: ProfessionalMethodRegistryError.invalidMethodContract(.blankDefinitionLabel)) {
            try builder.register(self.def(label: " "))
        }
    }

    @Test("Duplicate input roles, node kinds and edge kinds are rejected")
    func duplicateListEntries() throws {
        var b1 = ProfessionalMethodRegistryBuilder()
        #expect(throws: ProfessionalMethodRegistryError.duplicateInputRole("role.a")) {
            try b1.register(self.def(inputRoles: ["role.a", "role.a"]))
        }
        var b2 = ProfessionalMethodRegistryBuilder()
        #expect(throws: ProfessionalMethodRegistryError.duplicateNodeKind("cause")) {
            try b2.register(self.def(nodeKinds: ["cause", "cause"]))
        }
        var b3 = ProfessionalMethodRegistryBuilder()
        #expect(throws: ProfessionalMethodRegistryError.duplicateEdgeKind("leadsTo")) {
            try b3.register(self.def(edgeKinds: ["leadsTo", "leadsTo"]))
        }
    }

    @Test("Blank and duplicate required-review keys are rejected")
    func reviewKeyValidation() throws {
        var b1 = ProfessionalMethodRegistryBuilder()
        #expect(throws: ProfessionalMethodRegistryError.blankReviewKey) {
            try b1.register(self.def(reviews: [MethodRequiredReview(reviewKey: " ", label: "L")]))
        }
        var b2 = ProfessionalMethodRegistryBuilder()
        #expect(throws: ProfessionalMethodRegistryError.duplicateReviewKey("final")) {
            try b2.register(self.def(reviews: [
                MethodRequiredReview(reviewKey: "final", label: "A"),
                MethodRequiredReview(reviewKey: "final", label: "B")]))
        }
    }

    @Test("A blank required-review label is rejected")
    func blankReviewLabel() throws {
        var builder = ProfessionalMethodRegistryBuilder()
        #expect(throws: ProfessionalMethodRegistryError.blankReviewLabel) {
            try builder.register(self.def(reviews: [MethodRequiredReview(reviewKey: "k", label: " ")]))
        }
    }

    @Test("A non-human required review is rejected (the review ledger is human-only)")
    func nonHumanRequiredReviewRejected() throws {
        var builder = ProfessionalMethodRegistryBuilder()
        #expect(throws: ProfessionalMethodRegistryError.nonHumanRequiredReview("auto")) {
            try builder.register(self.def(reviews: [
                MethodRequiredReview(reviewKey: "auto", label: "Machine", mustBeHuman: false)]))
        }
    }

    @Test("Blank and duplicate validation identifiers are rejected")
    func validationIdentifierValidation() throws {
        var b1 = ProfessionalMethodRegistryBuilder()
        #expect(throws: ProfessionalMethodRegistryError.blankValidationIdentifier) {
            try b1.register(self.def(validators: [" "]))
        }
        var b2 = ProfessionalMethodRegistryBuilder()
        #expect(throws: ProfessionalMethodRegistryError.duplicateValidationIdentifier("v.structure")) {
            try b2.register(self.def(validators: ["v.structure", "v.structure"]))
        }
    }

    @Test("Blank and duplicate finding kinds are rejected")
    func findingKindValidation() throws {
        var b1 = ProfessionalMethodRegistryBuilder()
        #expect(throws: ProfessionalMethodRegistryError.blankFindingKind) {
            try b1.register(self.def(findingKinds: [" "]))
        }
        var b2 = ProfessionalMethodRegistryBuilder()
        #expect(throws: ProfessionalMethodRegistryError.duplicateFindingKind("candidateCause")) {
            try b2.register(self.def(findingKinds: ["candidateCause", "candidateCause"]))
        }
    }

    // MARK: - Immutability + order independence

    @Test("A frozen snapshot is independent of later builder mutations")
    func frozenSnapshotIndependence() throws {
        var builder = ProfessionalMethodRegistryBuilder()
        try builder.register(def(id: "com.k.m.a", version: 1))
        let first = builder.freeze()
        try builder.register(def(id: "com.k.m.b", version: 1))
        let second = builder.freeze()
        #expect(first.all.count == 1)
        #expect(second.all.count == 2)
    }

    @Test("Registration order does not affect lookup, all, or allKeys")
    func registrationOrderIndependence() throws {
        let a = def(id: "com.k.m.a", version: 1)
        let b = def(id: "com.k.m.b", version: 1)
        let r1 = try registry([a, b])
        let r2 = try registry([b, a])
        #expect(r1.all.map { $0.id.rawValue } == r2.all.map { $0.id.rawValue })
        #expect(r1.allKeys == r2.allKeys)
    }
}
