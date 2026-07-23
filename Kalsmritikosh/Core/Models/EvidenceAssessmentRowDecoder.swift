//
//  EvidenceAssessmentRowDecoder.swift
//  Kalsmritikosh
//
//  S0.5 item 2, Commit C2 (infra). ONE place that turns stored DB columns into an
//  EvidenceAssessment, so the three repositories (generic_facts / temporal_claims /
//  history_items) never re-implement fallback logic three different ways. Per-FIELD
//  precedence — a single malformed/unknown dimension is replaced with a conservative
//  default for THAT field only; it never discards the whole row:
//
//      valid dimensional value → valid legacy_status → valid status → conservative default
//
//  Conservative field defaults: basis .unknownLegacy, review .needsReview, origin
//  .importedLegacy, availability .partiallyAvailable, conflict .none (unless a real
//  contradiction relation is supplied). Pure; deterministic; LLM-free.
//

import Foundation

public enum EvidenceAssessmentRowDecoder {

    /// Raw column values as read from a row (any may be nil / malformed).
    public struct Row: Sendable, Hashable {
        public var evidenceBasis: String?
        public var reviewDisposition: String?
        public var proposalOrigin: String?
        public var availabilityStatus: String?
        public var conflictStatus: String?
        public var legacyStatus: String?
        public var status: String?
        public nonisolated init(evidenceBasis: String? = nil, reviewDisposition: String? = nil,
                                proposalOrigin: String? = nil, availabilityStatus: String? = nil,
                                conflictStatus: String? = nil, legacyStatus: String? = nil,
                                status: String? = nil) {
            self.evidenceBasis = evidenceBasis; self.reviewDisposition = reviewDisposition
            self.proposalOrigin = proposalOrigin; self.availabilityStatus = availabilityStatus
            self.conflictStatus = conflictStatus; self.legacyStatus = legacyStatus; self.status = status
        }
    }

    private static func parsedStatus(_ raw: String?) -> EvidenceStatus? {
        raw.flatMap(EvidenceStatus.init(rawValue:))
    }

    /// The legacy EvidenceStatus for this row: a VALID `legacy_status` is preferred, but a
    /// non-null-yet-malformed `legacy_status` must NOT block a valid `status` — each is
    /// parsed independently (valid legacy_status → valid status → nil).
    static func legacyEvidenceStatus(_ row: Row) -> EvidenceStatus? {
        parsedStatus(row.legacyStatus) ?? parsedStatus(row.status)
    }

    /// The assessment implied by the row's legacy status. Nil when neither legacy_status
    /// nor status is a recognisable EvidenceStatus.
    static func legacyFallback(_ row: Row) -> EvidenceAssessment? {
        legacyEvidenceStatus(row).map(LegacyEvidenceStatusAdapter.decode)
    }

    /// A derived conflict only OVERRIDES when it's meaningful. `.none` means "no override"
    /// — it must NOT erase a stored or legacy contradicted/unresolved/resolved state.
    static func meaningfulDerivedConflict(_ value: ConflictStatus?) -> ConflictStatus? {
        guard let value, value != .none else { return nil }
        return value
    }

    /// Decode a generic_facts / temporal_claims row. `derivedConflict` (from a real
    /// contradiction relation) wins over the stored/legacy conflict ONLY when meaningful.
    public static func decode(_ row: Row, derivedConflict: ConflictStatus? = nil) -> EvidenceAssessment {
        let fb = legacyFallback(row)
        let basis = EvidenceBasis(rawValue: row.evidenceBasis ?? "") ?? fb?.basis ?? .unknownLegacy
        let review = ReviewDisposition(rawValue: row.reviewDisposition ?? "") ?? fb?.review ?? .needsReview
        let origin = ProposalOrigin(rawValue: row.proposalOrigin ?? "") ?? fb?.origin ?? .importedLegacy
        let availability = AvailabilityStatus(rawValue: row.availabilityStatus ?? "") ?? fb?.availability ?? .partiallyAvailable
        // Precedence: meaningful derived → stored dimension → legacy → none.
        let conflict = meaningfulDerivedConflict(derivedConflict)
            ?? ConflictStatus(rawValue: row.conflictStatus ?? "")
            ?? fb?.conflict ?? .none
        // Preserve the exact original raw value (independently-parsed legacy status).
        let legacy = legacyEvidenceStatus(row)
        return EvidenceAssessment(basis: basis, review: review, origin: origin,
                                  availability: availability, conflict: conflict, legacyStatus: legacy)
    }

    /// Decode a history_items row. Review precedence is SPECIAL here (§C2):
    ///   review_disposition → mapped legacy review_status → legacy-status review → needsReview.
    /// Conflict is normally DERIVED (contradiction_group_id present) — pass it in.
    public static func decodeHistoryItem(_ row: Row, historyReviewStatusRaw: String?,
                                         derivedConflict: ConflictStatus?) -> EvidenceAssessment {
        let base = decode(row, derivedConflict: derivedConflict)
        let review = ReviewDisposition(rawValue: row.reviewDisposition ?? "")
            ?? mapHistoryReviewStatus(historyReviewStatusRaw)
            ?? legacyFallback(row)?.review
            ?? .needsReview
        return EvidenceAssessment(basis: base.basis, review: review, origin: base.origin,
                                  availability: base.availability, conflict: base.conflict,
                                  legacyStatus: base.legacyStatus)
    }

    /// Map the history review vocabulary (unreviewed/accepted/rejected/corrected) to the
    /// shared ReviewDisposition. Nil when the raw value isn't a known history review status.
    static func mapHistoryReviewStatus(_ raw: String?) -> ReviewDisposition? {
        guard let raw, let s = HistoryReviewStatus(rawValue: raw) else { return nil }
        switch s {
        case .unreviewed: return .unreviewed
        case .accepted:   return .confirmed
        case .corrected:  return .corrected
        case .rejected:   return .rejected
        }
    }
}
