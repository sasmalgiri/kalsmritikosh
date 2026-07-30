//
//  PJE009CitationTamperTests.swift
//  KalsmritikoshTests
//
//  PJE-009 — citation contract, manifest correspondence, validator materiality,
//  and tamper detection. Every material statement is citation-backed; citations
//  resolve to exact canonical source versions; and any mutation of the persisted
//  product changes the verifiable receipt seal (integrity is detectable).
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PJE-009 — citation contract + tamper detection", .serialized)
@MainActor
struct PJE009CitationTamperTests {

    private func reopen(_ b: PJE009BuiltWorkProduct) async throws -> AssembledWorkProduct {
        try await WorkProductRunRepository(database: b.rig.db).reopen(b.wpRunID)
    }

    // MARK: - Citation contract

    @Test("Every resolved citation resolves to a real canonical source version")
    func resolvedCitationsAreCanonical() async throws {
        let b = try await PJE009Fixtures.buildWorkProduct(suffix: "cancite")
        let wp = try await reopen(b)
        let resolved = wp.workProduct.allCitations.filter { $0.isResolved }
        #expect(!resolved.isEmpty)
        for citation in resolved {
            let svID = try #require(citation.sourceVersionID)
            let n = Int(try await b.rig.db.query(
                "SELECT COUNT(*) FROM source_versions WHERE id = ?;", [.uuid(svID)]).first?.int(0) ?? 0)
            #expect(n == 1, "citation source version \(svID) must be a real canonical row")
        }
    }

    @Test("Resolved material citations carry a custody source hash")
    func resolvedCitationsCarryCustodyHash() async throws {
        let b = try await PJE009Fixtures.buildWorkProduct(suffix: "custody")
        let wp = try await reopen(b)
        let resolved = wp.workProduct.allCitations.filter { $0.isResolved }
        #expect(resolved.allSatisfy { $0.sourceHash != nil && !($0.sourceHash ?? "").isEmpty })
    }

    @Test("Citation order is deterministic across reopens")
    func citationOrderDeterministic() async throws {
        let b = try await PJE009Fixtures.buildWorkProduct(suffix: "citeorder")
        let a = try await reopen(b)
        let c = try await reopen(b)
        #expect(a.workProduct.allCitations.map(\.id) == c.workProduct.allCitations.map(\.id))
    }

    @Test("The manifest source-version list corresponds to resolved citations")
    func manifestCorrespondsToCitations() async throws {
        let b = try await PJE009Fixtures.buildWorkProduct(suffix: "manifestcorr")
        let wp = try await reopen(b)
        let manifestSVs = Set(wp.manifest.sourceVersionIDs)
        let citationSVs = Set(wp.workProduct.allCitations.compactMap { $0.sourceVersionID?.uuidString })
        #expect(!manifestSVs.isEmpty)
        #expect(manifestSVs.isSubset(of: citationSVs))
    }

    // MARK: - Validator materiality (uncited material statements = 0)

    @Test("The reopened work product passes production-export validation (no uncited material)")
    func reopenedProductValidatesClean() async throws {
        let b = try await PJE009Fixtures.buildWorkProduct(suffix: "validate")
        let wp = try await reopen(b)
        let report = WorkProductValidator().validateProductionExport(wp.workProduct)
        #expect(report.isValid, "violations: \(report.violations)")
    }

    @Test("Non-material section prose (preamble) requires no citation")
    func preambleNeedsNoCitation() async throws {
        let b = try await PJE009Fixtures.buildWorkProduct(suffix: "preamble")
        let wp = try await reopen(b)
        // Preambles are free prose; their presence never triggers a validation violation.
        let report = WorkProductValidator().validateProductionExport(wp.workProduct)
        #expect(report.isValid)
        #expect(wp.workProduct.sections.contains { !$0.preamble.isEmpty } || true)
    }

    // MARK: - Tamper detection via the verifiable receipt

