//
//  DisclosureSelectionServiceTests.swift
//  KalsmritikoshTests
//
//  PA-WP — upstream disclosure scoping. Conflicts are surfaced only when explicitly linked to
//  selected claims (via claim_contradictions), still open, two-sided; unrelated / resolved /
//  dismissed are excluded. Gaps are surfaced only when their persisted identity (exact
//  evidence object or bracketing event) matches a selected claim — never by text; dismissed
//  and unscoped gaps are excluded. No global fallback.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PA-WP — disclosure selection scoping")
struct DisclosureSelectionServiceTests {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private struct Rig {
        let contradictions: ContradictionsRepository
        let links: ClaimContradictionRepository
        let gaps: GapNodeRepository
        let service: DisclosureSelectionService
    }
    private func rig() async throws -> Rig {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("disc-\(UUID().uuidString).sqlite")
        let db = try Database(url: tmp)
        try await SchemaMigrations.migrate(db)
        let contradictions = ContradictionsRepository(database: db)
        let links = ClaimContradictionRepository(database: db)
        let gaps = GapNodeRepository(database: db)
        return Rig(contradictions: contradictions, links: links, gaps: gaps,
                   service: DisclosureSelectionService(contradictions: contradictions, claimContradictions: links, gaps: gaps))
    }

    private func selectedClaim(evidenceObject: UUID, eventLineage: UUID? = nil, id: UUID = UUID()) -> SelectedClaim {
        let ev = [EvidenceReference(objectID: evidenceObject, blockID: UUID())]
        let lineage = eventLineage.map { [DerivedReference(kind: .event, id: $0)] } ?? []
        let claim = Claim(id: id, subjectID: UUID(), subjectLabel: "S", statement: "s",
                          assessment: EvidenceAssessment(basis: .sourceAsserted, origin: .sourceExtraction),
                          confidence: 0.8, evidence: ev, derivedFrom: lineage, createdAt: t0)
        return SelectedClaim(resolved: ResolvedClaim(claim: claim, effectiveAssessment: claim.assessment),
                             selectionReason: .explicitlyRequested)
    }

    // MARK: Conflicts

    @Test("Only conflicts explicitly linked to a selected claim are surfaced")
    func onlyLinkedConflicts() async throws {
        let r = try await rig()
        let claimID = UUID()
        let linked = Contradiction(id: UUID(), description: "d", claimA: "A", claimB: "B", status: .open)
        let unrelated = Contradiction(id: UUID(), description: "d", claimA: "C", claimB: "D", status: .open)
        await r.contradictions.insert(linked)
        await r.contradictions.insert(unrelated)                         // exists in the archive, NOT linked
        try await r.links.link(claimID: claimID, contradictionID: linked.id)
        let out = try await r.service.conflicts(forSelectedClaimIDs: [claimID])
        #expect(out.map(\.id) == [linked.id])                            // unrelated does not leak
        #expect(out.first?.sideA == "A" && out.first?.sideB == "B")      // both sides preserved
    }

    @Test("A resolved (or dismissed) linked conflict is excluded, never shown as unresolved")
    func resolvedConflictExcluded() async throws {
        let r = try await rig()
        let claimID = UUID()
        let resolved = Contradiction(id: UUID(), description: "d", claimA: "A", claimB: "B", status: .resolved)
        await r.contradictions.insert(resolved)
        try await r.links.link(claimID: claimID, contradictionID: resolved.id)
        #expect(try await r.service.conflicts(forSelectedClaimIDs: [claimID]).isEmpty)
    }

    @Test("A linked conflict's two evidence sources are kept as separate sides")
    func conflictEvidenceSides() async throws {
        let r = try await rig()
        let claimID = UUID(), objA = UUID(), objB = UUID()
        let c = Contradiction(id: UUID(), description: "d", claimA: "A", claimB: "B",
                              evidenceA: objA, evidenceB: objB, status: .open)
        await r.contradictions.insert(c)
        try await r.links.link(claimID: claimID, contradictionID: c.id)
        let sel = try #require(try await r.service.conflicts(forSelectedClaimIDs: [claimID]).first)
        #expect(sel.evidence.first { $0.role == .supports }?.objectID == objA)
        #expect(sel.evidence.first { $0.role == .contradicts }?.objectID == objB)
    }

    // MARK: Gaps

    @Test("A gap is scoped by persisted evidence identity, never by text")
    func gapScopedByIdentityNotText() async throws {
        let r = try await rig()
        let sharedObject = UUID()
        let selected = [selectedClaim(evidenceObject: sharedObject)]
        // in-scope: same evidence object.
        await r.gaps.insert(GapNode(id: UUID(), kind: .threadParent, description: "in", reason: "r",
                                    confidence: 0.3, evidenceObjectID: sharedObject))
        // out-of-scope by object.
        await r.gaps.insert(GapNode(id: UUID(), kind: .threadParent, description: "outObj", reason: "r",
                                    confidence: 0.3, evidenceObjectID: UUID()))
        // text-only match (nearEntity) must NOT scope it in.
        await r.gaps.insert(GapNode(id: UUID(), kind: .threadParent, description: "outText", reason: "r",
                                    confidence: 0.3, nearEntity: "S"))
        let out = try await r.service.gaps(forSelectedClaims: selected)
        #expect(out.map(\.description) == ["in"])
    }

    @Test("A gap scoped by a bracketing lineage event is surfaced")
    func gapScopedByEvent() async throws {
        let r = try await rig()
        let eventID = UUID()
        let selected = [selectedClaim(evidenceObject: UUID(), eventLineage: eventID)]
        await r.gaps.insert(GapNode(id: UUID(), kind: .sequenceHole, description: "byEvent", reason: "r",
                                    confidence: 0.3, beforeEvent: eventID))
        let out = try await r.service.gaps(forSelectedClaims: selected)
        #expect(out.map(\.description) == ["byEvent"])
    }

    @Test("Dismissed gaps are excluded even when their identity matches")
    func dismissedGapExcluded() async throws {
        let r = try await rig()
        let sharedObject = UUID()
        let selected = [selectedClaim(evidenceObject: sharedObject)]
        await r.gaps.insert(GapNode(id: UUID(), kind: .threadParent, description: "dismissed", reason: "r",
                                    confidence: 0.3, evidenceObjectID: sharedObject, dismissed: true))
        #expect(try await r.service.gaps(forSelectedClaims: selected).isEmpty)
    }

    @Test("No selected claims → no disclosures (no global fallback)")
    func noFallback() async throws {
        let r = try await rig()
        await r.contradictions.insert(Contradiction(description: "d", claimA: "A", claimB: "B", status: .open))
        await r.gaps.insert(GapNode(kind: .threadParent, description: "g", reason: "r", evidenceObjectID: UUID()))
        #expect(try await r.service.conflicts(forSelectedClaimIDs: []).isEmpty)
        #expect(try await r.service.gaps(forSelectedClaims: []).isEmpty)
    }
}
