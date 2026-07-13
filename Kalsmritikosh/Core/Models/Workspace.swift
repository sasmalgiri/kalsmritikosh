//
//  Workspace.swift
//  Kalsmritikosh
//
//  Persona features Epic 1 (F1 + F2) — the shared evidence-work model.
//  ONE engine, many work-product templates. A Workspace is a bounded,
//  filtered VIEW over the single ledger (a matter / investigation /
//  research question / personal issue); it never duplicates evidence.
//  Review tags + append-only review decisions + saved views are all
//  persona-agnostic here — persona templates (F6) only rename labels and
//  change defaults, never the stored semantics.
//

import Foundation

// MARK: - Workspace

/// The persona template a workspace was created from. Changes default
/// tags, views, terminology, and export layout — NOT the truth or
/// evidence model. `raw` matches the `template_type` column.
public enum WorkspaceTemplate: String, Sendable, CaseIterable, Codable, Hashable {
    case general
    case legalMatter
    case investigation
    case journalism
    case researchReview
    case personalMatter

    /// Human-facing label for the sidebar / pickers.
    public var displayName: String {
        switch self {
        case .general:        return "General"
        case .legalMatter:    return "Legal Matter"
        case .investigation:  return "Investigation"
        case .journalism:     return "Journalism Project"
        case .researchReview: return "Research Review"
        case .personalMatter: return "Personal Matter"
        }
    }

    public var symbolName: String {
        switch self {
        case .general:        return "square.grid.2x2"
        case .legalMatter:    return "building.columns"
        case .investigation:  return "magnifyingglass.circle"
        case .journalism:     return "newspaper"
        case .researchReview: return "books.vertical"
        case .personalMatter: return "house"
        }
    }
}

public enum WorkspaceStatus: String, Sendable, Codable, Hashable {
    case active
    case archived
}

/// A bounded matter. `defaultDateRange` and `defaultScope` seed new saved
/// views but never hard-limit what the user can add.
public struct Workspace: Sendable, Identifiable, Hashable {
    public typealias ID = UUID

    public let id: ID
    public var title: String
    public var template: WorkspaceTemplate
    public var description: String?
    public var status: WorkspaceStatus
    public var defaultDateStart: Date?
    public var defaultDateEnd: Date?
    /// Free-form JSON of extra default scope (source types, folders…).
    public var defaultScopeJSON: String
    public let createdAt: Date
    public var updatedAt: Date
    public var archivedAt: Date?

    public nonisolated init(
        id: ID = UUID(),
        title: String,
        template: WorkspaceTemplate = .general,
        description: String? = nil,
        status: WorkspaceStatus = .active,
        defaultDateStart: Date? = nil,
        defaultDateEnd: Date? = nil,
        defaultScopeJSON: String = "{}",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        archivedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.template = template
        self.description = description
        self.status = status
        self.defaultDateStart = defaultDateStart
        self.defaultDateEnd = defaultDateEnd
        self.defaultScopeJSON = defaultScopeJSON
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.archivedAt = archivedAt
    }
}

// MARK: - Review model (F2)

/// The kind of ledger item a review decision targets. `raw` matches the
/// `target_kind` column and is shared across every persona.
public enum ReviewTarget: String, Sendable, CaseIterable, Codable, Hashable {
    case source
    case evidenceBlock
    case assertion
    case event
    case entity
    case relationship
    case contradiction
    case gap
    case answerClaim
}

/// Generic review state. Persona templates may show these under different
/// labels (a lawyer sees "privilege candidate", a journalist "needs
/// response") but the stored value is one shared vocabulary. `markedPrivate`
/// carries raw value `"private"` (the spec's label) since `private` is a
/// Swift keyword.
public enum ReviewState: String, Sendable, CaseIterable, Codable, Hashable {
    case unreviewed
    case relevant
    case notRelevant
    case important
    case followUp
    case confirmed
    case disputed
    case rejected
    case needsSource
    case needsResponse
    case markedPrivate = "private"
    case privilegeCandidate

