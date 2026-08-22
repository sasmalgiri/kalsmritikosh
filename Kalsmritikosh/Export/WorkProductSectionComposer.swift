//
//  WorkProductSectionComposer.swift
//  Kalsmritikosh
//
//  PA-002/003/004 (persona-v2 Stage 1). The ResolvedClaim-native section-composer
//  architecture that every persona's work products build on.
//
//   • WorkProductContext — the ALREADY-selected, ALREADY-scoped, review-resolved input a
//     composer renders. Selection + subject/workspace scoping happen UPSTREAM; a composer
//     never queries repositories and never selects its own data.
//   • WorkProductSectionComposer — turns that context into one or more WorkProductSections.
//     Pure + deterministic + LLM-free. Composers evaluate `ResolvedClaim.effectiveAssessment`
//     (latest review applied), never the raw stored assessment, and never a forked status.
//   • WorkProductComposerRegistry — deterministic lookup keyed by a stable composer id;
//     rejects duplicate registrations.
//
//  Every production work-product template now assembles through this registry (see
//  WorkProductAssemblyService.plan). The legacy `WorkProductComposer.compose` is no longer on any
//  production route; it survives only as a WorkProduct factory in the export-gate unit tests.
//

import Foundation

/// A stable, comparable identity for a section composer (deterministic registry ordering).
public struct WorkProductComposerID: Sendable, Hashable, Comparable, RawRepresentable, CustomStringConvertible {
    public let rawValue: String
    public nonisolated init(rawValue: String) { self.rawValue = rawValue }
    public nonisolated init(_ rawValue: String) { self.rawValue = rawValue }
    public nonisolated static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    public nonisolated var description: String { rawValue }
}

/// Everything a composer needs, resolved and scoped upstream. A composer must render ONLY
/// these claims; it may not load more. Workspace / authority scope lives HERE (or in the
/// membership layer that produced the selection), never on the canonical Claim.
public struct WorkProductContext: Sendable {
    /// The already-selected, review-resolved, temporally-anchored, ORDERED claims. Selection,
    /// scoping, temporal placement, and ordering all happen upstream (ClaimSelectionService).
    public let selectedClaims: [SelectedClaim]
    /// Conflicts prepared upstream (explicitly linked to selected claims). Empty by default.
    public let selectedConflicts: [SelectedConflict]
    /// Gaps prepared upstream (scoped by persisted identity). Empty by default.
    public let selectedGaps: [SelectedGap]
    /// Display label for the subject of the output (titling only).
    public let subjectLabel: String
    /// The workspace this output belongs to, when scoped to one.
    public let workspaceID: UUID?
    /// The corpus snapshot the claim selection was taken against (provenance).
    public let corpusSnapshotID: UUID?

    /// Compatibility view: the resolved claims without their selection metadata, in order.
    public var claims: [ResolvedClaim] { selectedClaims.map(\.resolved) }

    public nonisolated init(selectedClaims: [SelectedClaim],
                            selectedConflicts: [SelectedConflict] = [],
                            selectedGaps: [SelectedGap] = [],
                            subjectLabel: String,
                            workspaceID: UUID? = nil, corpusSnapshotID: UUID? = nil) {
        self.selectedClaims = selectedClaims
        self.selectedConflicts = selectedConflicts
        self.selectedGaps = selectedGaps
        self.subjectLabel = subjectLabel
        self.workspaceID = workspaceID; self.corpusSnapshotID = corpusSnapshotID
    }

    /// Compatibility initializer: wrap bare resolved claims as explicitly-requested, undated
    /// selections (used by tests/callers that assemble a context without the selector).
    public nonisolated init(claims: [ResolvedClaim], subjectLabel: String,
                            workspaceID: UUID? = nil, corpusSnapshotID: UUID? = nil) {
        self.init(selectedClaims: claims.map {
            SelectedClaim(resolved: $0, selectionReason: .explicitlyRequested)
        }, subjectLabel: subjectLabel, workspaceID: workspaceID, corpusSnapshotID: corpusSnapshotID)
    }
}

