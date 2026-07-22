//
//  GenericFactTests.swift
//  KalsmritikoshTests
//
//  SEM-003 — domain-neutral fact layer + field schema.
//

import Testing
@testable import Kalsmritikosh

@Suite("SEM-003 GenericFact")
struct GenericFactTests {

    @Test("Field aliases normalize to a canonical field")
    func fieldNormalization() {
        #expect(FactSchemaRegistry.normalizeField("Company") == "employer")
        #expect(FactSchemaRegistry.normalizeField("paid to") == "counterparty")
        #expect(FactSchemaRegistry.normalizeField("Designation") == "role")
        // Unknown fields are preserved lowercased, never dropped (any-subject contract).
        #expect(FactSchemaRegistry.normalizeField("Molecular Weight") == "molecular weight")
    }

    @Test("Expected value shape resolves for known fields, text otherwise")
    func valueShapes() {
        #expect(FactSchemaRegistry.expectedShape(of: "amount") == .money)
        #expect(FactSchemaRegistry.expectedShape(of: "date") == .date)
        #expect(FactSchemaRegistry.expectedShape(of: "unknown domain field") == .text)
    }

    @Test("Assertable statuses gate material claims; unsupported does not")
    func assertableGating() {
        #expect(EvidenceStatus.directlyObserved.isAssertable)
        #expect(EvidenceStatus.sourceAsserted.isAssertable)
        #expect(!EvidenceStatus.unsupported.isAssertable)
        #expect(!EvidenceStatus.inferred.isAssertable)
        #expect(!EvidenceStatus.missingEvidence.isAssertable)
    }

    @Test("A material fact needs an assertable status AND a supporting block")
    func materialAndSupported() {
        let blk = UUID()
        let good = GenericFact(subjectLabel: "Sasmal", field: "employer", value: "Orchid Chemicals",
                               status: .sourceAsserted, confidence: 0.9, sourceBlockIDs: [blk])
        let noEvidence = GenericFact(subjectLabel: "Sasmal", field: "employer", value: "X",
                                     status: .sourceAsserted, confidence: 0.9, sourceBlockIDs: [])
        let unsupportedStatus = GenericFact(subjectLabel: "Sasmal", field: "employer", value: "Y",
                                            status: .inferred, confidence: 0.5, sourceBlockIDs: [blk])
        #expect(good.isMaterialAndSupported)
        #expect(!noEvidence.isMaterialAndSupported)
        #expect(!unsupportedStatus.isMaterialAndSupported)
    }
}
