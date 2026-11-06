//
//  CaseItemReview.swift
//  Kalsmritikosh
//
//  Owner's implementation plan 2026-11-04, P0-C 3–4 — a case review item (a contradiction today) is
//  confirmed, dismissed or deferred where it is shown, with the reason, and the decision is kept against
//  the item's stable identity AND the source version each side was read from (schema v170
//  investigation_review_decisions, append-only). An unchanged rerun finds the same item id and the same
//  versions, so a dismissal stays dismissed; when a side's document is revised the item reopens and says
//  which document changed. Earlier decisions stay in the history. A decision never touches either
//  source or the shared item; it records what this case decided.
//

import Foundation

/// What the person decided about one case review item.
public nonisolated enum CaseReviewDecision: String, Codable, Sendable, Equatable, CaseIterable {
    case confirmed
    case dismissed
    case deferred

    public var label: String {
        switch self {
        case .confirmed: return "Confirmed"
        case .dismissed: return "Dismissed"
        case .deferred: return "Deferred"
        }
    }

    /// The current disposition the existing desk table holds (deferred holds none: undecided).
    var deskDecision: DeskDecision? {
        switch self {
        case .confirmed: return .confirmed
        case .dismissed: return .dismissed
        case .deferred: return nil
        }
    }
}

/// Why an apparent contradiction was set aside or put off. "Other" needs the note.
public nonisolated enum CaseReviewReason: String, Codable, Sendable, Equatable, CaseIterable, Identifiable {
    case differentEvent
    case differentPerson
    case changedEstimate
    case transcriptionError
    case insufficientContext
    case other

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .differentEvent: return "Different event or transaction"
        case .differentPerson: return "Different person"
        case .changedEstimate: return "Changed or updated estimate"
        case .transcriptionError: return "Transcription or typing error"
        case .insufficientContext: return "Not enough context to decide"
        case .other: return "Other (say why in the note)"
        }
    }
}

/// One recorded decision, as it was made: who, when, why, and the version of each side's document.
public nonisolated struct CaseReviewDecisionRecord: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let caseID: UUID
    public let itemKind: DeskItemKind
    public let itemID: String
    public let decision: CaseReviewDecision
    public let reason: CaseReviewReason?
    public let note: String?
    /// Knowledge object (a side's document) → the source version it was read from at decision time.
    public let sourceVersions: [UUID: UUID]
    public let actor: String
    public let decidedAt: Date

    public init(id: UUID, caseID: UUID, itemKind: DeskItemKind, itemID: String, decision: CaseReviewDecision,
                reason: CaseReviewReason?, note: String?, sourceVersions: [UUID: UUID], actor: String, decidedAt: Date) {
        self.id = id; self.caseID = caseID; self.itemKind = itemKind; self.itemID = itemID; self.decision = decision
        self.reason = reason; self.note = note; self.sourceVersions = sourceVersions; self.actor = actor; self.decidedAt = decidedAt
    }

    /// The plain line shown in the history.
    public var summary: String {
        var s = "\(decision.label) by \(actor) on \(decidedAt.formatted(date: .abbreviated, time: .shortened))"
        if let reason { s += " — \(reason.label)" }
        if let note, !note.isEmpty { s += ": \(note)" }
        return s
    }

    static func encodeVersions(_ v: [UUID: UUID]) -> String {
        let pairs = v.map { "\"\($0.key.uuidString)\":\"\($0.value.uuidString)\"" }.sorted()
        return "{" + pairs.joined(separator: ",") + "}"
    }
    static func decodeVersions(_ raw: String?) -> [UUID: UUID] {
        guard let raw, let data = raw.data(using: .utf8),
              let map = (try? JSONSerialization.jsonObject(with: data)) as? [String: String] else { return [:] }
        var out: [UUID: UUID] = [:]
        for (k, v) in map { if let k = UUID(uuidString: k), let v = UUID(uuidString: v) { out[k] = v } }
        return out
    }
}

/// Where one item stands in this case: never decided, decided (still on the versions it was decided on),
/// or reopened because a side's document changed since the latest decision.
public nonisolated struct CaseItemReviewStatus: Sendable, Equatable {
    /// Every decision, oldest first (never rewritten).
    public let history: [CaseReviewDecisionRecord]
    /// The documents (knowledge objects) whose current version differs from the latest decision's.
    public let changedObjects: [UUID]

    public init(history: [CaseReviewDecisionRecord], changedObjects: [UUID]) {
        self.history = history; self.changedObjects = changedObjects
    }

    public var latest: CaseReviewDecisionRecord? { history.last }
    public var isReopened: Bool { latest != nil && !changedObjects.isEmpty }
    /// The decision that currently holds (nil: open, or reopened by a changed source).
    public var current: CaseReviewDecision? { isReopened ? nil : latest?.decision }
    /// Waiting for the person: never decided, deferred, or reopened.
    public var awaitingReview: Bool { current == nil || current == .deferred }

    /// The status from the decisions and each side's CURRENT version. A legacy decision without recorded
    /// versions is kept as made (nothing to compare); a side whose document no longer resolves counts as
    /// changed.
    public static func compute(history: [CaseReviewDecisionRecord], currentVersions: [UUID: UUID?]) -> CaseItemReviewStatus {
        guard let latest = history.last else { return CaseItemReviewStatus(history: [], changedObjects: []) }
        let changed = latest.sourceVersions.keys.sorted { $0.uuidString < $1.uuidString }.filter { object in
            guard let now = currentVersions[object] else { return false }   // a side not asked about: unchanged
            return now != latest.sourceVersions[object]
        }
        return CaseItemReviewStatus(history: history, changedObjects: changed)
    }

    /// The visible line: what holds now and why.
    public func label(names: [UUID: String] = [:]) -> String {
        guard let latest else { return "Not reviewed yet" }
        if isReopened {
            let docs = changedObjects.map { names[$0] ?? "a document" }
            let list = ListFormatter.localizedString(byJoining: docs)
            return "Reopened because \(list) changed since it was \(latest.decision.label.lowercased()) on \(latest.decidedAt.formatted(date: .abbreviated, time: .omitted))"
        }
        return latest.summary
    }
}

/// A contradiction inside the case scope with its review status and each side's current version.
public nonisolated struct CaseContradictionReviewItem: Sendable, Equatable, Identifiable {
    public let contradiction: Contradiction
    public let status: CaseItemReviewStatus
    /// Each side's document → its current source version (nil: no longer resolves).
    public let currentVersions: [UUID: UUID?]
    public var id: UUID { contradiction.id }

    public init(contradiction: Contradiction, status: CaseItemReviewStatus, currentVersions: [UUID: UUID?]) {
        self.contradiction = contradiction; self.status = status; self.currentVersions = currentVersions
    }
}