public protocol WorkProductSectionComposer: Sendable {
    /// Stable identity for deterministic registry lookup.
    var id: WorkProductComposerID { get }
    /// The blueprint section kind this composer produces.
    var sectionKind: BlueprintSection.Kind { get }
    /// Compose zero or more sections from the already-scoped context. MUST be deterministic,
    /// LLM-free, evaluate `effectiveAssessment`, and never query repositories.
    func compose(_ context: WorkProductContext) -> [WorkProductSection]
}

/// Deterministic registry of section composers. Registration rejects duplicate ids so two
/// composers can never silently claim the same identity.
public struct WorkProductComposerRegistry: Sendable {
    public enum RegistrationError: Error, Equatable, CustomStringConvertible {
        case duplicate(WorkProductComposerID)
        public var description: String {
            switch self { case .duplicate(let id): return "duplicate composer registration: \(id)" }
        }
    }

    private var byID: [WorkProductComposerID: any WorkProductSectionComposer] = [:]
    public nonisolated init() {}

    /// Register a composer. Throws `RegistrationError.duplicate` if its id is already taken.
    public mutating func register(_ composer: any WorkProductSectionComposer) throws {
        guard byID[composer.id] == nil else { throw RegistrationError.duplicate(composer.id) }
        byID[composer.id] = composer
    }

    /// The composer with this id, or nil.
    public func composer(for id: WorkProductComposerID) -> (any WorkProductSectionComposer)? {
        byID[id]
    }

    /// All registered composers in a deterministic order (by id).
    public var all: [any WorkProductSectionComposer] {
        byID.keys.sorted().compactMap { byID[$0] }
    }

    /// The built-in composers, registered in a locked order. THROWS on a duplicate id so a
    /// misconfigured build fails at construction rather than silently dropping a composer
    /// (never `try?` this — a duplicate built-in is a programming error to be caught).
    public static func makeDefault() throws -> WorkProductComposerRegistry {
        var reg = WorkProductComposerRegistry()
        try reg.register(HistoryChronologyComposer())
        try reg.register(ClaimMatrixComposer())
        try reg.register(GapsAndConflictsComposer())
        try reg.register(SourcedSummaryComposer())
        try reg.register(InvestigationExecutiveSummaryComposer())
        try reg.register(InvestigationFindingsComposer())
        try reg.register(InvestigationLimitationsComposer())
        try reg.register(FactMemoComposer())
        return reg
    }
}

// MARK: - Shared precision-honest date phrasing

/// The single precision-honest date phrase for a selected claim, shared by every composer that
/// dates a row (chronology, investigation findings). A claim with a lineage-resolved anchor is
/// phrased by that anchor's precision; a claim with conflicting lineage dates is labelled
/// explicitly as conflicting; anything else is plainly "Undated". A date is NEVER guessed.
public enum SelectedClaimDatePhrase {
    public nonisolated static func phrase(for selected: SelectedClaim) -> String {
        if let anchor = selected.temporalAnchor {
            let tv = TemporalValue(start: anchor.start, end: anchor.end,
                                   precision: anchor.precision, confidence: 1.0)
            return HistoryNarrativeRenderer.datePhrase(tv) ?? "Undated"
        }
        return selected.isTemporallyAmbiguous ? "Undated (conflicting source dates)" : "Undated"
    }
}

// MARK: - Shared claim → section rendering

/// A fully-rendered selection: the source SelectedClaim, the output WorkProductClaim, and the
/// EXACT canonical decision + presentation that produced it. Composers that need the fine
/// presentation category (e.g. the claim matrix distinguishing corroborated from attributed,
/// which the coarser EpistemicStatus collapses) read `presentation` here.
public struct RenderedSelectedClaim: Sendable, Hashable {
    public let selectedClaim: SelectedClaim
    public let workProductClaim: WorkProductClaim
    public let decision: AssertabilityDecision
    public let presentation: ClaimPresentation
    public nonisolated init(selectedClaim: SelectedClaim, workProductClaim: WorkProductClaim,
                            decision: AssertabilityDecision, presentation: ClaimPresentation) {
        self.selectedClaim = selectedClaim; self.workProductClaim = workProductClaim
        self.decision = decision; self.presentation = presentation
    }
}

