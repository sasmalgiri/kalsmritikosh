//
//  InvestigationDeskReview.swift
//  Kalsmritikosh
//
//  INV-08 (Source reliability) + INV-12 (Contradiction & gap desk) — persona domain (schema v100). The
//  Investigator REUSES the shared canonical authorities (SourceReliabilityAssessmentRepository,
//  ContradictionsRepository, GapNodeRepository) and adds only a thin, case-scoped human review decision that
//  REFERENCES a shared item by id. It forks none of them. Truth boundaries this model preserves:
//    • a reported statement / reliability rating ≠ a verified fact
//    • a contradiction ≠ a resolved truth (both sides are always preserved)
//    • a gap ≠ a guessed answer (absence is not proof)
//

import Foundation

/// The kind of shared canonical item a case review dispositions.
public nonisolated enum DeskItemKind: String, Codable, Sendable, Equatable, CaseIterable {
    case reliability   // item_id = source_version_id (source_reliability_assessments)
    case contradiction // item_id = contradiction id
    case gap           // item_id = gap_nodes id
}

/// The human disposition of an item WITHIN a case. `confirmed` = the investigator accepts the item into the
/// case record; `dismissed` = the investigator sets it aside for this case. Neither mutates the shared item.
public nonisolated enum DeskDecision: String, Codable, Sendable, Equatable, CaseIterable {
    case confirmed
    case dismissed
}

public nonisolated struct InvestigationDeskReview: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let caseID: UUID
    public let itemKind: DeskItemKind
    public let itemID: String
    public let decision: DeskDecision
    public let note: String?
    public let actor: String
    public let createdAt: Date
    public let updatedAt: Date

    public nonisolated init(id: UUID, caseID: UUID, itemKind: DeskItemKind, itemID: String, decision: DeskDecision,
                            note: String?, actor: String, createdAt: Date, updatedAt: Date) {
        self.id = id; self.caseID = caseID; self.itemKind = itemKind; self.itemID = itemID; self.decision = decision
        self.note = note; self.actor = actor; self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}

// MARK: - INV-08 reliability schedule projection

/// One row of the case Source Reliability Schedule: an authorized source version, its effective shared
/// reliability assessment (nil = not yet rated — a rating is never invented), the case's review disposition,
/// and whether this is a single-source case (independence/corroboration signal).
public nonisolated struct ReliabilityScheduleEntry: Sendable {
    public let sourceVersionID: UUID
    public let assessment: SourceReliabilityAssessment?
    public let review: InvestigationDeskReview?
    public let isSingleSource: Bool

    public nonisolated init(sourceVersionID: UUID, assessment: SourceReliabilityAssessment?,
                            review: InvestigationDeskReview?, isSingleSource: Bool) {
        self.sourceVersionID = sourceVersionID; self.assessment = assessment; self.review = review; self.isSingleSource = isSingleSource
    }
}

// MARK: - INV-12 desk projections

/// A contradiction inside the case scope, paired with the case's review disposition. Both sides (claimA /
/// claimB) are carried verbatim from the shared Contradiction — the desk never averages them into one truth.
public nonisolated struct CaseContradictionItem: Sendable, Equatable {
    public let contradiction: Contradiction
    public let review: InvestigationDeskReview?
    public nonisolated init(contradiction: Contradiction, review: InvestigationDeskReview?) {
        self.contradiction = contradiction; self.review = review
    }
}

/// A gap inside the case scope, paired with the case's review disposition. A gap carries its `reason`
/// verbatim from the shared GapNode — its presence is a missing-evidence signal, never proof of wrongdoing.
public nonisolated struct CaseGapItem: Sendable, Equatable {
    public let gap: GapNode
    public let review: InvestigationDeskReview?
    public nonisolated init(gap: GapNode, review: InvestigationDeskReview?) {
        self.gap = gap; self.review = review
    }
}

public nonisolated enum InvestigationDeskError: Error, Sendable, Equatable {
    case caseNotFound(UUID)
    case caseClosed(UUID)
    case sourceOutOfScope(UUID)          // a source version not authorized for the case
    case contradictionNotFound(UUID)
    case contradictionOutOfScope(UUID)   // its evidence is not inside the case scope
    case gapNotFound(UUID)
    case gapOutOfScope(UUID)             // its evidence is not inside the case scope
    case blankActor
}
