//
//  EvidenceAssessment.swift
//  Kalsmritikosh
//
//  S0.5 item 2 (Commit A — vocabulary + compatibility only; NO schema or call-site
//  changes yet). The single `EvidenceStatus` enum mixes five orthogonal ideas — how the
//  information was established, whether a human reviewed it, who proposed it, whether the
//  backing evidence is present, and whether it conflicts with other evidence. That mixing
//  is why `isAssertable` had to treat human confirmation as an evidentiary basis, which is
//  wrong: confirming a claim does not prove HOW it was originally established.
//
//  This file introduces the five separate dimensions + an aggregate + a lossy-but-
//  faithful compatibility adapter to/from the legacy enum. Nothing reads these yet;
//  adoption lands in Commit C. Pure value types.
//

import Foundation

/// How the information was established. Human review is deliberately NOT here.
public enum EvidenceBasis: String, Codable, Sendable, Hashable, CaseIterable {
    case directlyObserved
    case sourceAsserted
    case deterministicallyDerived
    case inferred
    /// Legacy rows whose true basis cannot be recovered — never guessed.
    case unknownLegacy
}

/// The human review disposition. Distinct from the evidence basis and from conflict.
public enum ReviewDisposition: String, Codable, Sendable, Hashable, CaseIterable {
    case unreviewed
    case confirmed
    case corrected
    case disputed
    case rejected
    case needsReview
}

/// Who or what proposed the item.
public enum ProposalOrigin: String, Codable, Sendable, Hashable, CaseIterable {
    case sourceExtraction
    case deterministicRule
    case modelProposed
    case userCreated
    case importedLegacy
}

/// Whether the backing evidence is actually available.
public enum AvailabilityStatus: String, Codable, Sendable, Hashable, CaseIterable {
    case present
    case partiallyAvailable
    case missingEvidence
    case unsupported
    case preservedOnly
}

/// Relational conflict state — derived from contradiction links where possible, and
/// persisted only in snapshots/caches. CONTRADICTED lives HERE, not in EvidenceBasis.
public enum ConflictStatus: String, Codable, Sendable, Hashable, CaseIterable {
    case none
    case contradicted
    case unresolved
    case resolved
}

/// The five orthogonal dimensions carried together. Replaces the single
/// `EvidenceStatus` field on domain models (adopted in Commit C). `legacyStatus`
/// preserves the original raw value so nothing is lost across the split.
public struct EvidenceAssessment: Codable, Sendable, Hashable {
    public let basis: EvidenceBasis
    public let review: ReviewDisposition
    public let origin: ProposalOrigin
    public let availability: AvailabilityStatus
    public let conflict: ConflictStatus
    public let legacyStatus: EvidenceStatus?

    public nonisolated init(
        basis: EvidenceBasis,
        review: ReviewDisposition = .unreviewed,
        origin: ProposalOrigin,
        availability: AvailabilityStatus = .present,
        conflict: ConflictStatus = .none,
        legacyStatus: EvidenceStatus? = nil
    ) {
        self.basis = basis
        self.review = review
        self.origin = origin
        self.availability = availability
        self.conflict = conflict
        self.legacyStatus = legacyStatus
    }
}

/// Bidirectional bridge between the legacy `EvidenceStatus` and the new
/// `EvidenceAssessment`. The forward map (legacy → assessment) is faithful and preserves
/// the raw value; the reverse (assessment → legacy) is intentionally lossy (five
/// dimensions collapse to one) and exists only so old readers keep working during
/// migration. Human review NEVER sets the evidence basis.
public enum LegacyEvidenceStatusAdapter {

    /// Legacy status → separated dimensions. The old enum does NOT record who/what
    /// created the item, so `ProposalOrigin` is `importedLegacy` for everything except
    /// `deterministicallyDerived` (whose rule origin IS implied by the basis). An old
    /// `.inferred` could be a model, a heuristic, or another reconstruction path — the
    /// legacy value alone can't establish `modelProposed`. `humanConfirmed/Corrected/
    /// Rejected` carry a review disposition but leave the basis `unknownLegacy` —
    /// confirmation does not establish how the underlying information was produced.
    public nonisolated static func decode(_ status: EvidenceStatus) -> EvidenceAssessment {
        switch status {
        case .directlyObserved:
            return .init(basis: .directlyObserved, origin: .importedLegacy, legacyStatus: status)
        case .sourceAsserted:
            return .init(basis: .sourceAsserted, origin: .importedLegacy, legacyStatus: status)
        case .deterministicallyDerived:
            return .init(basis: .deterministicallyDerived, origin: .deterministicRule, legacyStatus: status)
        case .inferred:
            return .init(basis: .inferred, origin: .importedLegacy, legacyStatus: status)
        case .contradicted:
            return .init(basis: .unknownLegacy, origin: .importedLegacy, conflict: .contradicted, legacyStatus: status)
        case .unsupported:
            return .init(basis: .unknownLegacy, origin: .importedLegacy, availability: .unsupported, legacyStatus: status)
        case .missingEvidence:
            return .init(basis: .unknownLegacy, origin: .importedLegacy, availability: .missingEvidence, legacyStatus: status)
        case .humanConfirmed:
            return .init(basis: .unknownLegacy, review: .confirmed, origin: .importedLegacy, legacyStatus: status)
        case .humanCorrected:
            return .init(basis: .unknownLegacy, review: .corrected, origin: .importedLegacy, legacyStatus: status)
        case .humanRejected:
            return .init(basis: .unknownLegacy, review: .rejected, origin: .importedLegacy, legacyStatus: status)
        }
    }

    /// Assessment → best-effort legacy status for old readers. Review disposition is
    /// DELIBERATELY not consulted: it must not override a known evidence basis, and it
    /// must never SYNTHESISE a new `humanConfirmed/Corrected/Rejected` value (those old
    /// values survive only when preserved in `legacyStatus`). `disputed` does not invent
    /// a contradiction. Priority: actual conflict → missing/unsupported availability →
    /// known basis → preserved legacy status → safe `unsupported` fallback. Lossy by
    /// design; callers needing the exact original read `assessment.legacyStatus`.
    public nonisolated static func encode(_ a: EvidenceAssessment) -> EvidenceStatus {
        if a.conflict == .contradicted || a.conflict == .unresolved { return .contradicted }
        switch a.availability {
        case .missingEvidence: return .missingEvidence
        case .unsupported:     return .unsupported
        case .present, .partiallyAvailable, .preservedOnly: break
        }
        switch a.basis {
        case .directlyObserved:          return .directlyObserved
        case .sourceAsserted:            return .sourceAsserted
        case .deterministicallyDerived:  return .deterministicallyDerived
        case .inferred:                  return .inferred
        case .unknownLegacy:             return a.legacyStatus ?? .unsupported
        }
    }
}