public extension ClaimPresentation {
    /// The one shared human-facing label per canonical presentation category. `.userAttributed`
    /// defaults to "User-confirmed"; the corrected variant is resolved with review context via
    /// `RenderedSelectedClaim.categoryLabel`.
    var displayLabel: String {
        switch self {
        case .fact:          return "Observed fact"
        case .attributed:    return "Source-reported"
        case .corroborated:  return "Independently corroborated"
        case .derivation:    return "Deterministically derived"
        case .userAttributed: return "User-confirmed"
        case .inference:     return "Inference"
        case .conflict:      return "Conflicting accounts"
        }
    }
}

public extension RenderedSelectedClaim {
    /// The presentation label, refined for a corrected user-attributed claim (User-corrected
    /// vs User-confirmed) using the effective review disposition. A corrected claim is never
    /// mislabelled as merely confirmed.
    var categoryLabel: String {
        if presentation == .userAttributed,
           selectedClaim.resolved.effectiveAssessment.review == .corrected {
            return "User-corrected"
        }
        return presentation.displayLabel
    }
}

/// Deterministic helper shared by ResolvedClaim-native composers: turn one selected claim
/// into a cited WorkProductClaim using the CANONICAL trust pipeline — AssertabilityPolicy on
/// the EFFECTIVE assessment, with the claim's own independence keys — never a parallel trust
/// rule. Returns nil for a claim the policy refuses (fail-closed).
public enum ResolvedClaimRenderer {

    /// Full render preserving the exact decision + presentation. Uses
    /// `SelectedClaim.independenceKeys` so genuinely independent sources can corroborate.
    public nonisolated static func render(_ selected: SelectedClaim) -> RenderedSelectedClaim? {
        let claim = selected.resolved.claim
        let evidence = claim.evidence.map {
            AssertabilityEvidence(objectID: $0.objectID, blockID: $0.blockID,
                                  independenceKey: selected.independenceKeys[$0.objectID])
        }
        let decision = AssertabilityContextBuilder()
            .decision(assessment: selected.resolved.effectiveAssessment, evidence: evidence,
                      hasReproducibleDerivation: selected.hasReproducibleDerivation).decision
        guard let presentation = ClaimPresentation(decision: decision) else { return nil }  // refuse

        let citations = claim.evidence.enumerated().map { (i, ev) in
            CitationRecord(sourceVersionID: ev.sourceVersionID,
                           evidenceBlockIDs: ev.blockID.map { [$0] } ?? [],
                           displayLabel: "[\(i + 1)]",
                           sourceTitle: claim.subjectLabel)
        }
        // Contradicting evidence is carried on its own role, kept separate from support.
        let supporting = zip(citations, claim.evidence).filter { $0.1.role != .contradicts }.map(\.0)
        let contradicting = zip(citations, claim.evidence).filter { $0.1.role == .contradicts }.map(\.0)

        let wp = WorkProductClaim(
            text: claim.statement,                       // id defaults per output occurrence
            status: epistemicStatus(for: presentation),
            supporting: supporting,
            contradicting: contradicting,
            confidence: claim.confidence,
            reviewState: selected.resolved.effectiveAssessment.review.rawValue,
            sourceClaimID: claim.id,                     // canonical Claim identity carried here
            assertabilityDecision: decision)             // exact decision → decision-aware validation
        return RenderedSelectedClaim(selectedClaim: selected, workProductClaim: wp,
                                     decision: decision, presentation: presentation)
    }

    /// Compatibility wrapper: render a bare resolved claim (+ optional keys) to just the
    /// WorkProductClaim. Used by the chronology composer.
    public nonisolated static func renderedClaim(_ resolved: ResolvedClaim,
                                                 independenceKeys: [KnowledgeObject.ID: String] = [:]) -> WorkProductClaim? {
        render(SelectedClaim(resolved: resolved, selectionReason: .explicitlyRequested,
                             independenceKeys: independenceKeys))?.workProductClaim
    }

    /// Map the canonical ClaimPresentation to the coarser export EpistemicStatus vocabulary.
    /// This is a display mapping only — the trust DECISION is AssertabilityPolicy's, and the
    /// fine presentation is preserved on RenderedSelectedClaim for composers that need it.
    private nonisolated static func epistemicStatus(for p: ClaimPresentation) -> EpistemicStatus {
        switch p {
        case .fact:                    return .directEvidence
        case .corroborated, .attributed: return .sourceAssertion
        case .derivation:              return .deterministicDerivation
        case .userAttributed:          return .humanNote
        case .inference, .conflict:    return .inference
        }
    }
}

