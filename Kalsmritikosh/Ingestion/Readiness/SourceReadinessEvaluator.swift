//
//  SourceReadinessEvaluator.swift
//  Kalsmritikosh
//
//  USF-002 — the DETERMINISTIC evaluation of a source version's ten dimensions into search /
//  evidence / analytical readiness and one derived completion state. It is a pure function over
//  the persisted dimensions: no single dimension implies another, embeddings alone never make a
//  source searchable or analytical, and a structurally partial source stays searchablePartial
//  rather than evidenceReady. The result carries per-dimension coverage but NEVER an overall
//  percentage.
//

import Foundation

public nonisolated enum SourceReadinessEvaluator {

    /// Evaluate the ten dimensions of a source version into a snapshot. Order-independent.
    public nonisolated static func evaluate(sourceVersionID: UUID, aggregateRevision: Int,
                                dimensions raw: [SourceReadinessDimensionRecord], updatedAt: Date) -> SourceReadinessSnapshot {
        let dims = raw.sorted { $0.dimension.ordinal < $1.dimension.ordinal }
        func d(_ dim: SourceReadinessDimension) -> SourceReadinessDimensionRecord? { dims.first { $0.dimension == dim } }
        func blockedBy(_ c: SourceReadinessCondition) -> Bool { dims.contains { $0.state == .blocked && $0.condition == c } }

        let searchReady = Self.searchReady(dims: dims, d: d)
        let evidenceReady = searchReady && Self.evidenceReady(d: d)
        let analyticalReady = evidenceReady && Self.analyticalReady(d: d)
        let completion = Self.completion(dims: dims, blockedBy: blockedBy,
                                         searchReady: searchReady, evidenceReady: evidenceReady)

        // Limitations: any APPLICABLE dimension that is not fully ready (partial/blocked/unsupported/failed).
        let limitations = dims
            .filter { $0.isApplicable && [.partial, .blocked, .unsupported, .failed].contains($0.state) }
            .map { SourceReadinessLimitation(dimension: $0.dimension, state: $0.state, detail: $0.detail) }
        // Blockers: dimensions held back by an explicit condition.
        let blockers = dims.compactMap { r -> SourceReadinessBlocker? in
            guard r.state == .blocked, let c = r.condition else { return nil }
            return SourceReadinessBlocker(dimension: r.dimension, condition: c, detail: r.detail)
        }

        return SourceReadinessSnapshot(
            sourceVersionID: sourceVersionID, aggregateRevision: aggregateRevision, dimensions: dims,
            completionState: completion, isSearchReady: searchReady, isEvidenceReady: evidenceReady,
            isAnalyticallyReady: analyticalReady, limitations: limitations, blockers: blockers, updatedAt: updatedAt)
    }

    // MARK: - §7.1 search readiness

    private static func searchReady(dims: [SourceReadinessDimensionRecord],
                                    d: (SourceReadinessDimension) -> SourceReadinessDimensionRecord?) -> Bool {
        // preservation must be reopenable (ready) or an accepted partial.
        guard let pres = d(.preservation), pres.state == .ready || pres.state == .partial else { return false }
        // A source-level encrypted/corrupt blocker prevents search entirely.
        if dims.contains(where: { $0.state == .blocked && ($0.condition == .encrypted || $0.condition == .corrupt) }) { return false }
        // searchable text present (empty text = ready with 0 units is NOT searchable).
        guard let text = d(.textExtraction), text.hasPresentContent else { return false }
        // FTS/index coverage present. Semantic embeddings are NOT required.
        guard let idx = d(.indexing), idx.hasPresentContent else { return false }
        return true
    }

    // MARK: - §7.2 evidence readiness (assumes search readiness)

    private static func evidenceReady(d: (SourceReadinessDimension) -> SourceReadinessDimensionRecord?) -> Bool {
        // structural extraction fully ready with at least one substantive block, all located.
        guard let structural = d(.structuralExtraction), structural.state == .ready,
              let total = structural.totalUnits, total > 0, (structural.completedUnits ?? 0) == total else { return false }
        // no blocking parser/persistence failure on the text path.
        if let text = d(.textExtraction), text.state == .failed { return false }
        return true
    }

    // MARK: - §7.3 analytical readiness (assumes evidence readiness)

    private static func analyticalReady(d: (SourceReadinessDimension) -> SourceReadinessDimensionRecord?) -> Bool {
        guard let analysis = d(.analyticalReadiness), analysis.state == .ready else { return false }
        // required typed-field dimension must be ready; conditional/notApplicable does not gate.
        if let typed = d(.typedFieldExtraction), typed.applicability == .required, typed.state != .ready { return false }
        return true
    }

    // MARK: - §7.4 completion-state precedence

    private static func completion(dims: [SourceReadinessDimensionRecord], blockedBy: (SourceReadinessCondition) -> Bool,
                                   searchReady: Bool, evidenceReady: Bool) -> SourceCompletionState {
        if evidenceReady { return .evidenceReady }
        if searchReady { return .searchablePartial }
        // Not searchable — apply the negative state that PREVENTS the positive, in precedence.
        if blockedBy(.encrypted) { return .encrypted }
        if blockedBy(.corrupt) { return .corrupt }
        if blockedBy(.deferred) { return .deferred }
        let core: Set<SourceReadinessDimension> = [.textExtraction, .structuralExtraction]
        if dims.contains(where: { $0.isApplicable && $0.state == .unsupported && core.contains($0.dimension) }) { return .unsupported }
        if dims.contains(where: { $0.isApplicable && $0.state == .failed
            && (core.contains($0.dimension) || $0.dimension == .preservation) }) { return .failed }
        return .preservedOnly
    }
}
