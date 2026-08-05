//
//  InvestigationContradictionGapService.swift
//  Kalsmritikosh
//
//  INV-12 — the case Contradiction & Gap desk. Orchestration only: it REUSES the shared
//  ContradictionsRepository + GapNodeRepository (the canonical detectors) and bounds them to the case's
//  authorized source versions, pairing each in-scope item with the case's human disposition recorded in the
//  thin InvestigationDeskReviewRepository. It forks neither authority and mutates neither's global status —
//  so a contradiction keeps BOTH sides (never averaged into one truth) and a gap keeps its reason (absence
//  is never proof). Confirm/dismiss here is the case's disposition, not a resolution of the underlying item.
//

import Foundation

public actor InvestigationContradictionGapService {
    private let cases: InvestigationCaseRepository
    private let resolver: CaseRetrievalScopeResolver
    private let evidence: EvidenceStore
    private let contradictions: ContradictionsRepository
    private let gaps: GapNodeRepository
    private let reviews: InvestigationDeskReviewRepository

    public init(cases: InvestigationCaseRepository, resolver: CaseRetrievalScopeResolver, evidence: EvidenceStore,
                contradictions: ContradictionsRepository, gaps: GapNodeRepository, reviews: InvestigationDeskReviewRepository) {
        self.cases = cases; self.resolver = resolver; self.evidence = evidence
        self.contradictions = contradictions; self.gaps = gaps; self.reviews = reviews
    }

    // MARK: - Read (in-scope items + case disposition)

    /// The contradictions whose evidence sits inside the case scope, each paired with the case's disposition.
    /// Both claim sides are preserved verbatim from the shared Contradiction.
    public func contradictions(caseID: UUID, limit: Int = 500) async throws -> [CaseContradictionItem] {
        let authorized = try await authorizedSet(caseID)
        let caseReviews = try await reviews.reviewsByItem(caseID: caseID, itemKind: .contradiction)
        var out: [CaseContradictionItem] = []
        for c in await contradictions.all(limit: limit) where try await isContradictionInScope(c, authorized: authorized) {
            out.append(CaseContradictionItem(contradiction: c, review: caseReviews[c.id.uuidString]))
        }
        return out
    }

    /// The gaps whose evidence sits inside the case scope, each paired with the case's disposition.
    public func gaps(caseID: UUID, limit: Int = 500) async throws -> [CaseGapItem] {
        let authorized = try await authorizedSet(caseID)
        let caseReviews = try await reviews.reviewsByItem(caseID: caseID, itemKind: .gap)
        var out: [CaseGapItem] = []
        for g in await gaps.all(includeDismissed: true, limit: limit) where try await isGapInScope(g, authorized: authorized) {
            out.append(CaseGapItem(gap: g, review: caseReviews[g.id.uuidString]))
        }
        return out
    }

    // MARK: - Human disposition (case-scoped; shared item status untouched)

    public func confirmContradiction(caseID: UUID, contradictionID: UUID, note: String?, actor: String, at date: Date) async throws -> InvestigationDeskReview {
        try await disposeContradiction(caseID: caseID, contradictionID: contradictionID, decision: .confirmed, note: note, actor: actor, at: date)
    }
    public func dismissContradiction(caseID: UUID, contradictionID: UUID, note: String?, actor: String, at date: Date) async throws -> InvestigationDeskReview {
        try await disposeContradiction(caseID: caseID, contradictionID: contradictionID, decision: .dismissed, note: note, actor: actor, at: date)
    }
    public func confirmGap(caseID: UUID, gapID: UUID, note: String?, actor: String, at date: Date) async throws -> InvestigationDeskReview {
        try await disposeGap(caseID: caseID, gapID: gapID, decision: .confirmed, note: note, actor: actor, at: date)
    }
    public func dismissGap(caseID: UUID, gapID: UUID, note: String?, actor: String, at date: Date) async throws -> InvestigationDeskReview {
        try await disposeGap(caseID: caseID, gapID: gapID, decision: .dismissed, note: note, actor: actor, at: date)
    }

    // MARK: - Internals

    private func disposeContradiction(caseID: UUID, contradictionID: UUID, decision: DeskDecision, note: String?, actor: String, at date: Date) async throws -> InvestigationDeskReview {
        _ = try await requireOpenCaseScope(caseID)
        let authorized = try await authorizedSet(caseID)
        guard let c = try await contradictions.findByIDs([contradictionID]).first else { throw InvestigationDeskError.contradictionNotFound(contradictionID) }
        guard try await isContradictionInScope(c, authorized: authorized) else { throw InvestigationDeskError.contradictionOutOfScope(contradictionID) }
        return try await reviews.record(caseID: caseID, itemKind: .contradiction, itemID: contradictionID.uuidString, decision: decision, note: note, actor: actor, at: date)
    }

    private func disposeGap(caseID: UUID, gapID: UUID, decision: DeskDecision, note: String?, actor: String, at date: Date) async throws -> InvestigationDeskReview {
        _ = try await requireOpenCaseScope(caseID)
        let authorized = try await authorizedSet(caseID)
        guard let g = await gaps.all(includeDismissed: true, limit: 5000).first(where: { $0.id == gapID }) else { throw InvestigationDeskError.gapNotFound(gapID) }
        guard try await isGapInScope(g, authorized: authorized) else { throw InvestigationDeskError.gapOutOfScope(gapID) }
        return try await reviews.record(caseID: caseID, itemKind: .gap, itemID: gapID.uuidString, decision: decision, note: note, actor: actor, at: date)
    }

    /// A contradiction is in scope iff it has at least one evidence side and EVERY present side resolves to
    /// an authorized source version (fail-closed on an unresolved side).
    private func isContradictionInScope(_ c: Contradiction, authorized: Set<UUID>) async throws -> Bool {
        let sides = [c.evidenceA, c.evidenceB].compactMap { $0 }
        guard !sides.isEmpty else { return false }
        for ko in sides {
            guard let v = try await evidence.currentVersionID(forObject: ko), authorized.contains(v) else { return false }
        }
        return true
    }

    /// A gap is in scope iff it anchors to an evidence object that resolves to an authorized source version.
    private func isGapInScope(_ g: GapNode, authorized: Set<UUID>) async throws -> Bool {
        guard let ko = g.evidenceObjectID, let v = try await evidence.currentVersionID(forObject: ko) else { return false }
        return authorized.contains(v)
    }

    private func authorizedSet(_ caseID: UUID) async throws -> Set<UUID> {
        guard let record = try await cases.fetch(caseID: caseID) else { throw InvestigationDeskError.caseNotFound(caseID) }
        return Set(try await resolver.scope(for: record).authorizedSourceVersionIDs)
    }

    private func requireOpenCaseScope(_ caseID: UUID) async throws -> RetrievalSourceScope {
        guard let record = try await cases.fetch(caseID: caseID) else { throw InvestigationDeskError.caseNotFound(caseID) }
        guard record.caseHeader.status != .closed else { throw InvestigationDeskError.caseClosed(caseID) }
        return try await resolver.scope(for: record)
    }
}
