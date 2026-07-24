//
//  ClaimSelectionService.swift
//  Kalsmritikosh
//
//  PA-SEL (persona-v2 Stage 1). The ONE deterministic service that turns canonical claims
//  into a fully-formed WorkProductContext for section composers. Composers and UI callers
//  MUST NOT select their own claims — this is the single selection/scoping/ordering point.
//
//  Guarantees:
//   • Explicit scope only — subject, workspace (with upstream-resolved member subjects), or
//     explicit claim ids. NEVER a silent corpus-global fallback.
//   • Membership stays OUTSIDE the Claim model (workspace scope carries member subject ids
//     resolved by the membership layer; the Claim has no workspace field).
//   • Every claim is resolved through ClaimResolver, so the LATEST review produces the
//     effective assessment.
//   • Temporal anchors come from LINEAGE (TemporalClaim → Event → HistoryItem), never from
//     statement text; conflicting lineage stays explicitly ambiguous; nothing is fabricated.
//   • Deterministic chronology order: dated before undated, start ascending, finer precision
//     first on ties, stable Claim id last.
//   • Exact evidence and the effective assessment are preserved unchanged; independence keys
//     are resolved here so the renderer can recognise corroboration.
//   • Repositories are never exposed to composers — only the finished context.
//

import Foundation

