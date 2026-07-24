//
//  SelectedClaim.swift
//  Kalsmritikosh
//
//  PA-SEL (persona-v2 Stage 1). The selection-layer wrapper around a canonical Claim. A
//  Claim is deliberately date-free — it can be non-temporal, derived from several dated
//  sources, valid over an interval, associated with conflicting dates, or reused in
//  non-chronological products. Putting one date on the Claim would collapse those. Instead
//  the SELECTOR attaches a temporal anchor (resolved from lineage, never from statement
//  text, never fabricated) and the independence keys the renderer needs to recognise
//  corroboration. Pure value types.
//

import Foundation

/// A temporal placement for a claim, resolved from its LINEAGE (a dated source), never from
/// the statement text and never invented. `source` records which lineage reference supplied it.
public struct ClaimTemporalAnchor: Sendable, Hashable {
    public let start: Date
    public let end: Date?
    public let precision: DatePrecision
    public let source: DerivedReference
    public nonisolated init(start: Date, end: Date? = nil, precision: DatePrecision, source: DerivedReference) {
        self.start = start; self.end = end; self.precision = precision; self.source = source
    }
}

/// A precision-supported temporal interval used to reconcile lineage anchors by OVERLAP
/// rather than raw start equality (so same-month anchors agree and a year that contains a
/// day agrees with it, while disjoint periods conflict). Closed bounds.
public struct NormalizedTemporalExtent: Sendable, Hashable {
    public let lowerBound: Date
    public let upperBound: Date
    public nonisolated init(lowerBound: Date, upperBound: Date) {
        self.lowerBound = lowerBound; self.upperBound = upperBound
    }
}

/// Why a claim entered the selection (mirrors the requested scope).
public enum ClaimSelectionReason: Sendable, Hashable {
    case subjectScope(Entity.ID)
    case workspaceScope(Workspace.ID)
    case explicitlyRequested
}

/// A canonical claim resolved (effective review applied), placed, and scoped for a work
/// product. `temporalAnchor == nil` means the claim is not placed on a timeline: either it
/// has no dated lineage (`isTemporallyAmbiguous == false`, plainly undated) or its lineage
/// carried CONFLICTING dates (`isTemporallyAmbiguous == true`) — in which case it is kept
/// explicitly undated rather than guessed.
public struct SelectedClaim: Sendable, Hashable {
    public let resolved: ResolvedClaim
    public let temporalAnchor: ClaimTemporalAnchor?
    public let isTemporallyAmbiguous: Bool
    public let selectionReason: ClaimSelectionReason
    /// Independence keys (object id → key) resolved during selection, so the renderer can
    /// recognise corroboration instead of permanently evaluating evidence as unkeyed.
    public let independenceKeys: [KnowledgeObject.ID: String]
    /// True ONLY when the selector verified a persisted deterministic lineage / derivation
    /// record whose input references are present and reopenable — NEVER inferred merely from
    /// `basis == .deterministicallyDerived`. When false, a deterministic claim is surfaced
    /// conservatively as an inference rather than as an asserted derivation.
    public let hasReproducibleDerivation: Bool

    public nonisolated init(resolved: ResolvedClaim,
                            temporalAnchor: ClaimTemporalAnchor? = nil,
                            isTemporallyAmbiguous: Bool = false,
                            selectionReason: ClaimSelectionReason,
                            independenceKeys: [KnowledgeObject.ID: String] = [:],
                            hasReproducibleDerivation: Bool = false) {
        self.resolved = resolved
        self.temporalAnchor = temporalAnchor
        self.isTemporallyAmbiguous = isTemporallyAmbiguous
        self.selectionReason = selectionReason
        self.independenceKeys = independenceKeys
        self.hasReproducibleDerivation = hasReproducibleDerivation
    }
}
