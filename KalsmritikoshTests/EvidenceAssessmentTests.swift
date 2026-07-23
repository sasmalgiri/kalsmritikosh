//
//  EvidenceAssessmentTests.swift
//  Kalsmritikosh Tests
//
//  S0.5 item 2 (Commit A). The five-dimension split + compatibility adapter. Proves:
//  every one of the ten legacy EvidenceStatus values decodes to the correct dimensions;
//  human review never sets the evidence basis (humanConfirmed → basis unknownLegacy, NOT
//  sourceAsserted); the reverse encode is deterministic and preserves assertability
//  intent; unknown/future raw values fail safely rather than crashing. No schema or
//  call-site changes are exercised here — vocabulary only.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("S0.5 item 2 — EvidenceAssessment vocabulary + legacy adapter")
struct EvidenceAssessmentTests {

    @Test("All ten legacy statuses decode to the specified dimensions")
    func decodeAllLegacyStatuses() {
        func a(_ s: EvidenceStatus) -> EvidenceAssessment { LegacyEvidenceStatusAdapter.decode(s) }

        // Legacy value cannot establish origin → importedLegacy, EXCEPT the rule basis.
        #expect(a(.directlyObserved) == EvidenceAssessment(basis: .directlyObserved, origin: .importedLegacy, legacyStatus: .directlyObserved))
        #expect(a(.sourceAsserted) == EvidenceAssessment(basis: .sourceAsserted, origin: .importedLegacy, legacyStatus: .sourceAsserted))
        #expect(a(.deterministicallyDerived) == EvidenceAssessment(basis: .deterministicallyDerived, origin: .deterministicRule, legacyStatus: .deterministicallyDerived))
        #expect(a(.inferred) == EvidenceAssessment(basis: .inferred, origin: .importedLegacy, legacyStatus: .inferred))   // NOT modelProposed
        #expect(a(.humanCorrected).origin == .importedLegacy)   // NOT userCreated
        // Every non-rule legacy status decodes with importedLegacy origin.
        for s in EvidenceStatus.allCases where s != .deterministicallyDerived {
            #expect(a(s).origin == .importedLegacy)
        }

        // Relational + availability legacy statuses → their own dimensions, basis unknown.
        #expect(a(.contradicted).conflict == .contradicted)
        #expect(a(.contradicted).basis == .unknownLegacy)
        #expect(a(.unsupported).availability == .unsupported)
        #expect(a(.missingEvidence).availability == .missingEvidence)

        // Human review statuses: review dimension set, basis NOT recovered.
        #expect(a(.humanConfirmed).review == .confirmed)
        #expect(a(.humanConfirmed).basis == .unknownLegacy)     // NOT sourceAsserted
        #expect(a(.humanCorrected).review == .corrected)
        #expect(a(.humanCorrected).basis == .unknownLegacy)
        #expect(a(.humanRejected).review == .rejected)
        #expect(a(.humanRejected).basis == .unknownLegacy)

        // Every decode preserves the exact original raw value.
        for s in EvidenceStatus.allCases {
            #expect(LegacyEvidenceStatusAdapter.decode(s).legacyStatus == s)
        }
    }

    @Test("Human review never sets the evidence basis for any legacy status")
    func reviewNeverSetsBasis() {
        for s in [EvidenceStatus.humanConfirmed, .humanCorrected, .humanRejected] {
            #expect(LegacyEvidenceStatusAdapter.decode(s).basis == .unknownLegacy)
        }
    }

    @Test("Reverse encode prioritises conflict → availability → basis; review never overrides basis")
    func encodePriority() {
        // Conflict wins.
        #expect(LegacyEvidenceStatusAdapter.encode(.init(basis: .directlyObserved, origin: .importedLegacy, conflict: .contradicted)) == .contradicted)
        // Availability before basis.
        #expect(LegacyEvidenceStatusAdapter.encode(.init(basis: .unknownLegacy, origin: .importedLegacy, availability: .missingEvidence)) == .missingEvidence)
        // Basis.
        #expect(LegacyEvidenceStatusAdapter.encode(.init(basis: .inferred, origin: .importedLegacy)) == .inferred)
        // unknownLegacy with no other signal falls back to its preserved raw value.
        #expect(LegacyEvidenceStatusAdapter.encode(.init(basis: .unknownLegacy, origin: .importedLegacy, legacyStatus: .humanConfirmed)) == .humanConfirmed)
        // Determinism: same input, same output.
        let x = EvidenceAssessment(basis: .sourceAsserted, review: .disputed, origin: .importedLegacy)
        #expect(LegacyEvidenceStatusAdapter.encode(x) == LegacyEvidenceStatusAdapter.encode(x))
    }

    @Test("New compatibility writes never synthesise human statuses, and disputed invents no conflict")
    func encodeNeverSynthesisesHumanOrConflict() {
        // Review disposition must NOT override a known basis or create a human legacy value.
        #expect(LegacyEvidenceStatusAdapter.encode(.init(basis: .sourceAsserted, review: .confirmed, origin: .sourceExtraction)) == .sourceAsserted)
        #expect(LegacyEvidenceStatusAdapter.encode(.init(basis: .directlyObserved, review: .corrected, origin: .userCreated)) == .directlyObserved)
        #expect(LegacyEvidenceStatusAdapter.encode(.init(basis: .sourceAsserted, review: .rejected, origin: .sourceExtraction)) == .sourceAsserted)
        // disputed WITHOUT an actual conflict must not become contradicted.
        #expect(LegacyEvidenceStatusAdapter.encode(.init(basis: .sourceAsserted, review: .disputed, origin: .sourceExtraction)) == .sourceAsserted)
        // No assessment lacking a legacy human value ever encodes to a human status.
        let humans: Set<EvidenceStatus> = [.humanConfirmed, .humanCorrected, .humanRejected]
        for review in ReviewDisposition.allCases {
            let s = LegacyEvidenceStatusAdapter.encode(.init(basis: .sourceAsserted, review: review, origin: .sourceExtraction))
            #expect(!humans.contains(s))
        }
    }

    @Test("Forward decode carries assertability intent through the reverse encode")
    func roundTripPreservesAssertabilityIntent() {
        // The dimension→legacy round trip is lossy, but assertable-vs-not must survive
        // for the cases where a single legacy value fully determines it.
        for s in [EvidenceStatus.directlyObserved, .sourceAsserted, .deterministicallyDerived, .inferred] {
            let back = LegacyEvidenceStatusAdapter.encode(LegacyEvidenceStatusAdapter.decode(s))
            #expect(back == s)
            #expect(back.isAssertable == s.isAssertable)
        }
    }

    @Test("Unknown / future raw values fail safely (decode to nil, no crash)")
    func unknownRawValueFailsSafely() {
        #expect(EvidenceStatus(rawValue: "SOME_FUTURE_STATUS") == nil)
        #expect(EvidenceBasis(rawValue: "nope") == nil)
        #expect(ConflictStatus(rawValue: "nope") == nil)
        // A malformed JSON status field decodes to nil rather than throwing to the caller.
        let bad = "\"NOT_A_STATUS\"".data(using: .utf8)!
        #expect((try? JSONDecoder().decode(EvidenceStatus.self, from: bad)) == nil)
    }
}
