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
//  The legacy `WorkProductComposer.compose` remains operational OUTSIDE this registry during
//  migration; sections move onto this protocol one composer at a time.
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
        return reg
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
            text: claim.statement,
            status: epistemicStatus(for: presentation),
            supporting: supporting,
            contradicting: contradicting,
            confidence: claim.confidence,
            reviewState: selected.resolved.effectiveAssessment.review.rawValue)
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