    public var displayName: String {
        switch self {
        case .unreviewed:         return "Unreviewed"
        case .relevant:           return "Relevant"
        case .notRelevant:        return "Not Relevant"
        case .important:          return "Important"
        case .followUp:           return "Follow Up"
        case .confirmed:          return "Confirmed"
        case .disputed:           return "Disputed"
        case .rejected:           return "Rejected"
        case .needsSource:        return "Needs Source"
        case .needsResponse:      return "Needs Response"
        case .markedPrivate:      return "Private"
        case .privilegeCandidate: return "Privilege Candidate"
        }
    }
}

/// What a review_decisions row records. `reviewState` sets/updates the
/// item's status; `tag` applies or removes a tag; `note` attaches a note.
public enum ReviewDimension: String, Sendable, Codable, Hashable {
    case reviewState
    case tag
    case note
}

/// A tag definition. `workspaceID == nil` means a global tag.
public struct ReviewTag: Sendable, Identifiable, Hashable {
    public typealias ID = UUID
    public let id: ID
    public let workspaceID: Workspace.ID?
    public var name: String
    public var color: String?
    /// "user" or "template" (seeded by a persona template).
    public var kind: String
    public let createdAt: Date

    public nonisolated init(
        id: ID = UUID(),
        workspaceID: Workspace.ID? = nil,
        name: String,
        color: String? = nil,
        kind: String = "user",
        createdAt: Date = Date()
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.name = name
        self.color = color
        self.kind = kind
        self.createdAt = createdAt
    }
}

/// One append-only entry in the review ledger. Never mutated in place; an
/// undo is a new row whose `reversalOf` points at the row it reverses.
public struct ReviewDecision: Sendable, Identifiable, Hashable {
    public typealias ID = UUID
    public let id: ID
    public let workspaceID: Workspace.ID?
    public let targetKind: ReviewTarget
    public let targetID: String
    public let dimension: ReviewDimension
    /// For `.reviewState` this is a `ReviewState` raw value; for `.tag` it is
    /// "add"/"remove"; nil for `.note`.
    public let decision: String?
    public let tagID: ReviewTag.ID?
    public let note: String?
    public let priorValue: String?
    public let reviewer: String
    public let reversalOf: ID?
    public let createdAt: Date

    public nonisolated init(
        id: ID = UUID(),
        workspaceID: Workspace.ID? = nil,
        targetKind: ReviewTarget,
        targetID: String,
        dimension: ReviewDimension,
        decision: String? = nil,
        tagID: ReviewTag.ID? = nil,
        note: String? = nil,
        priorValue: String? = nil,
        reviewer: String = "user",
        reversalOf: ID? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.targetKind = targetKind
        self.targetID = targetID
        self.dimension = dimension
        self.decision = decision
        self.tagID = tagID
        self.note = note
        self.priorValue = priorValue
        self.reviewer = reviewer
        self.reversalOf = reversalOf
        self.createdAt = createdAt
    }
}

/// A named, reopenable filter set scoped to a workspace (or global).
public struct SavedView: Sendable, Identifiable, Hashable {
    public typealias ID = UUID
    public let id: ID
    public let workspaceID: Workspace.ID?
    public var title: String
    /// Ordered filter key/value pairs (e.g. "tag"→"key", "status"→"disputed").
    public var filters: [SavedViewFilter]
    public let createdAt: Date
    public var updatedAt: Date

    public nonisolated init(
        id: ID = UUID(),
        workspaceID: Workspace.ID? = nil,
        title: String,
        filters: [SavedViewFilter] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.title = title
        self.filters = filters
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct SavedViewFilter: Sendable, Identifiable, Hashable {
    public typealias ID = UUID
    public let id: ID
    public let key: String
    public let value: String

    public nonisolated init(id: ID = UUID(), key: String, value: String) {
        self.id = id
        self.key = key
        self.value = value
    }
}
