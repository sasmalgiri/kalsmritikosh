//
//  ArchiveQuestionConsent.swift
//  Kalsmritikosh
//
//  AI split AI-49 (owner decision 2026-11-24, recommended default; reversible) — the once-per-question permission of an
//  archive question (asked outside a case): "The AI may read documents it finds for this question — privileged and
//  restricted documents are never sent — up to N documents, about X credits." Allow → the archive agent's steps for this
//  question run without another preview (ArchiveQuestionPermission); "Not now" → the search results. Same pattern as
//  CaseReadConsent and ImportAIConsent (one sheet, one continuation).
//

import Foundation
import Observation
import os

public nonisolated struct ArchiveQuestionConsentRequest: Sendable, Identifiable, Equatable {
    public let id = UUID()
    public let question: String
    public let provider: String
    public let maxDocuments: Int
    /// Documents the app's first search found that may be sent, and those that may not (privileged / restricted).
    public let found: Int
    public let withheld: Int
    public let estimate: String
}

@MainActor
@Observable
public final class ArchiveQuestionConsent {
    public static let shared = ArchiveQuestionConsent()

    public private(set) var pending: ArchiveQuestionConsentRequest?
    private var continuation: CheckedContinuation<Bool, Never>?
    /// A test host answers for the person; nil in the app.
    public var scriptedAnswer: Bool?
    /// How many times the person was asked (tests: once per question).
    public private(set) var askedCount = 0

    public func request(_ request: ArchiveQuestionConsentRequest) async -> Bool {
        askedCount += 1
        if let scriptedAnswer { return scriptedAnswer }
        while pending != nil { try? await Task.sleep(nanoseconds: 200_000_000) }
        return await withCheckedContinuation { c in
            continuation = c
            pending = request
        }
    }

    public func resolve(allow: Bool) {
        pending = nil
        continuation?.resume(returning: allow)
        continuation = nil
    }

    /// What one question may cost at most: per agent run, the agent's own cost ceiling (three times a full first step,
    /// plus room for the tool results) as input and one reply per step as output; `runs` agent runs (an investigation's
    /// steps share one question), each reading at most its share of the cap.
    nonisolated static func makeRequest(question: String, maxDocuments: Int, perDocumentCharacters: Int, maxRounds: Int,
                                        runs: Int = 1, found: Int, withheld: Int) -> ArchiveQuestionConsentRequest {
        let kind = OnlineSettings.kind
        let perRun = max(1, (maxDocuments + max(1, runs) - 1) / max(1, runs))
        let firstStep = AIPricing.approximateTokens(characters: perRun * perDocumentCharacters) + 2_000
        let input = max(1, runs) * (3 * firstStep + 60_000)
        let replies = max(1, runs) * (maxRounds + 1) * OnlineRequestBuilder.caseReadReplyTokens
        let estimate: String
        switch kind {
        case .included:
            estimate = "About \(AIPricing.estimateCredits(inputTokens: input, maxOutputTokens: replies).formatted()) credits at most (only the actual cost is charged; a short answer costs less)."
        default:
            estimate = OwnKeyBudget.estimateLine(model: OnlineSettings.model, inputTokens: input, maxOutputTokens: replies)
                ?? "At most about \(input.formatted()) tokens of document text would be read."
        }
        return ArchiveQuestionConsentRequest(question: question, provider: kind.displayName, maxDocuments: maxDocuments,
                                             found: found, withheld: withheld, estimate: estimate)
    }
}
