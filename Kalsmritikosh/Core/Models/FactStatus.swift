//
//  FactStatus.swift
//  Kalsmritikosh
//
//  The evidence-status vocabulary for the Fact Status Matrix (T14). Every
//  reconstructed item the app surfaces is placed into exactly ONE status so
//  the user can tell, at a glance, what is directly proven from what is
//  inferred, contradicted, or simply missing. This is the product's honesty
//  contract: an AI inference is NEVER presented as established truth.
//
//  Foundation-only by design — the model layer stays free of SwiftUI. The
//  UI maps each status to a colour/badge in FactStatusView; the display
//  strings and SF Symbols live here so the vocabulary has one home.
//

import Foundation

/// The status assigned to a reconstructed fact by `FactStatusClassifier`.
/// Ordered by presentation precedence (see the classifier): a fact that is
/// in conflict is shown as `.contradicted`, never as `.proven`.
public nonisolated enum FactStatus: String, Codable, Sendable, CaseIterable, Hashable {
    /// Directly visible in reliable structured evidence (e.g. an email
    /// header timestamp, a From/To field). The strongest category.
    case proven
    /// Reconstructed from evidence rather than directly asserted — a derived
    /// or likely event. Real, but the app owns the inference.
    case inferred
    /// Conflicts with other evidence. Both sides are always preserved.
    case contradicted
    /// A necessary-but-absent item the archive is missing (a "silence").
    case missing
    /// A claim with no valid supporting evidence, or below the trust floor.
    /// Never silently hidden — surfaced under its own status.
    case unverified

    /// Short label shown on the status chip and the tab counts.
    public var displayName: String {
        switch self {
        case .proven:       return "Proven"
        case .inferred:     return "Inferred"
        case .contradicted: return "Contradicted"
        case .missing:      return "Missing"
        case .unverified:   return "Unverified"
        }
    }

    /// SF Symbol for the status chip.
    public var systemImage: String {
        switch self {
        case .proven:       return "checkmark.seal.fill"
        case .inferred:     return "wand.and.stars"
        case .contradicted: return "exclamationmark.triangle.fill"
        case .missing:      return "questionmark.square.dashed"
        case .unverified:   return "circle.dotted"
        }
    }
}

/// Where a `FactStatusItem` was derived from — so the UI can route a tap to
/// the right detail surface and the tabs can filter by origin.
public nonisolated enum FactSourceKind: String, Codable, Sendable, Hashable {
    case event
    case assertion
    case contradiction
    case gap
}

/// A single row in the Fact Status Matrix: one reconstructed fact plus the
/// classifier's verdict. `reason` is ALWAYS specific — a blanket reason is a
/// bug, mirroring the GapNode contract.
public nonisolated struct FactStatusItem: Identifiable, Sendable, Hashable {
    public let id: UUID
    public let status: FactStatus
    public let title: String
    /// Why the classifier assigned THIS status to THIS item. Specific,
    /// human-readable, never generic.
    public let reason: String
    /// The fact's date, when it has one (events do; gaps/contradictions may not).
    public let date: Date?
    /// 0…1 trust in the fact itself (not in the classification).
    public let confidence: Double
    /// KnowledgeObject IDs that back this fact — resolvable to real sources.
    public let evidenceObjectIDs: [UUID]
    public let sourceKind: FactSourceKind
    /// For contradictions: the opposing claim, so both sides show paired.
    public let secondaryText: String?

    public nonisolated init(
        id: UUID = UUID(),
        status: FactStatus,
        title: String,
        reason: String,
        date: Date? = nil,
        confidence: Double,
        evidenceObjectIDs: [UUID] = [],
        sourceKind: FactSourceKind,
        secondaryText: String? = nil
    ) {
        self.id = id
        self.status = status
        self.title = title
        self.reason = reason
        self.date = date
        self.confidence = max(0.0, min(1.0, confidence))
        self.evidenceObjectIDs = evidenceObjectIDs
        self.sourceKind = sourceKind
        self.secondaryText = secondaryText
    }
}