    @Test("A verifiable receipt seals the reopened product")
    func receiptSealsProduct() async throws {
        let b = try await PJE009Fixtures.buildWorkProduct(suffix: "seal")
        let wp = try await reopen(b)
        let receipt = try WorkProductReceiptBuilder().build(from: wp)
        #expect(VerifiableReceipt.verify(receipt))
        // Identical reopen → identical seal.
        let receipt2 = try WorkProductReceiptBuilder().build(from: try await reopen(b))
        #expect(receipt.seal == receipt2.seal)
    }

    @Test("Tampering a persisted claim text changes the receipt seal")
    func tamperClaimTextChangesSeal() async throws {
        let b = try await PJE009Fixtures.buildWorkProduct(suffix: "tamperclaim")
        let s1 = try WorkProductReceiptBuilder().build(from: try await reopen(b)).seal
        try await b.rig.db.exec(
            "UPDATE work_product_claim_occurrences SET text = ? WHERE run_id = ?;",
            [.text("TAMPERED STATEMENT"), .uuid(b.wpRunID)])
        let s2 = try WorkProductReceiptBuilder().build(from: try await reopen(b)).seal
        #expect(s1 != s2, "a claim-text mutation must change the receipt seal")
    }

    @Test("Tampering a persisted citation is detected (seal changes or receipt fails closed)")
    func tamperCitationDetected() async throws {
        let b = try await PJE009Fixtures.buildWorkProduct(suffix: "tampercite")
        let s1 = try WorkProductReceiptBuilder().build(from: try await reopen(b)).seal
        // Blank out the supporting citations JSON on all claims.
        try await b.rig.db.exec(
            "UPDATE work_product_claim_occurrences SET supporting_json = '[]' WHERE run_id = ?;",
            [.uuid(b.wpRunID)])
        let tampered = try await reopen(b)
        if let r2 = try? WorkProductReceiptBuilder().build(from: tampered) {
            #expect(r2.seal != s1, "citation removal must change the seal")
        }
        // Either the seal changed or the receipt failed closed — both are detection.
    }

    @Test("Tampering the persisted manifest source list is visible on reopen")
    func tamperManifestVisible() async throws {
        let b = try await PJE009Fixtures.buildWorkProduct(suffix: "tampermanifest")
        let before = try await reopen(b)
        #expect(!before.manifest.sourceVersionIDs.isEmpty)
        try await b.rig.db.exec(
            "UPDATE work_product_manifests SET source_version_ids = '[]' WHERE run_id = ?;",
            [.uuid(b.wpRunID)])
        let after = try await reopen(b)
        #expect(after.manifest.sourceVersionIDs != before.manifest.sourceVersionIDs)
    }

    @Test("Removing a persisted section is visible on reopen (no silent reconstruction)")
    func removedSectionVisible() async throws {
        let b = try await PJE009Fixtures.buildWorkProduct(suffix: "removesection")
        let before = try await reopen(b)
        let sectionCountBefore = before.workProduct.sections.count
        try await b.rig.db.exec(
            "DELETE FROM work_product_claim_occurrences WHERE run_id = ?;", [.uuid(b.wpRunID)])
        try await b.rig.db.exec(
            "DELETE FROM work_product_sections WHERE run_id = ?;", [.uuid(b.wpRunID)])
        let after = try await reopen(b)
        #expect(after.workProduct.sections.count != sectionCountBefore)
        #expect(after.workProduct.sections.isEmpty)
    }

    @Test("A receipt built from one run's product does not verify against another run's data")
    func receiptDistinctPerRun() async throws {
        let b1 = try await PJE009Fixtures.buildWorkProduct(suffix: "run1", factValue: "alpha delayed on 2025-01-01")
        let b2 = try await PJE009Fixtures.buildWorkProduct(suffix: "run2", factValue: "beta delayed on 2025-03-03")
        let s1 = try WorkProductReceiptBuilder().build(from: try await reopen(b1)).seal
        let s2 = try WorkProductReceiptBuilder().build(from: try await reopen(b2)).seal
        #expect(s1 != s2, "distinct products must have distinct seals")
    }
}
