//
//  CloudUsage.swift
//  Kalsmritikosh
//
//  Plan A (owner, 2026-11-04) — what one cloud call used, read from the provider's own reply
//  (Anthropic: input_tokens, cache_creation_input_tokens, cache_read_input_tokens, output_tokens),
//  and the hook the billing layer installs to receive it. Nothing here holds data or sends anything.
//
//  The estimate shown before a case's first AI read lives here too (prices are model facts, which by
//  the capability rule live in Routing/Providers): dollars for the person's own key, or the plan's
//  credits (AIPricing, the relay's display mirror).
//

import Foundation
import os

public nonisolated struct CloudCallUsage: Sendable, Equatable, Codable {
    /// Input tokens neither written to nor read from the cache.
    public var inputTokens: Int
    public var cacheWriteTokens: Int
    public var cacheReadTokens: Int
    public var outputTokens: Int
    /// What the call was for ("case.question", "case.analysis" …).
    public var purpose: String
    public var provider: String
    /// S10 (AI-06 / AI-12) — the model the provider says answered (its reply's own field; a server-side fallback may differ
    /// from the one asked for) and why it stopped ("end_turn", "max_tokens" — a reply cut off at its limit is partial).
    /// nil when the reply does not say.
    public var model: String? = nil
    public var stopReason: String? = nil
    public init(inputTokens: Int, cacheWriteTokens: Int, cacheReadTokens: Int, outputTokens: Int, purpose: String, provider: String) {
        self.inputTokens = inputTokens; self.cacheWriteTokens = cacheWriteTokens; self.cacheReadTokens = cacheReadTokens
        self.outputTokens = outputTokens; self.purpose = purpose; self.provider = provider
    }
    public var totalInputTokens: Int { inputTokens + cacheWriteTokens + cacheReadTokens }
}

/// The billing layer's hooks. `report` receives every case-reading call's usage; `creditEstimator`
/// (inputTokens, maxOutputTokens, cachedTokens) → credits, when the plan bills in credits.
public nonisolated enum CloudUsageMeter {
    public typealias Sink = @Sendable (CloudCallUsage) -> Void
    public typealias CreditEstimator = @Sendable (_ inputTokens: Int, _ maxOutputTokens: Int, _ cachedTokens: Int) -> Int

    private static let state = OSAllocatedUnfairLock<(sink: Sink?, estimator: CreditEstimator?)>(initialState: (nil, nil))

    public static func install(sink: Sink?) { state.withLock { $0.sink = sink } }
    public static func install(creditEstimator: CreditEstimator?) { state.withLock { $0.estimator = creditEstimator } }

    public static func report(_ usage: CloudCallUsage) {
        KalsmritikoshLog.routing.info("cloud usage \(usage.purpose, privacy: .public): input \(usage.inputTokens, privacy: .public), cache write \(usage.cacheWriteTokens, privacy: .public), cache read \(usage.cacheReadTokens, privacy: .public), output \(usage.outputTokens, privacy: .public)")
        let sink = state.withLock { $0.sink }
        sink?(usage)
    }

    /// Credits by the installed estimator, else AIPricing (the relay's display mirror).
    public static func estimateCredits(inputTokens: Int, maxOutputTokens: Int, cachedTokens: Int) -> Int {
        let e = state.withLock { $0.estimator }
        return e?(inputTokens, maxOutputTokens, cachedTokens)
            ?? AIPricing.estimateCredits(inputTokens: inputTokens, maxOutputTokens: maxOutputTokens, cachedTokens: cachedTokens)
    }
}

/// The estimate shown on a case's AI-reading permission sheet, for the first read of the case.
public nonisolated enum CaseReadCostEstimate {
    /// Anthropic list prices for the own-key reader (claude-opus-5, the own-key default), dollars per million tokens.
    static let inputPerMillion = 5.0
    static let outputPerMillion = 25.0
    /// Cache writes: 1.25× (5-minute) or 2× (1-hour) input; reads 0.1×.
    static func writeMultiplier(oneHour: Bool) -> Double { oneHour ? 2.0 : 1.25 }
    static let readMultiplier = 0.1

    /// The person's own key: dollars for the first read (the case written to the cache) and for each
    /// later question while the cache is warm.
    public static func ownKeyDollars(caseTokens: Int, questionTokens: Int, maxOutputTokens: Int, oneHourCache: Bool) -> (first: Double, next: Double) {
        let out = Double(maxOutputTokens) * outputPerMillion / 1_000_000
        let q = Double(questionTokens) * inputPerMillion / 1_000_000
        let first = Double(caseTokens) * inputPerMillion * writeMultiplier(oneHour: oneHourCache) / 1_000_000 + q + out
        let next = Double(caseTokens) * inputPerMillion * readMultiplier / 1_000_000 + q + out
        return (first, next)
    }

    /// The line the sheet shows: credits for a plan, dollars for an own key.
    public static func line(kind: OnlineProviderKind, caseTokens: Int, questionTokens: Int, maxOutputTokens: Int, oneHourCache: Bool) -> String {
        if kind == .included {
            // AIPricing (the relay's display mirror): the first read writes the case to the 1-hour cache
            // (twice the input rate), later questions read it at the relay model's cache-read rate.
            let first = CloudUsageMeter.estimateCredits(inputTokens: caseTokens * 2 + questionTokens, maxOutputTokens: maxOutputTokens, cachedTokens: 0)
            let next = CloudUsageMeter.estimateCredits(inputTokens: caseTokens + questionTokens, maxOutputTokens: maxOutputTokens, cachedTokens: caseTokens)
            return "At most about \(first) credits for the first read of this case, then about \(next) per question asked within an hour of the last one (the AI keeps the case for about an hour; after an idle hour the first question costs about the first-read amount again)."
        }
        let d = ownKeyDollars(caseTokens: caseTokens, questionTokens: questionTokens, maxOutputTokens: maxOutputTokens, oneHourCache: oneHourCache)
        return String(format: "At most about $%.2f on your own key for the first read of this case, then about $%.2f per question asked within an hour of the last one (the AI keeps the case for about an hour; after an idle hour the first question costs about the first-read amount again; list prices; billed by your provider).", d.first, d.next)
    }
}
