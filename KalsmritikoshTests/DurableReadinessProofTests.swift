//
//  DurableReadinessProofTests.swift
//  KalsmritikoshTests
//
//  USF-002.1 — readiness must be reconstructed from durable state, never asserted. Proves the
//  committed structural receipt (exact counts + complete/located gating), a persistence failure
//  yields NO receipt, exact per-version FTS coverage, and the repository's positive-proof rules
//  (indexing needs an ftsIndex basis whose coverage matches the database; structural needs a basis;
//  foreign/soft bases and empty plans are rejected). Synthetic sources only.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("USF-002.1 — durable readiness proof", .serialized)
struct DurableReadinessProofTests {

    private let hexHash = String(repeating: "a", count: 64)

    private func block(_ ordinal: Int, docID: UUID, located: Bool, ocr: Bool = false,
                       kind: EvidenceBlockKind = .paragraph) -> EvidenceBlock {
        EvidenceBlock(documentID: docID, ordinal: ordinal, kind: kind, rawText: "substantive block text",
                      locator: located ? SourceLocator(page: 1) : SourceLocator(),
                      extractionMethod: ocr ? .ocr : .native)
    }
    private func makeDoc(versionID: UUID, docID: UUID = UUID(), blocks: [EvidenceBlock],
                         status: ExtractionStatus = .complete) -> ParsedDocument {
        ParsedDocument(id: docID, logicalSourceID: versionID, sourceVersionID: versionID, filename: "f.txt",
                       detectedType: .txt, contentHash: hexHash, blocks: blocks, extractionStatus: status)
    }

    // MARK: - Committed receipt

    @Test("A successful persist returns a receipt with exact committed counts")
    func receiptCountsCorrect() async throws {
        let rig = try await USF002Fixtures.makeRig()
        let v = try await USF002Fixtures.seedVersion(rig)
        let store = EvidenceStore(database: rig.db)
        let docID = UUID()
        let blocks = [
            block(0, docID: docID, located: true),
            block(1, docID: docID, located: true),
            block(2, docID: docID, located: false),                     // substantive, not located
            block(3, docID: docID, located: true, ocr: true),           // OCR block (located)
            block(4, docID: docID, located: true, kind: .pageFooter) // boilerplate → not substantive
        ]
        let receipt = try await store.persist(makeDoc(versionID: v, docID: docID, blocks: blocks),
                                              parser: "p", parserVersion: "1", startedAt: Date())
        #expect(receipt.blockCount == 5)
        #expect(receipt.substantiveBlockCount == 4)          // all but the pageFurniture boilerplate
        #expect(receipt.locatedSubstantiveBlockCount == 3)   // one substantive block is unlocated
        #expect(receipt.ocrBlockCount == 1)
        #expect(receipt.sourceVersionID == v)
        #expect(receipt.sourceDocumentID == docID)
    }

