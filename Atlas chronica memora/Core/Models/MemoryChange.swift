//
//  MemoryChange.swift
//  Atlas chronica memora
//
//  Append-only change log per subject. Every time the MemoryDistiller
//  decides a MemoryObject must mutate, it writes a MemoryChange row
//  capturing the prior + new version + a diff payload + what KO
//  triggered it. Enables the "What changed this week?" briefing the
//  user wants in M6+.
//

import Foundation

public struct MemoryChange: Codable, Identifiable, Hashable, Sendable {
    public typealias ID = UUID

    public let id: ID
    public let memoryObjectID: MemoryObject.ID
    public let subjectKind: MemoryObject.SubjectKind
    public let subjectIdentifier: String
    public let priorVersion: Int
    public let newVersion: Int
    public let delta: Delta
    public let triggeringObjectID: KnowledgeObject.ID?
    public let occurredAt: Date

    public init(
        id: ID = UUID(),
        memoryObjectID: MemoryObject.ID,
        subjectKind: MemoryObject.SubjectKind,
        subjectIdentifier: String,
        priorVersion: Int,
        newVersion: Int,
        delta: Delta,
        triggeringObjectID: KnowledgeObject.ID? = nil,
        occurredAt: Date = .init()
    ) {
        self.id = id
        self.memoryObjectID = memoryObjectID
        self.subjectKind = subjectKind
        self.subjectIdentifier = subjectIdentifier
        self.priorVersion = priorVersion
        self.newVersion = newVersion
        self.delta = delta
        self.triggeringObjectID = triggeringObjectID
        self.occurredAt = occurredAt
    }

    public struct Delta: Codable, Sendable, Hashable {
        public let addedDecisions: [String]
        public let removedDecisions: [String]
        public let addedRisks: [String]
        public let removedRisks: [String]
        public let addedEventIDs: [Event.ID]
        public let statusChanged: StatusChange?
        public let narrativeRewrite: Bool

        public init(
            addedDecisions: [String] = [],
            removedDecisions: [String] = [],
            addedRisks: [String] = [],
            removedRisks: [String] = [],
            addedEventIDs: [Event.ID] = [],
            statusChanged: StatusChange? = nil,
            narrativeRewrite: Bool = false
        ) {
            self.addedDecisions = addedDecisions
            self.removedDecisions = removedDecisions
            self.addedRisks = addedRisks
            self.removedRisks = removedRisks
            self.addedEventIDs = addedEventIDs
            self.statusChanged = statusChanged
            self.narrativeRewrite = narrativeRewrite
        }

        public struct StatusChange: Codable, Sendable, Hashable {
            public let from: String
            public let to: String
            public init(from: String, to: String) {
                self.from = from
                self.to = to
            }
        }
    }
}
