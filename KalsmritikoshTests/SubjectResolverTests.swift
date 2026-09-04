//
//  SubjectResolverTests.swift
//  KalsmritikoshTests
//
//  P3-U0 — subject resolution + the surfacing gate, pinned to the owner's
//  witnessed session. THE SIX STRINGS with stated fates:
//    ", Akhilesh Sharma" / "'Arindam Das'"      → cleaned at source (U0-b, done)
//    "Auro Laboratories Ltd - Career"           → title-shaped, REJECTED
//    "Bill Delhi"                               → place-name surname, SUSPECT
//                                                 (demoted, NEVER deleted)
//    "Centralized Claims"                       → never surfaces unasked (the
//                                                 mined footer is dead; only a
//                                                 resolved charter renders)
//    "Guruditsingh Vadhwa"                      → INNOCENCE — kept, passes
//  And the end-to-end target: "is the patent granted?" resolves to
//  "About: Patent No. 555489 (Application 202331019665)" — zero bycatch.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("P3-U0 — subject resolution + surfacing gate (the six strings)")
@MainActor
struct SubjectResolverTests {

    private func anchor(_ field: String, _ canon: String, source: UUID = UUID()) -> Entity {
        Entity(kind: .identifierAnchor, value: "\(field)|\(canon)",
               normalizedValue: "\(field)|\(canon)", sourceObjectID: source, confidence: .high)
    }

    // MARK: - the gate fates

    @Test("Title-shaped fragments are rejected; a person named Career without a separator passes")
    func titleShapedFate() {
        let gate = EntityQualityGate.bundled()
        let portal = Entity(kind: .person, value: "Auro Laboratories Ltd - Career",
                            sourceObjectID: UUID(), confidence: .high)
        #expect(gate.classify(portal) == "title-shaped", "the job-portal page title is not a party")
        for tail in ["Home", "Login", "Jobs", "Profile", "About"] {
            let t = Entity(kind: .person, value: "Acme Corp | \(tail)", sourceObjectID: UUID(), confidence: .high)
            #expect(gate.classify(t) == "title-shaped", "'| \(tail)' marks a page title")
        }
        // Innocence: no separator → a real (odd) name passes.
        let homer = Entity(kind: .person, value: "Homer Career", sourceObjectID: UUID(), confidence: .high)
        #expect(gate.classify(homer) == nil, "no separator — a real name keeps its innocence")
    }

    @Test("Place-name surnames are SUSPECT (demoted), never rejected — Jack London is a person")
    func placeSurnameFate() {
        let gate = EntityQualityGate.bundled()
        let bill = Entity(kind: .person, value: "Bill Delhi", sourceObjectID: UUID(), confidence: .high)
        #expect(gate.isPlaceNameSurnameSuspect(bill), "the parse ghost is flagged")
        #expect(gate.classify(bill) == nil, "SUSPECT is a demotion, never a deletion")
        let jack = Entity(kind: .person, value: "Jack London", sourceObjectID: UUID(), confidence: .high)
        #expect(gate.isPlaceNameSurnameSuspect(jack), "flagged for review — the reviewer restores")
        let vadhwa = Entity(kind: .person, value: "Guruditsingh Vadhwa", sourceObjectID: UUID(), confidence: .high)
        #expect(!gate.isPlaceNameSurnameSuspect(vadhwa) && gate.classify(vadhwa) == nil,
                "the innocence case passes everything")
    }

    // MARK: - the resolver laws

    @Test("An identifier in the question resolves exactly, with same-document siblings")
    func identifierResolves() {
        let doc = UUID()
        let anchors = [anchor("patentnumber", "555489", source: doc),
                       anchor("applicationnumber", "202331019665", source: doc),
                       anchor("invoicenumber", "7741")]
        let charter = SubjectResolver.resolve(question: "when was 555489 granted", anchors: anchors)
        #expect(charter.method == .identifierInQuestion)
        #expect(charter.footerText == "About: Patent No. 555489 (Application 202331019665)")
    }

    @Test("THE OWNER'S QUESTION: 'is the patent granted?' → the exact footer, zero bycatch")
    func definiteReferenceResolves() {
        let doc = UUID()
        let anchors = [anchor("patentnumber", "555489", source: doc),
                       anchor("applicationnumber", "202331019665", source: doc)]
        let charter = SubjectResolver.resolve(question: "is the patent granted?", anchors: anchors)
        #expect(charter.method == .definiteReference)
        #expect(charter.footerText == "About: Patent No. 555489 (Application 202331019665)",
                "got \(charter.footerText ?? "nil")")
    }

    @Test("Several subjects LIST, never guess; none resolves to an omitted footer")
    func ambiguityAndAbsence() {
        let two = [anchor("invoicenumber", "7741"), anchor("invoicenumber", "8802")]
        let ambiguous = SubjectResolver.resolve(question: "is the invoice paid?", anchors: two)
        #expect(ambiguous.method == .ambiguous)
        #expect(ambiguous.footerText?.contains("7741") == true && ambiguous.footerText?.contains("8802") == true,
                "both candidates are LISTED")
        #expect(ambiguous.receiptLine.contains("say which"), "the receipt asks, never guesses")

        let none = SubjectResolver.resolve(question: "who is Dana Whitfield", anchors: two)
        #expect(none.method == .none && none.footerText == nil, "no charter → the footer is omitted")
        let empty = SubjectResolver.resolve(question: "is the patent granted?", anchors: [])
        #expect(empty.method == .none && empty.footerText == nil)
    }

    @Test("Resolution is deterministic — same inputs, same charter, always")
    func deterministic() {
        let doc = UUID()
        let anchors = [anchor("patentnumber", "555489", source: doc),
                       anchor("applicationnumber", "202331019665", source: doc)]
        let a = SubjectResolver.resolve(question: "is the patent granted?", anchors: anchors)
        let b = SubjectResolver.resolve(question: "is the patent granted?", anchors: anchors)
        #expect(a == b)
    }
}
