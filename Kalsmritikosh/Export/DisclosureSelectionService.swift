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

    /// Conflicts explicitly linked to the selected claims (via claim_contradictions). Only
    /// OPEN, two-sided conflicts are returned, ordered deterministically by the composer.
    public func conflicts(forSelectedClaimIDs claimIDs: [Claim.ID]) async throws -> [SelectedConflict] {
        guard !claimIDs.isEmpty else { return [] }
        var linkers: [Contradiction.ID: [Claim.ID]] = [:]
        for cid in claimIDs {
            for contradictionID in try await claimContradictions.contradictionIDs(claimID: cid) {
                linkers[contradictionID, default: []].append(cid)
            }
        }
        guard !linkers.isEmpty else { return [] }            // no linked conflicts → none
        let linked = Set(linkers.keys)
        return (await contradictions.all(limit: 5000)).compactMap { c -> SelectedConflict? in
            guard linked.contains(c.id) else { return nil }              // linked only, never text-matched
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

    /// Gaps whose PERSISTED identity proves membership in the selected set: the gap's exact
    /// evidence object, or a bracketing event id, matches a selected claim's evidence object /
    /// lineage event. `nearEntity` text is never consulted. Dismissed gaps are excluded.
    public func gaps(forSelectedClaims selected: [SelectedClaim]) async throws -> [SelectedGap] {
        guard !selected.isEmpty else { return [] }
        var claimsByObject: [UUID: [Claim.ID]] = [:]
        var claimsByEvent: [UUID: [Claim.ID]] = [:]
        for s in selected {
            let claim = s.resolved.claim
            for ev in claim.evidence { claimsByObject[ev.objectID, default: []].append(claim.id) }
            for ref in claim.derivedFrom where ref.kind == .event { claimsByEvent[ref.id, default: []].append(claim.id) }
        }
        return (await gaps.all(includeDismissed: false)).compactMap { g -> SelectedGap? in
            var related: Set<Claim.ID> = []
            if let obj = g.evidenceObjectID, let cs = claimsByObject[obj] { related.formUnion(cs) }
            if let be = g.beforeEvent, let cs = claimsByEvent[be] { related.formUnion(cs) }
            if let ae = g.afterEvent, let cs = claimsByEvent[ae] { related.formUnion(cs) }
            guard !related.isEmpty else { return nil }       // no proven membership → excluded (no fallback)
            return SelectedGap(id: g.id, kind: g.kind, description: g.description, reason: g.reason,
                               confidence: g.confidence,
                               relatedClaimIDs: related.sorted { $0.uuidString < $1.uuidString })
        }
    }
}
