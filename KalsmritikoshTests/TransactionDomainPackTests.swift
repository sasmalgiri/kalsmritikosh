//
//  TransactionDomainPackTests.swift
//  KalsmritikoshTests
//
//  SEM-005 — the transaction/payment domain pack extracts amount + counterparty + date as
//  evidence-linked SOURCE_ASSERTED facts, and stays quiet on non-transactional text.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("SEM-005 TransactionDomainPack")
struct TransactionDomainPackTests {

    private let block = UUID()

    @Test("Receipt text yields amount + counterparty + date, all evidence-linked")
    func extractsReceipt() {
        let receipt = "PhonePe Transaction Successful\nPaid to Rajesh Kumar\nAmount ₹3,800\nDate 12/01/2024"
        let facts = TransactionDomainPack.extractFacts(fromText: receipt, subjectLabel: "payment", blockID: block)
        let byField = Dictionary(uniqueKeysWithValues: facts.map { ($0.field, $0) })
        #expect(byField["amount"]?.value == "₹3,800")     // existing amount normalizer (A3 pattern), unchanged
        #expect(byField["amount"]?.unit == "INR")
        #expect(byField["counterparty"]?.value == "Rajesh Kumar")
        // V2 storage-gold (enumerated): date is the ISO atom (inherited C-7);
        // surface canon unchanged via the shared inverse.
        #expect(byField["date"]?.value == "2024-01-12")
        #expect(byField["date"].map { SlotAnswerComposer.renderValue($0) } == "12/01/2024")
        for f in facts {
            #expect(f.status == .sourceAsserted)
            #expect(f.sourceBlockIDs == [block])
            #expect(f.isMaterialAndSupported)
            #expect(f.producerVersion == DerivedProducerVersions.facts, "\(f.field) stamped v1")
        }
    }

    @Test("Org normalizer: legal-suffix variance trims (dedup) WITHOUT collapsing distinct stems")
    func orgNormalizerTrimsVarianceNotEntities() {
        let cmp = CanonicalFactComparator()
        func party(_ v: String) -> GenericFact {
            GenericFact(subjectLabel: "p", field: "counterparty", value: v,
                        status: .sourceAsserted, confidence: 0.7, sourceBlockIDs: [block])
        }
        // Same entity, suffix variance → equivalent (collapses at dedup/comparison).
        #expect(cmp.compare(party("Orchid Chemicals Ltd"), party("Orchid Chemicals Pvt Ltd")) == .equivalent)
        // Two real companies sharing a stem → stay TWO (distinctive tokens differ).
        #expect(cmp.compare(party("Orchid Chemicals"), party("Orchid Pharma")) == .contradictory)
    }

    @Test("Non-transactional text extracts nothing (no false facts)")
    func quietOnNonTransactional() {
        #expect(TransactionDomainPack.extractFacts(fromText: "Hope the project goes well.",
                                                   subjectLabel: "x", blockID: block).isEmpty)
    }

    @Test("Pack registers its recognizers additively onto the semantics registry")
    func registersRecognizers() {
        let reg = TransactionDomainPack.registry()
        #expect(reg.tags(forText: "Paid to Rajesh Kumar").contains { $0.role == "payeeLine" })
        #expect(reg.tags(forText: "UPI Ref: 40233112").contains { $0.role == "transactionReference" })
    }

    @Test("USD amounts carry a USD unit")
    func usdUnit() {
        let facts = TransactionDomainPack.extractFacts(fromText: "Paid to Acme. Amount $120.50",
                                                       subjectLabel: "p", blockID: block)
        #expect(facts.first { $0.field == "amount" }?.unit == "USD")
    }
}
