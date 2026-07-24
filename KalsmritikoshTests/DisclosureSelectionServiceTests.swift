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

    private func selectedClaim(id: UUID = UUID(), evidenceObject: UUID = UUID(),
                               eventLineage: UUID? = nil, refused: Bool = false) -> SelectedClaim {
        let ev = [EvidenceReference(objectID: evidenceObject, blockID: UUID())]
        let lineage = eventLineage.map { [DerivedReference(kind: .event, id: $0)] } ?? []
        let base = EvidenceAssessment(basis: .sourceAsserted, origin: .sourceExtraction)
        let claim = Claim(id: id, subjectID: UUID(), subjectLabel: "S", statement: "s",
                          assessment: base, confidence: 0.8, evidence: ev, derivedFrom: lineage, createdAt: t0)
        // A rejected review makes the policy refuse → the claim may not establish scope.
        let effective = refused ? base.with(review: .rejected) : base
        return SelectedClaim(resolved: ResolvedClaim(claim: claim, effectiveAssessment: effective),
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
        let out = try await r.service.conflicts(forSelectedClaims: [selectedClaim(id: claimID)])
        #expect(out.map(\.id) == [linked.id])                            // unrelated does not leak
        #expect(out.first?.sideA == "A" && out.first?.sideB == "B")      // both sides preserved
    }

    @Test("A refused (rejected) claim cannot establish conflict scope")
    func refusedClaimNoConflictScope() async throws {
        let r = try await rig()
        let claimID = UUID()
        let c = Contradiction(id: UUID(), description: "d", claimA: "A", claimB: "B", status: .open)
        await r.contradictions.insert(c)
        try await r.links.link(claimID: claimID, contradictionID: c.id)
        // The only linking claim is refused → its statement must not leak through the conflict.
        #expect(try await r.service.conflicts(forSelectedClaims: [selectedClaim(id: claimID, refused: true)]).isEmpty)
    }

    @Test("A resolved (or dismissed) linked conflict is excluded, never shown as unresolved")
    func resolvedConflictExcluded() async throws {
        let r = try await rig()
        let claimID = UUID()
        let resolved = Contradiction(id: UUID(), description: "d", claimA: "A", claimB: "B", status: .resolved)
        await r.contradictions.insert(resolved)
        try await r.links.link(claimID: claimID, contradictionID: resolved.id)
        #expect(try await r.service.conflicts(forSelectedClaims: [selectedClaim(id: claimID)]).isEmpty)
    }

    @Test("A linked conflict's two evidence sources are kept as separate sides")
    func conflictEvidenceSides() async throws {
        let r = try await rig()
        let claimID = UUID(), objA = UUID(), objB = UUID()
        let c = Contradiction(id: UUID(), description: "d", claimA: "A", claimB: "B",
                              evidenceA: objA, evidenceB: objB, status: .open)
        await r.contradictions.insert(c)
        try await r.links.link(claimID: claimID, contradictionID: c.id)
        let sel = try #require(try await r.service.conflicts(forSelectedClaims: [selectedClaim(id: claimID)]).first)
        #expect(sel.evidence.first { $0.role == .supports }?.objectID == objA)
        #expect(sel.evidence.first { $0.role == .contradicts }?.objectID == objB)
    }

    @Test("Exact-id contradiction loading returns a linked conflict past the former 5,000 ceiling")
    func findByIDsBeyondRowCeiling() async throws {
        let r = try await rig()
        // Insert 5,001 conflicts; the linked one is the OLDEST, so a bounded all(limit:5000)
        // ordered by detected_at DESC would have dropped it. findByIDs fetches it regardless.
        let linkedID = UUID()
        let base = Date(timeIntervalSince1970: 1_000_000)
        var bulk: [Contradiction] = [Contradiction(id: linkedID, description: "old", claimA: "A", claimB: "B",
                                                    status: .open, detectedAt: base)]  // oldest
        for i in 1...5000 {
            bulk.append(Contradiction(description: "c\(i)", claimA: "A", claimB: "B", status: .open,
                                      detectedAt: base.addingTimeInterval(Double(i))))
        }
        await r.contradictions.insertMany(bulk)
        let claimID = UUID()
        try await r.links.link(claimID: claimID, contradictionID: linkedID)
        let out = try await r.service.conflicts(forSelectedClaims: [selectedClaim(id: claimID)])
        #expect(out.map(\.id) == [linkedID])
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

    @Test("A refused claim cannot establish gap scope via its evidence object")
    func refusedClaimNoGapScope() async throws {
        let r = try await rig()
        let sharedObject = UUID()
        await r.gaps.insert(GapNode(id: UUID(), kind: .threadParent, description: "g", reason: "r",
                                    confidence: 0.3, evidenceObjectID: sharedObject))
        // The only claim carrying that object is refused → the gap must not surface.
        let refused = [selectedClaim(evidenceObject: sharedObject, refused: true)]
        #expect(try await r.service.gaps(forSelectedClaims: refused).isEmpty)
    }

    @Test("A two-ended gap with only one endpoint in scope is excluded (no external leak)")
    func mixedScopeTwoEndedGapExcluded() async throws {
        let r = try await rig()
        let inScopeEvent = UUID(), outOfScopeEvent = UUID()
        let selected = [selectedClaim(eventLineage: inScopeEvent)]
        await r.gaps.insert(GapNode(id: UUID(), kind: .sequenceHole, description: "mixed", reason: "r",
                                    confidence: 0.3, beforeEvent: inScopeEvent, afterEvent: outOfScopeEvent))
        #expect(try await r.service.gaps(forSelectedClaims: selected).isEmpty)
    }

    @Test("A two-ended gap with both endpoints in scope is included")
    func twoEndedGapBothInScope() async throws {
        let r = try await rig()
        let e1 = UUID(), e2 = UUID()
        let selected = [selectedClaim(eventLineage: e1), selectedClaim(eventLineage: e2)]
        await r.gaps.insert(GapNode(id: UUID(), kind: .sequenceHole, description: "both", reason: "r",
                                    confidence: 0.3, beforeEvent: e1, afterEvent: e2))
        #expect(try await r.service.gaps(forSelectedClaims: selected).map(\.description) == ["both"])
    }

    @Test("No selected claims → no disclosures (no global fallback)")
    func noFallback() async throws {
        let r = try await rig()
        await r.contradictions.insert(Contradiction(description: "d", claimA: "A", claimB: "B", status: .open))
        await r.gaps.insert(GapNode(kind: .threadParent, description: "g", reason: "r", evidenceObjectID: UUID()))
        #expect(try await r.service.conflicts(forSelectedClaims: []).isEmpty)
        #expect(try await r.service.gaps(forSelectedClaims: []).isEmpty)
    }
}
