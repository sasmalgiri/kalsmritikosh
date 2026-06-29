//
//  Investigation.swift
//  Kalsmritikosh
//
//  Phase H — Plan-and-Solve investigation models. A user-issued
//  question that the planner decomposes into 2-5 focused
//  sub-questions, each one answered by the existing single-turn brain
//  pipeline, then synthesized into a final response.
//
//  These are the shape of the planner's input/output AND the stream
//  events the runner emits to the UI. Investigations are not
//  persisted yet (Phase I notebook will handle storage); the in-flight
//  Investigation lives entirely in InvestigationRunner's actor state.
//

import Foundation

/// A single decomposed sub-question. Created by the planner; the
/// runner fills `answer` after it completes the single-turn brain
/// call for the sub-question text.
public nonisolated struct InvestigationStep: Sendable, Identifiable {
    public let id: UUID
    public let question: String
    public var answer: VerifiedAnswer?
    public let createdAt: Date

    public nonisolated init(
        id: UUID = UUID(),
        question: String,
        answer: VerifiedAnswer? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.question = question
        self.answer = answer
        self.createdAt = createdAt
    }
}

/// Top-level investigation. Has the user's original question, the
/// planner's decomposition into sub-question steps, and (when the
/// runner finishes) a synthesis paragraph that knits the sub-answers
/// together. `synthesis` is nil while steps are still running.
public nonisolated struct Investigation: Sendable, Identifiable {
    public let id: UUID
    public let question: String
    public var steps: [InvestigationStep]
    public var synthesis: String?
    public let createdAt: Date

    public nonisolated init(
        id: UUID = UUID(),
        question: String,
        steps: [InvestigationStep] = [],
        synthesis: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.question = question
        self.steps = steps
        self.synthesis = synthesis
        self.createdAt = createdAt
    }
}

/// Streaming progress envelope. Mirrors the AnswerUpdate pattern so
/// SwiftUI views can subscribe to an `AsyncStream` and update step
/// rows in place as the runner makes progress.
public nonisolated enum InvestigationUpdate: Sendable {
    /// Planner finished decomposition. `investigation.steps` carries
    /// the sub-questions but no answers yet.
    case planReady(Investigation)
    /// Runner started answering this step. UI flips its row to
    /// "investigating…".
    case stepStarted(stepID: UUID)
    /// Runner finished a step with a verified answer.
    case stepCompleted(stepID: UUID, answer: VerifiedAnswer)
    /// Synthesizer started. UI shows a final "Composing answer…" hint.
    case synthesizing
    /// Investigation complete. `investigation.synthesis` is set.
    case finished(Investigation)
    /// Terminal failure (planner couldn't decompose, no reasoning
    /// provider available, etc.). The UI surfaces `reason`.
    case failed(reason: String)
}