public actor ClaimSelectionService {

    /// The requested selection scope. There is deliberately no "everything" case.
    public enum Scope: Sendable, Hashable {
        case subject(Entity.ID)
        /// Workspace membership is resolved UPSTREAM (WorkspaceRepository.entityIDs) and
        /// handed in as member subject ids — the selector never reads a claim↔workspace table
        /// (there is none) and never falls back to global.
        case workspace(id: Workspace.ID, memberSubjectIDs: Set<Entity.ID>)
        case explicitClaimIDs([Claim.ID])
    }

    private let claims: ClaimRepository
    private let resolver: ClaimResolver
    private let temporalClaims: TemporalClaimRepository
    private let events: EventsRepository
    private let independenceKeyProvider: (any SourceIndependenceKeyProvider)?

    public init(claims: ClaimRepository, resolver: ClaimResolver,
                temporalClaims: TemporalClaimRepository, events: EventsRepository,
                independenceKeyProvider: (any SourceIndependenceKeyProvider)? = nil) {
        self.claims = claims; self.resolver = resolver
        self.temporalClaims = temporalClaims; self.events = events
        self.independenceKeyProvider = independenceKeyProvider
    }

    // MARK: - Build

    public func buildContext(scope: Scope, subjectLabel: String,
                             corpusSnapshotID: UUID? = nil) async throws -> WorkProductContext {
        // 1. Load candidates for the explicit scope (never global), dedup by id.
        var candidates = try await load(scope)
        var seen = Set<Claim.ID>()
        candidates = candidates.filter { seen.insert($0.id).inserted }

        // 2. Exclude anything outside the requested scope BEFORE composition.
        candidates = excludeOutOfScope(candidates, scope: scope)

        // 3. Resolve effective assessment for each (latest review applied).
        var resolvedClaims: [ResolvedClaim] = []
        resolvedClaims.reserveCapacity(candidates.count)
        for c in candidates { resolvedClaims.append(try await resolver.resolve(c)) }

        // 4. Resolve independence keys once for all cited objects (corroboration awareness).
        let keys = try await independenceKeys(for: resolvedClaims)

        // 5. Build lineage indexes for temporal anchoring (no fabrication).
        let tcIndex = try await temporalClaimIndex(for: resolvedClaims)
        let evIndex = try await eventIndex(for: resolvedClaims)

        // 6. Wrap each claim with its anchor, ambiguity, reason, and its own keys.
        let reason = selectionReason(for: scope)
        let selected: [SelectedClaim] = resolvedClaims.map { resolved in
            let (anchor, ambiguous) = temporalAnchor(for: resolved.claim, tcIndex: tcIndex, evIndex: evIndex)
            let objIDs = Set(resolved.claim.evidence.map(\.objectID))
            let claimKeys = keys.filter { objIDs.contains($0.key) }
            return SelectedClaim(resolved: resolved, temporalAnchor: anchor,
                                 isTemporallyAmbiguous: ambiguous, selectionReason: reason,
                                 independenceKeys: claimKeys)
        }

        // 7. Deterministic chronology ordering.
        let ordered = selected.sorted(by: Self.chronologicalOrder)

        return WorkProductContext(selectedClaims: ordered, subjectLabel: subjectLabel,
                                  workspaceID: workspaceID(for: scope), corpusSnapshotID: corpusSnapshotID)
    }

    // MARK: - Loading & scope

    private func load(_ scope: Scope) async throws -> [Claim] {
        switch scope {
        case .subject(let s):
            return try await claims.claims(subjectID: s)
        case .workspace(_, let members):
            var acc: [Claim] = []
            for m in members.sorted(by: { $0.uuidString < $1.uuidString }) {
                acc += try await claims.claims(subjectID: m)
            }
            return acc
        case .explicitClaimIDs(let ids):
            var acc: [Claim] = []
            for id in ids { if let c = try await claims.claim(id: id) { acc.append(c) } }
            return acc
        }
    }

    private func excludeOutOfScope(_ cs: [Claim], scope: Scope) -> [Claim] {
        switch scope {
        case .subject(let s):
            return cs.filter { $0.subjectID == s }
        case .workspace(_, let members):
            return cs.filter { $0.subjectID.map(members.contains) ?? false }
        case .explicitClaimIDs:
            return cs   // requested by id; no subject constraint to apply
        }
    }

    private func selectionReason(for scope: Scope) -> ClaimSelectionReason {
        switch scope {
        case .subject(let s):        return .subjectScope(s)
        case .workspace(let id, _):  return .workspaceScope(id)
        case .explicitClaimIDs:      return .explicitlyRequested
        }
    }

    private func workspaceID(for scope: Scope) -> UUID? {
        if case .workspace(let id, _) = scope { return id }
        return nil
    }

    // MARK: - Independence keys

    private func independenceKeys(for resolved: [ResolvedClaim]) async throws -> [KnowledgeObject.ID: String] {
        guard let provider = independenceKeyProvider else { return [:] }
        let objIDs = Set(resolved.flatMap { $0.claim.evidence.map(\.objectID) })
        guard !objIDs.isEmpty else { return [:] }
        return try await provider.keys(for: objIDs)
    }

    // MARK: - Temporal lineage indexes

    private func temporalClaimIndex(for resolved: [ResolvedClaim]) async throws -> [UUID: TemporalClaim] {
        // Temporal claims are subject-scoped (no fetch-by-id), so index by the subjects of the
        // selected claims that actually cite a temporalClaim in their lineage.
        let needsTemporal = resolved.contains { $0.claim.derivedFrom.contains { $0.kind == .temporalClaim } }
        guard needsTemporal else { return [:] }
        let subjectIDs = Set(resolved.compactMap { $0.claim.subjectID })
        var index: [UUID: TemporalClaim] = [:]
        for s in subjectIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            for tc in try await allTemporalClaims(subjectID: s) { index[tc.id] = tc }
        }
        return index
    }

    private func allTemporalClaims(subjectID: Entity.ID) async throws -> [TemporalClaim] {
        var out: [TemporalClaim] = []
        var offset = 0
        let page = 500
        while true {
            let batch = try await temporalClaims.claims(subjectID: subjectID, offset: offset, pageSize: page)
            out += batch
            if batch.count < page { break }
            offset += page
        }
        return out
    }

    private func eventIndex(for resolved: [ResolvedClaim]) async throws -> [UUID: Event] {
        let eventIDs = Array(Set(resolved.flatMap {
            $0.claim.derivedFrom.filter { $0.kind == .event }.map(\.id)
        }))
        guard !eventIDs.isEmpty else { return [:] }
        var index: [UUID: Event] = [:]
        for e in try await events.findByIDs(eventIDs) { index[e.id] = e }
        return index
    }

    // MARK: - Temporal anchoring (lineage only, never fabricated)

    /// Resolve a claim's temporal anchor by walking its lineage in priority order:
    /// TemporalClaim interval → Event date → (HistoryItem has no loader; skipped). Within the
    /// highest tier that yields any dated source: if all agree on a start date, anchor there;
    /// if they conflict, return ambiguous (undated, flagged). No dated lineage → plainly undated.
    private func temporalAnchor(for claim: Claim,
                                tcIndex: [UUID: TemporalClaim],
                                evIndex: [UUID: Event]) -> (ClaimTemporalAnchor?, Bool) {
        // Tier 1 — temporal claims.
        let tcAnchors = claim.derivedFrom.filter { $0.kind == .temporalClaim }.compactMap { ref -> ClaimTemporalAnchor? in
            guard let tc = tcIndex[ref.id], let vf = tc.validFrom, let start = vf.start else { return nil }
            return ClaimTemporalAnchor(start: start, end: tc.validTo?.start, precision: vf.precision, source: ref)
        }
        if !tcAnchors.isEmpty { return finalize(tcAnchors) }

        // Tier 2 — events.
        let evAnchors = claim.derivedFrom.filter { $0.kind == .event }.compactMap { ref -> ClaimTemporalAnchor? in
            guard let e = evIndex[ref.id] else { return nil }
            return ClaimTemporalAnchor(start: e.date, end: e.endDate, precision: e.datePrecision, source: ref)
        }
        if !evAnchors.isEmpty { return finalize(evAnchors) }

        // Tier 3 — HistoryItem: no repository load-by-id exists, so no anchor is derived here
        // (deferred, never fabricated).
        return (nil, false)
    }

    /// Reconcile the anchors from one lineage tier. All agree on a start date → anchor at the
    /// deterministically-chosen source; they disagree → ambiguous (undated, flagged).
    private func finalize(_ anchors: [ClaimTemporalAnchor]) -> (ClaimTemporalAnchor?, Bool) {
        let distinctStarts = Set(anchors.map(\.start))
        guard distinctStarts.count == 1 else { return (nil, true) }   // conflicting → ambiguous
        let chosen = anchors.sorted { $0.source.id.uuidString < $1.source.id.uuidString }.first!
        return (chosen, false)
    }

    // MARK: - Deterministic ordering

    /// dated < undated; then start ascending; then finer precision first; then stable Claim id.
    private nonisolated static func chronologicalOrder(_ a: SelectedClaim, _ b: SelectedClaim) -> Bool {
        switch (a.temporalAnchor, b.temporalAnchor) {
        case let (x?, y?):
            if x.start != y.start { return x.start < y.start }
            if x.precision.rawValue != y.precision.rawValue { return x.precision.rawValue > y.precision.rawValue }
            return a.resolved.claim.id.uuidString < b.resolved.claim.id.uuidString
        case (_?, nil): return true     // dated before undated
        case (nil, _?): return false
        case (nil, nil): return a.resolved.claim.id.uuidString < b.resolved.claim.id.uuidString
        }
    }
}
