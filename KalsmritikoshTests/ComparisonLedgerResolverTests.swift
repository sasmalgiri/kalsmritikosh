//
//  ComparisonLedgerResolverTests.swift
//  KalsmritikoshTests
//
//  G3/Workflow C (T-G3.3b) — the ledger resolver turns real facts into honest
//  per-source presence: stated (unit folded in), explicit-none, or silent; an
//  unknown field is silent, never fabricated. End-to-end it drives the
//  ComparisonService so "same magnitude, different currency" reads as a
//  different-unit note, not a disagreement.
//

import Testing
import Foundation
@testable import Kalsmritikosh

@Suite("G3 comparison ledger resolver")
struct ComparisonLedgerResolverTests {

    private let docA = UUID()
    private let docB = UUID()

    /// blockID → owning document, and the facts keyed by canonical field.
    private func rig() -> (ComparisonLedgerResolver, sources: [(id: String, label: String)]) {
        let blkA_amount = UUID(), blkB_amount = UUID()
        let blkA_role = UUID()
        let blkA_employer = UUID()
        let blockToDoc: [UUID: UUID] = [
            blkA_amount: docA, blkB_amount: docB,
            blkA_role: docA, blkA_employer: docA,
        ]
        func fact(_ field: String, _ value: String, unit: String?, block: UUID, conf: Double = 0.9) -> GenericFact {
            GenericFact(subjectLabel: "subject", field: field, value: value, unit: unit,
                        assessment: EvidenceAssessment(basis: .sourceAsserted, origin: .sourceExtraction),
                        confidence: conf, sourceBlockIDs: [block])
        }
        let byField: [String: [GenericFact]] = [
            "amount": [fact("amount", "500000", unit: "INR", block: blkA_amount),
                       fact("amount", "500000", unit: "USD", block: blkB_amount)],
            "role":   [fact("role", "PPIC Executive", unit: nil, block: blkA_role)],
            "employer": [fact("employer", "none", unit: nil, block: blkA_employer)],
        ]
        let resolver = ComparisonLedgerResolver(
            factsForField: { field in byField[FactSchemaRegistry.normalizeField(field)] ?? [] },
            documentOfBlock: { blk in blockToDoc[blk] })
        return (resolver, [(docA.uuidString, "Doc A"), (docB.uuidString, "Doc B")])
    }

    @Test func presenceIsStatedNoneOrSilentHonestly() async {
        let (resolver, _) = rig()
        // Stated, with the unit folded into the value.
        #expect(await resolver.presence(field: "amount", sourceID: docA.uuidString) == .stated("500000 INR"))
        #expect(await resolver.presence(field: "amount", sourceID: docB.uuidString) == .stated("500000 USD"))
        // One source states role; the other never mentions it → silent, not none.
        #expect(await resolver.presence(field: "role", sourceID: docA.uuidString) == .stated("PPIC Executive"))
        #expect(await resolver.presence(field: "role", sourceID: docB.uuidString) == .silent)
        // A recorded "none" is evidence of absence, distinct from silence.
        #expect(await resolver.presence(field: "employer", sourceID: docA.uuidString) == .explicitlyNone)
        #expect(await resolver.presence(field: "employer", sourceID: docB.uuidString) == .silent)
        // Unknown field is never fabricated.
        #expect(await resolver.presence(field: "florble", sourceID: docA.uuidString) == .silent)
    }

    @Test func serviceReadsLiveResolverAndSeparatesUnitFromConflict() async {
        let (resolver, sources) = rig()
        let service = ComparisonService(resolver: resolver)
        let (cells, brief) = await service.compare(fields: ["amount", "role"], sources: sources)

        let amount = cells.first { $0.field == "amount" }
        #expect(amount?.verdict == .differentUnit, "same magnitude, different currency is not a disagreement")

        let role = cells.first { $0.field == "role" }
        #expect(role?.verdict == .singleSource)

        #expect(brief.disagreements.isEmpty, "no genuine disagreement here")
        #expect(brief.differentUnits.count == 1)
        #expect(brief.sourceRegister == ["Doc A", "Doc B"])
    }
}
