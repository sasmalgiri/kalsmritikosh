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
    /// S5 (REASON-06, v181) — a real difference with an explanation recorded (e.g. two separate payments); not a
    /// contradiction, and not dismissed as an error. Needs the explanation in the note.
    case explained
    /// S5 (REASON-06, v181) — examined, and it cannot be resolved on what is in the case. It stays an open conflict
    /// (not waiting for a first review). Needs the reason in the note.
    case unresolved

    public var label: String {
        switch self {
        case .confirmed: return "Confirmed"
        case .dismissed: return "Dismissed"
        case .deferred: return "Deferred"
        case .explained: return "Explained"
        case .unresolved: return "Unresolved"
        }
    }

    /// The decisions offered when reviewing in place (explained and unresolved need a note).
    public static let reviewChoices: [CaseReviewDecision] = [.confirmed, .explained, .unresolved, .dismissed, .deferred]
    public var needsNote: Bool { self == .explained || self == .unresolved }

    /// The current disposition the existing desk table holds (deferred and unresolved hold none: undecided).
    var deskDecision: DeskDecision? {
        switch self {
        case .confirmed: return .confirmed
        case .dismissed, .explained: return .dismissed
        case .deferred, .unresolved: return nil
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
    /// S5 (REASON-12, v181) — knowledge object (a side's document) → the words of that side the decision was made on.
    /// Empty for a decision recorded before v181.
    public var passages: [UUID: String] = [:]

    public init(id: UUID, caseID: UUID, itemKind: DeskItemKind, itemID: String, decision: CaseReviewDecision,
                reason: CaseReviewReason?, note: String?, sourceVersions: [UUID: UUID], actor: String, decidedAt: Date,
                passages: [UUID: String] = [:]) {
        self.id = id; self.caseID = caseID; self.itemKind = itemKind; self.itemID = itemID; self.decision = decision
        self.reason = reason; self.note = note; self.sourceVersions = sourceVersions; self.actor = actor; self.decidedAt = decidedAt
        self.passages = passages
    }

    static func encodePassages(_ p: [UUID: String]) -> String? {
        guard !p.isEmpty, let data = try? JSONSerialization.data(withJSONObject: Dictionary(uniqueKeysWithValues: p.map { ($0.key.uuidString, $0.value) }),
                                                                 options: [.sortedKeys]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
    static func decodePassages(_ raw: String?) -> [UUID: String] {
        guard let raw, let data = raw.data(using: .utf8), let map = (try? JSONSerialization.jsonObject(with: data)) as? [String: String] else { return [:] }
        var out: [UUID: String] = [:]
        for (k, v) in map { if let k = UUID(uuidString: k) { out[k] = v } }
        return out
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
    /// The documents (knowledge objects) whose current version differs from the latest decision's in a way that matters
    /// (REASON-12: the words the decision was made on are no longer in it, or cannot be checked).
    public let changedObjects: [UUID]
    /// S5 (REASON-12) — documents with a new version that still contains, word for word, the passage the decision was
    /// made on. The change is not material to this item, so the decision stands (and says so).
    public var unchangedPassageObjects: [UUID] = []

    public init(history: [CaseReviewDecisionRecord], changedObjects: [UUID], unchangedPassageObjects: [UUID] = []) {
        self.history = history; self.changedObjects = changedObjects; self.unchangedPassageObjects = unchangedPassageObjects
    }

    public var latest: CaseReviewDecisionRecord? { history.last }
    public var isReopened: Bool { latest != nil && !changedObjects.isEmpty }
    /// The decision that currently holds (nil: open, or reopened by a changed source).
    public var current: CaseReviewDecision? { isReopened ? nil : latest?.decision }
    /// Waiting for the person: never decided, deferred, or reopened. (Unresolved is decided — it stays an open conflict.)
    public var awaitingReview: Bool { current == nil || current == .deferred }

    /// S5 (REASON-06) — where the item stands, in one of the named states. Never inferred from its absence on a screen.
    public var state: CaseConflictState {
        if isReopened { return .reopened }
        switch current {
        case nil: return .proposed
        case .confirmed?: return .confirmed
        case .explained?: return .explained
        case .dismissed?: return .dismissed
        case .unresolved?: return .unresolved
        case .deferred?: return .deferred
        }
    }

    /// The status from the decisions and each side's CURRENT version. A legacy decision without recorded
    /// versions is kept as made (nothing to compare); a side whose document no longer resolves counts as
    /// changed. `stillContains` (REASON-12): documents whose current version still holds the decided passage word for
    /// word — such a version change is not material and does not reopen the item.
    public static func compute(history: [CaseReviewDecisionRecord], currentVersions: [UUID: UUID?], stillContains: Set<UUID> = []) -> CaseItemReviewStatus {
        guard let latest = history.last else { return CaseItemReviewStatus(history: [], changedObjects: []) }
        let versionChanged = latest.sourceVersions.keys.sorted { $0.uuidString < $1.uuidString }.filter { object in
            guard let now = currentVersions[object] else { return false }   // a side not asked about: unchanged
            return now != latest.sourceVersions[object]
        }
        let immaterial = versionChanged.filter { stillContains.contains($0) && latest.passages[$0] != nil && (currentVersions[$0] ?? nil) != nil }
        return CaseItemReviewStatus(history: history, changedObjects: versionChanged.filter { !immaterial.contains($0) }, unchangedPassageObjects: immaterial)
    }

    /// The visible line: what holds now and why.
    public func label(names: [UUID: String] = [:]) -> String {
        guard let latest else { return "Not reviewed yet" }
        if isReopened {
            let docs = changedObjects.map { names[$0] ?? "a document" }
            let list = ListFormatter.localizedString(byJoining: docs)
            return "Reopened because \(list) changed since it was \(latest.decision.label.lowercased()) on \(latest.decidedAt.formatted(date: .abbreviated, time: .omitted))"
        }
        if !unchangedPassageObjects.isEmpty {
            let docs = ListFormatter.localizedString(byJoining: unchangedPassageObjects.map { names[$0] ?? "a document" })
            return latest.summary + " — \(docs) has a new version, but the passage this was decided on is unchanged there, so the decision stands"
        }
        return latest.summary
    }
}

/// S5 (REASON-06) — the named states of a case review item.
public nonisolated enum CaseConflictState: String, Sendable, Equatable, CaseIterable {
    case proposed, confirmed, explained, dismissed, unresolved, deferred, reopened, noLongerDetected
    public var label: String {
        switch self {
        case .proposed: return "Proposed by the check — not assessed yet"
        case .confirmed: return "Confirmed conflict"
        case .explained: return "Explained — a real difference, with the explanation recorded"
        case .dismissed: return "Dismissed, with the reason"
        case .unresolved: return "Unresolved — examined, cannot be settled on the case material"
        case .deferred: return "Deferred — still waiting"
        case .reopened: return "Reopened — a source changed since the decision"
        case .noLongerDetected: return "No longer detected — the last decision is kept"
        }
    }
    /// Still an open matter of the case (never resolved by disappearing from a view).
    public var isOpen: Bool { [.proposed, .confirmed, .unresolved, .deferred, .reopened].contains(self) }
}

/// S5 (REASON-06) — an item decided in this case that the check no longer produces (its pair is gone or out of scope).
/// It stays listed with its last decision; disappearing never resolves it.
public nonisolated struct CaseVanishedReviewItem: Sendable, Equatable, Identifiable {
    public let itemID: String
    public let history: [CaseReviewDecisionRecord]
    /// "no longer produced by the check" / "its documents are no longer in the case's scope".
    public let why: String
    public var id: String { itemID }
    public var state: CaseConflictState { .noLongerDetected }
    public var line: String {
        guard let last = history.last else { return "No longer detected (\(why))." }
        return "No longer detected (\(why)). Last decision: \(last.summary). The decision is kept and the item is not treated as resolved."
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
