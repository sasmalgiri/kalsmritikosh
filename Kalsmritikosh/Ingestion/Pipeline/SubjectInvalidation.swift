//
//  SubjectInvalidation.swift
//  Kalsmritikosh
//
//  The signal IngestCoordinator emits after each successful ingest.
//  IncrementalUpdater consumes the stream and asks MemoryDistiller to
//  refresh only the affected subjects — no full corpus rescan.
//

import Foundation

public struct SubjectInvalidation: Sendable, Hashable {
    public let subjects: [Subject]
    public let triggeringObjectID: KnowledgeObject.ID
    public let occurredAt: Date

    public init(
        subjects: [Subject],
        triggeringObjectID: KnowledgeObject.ID,
        occurredAt: Date = .init()
    ) {
        self.subjects = subjects
        self.triggeringObjectID = triggeringObjectID
        self.occurredAt = occurredAt
    }

    public struct Subject: Sendable, Hashable {
        public let kind: MemoryObject.SubjectKind
        public let identifier: String
        public init(kind: MemoryObject.SubjectKind, identifier: String) {
            self.kind = kind
            self.identifier = identifier
        }
    }
}
