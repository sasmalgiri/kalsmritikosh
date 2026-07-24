//
//  DisclosureSelectionService.swift
//  Kalsmritikosh
//
//  PA-WP — prepares the workspace-scoped conflicts and gaps a GapsAndConflictsComposer will
//  render. This is where scoping happens; the composer never touches repositories. Scoping is
//  by PERSISTED IDENTITY, never by text match, and there is no global fallback:
//   • A conflict is surfaced only when it is explicitly linked (claim_contradictions) to one
//     or more of the selected claims, is still OPEN, and carries both sides. Resolved /
//     dismissed conflicts are excluded — never silently rendered as unresolved.
//   • A gap is surfaced only when its exact evidence object, or a bracketing event id, matches
//     a selected claim's evidence / lineage. Dismissed gaps are excluded.
//

import Foundation

public actor DisclosureSelectionService {
    private let contradictions: ContradictionsRepository
    private let claimContradictions: ClaimContradictionRepository
    private let gaps: GapNodeRepository

    public init(contradictions: ContradictionsRepository,
                claimContradictions: ClaimContradictionRepository,
                gaps: GapNodeRepository) {
        self.contradictions = contradictions
        self.claimContradictions = claimContradictions
        self.gaps = gaps
    }

    /// Conflicts explicitly linked (claim_contradictions) to SURFACEABLE selected claims. A
    /// refused claim never links a conflict into the output. Only OPEN, two-sided conflicts
    /// are returned; the exact linked ids are fetched by id (no row ceiling).
    public func conflicts(forSelectedClaims selected: [SelectedClaim]) async throws -> [SelectedConflict] {
        let surfaceable = selected.filter(\.maySurface)
        guard !surfaceable.isEmpty else { return [] }
        var linkers: [Contradiction.ID: [Claim.ID]] = [:]
        for s in surfaceable {
            let cid = s.resolved.claim.id
            for contradictionID in try await claimContradictions.contradictionIDs(claimID: cid) {
                linkers[contradictionID, default: []].append(cid)
            }
        }
        guard !linkers.isEmpty else { return [] }            // no linked conflicts → none
        return (try await contradictions.findByIDs(Array(linkers.keys))).compactMap { c -> SelectedConflict? in
            guard c.status == .open else { return nil }                  // resolved/dismissed excluded
            guard !c.claimA.isEmpty, !c.claimB.isEmpty else { return nil } // both sides represented
            let evidence = [
                c.evidenceA.map { EvidenceReference(objectID: $0, role: .supports) },
                c.evidenceB.map { EvidenceReference(objectID: $0, role: .contradicts) }
            ].compactMap { $0 }
            return SelectedConflict(
                id: c.id, description: c.description, sideA: c.claimA, sideB: c.claimB,
                supportingClaimIDs: (linkers[c.id] ?? []).sorted { $0.uuidString < $1.uuidString },
                evidence: evidence, severity: c.severity)
        }
    }

    /// Gaps whose PERSISTED identity proves membership in the SURFACEABLE selected set: the
    /// gap's exact evidence object, or its bracketing event ids, match a surfaceable claim's
    /// evidence object / lineage event. `nearEntity` text is never consulted; dismissed gaps
    /// are excluded; a two-ended gap must have BOTH ends in scope (so it can't leak an
    /// external side); a one-ended gap needs that end in scope.
    public func gaps(forSelectedClaims selected: [SelectedClaim]) async throws -> [SelectedGap] {
        let surfaceable = selected.filter(\.maySurface)
        guard !surfaceable.isEmpty else { return [] }
        var claimsByObject: [UUID: [Claim.ID]] = [:]
        var claimsByEvent: [UUID: [Claim.ID]] = [:]
        for s in surfaceable {
            let claim = s.resolved.claim
            for ev in claim.evidence { claimsByObject[ev.objectID, default: []].append(claim.id) }
            for ref in claim.derivedFrom where ref.kind == .event { claimsByEvent[ref.id, default: []].append(claim.id) }
        }
        return (await gaps.all(includeDismissed: false)).compactMap { g -> SelectedGap? in
            var related: Set<Claim.ID> = []
            if let obj = g.evidenceObjectID, let cs = claimsByObject[obj] {
                related.formUnion(cs)                                    // exact evidence match → include
            } else {
                switch (g.beforeEvent, g.afterEvent) {
                case let (be?, ae?):                                     // two-ended: BOTH ends must be in scope
                    guard let a = claimsByEvent[be], let b = claimsByEvent[ae] else { return nil }
                    related.formUnion(a); related.formUnion(b)
                case let (single?, nil), let (nil, single?):             // one-ended: that end in scope
                    guard let cs = claimsByEvent[single] else { return nil }
                    related.formUnion(cs)
                case (nil, nil):
                    return nil
                }
            }
            guard !related.isEmpty else { return nil }       // no proven membership → excluded (no fallback)
            return SelectedGap(id: g.id, kind: g.kind, description: g.description, reason: g.reason,
                               confidence: g.confidence,
                               relatedClaimIDs: related.sorted { $0.uuidString < $1.uuidString })
        }
    }
}
