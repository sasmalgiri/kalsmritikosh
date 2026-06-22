//
//  Summary.swift
//  Kalsmritikosh
//
//  The hierarchical summarization layer — the most important AI tier.
//  Summaries are stored permanently and refreshed by the nightly
//  CompressionScheduler so we never regenerate them per query.
//

import Foundation

public struct Summary: Codable, Identifiable, Hashable, Sendable {
    public typealias ID = UUID

    public let id: ID
    public let level: Level
    public let length: Length
    public let scope: Scope
    public let body: String
    public let producedAt: Date
    public let modelID: String?
    public let confidence: Confidence

    public nonisolated init(
        id: ID = UUID(),
        level: Level,
        length: Length,
        scope: Scope,
        body: String,
        producedAt: Date = .init(),
        modelID: String? = nil,
        confidence: Confidence = .medium
    ) {
        self.id = id
        self.level = level
        self.length = length
        self.scope = scope
        self.body = body
        self.producedAt = producedAt
        self.modelID = modelID
        self.confidence = confidence
    }

    /// 6 levels per the locked Summarization Layer instruction.
    public enum Level: String, Codable, CaseIterable, Sendable {
        case document
        case folder
        case project
        case organization
        case timeline
        case knowledgeBase
    }

    public enum Length: String, Codable, CaseIterable, Sendable {
        case short
        case medium
        case executive
    }

    /// What this summary is about. Decoded into specific identifiers
    /// per level when the summary is read back.
    // G2-SWIFT6 — Codable conformance moved to a nonisolated extension
    // (see bottom of file) so SummariesRepository's actor-isolated SQL
    // path can encode/decode without picking up main-actor isolation
    // from the synthesized conformance.
    public enum Scope: Hashable, Sendable {
        case document(KnowledgeObject.ID)
        case folder(String)             // folder path (relative to a root bookmark)
        case project(String)            // project name / id
        case organization(String)       // org name / id
        case timeline(Range)            // a closed date range
        case knowledgeBase

        public struct Range: Hashable, Sendable {
            public let start: Date
            public let end: Date
            public nonisolated init(start: Date, end: Date) {
                self.start = start
                self.end = end
            }
        }
    }
}

// G2-SWIFT6 — nonisolated extensions add Codable so repository actors
// can call encode/decode without picking up main-actor isolation.
nonisolated extension Summary.Scope: Codable {}
nonisolated extension Summary.Scope.Range: Codable {}
