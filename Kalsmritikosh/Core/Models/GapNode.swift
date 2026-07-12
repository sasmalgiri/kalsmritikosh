//
//  GapNode.swift
//  Kalsmritikosh
//
//  System 3 — Gap / "missing link" detection. A GapNode records an
//  expected-but-absent item in the archive: a reply whose original was
//  never ingested, a hole in a numbered sequence, a referenced document
//  that isn't present. These are the historiographical "silences" — the
//  discipline is to flag only what a real pattern implies is missing,
//  and to keep every such claim low-confidence and reasoned. Detection
//  is purely rule-based (see Knowledge/Ledger/GapDetector.swift); no LLM
//  is involved and nothing here writes to the ledger.
//
//  Persisted in `gap_nodes` (schema v31). Dismissed gaps are kept, not
//  deleted — the user's core directive is to preserve everything and
//  rank by trust.
//

import Foundation

/// The kind of gap detected. Each case carries a human-readable label
/// and an SF Symbol for the History-tab "gaps" surface.
public nonisolated enum GapKind: String, Codable, Sendable, CaseIterable {
    /// A reply/forward whose parent message isn't in the archive.
    case threadParent
    /// A hole in an otherwise contiguous numbered sequence.
    case sequenceHole
    /// A referenced document (e.g. "invoice #42") that was never ingested.
    case danglingReference
    /// A break in an established periodic cadence (monthly report, etc.).
    case cadenceBreak
    /// A5.7 — a message references an attachment ("see attached") but no
    /// attachment was ingested with it. Absence ≠ wrongdoing: the file may
    /// simply not have been included in the export.
    case referencedAttachment

    /// Short label shown in the UI.
    public var displayName: String {
        switch self {
        case .threadParent:         return "Missing Original"
        case .sequenceHole:         return "Sequence Gap"
        case .danglingReference:    return "Dangling Reference"
        case .cadenceBreak:         return "Cadence Break"
        case .referencedAttachment: return "Missing Attachment"
        }
    }

    /// SF Symbol name for the gap row.
    public var systemImage: String {
        switch self {
        case .threadParent:         return "arrowshape.turn.up.left"
        case .sequenceHole:         return "number.square"
        case .danglingReference:    return "link.badge.plus"
        case .cadenceBreak:         return "calendar.badge.exclamationmark"
        case .referencedAttachment: return "paperclip.badge.ellipsis"
        }
    }
}

/// A single detected gap. Every field that anchors the gap to the
/// ledger (near entity, surrounding events, evidence object) is
/// optional because different gap kinds anchor differently.
public nonisolated struct GapNode: Sendable, Identifiable, Hashable {
    public let id: UUID
    public let kind: GapKind
    public let description: String
    /// Why the detector believes this item is missing — always present,
    /// always specific. Blanket "something might be missing" is a bug.
    public let reason: String
    /// 0..1 — gaps are inherently low-confidence inferences about
    /// absence. The detector never emits a high-confidence gap.
    public let confidence: Double
    public let nearEntity: String?
    public let beforeEvent: UUID?
    public let afterEvent: UUID?
    public let evidenceObjectID: UUID?
    public let detectedAt: Date
    /// User-dismissed gaps stay in the ledger (never deleted); this
    /// flag hides them from the default surface.
    public var dismissed: Bool

    public nonisolated init(
        id: UUID = UUID(),
        kind: GapKind,
        description: String,
        reason: String,
        confidence: Double = 0.3,
        nearEntity: String? = nil,
        beforeEvent: UUID? = nil,
        afterEvent: UUID? = nil,
        evidenceObjectID: UUID? = nil,
        detectedAt: Date = Date(),
        dismissed: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.description = description
        self.reason = reason
        self.confidence = max(0.0, min(1.0, confidence))
        self.nearEntity = nearEntity
        self.beforeEvent = beforeEvent
        self.afterEvent = afterEvent
        self.evidenceObjectID = evidenceObjectID
        self.detectedAt = detectedAt
        self.dismissed = dismissed
    }
}
