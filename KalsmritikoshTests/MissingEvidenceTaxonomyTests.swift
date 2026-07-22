//
//  MissingEvidenceTaxonomyTests.swift
//  KalsmritikoshTests
//
//  CLM-004 — neutral, scoped missing-evidence classification. A gap is never phrased as
//  proof of wrongdoing.
//

import Testing
@testable import Kalsmritikosh

@Suite("CLM-004 MissingEvidenceTaxonomy")
struct MissingEvidenceTaxonomyTests {

    private let classifier = MissingEvidenceClassifier()

    @Test("Empty corpus → notInCorpus")
    func emptyCorpus() {
        let g = classifier.classify(missingFields: ["amount"], documentsSearched: 0)
        #expect(g.first?.kind == .notInCorpus)
    }

    @Test("Searched but not found is the default benign reason")
    func searchedNotFound() {
        let g = classifier.classify(missingFields: ["amount"], documentsSearched: 12)
        #expect(g.first?.kind == .searchedNotFound)
    }

    @Test("Deferred / encrypted / preserved-only contexts escalate to their benign reason")
    func contextualReasons() {
        #expect(classifier.classify(missingFields: ["x"], documentsSearched: 5, hasEncryptedSources: true).first?.kind == .encrypted)
        #expect(classifier.classify(missingFields: ["x"], documentsSearched: 5, hasDeferredSources: true).first?.kind == .deferredProcessing)
        #expect(classifier.classify(missingFields: ["x"], documentsSearched: 5, hasPreservedOnlySources: true).first?.kind == .preservedOnly)
    }

    @Test("Out-of-time-scope wins and carries the scope note")
    func timeScope() {
        let g = classifier.classify(missingFields: ["payment"], documentsSearched: 5,
                                    outOfTimeScope: true, timeScopeNote: "searched 2020–2021 only")
        #expect(g.first?.kind == .outOfTimeScope)
        #expect(g.first?.disclosure().contains("2020–2021") == true)
    }

    @Test("No phrase implies wrongdoing or concealment")
    func neverAccusatory() {
        for kind in MissingEvidenceKind.allCases {
            let p = kind.neutralPhrase.lowercased()
            for bad in ["hid", "conceal", "withheld evidence", "guilty", "suspicious", "deliberate"] {
                #expect(!p.contains(bad), "\(kind) phrase must not imply wrongdoing")
            }
        }
    }
}