    @Test("Persisting a second, different document to the same version throws (no receipt)")
    func persistFailureThrowsNoReceipt() async throws {
        let rig = try await USF002Fixtures.makeRig()
        let v = try await USF002Fixtures.seedVersion(rig)
        let store = EvidenceStore(database: rig.db)
        let d1 = UUID()
        _ = try await store.persist(makeDoc(versionID: v, docID: d1, blocks: [block(0, docID: d1, located: true)]),
                                    parser: "p", parserVersion: "1", startedAt: Date())
        let d2 = UUID()
        await #expect(throws: SourceIntakeError.self) {
            _ = try await store.persist(self.makeDoc(versionID: v, docID: d2, blocks: [self.block(0, docID: d2, located: true)]),
                                        parser: "p", parserVersion: "1", startedAt: Date())
        }
    }

    @Test("isStructurallyComplete requires complete status and every substantive block located")
    func isStructurallyCompleteGating() async throws {
        let rig = try await USF002Fixtures.makeRig()
        let store = EvidenceStore(database: rig.db)
        // complete + all located → complete
        let v1 = try await USF002Fixtures.seedVersion(rig)
        let d1 = UUID()
        let r1 = try await store.persist(makeDoc(versionID: v1, docID: d1, blocks: [block(0, docID: d1, located: true)]),
                                         parser: "p", parserVersion: "1", startedAt: Date())
        #expect(r1.isStructurallyComplete)
        // complete but a substantive block is unlocated → NOT complete
        let v2 = try await USF002Fixtures.seedVersion(rig)
        let d2 = UUID()
        let r2 = try await store.persist(makeDoc(versionID: v2, docID: d2, blocks: [block(0, docID: d2, located: false)]),
                                         parser: "p", parserVersion: "1", startedAt: Date())
        #expect(r2.isStructurallyComplete == false)
        // extractionStatus partial → NOT complete even when all located
        let v3 = try await USF002Fixtures.seedVersion(rig)
        let d3 = UUID()
        let r3 = try await store.persist(makeDoc(versionID: v3, docID: d3, blocks: [block(0, docID: d3, located: true)], status: .partial),
                                         parser: "p", parserVersion: "1", startedAt: Date())
        #expect(r3.isStructurallyComplete == false)
    }

    // MARK: - Exact per-version coverage

    @Test("ftsCoverage counts only the exact version's chunks, never another version's")
    func ftsCoverageExactPerVersion() async throws {
        let rig = try await USF002Fixtures.makeRig()
        let a = try await USF002Fixtures.seedVersion(rig)
        let b = try await USF002Fixtures.seedVersion(rig)
        try await USF002Fixtures.seedChunks(rig, sourceVersionID: a, count: 3)
        try await USF002Fixtures.seedChunks(rig, sourceVersionID: b, count: 5)
        let covA = try await rig.repo.ftsCoverage(sourceVersionID: a)
        let covB = try await rig.repo.ftsCoverage(sourceVersionID: b)
        #expect(covA.eligible == 3 && covA.indexed == 3)
        #expect(covB.eligible == 5 && covB.indexed == 5)
    }

    // MARK: - Positive-proof rules

    private func bootstrapped(_ rig: USF002Rig, _ id: UUID) async throws {
        _ = try await rig.repo.bootstrap(sourceVersionID: id, detectedType: .txt, preservationStatus: .referenceRecorded, at: USF002Fixtures.t0)
    }

    @Test("Indexing readiness requires an ftsIndex basis")
    func indexingReadyRequiresBasis() async throws {
        let rig = try await USF002Fixtures.makeRig()
        let id = try await USF002Fixtures.seedVersion(rig); try await bootstrapped(rig, id)
        try await USF002Fixtures.seedChunks(rig, sourceVersionID: id, count: 2)
        await #expect(throws: SourceReadinessError.self) {
            _ = try await rig.repo.apply(USF002Fixtures.plan(id, expectedRevision: 1,
                [USF002Fixtures.update(.indexing, .ready, action: .satisfy, c: 2, t: 2)]))   // no basis
        }
    }

    @Test("Indexing coverage units must match the database-derived coverage")
    func indexingCoverageMustMatch() async throws {
        let rig = try await USF002Fixtures.makeRig()
        let id = try await USF002Fixtures.seedVersion(rig); try await bootstrapped(rig, id)
        try await USF002Fixtures.seedChunks(rig, sourceVersionID: id, count: 2)
        await #expect(throws: SourceReadinessError.self) {
            _ = try await rig.repo.apply(USF002Fixtures.plan(id, expectedRevision: 1,
                [USF002Fixtures.update(.indexing, .ready, action: .satisfy, c: 5, t: 5, basis: USF002Fixtures.ftsIndexBasis(id))]))
        }
        // matching coverage → accepted
        let snap = try await rig.repo.apply(USF002Fixtures.plan(id, expectedRevision: 1,
            [USF002Fixtures.update(.indexing, .ready, action: .satisfy, c: 2, t: 2, basis: USF002Fixtures.ftsIndexBasis(id))]))
        #expect(snap.dimension(.indexing)?.state == .ready)
    }

    @Test("Structural readiness requires a durable basis")
    func structuralReadyRequiresBasis() async throws {
        let rig = try await USF002Fixtures.makeRig()
        let id = try await USF002Fixtures.seedVersion(rig); try await bootstrapped(rig, id)
        await #expect(throws: SourceReadinessError.self) {
            _ = try await rig.repo.apply(USF002Fixtures.plan(id, expectedRevision: 1,
                [USF002Fixtures.update(.structuralExtraction, .ready, action: .satisfy, c: 1, t: 1)]))   // no basis
        }
    }

    @Test("An ftsIndex basis for another version is rejected")
    func foreignFtsBasisRejected() async throws {
        let rig = try await USF002Fixtures.makeRig()
        let id = try await USF002Fixtures.seedVersion(rig); try await bootstrapped(rig, id)
        try await USF002Fixtures.seedChunks(rig, sourceVersionID: id, count: 1)
        await #expect(throws: SourceReadinessError.self) {
            _ = try await rig.repo.apply(USF002Fixtures.plan(id, expectedRevision: 1,
                [USF002Fixtures.update(.indexing, .ready, action: .satisfy, c: 1, t: 1,
                                       basis: SourceReadinessBasis(kind: .ftsIndex, identifier: UUID().uuidString))]))
        }
    }

    @Test("A soft basis (custody) naming another version is rejected")
    func softBasisWrongIdentifierRejected() async throws {
        let rig = try await USF002Fixtures.makeRig()
        let id = try await USF002Fixtures.seedVersion(rig); try await bootstrapped(rig, id)
        await #expect(throws: SourceReadinessError.self) {
            _ = try await rig.repo.apply(USF002Fixtures.plan(id, expectedRevision: 1,
                [USF002Fixtures.update(.textExtraction, .ready, action: .satisfy,
                                       basis: SourceReadinessBasis(kind: .custody, identifier: UUID().uuidString))]))
        }
    }

    @Test("An empty plan is rejected")
    func emptyPlanRejected() async throws {
        let rig = try await USF002Fixtures.makeRig()
        let id = try await USF002Fixtures.seedVersion(rig); try await bootstrapped(rig, id)
        await #expect(throws: SourceReadinessError.self) {
            _ = try await rig.repo.apply(USF002Fixtures.plan(id, expectedRevision: 1, []))
        }
    }

    @Test("A structurally failed version is never evidence-ready even when searchable")
    func failedStructuralNeverEvidenceReady() async throws {
        let rig = try await USF002Fixtures.makeRig()
        let id = try await USF002Fixtures.seedVersion(rig); try await bootstrapped(rig, id)
        try await USF002Fixtures.seedChunks(rig, sourceVersionID: id, count: 2)
        _ = try await rig.repo.apply(USF002Fixtures.plan(id, expectedRevision: 1, [
            USF002Fixtures.update(.textExtraction, .ready, action: .satisfy, c: 2, t: 2),
            USF002Fixtures.update(.indexing, .ready, action: .satisfy, c: 2, t: 2, basis: USF002Fixtures.ftsIndexBasis(id)),
            USF002Fixtures.update(.structuralExtraction, .failed, action: .fail, detail: "persist failed"),
        ]))
        let snap = try await rig.repo.snapshot(sourceVersionID: id)
        #expect(snap.isSearchReady)
        #expect(snap.isEvidenceReady == false)
    }

    @Test("ftsCoverage is zero for a version with no chunks")
    func ftsCoverageZeroWhenNoChunks() async throws {
        let rig = try await USF002Fixtures.makeRig()
        let id = try await USF002Fixtures.seedVersion(rig)
        let cov = try await rig.repo.ftsCoverage(sourceVersionID: id)
        #expect(cov.eligible == 0 && cov.indexed == 0)
    }

    @Test("Structural PARTIAL also requires a durable basis")
    func structuralPartialRequiresBasis() async throws {
        let rig = try await USF002Fixtures.makeRig()
        let id = try await USF002Fixtures.seedVersion(rig); try await bootstrapped(rig, id)
        await #expect(throws: SourceReadinessError.self) {
            _ = try await rig.repo.apply(USF002Fixtures.plan(id, expectedRevision: 1,
                [USF002Fixtures.update(.structuralExtraction, .partial, action: .partiallySatisfy, c: 1, t: 3)]))   // no basis
        }
    }

    @Test("A soft basis (vectorIndex) naming THIS version is accepted")
    func softBasisMatchingAccepted() async throws {
        let rig = try await USF002Fixtures.makeRig()
        let id = try await USF002Fixtures.seedVersion(rig); try await bootstrapped(rig, id)
        let snap = try await rig.repo.apply(USF002Fixtures.plan(id, expectedRevision: 1,
            [USF002Fixtures.update(.textExtraction, .ready, action: .satisfy,
                                   basis: SourceReadinessBasis(kind: .vectorIndex, identifier: id.uuidString))]))
        #expect(snap.dimension(.textExtraction)?.state == .ready)
    }

    @Test("SourceLocator.isResolvable distinguishes a real anchor from an empty locator")
    func locatorResolvable() {
        #expect(SourceLocator().isResolvable == false)
        #expect(SourceLocator(page: 1).isResolvable)
        #expect(SourceLocator(evidenceBlockID: UUID()).isResolvable == false)   // a self-reference is not a position
        var loc = SourceLocator(); loc.messageID = "m1"
        #expect(loc.isResolvable)
    }
}
