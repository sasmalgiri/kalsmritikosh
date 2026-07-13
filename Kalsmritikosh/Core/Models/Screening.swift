//
//  Screening.swift
//  Kalsmritikosh
//
//  Persona features (F9). Research screening model. A transparent single-user
//  screening log with PRISMA-compatible flow counts — NOT dual-review
//  compliance, meta-analysis, or a final risk-of-bias judgment (§14). Every
//  exclusion must carry a reason; decisions are reversible; no LLM makes the
//  final inclusion decision.
//

import Foundation

/// Screening stage (§14.2). Ordered along the PRISMA flow.
public enum ScreeningStage: String, Sendable, CaseIterable, Codable {
    case identified
    case deduplicated
    case titleAbstractScreen
    case fullTextScreen
    case included
    case excluded
    case awaitingInformation

    public var displayName: String {
        switch self {
        case .identified:          return "Identified"
        case .deduplicated:        return "Deduplicated"
        case .titleAbstractScreen: return "Title/Abstract screen"
        case .fullTextScreen:      return "Full-text screen"
        case .included:            return "Included"
        case .excluded:            return "Excluded"
        case .awaitingInformation: return "Awaiting information"
        }
    }
}

/// Reviewer decision on a candidate. `duplicate` and `unresolved` are distinct
/// from include/exclude so the flow counts stay honest.
public enum ScreeningDecision: String, Sendable, CaseIterable, Codable {
    case unresolved
    case include
    case exclude
    case duplicate

    public var displayName: String {
        switch self {
        case .unresolved: return "Unresolved"
        case .include:    return "Include"
        case .exclude:    return "Exclude"
        case .duplicate:  return "Duplicate"
        }
    }
}

public struct ScreeningRecord: Sendable, Identifiable, Hashable {
    public typealias ID = UUID
    public let id: ID
    public let workspaceID: Workspace.ID
    public var sourceID: UUID?
    public var title: String
    public var authors: String?
    public var year: Int?
    public var stage: ScreeningStage
    public var decision: ScreeningDecision
    public var exclusionReason: String?
    public var reviewer: String
    public var disagreement: Bool
    public var notes: String?
    public let createdAt: Date
    public var updatedAt: Date

    public nonisolated init(
        id: ID = UUID(),
        workspaceID: Workspace.ID,
        sourceID: UUID? = nil,
        title: String,
        authors: String? = nil,
        year: Int? = nil,
        stage: ScreeningStage = .identified,
        decision: ScreeningDecision = .unresolved,
        exclusionReason: String? = nil,
        reviewer: String = "user",
        disagreement: Bool = false,
        notes: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.sourceID = sourceID
        self.title = title
        self.authors = authors
        self.year = year
        self.stage = stage
        self.decision = decision
        self.exclusionReason = exclusionReason
        self.reviewer = reviewer
        self.disagreement = disagreement
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// PRISMA-COMPATIBLE flow counts (§14.3) — deterministically derived from the
/// records, never from an LLM. Deliberately named "compatible" until full
/// PRISMA export is verified.
public struct PRISMACounts: Sendable, Hashable {
    public var identified: Int
    public var duplicatesRemoved: Int
    public var screened: Int
    public var excludedAtScreening: Int
    public var fullTextReviewed: Int
    public var fullTextExcluded: Int
    public var included: Int
    public var awaitingInformation: Int
    /// exclusion reason → count (full-text exclusions).
    public var exclusionReasons: [String: Int]

    public nonisolated init(
        identified: Int = 0, duplicatesRemoved: Int = 0, screened: Int = 0,
        excludedAtScreening: Int = 0, fullTextReviewed: Int = 0, fullTextExcluded: Int = 0,
        included: Int = 0, awaitingInformation: Int = 0, exclusionReasons: [String: Int] = [:]
    ) {
        self.identified = identified
        self.duplicatesRemoved = duplicatesRemoved
        self.screened = screened
        self.excludedAtScreening = excludedAtScreening
        self.fullTextReviewed = fullTextReviewed
        self.fullTextExcluded = fullTextExcluded
        self.included = included
        self.awaitingInformation = awaitingInformation
        self.exclusionReasons = exclusionReasons
    }

    /// Deterministic derivation from a record set. Same input → same counts.
    public static func from(_ records: [ScreeningRecord]) -> PRISMACounts {
        var c = PRISMACounts()
        c.identified = records.count
        c.duplicatesRemoved = records.filter { $0.decision == .duplicate }.count
        c.awaitingInformation = records.filter { $0.stage == .awaitingInformation }.count
        let nonDuplicate = records.filter { $0.decision != .duplicate }
        c.screened = nonDuplicate.count
        // Excluded at the title/abstract stage.
        c.excludedAtScreening = nonDuplicate.filter {
            $0.decision == .exclude && $0.stage == .titleAbstractScreen
        }.count
        // Reached full-text review (either still there, excluded there, or included).
        c.fullTextReviewed = nonDuplicate.filter {
            $0.stage == .fullTextScreen || $0.stage == .included
                || ($0.stage == .excluded && $0.decision == .exclude)
        }.count
        c.fullTextExcluded = nonDuplicate.filter {
            $0.decision == .exclude && $0.stage != .titleAbstractScreen
        }.count
        c.included = nonDuplicate.filter { $0.decision == .include }.count
        var reasons: [String: Int] = [:]
        for r in nonDuplicate where r.decision == .exclude {
            let reason = r.exclusionReason?.isEmpty == false ? r.exclusionReason! : "(no reason given)"
            reasons[reason, default: 0] += 1
        }
        c.exclusionReasons = reasons
        return c
    }
}