// MARK: - Shared claim bucketing (sourced summary, fact memo)

/// The surfaceable selected claims split by how they are grounded — the single bucketing rule
/// shared by the summary-style composers. Each claim is rendered ONCE through the canonical
/// ResolvedClaimRenderer (refused dropped) and prefixed with its corrected-aware category label;
/// assertive grounding → `supported`, `.inference` → `qualified`, `.conflict` → `claimLevelConflicts`.
/// Stable input order is preserved within each bucket.
public struct BucketedSelectedClaims: Sendable {
    public let supported: [WorkProductClaim]
    public let qualified: [WorkProductClaim]
    public let claimLevelConflicts: [WorkProductClaim]
}

public enum WorkProductClaimBucketing {
    public nonisolated static func bucket(_ selectedClaims: [SelectedClaim]) -> BucketedSelectedClaims {
        var supported: [WorkProductClaim] = []
        var qualified: [WorkProductClaim] = []
        var conflicts: [WorkProductClaim] = []
        for selected in selectedClaims {
            guard let rendered = ResolvedClaimRenderer.render(selected) else { continue }   // refuse excluded
            var wp = rendered.workProductClaim
            wp.text = "\(rendered.categoryLabel): \(wp.text)"    // exact category label (corrected-aware)
            switch rendered.presentation {
            case .fact, .attributed, .corroborated, .derivation, .userAttributed:
                supported.append(wp)
            case .inference:
                qualified.append(wp)
            case .conflict:
                conflicts.append(wp)
            }
        }
        return BucketedSelectedClaims(supported: supported, qualified: qualified, claimLevelConflicts: conflicts)
    }
}

// MARK: - Shared disclosure rendering (gaps/conflicts composer, fact memo)

/// The workspace-scoped CONFLICTS and GAPS prepared upstream, rendered into disclosure claims by
/// the single shared rule. A conflict shows both sides without choosing or averaging (two
/// separate citation lists); a gap is inference-framed and citation-free (absence is not proof).
/// Both are `.inference` status, so they never count as material assertions or trip the
/// fail-closed export gate. Deterministic ordering (severity then id; kind then confidence then id).
public enum WorkProductDisclosureRendering {

    public nonisolated static func conflictClaims(_ conflicts: [SelectedConflict]) -> [WorkProductClaim] {
        conflicts.sorted { a, b in
            severityRank(a.severity) != severityRank(b.severity)
                ? severityRank(a.severity) < severityRank(b.severity)       // high first
                : a.id.uuidString < b.id.uuidString
        }.map { c in
            let cites = c.evidence.enumerated().map { (i, ev) in
                CitationRecord(sourceVersionID: ev.sourceVersionID,
                               evidenceBlockIDs: ev.blockID.map { [$0] } ?? [],
                               displayLabel: "[\(i + 1)]", sourceTitle: c.description)
            }
            let supporting = zip(cites, c.evidence).filter { $0.1.role != .contradicts }.map(\.0)
            let contradicting = zip(cites, c.evidence).filter { $0.1.role == .contradicts }.map(\.0)
            return WorkProductClaim(
                text: "Conflicting accounts:\nA: \(c.sideA)\nB: \(c.sideB)",
                status: .inference,                          // a disclosure, not a source assertion
                supporting: supporting, contradicting: contradicting)
        }
    }

    public nonisolated static func gapClaims(_ gaps: [SelectedGap]) -> [WorkProductClaim] {
        gaps.sorted { a, b in
            if a.kind.rawValue != b.kind.rawValue { return a.kind.rawValue < b.kind.rawValue }
            if a.confidence != b.confidence { return a.confidence > b.confidence }   // higher confidence first
            return a.id.uuidString < b.id.uuidString
        }.map { g in
            WorkProductClaim(
                text: "Missing evidence: \(g.description)\nReason: \(g.reason)\nThe expected material may exist outside the indexed archive.",
                status: .inference, supporting: [], contradicting: [])
        }
    }

    private nonisolated static func severityRank(_ s: Contradiction.Severity) -> Int {
        switch s { case .high: return 0; case .medium: return 1; case .low: return 2 }
    }
}
