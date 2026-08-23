//
//  EmailParticipantOccurrence.swift
//  Kalsmritikosh
//
//  OPS-005 — message-level occurrence of an email address in a specific
//  role. Persisted to email_participant_occurrences (schema v73).
//
//  EmailParticipantSeed is the lightweight Codable value that EmailLoader
//  embeds in KO metadata for each parsed address. IngestCoordinator
//  resolves seeds to canonical entity IDs and constructs full
//  EmailParticipantOccurrence rows, which EmailParticipantRepository
//  writes to the database.
//

import Foundation

/// Transfer object: raw address + role before canonical entity resolution.
/// Encoded as JSON in KO metadata under `EmailLoader.emailParticipantSeedsMetaKey`.
public struct EmailParticipantSeed: Codable, Sendable {
    public let rawAddress: String
    public let displayName: String?
    /// `EmailParticipantRole.rawValue`
    public let role: String

    public init(rawAddress: String, displayName: String?, role: EmailParticipantRole) {
        self.rawAddress  = rawAddress
        self.displayName = displayName
        self.role        = role.rawValue
    }

    public var participantRole: EmailParticipantRole? { EmailParticipantRole(rawValue: role) }
}

/// Fully resolved occurrence row ready for `EmailParticipantRepository`.
public nonisolated struct EmailParticipantOccurrence: Sendable {
    public let id: UUID
    public let sourceObjectID: KnowledgeObject.ID
    public let entityID: Entity.ID
    public let role: EmailParticipantRole
    public let rawAddress: String
    public let displayName: String?
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        sourceObjectID: KnowledgeObject.ID,
        entityID: Entity.ID,
        role: EmailParticipantRole,
        rawAddress: String,
        displayName: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id            = id
        self.sourceObjectID = sourceObjectID
        self.entityID      = entityID
        self.role          = role
        self.rawAddress    = rawAddress
        self.displayName   = displayName
        self.createdAt     = createdAt
    }
}
