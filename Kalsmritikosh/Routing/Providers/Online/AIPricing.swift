//
//  AIPricing.swift
//  Kalsmritikosh
//
//  Plans and credits (owner decisions 2026-11-04): the app's DISPLAY mirror of relay/src/policy.ts,
//  which is the one authority (the relay meters; the app only estimates and shows). Kept identical by
//  ci/guards/relay-host-match.sh. Model names live here by the capability-discipline rule; callers in
//  other layers use the model-free functions (`estimateCredits`, `estimateUSD`).
//
//  1 credit = US$0.01 of real Claude cost at Anthropic's published rates. Nothing here touches the network.
//

import Foundation

public nonisolated enum AIPricing {

    // MARK: Plans (mirror of PLANS in relay/src/policy.ts)

    public struct PlanLimits: Equatable, Sendable {
        public let monthlyCredits: Int
        public let perRequestCredits: Int
        public let caseReadCredits: Int
        public let dailyCredits: Int
    }
    /// AI Included.
    public static let aiIncluded = PlanLimits(monthlyCredits: 2_000, perRequestCredits: 400, caseReadCredits: 600, dailyCredits: 1_500)
    /// AI Pro.
    public static let aiPro = PlanLimits(monthlyCredits: 6_000, perRequestCredits: 400, caseReadCredits: 3_000, dailyCredits: 4_000)

    /// Credits in each pack (mirror of TOPUP_CREDITS).
    public static let credits500 = 500
    public static let credits2000 = 2_000

    // MARK: Rates (mirror of ANTHROPIC_RATES)

    public struct Rates: Equatable, Sendable {
        public let inputPerMTok: Double
        public let outputPerMTok: Double
        public let cacheWrite5m: Double
        public let cacheWrite1h: Double
        public let cacheRead: Double
        public let batch: Double
    }
    public static let rates: [String: Rates] = [
        "claude-opus-5": Rates(inputPerMTok: 5, outputPerMTok: 25, cacheWrite5m: 1.25, cacheWrite1h: 2, cacheRead: 0.1, batch: 0.5),
    ]
    /// The model AI Included and AI Pro use (the relay's; also the default own-key Claude model).
    static let relayModel = "claude-opus-5"
    static var relayRates: Rates { rates[relayModel] ?? Rates(inputPerMTok: 5, outputPerMTok: 25, cacheWrite5m: 1.25, cacheWrite1h: 2, cacheRead: 0.1, batch: 0.5) }

    /// One credit in US dollars.
    public static let creditUSD = 0.01

    // MARK: Estimates

    /// The cost of one request in micro-dollars: `inputTokens` new input (of which `cachedTokens` are
    /// read from the cache), up to `maxOutputTokens` of output (thinking included).
    static func micro(inputTokens: Int, maxOutputTokens: Int, cachedTokens: Int, rates r: Rates) -> Double {
        let cached = max(0, min(cachedTokens, inputTokens))
        let plain = max(0, inputTokens - cached)
        return Double(plain) * r.inputPerMTok + Double(cached) * r.inputPerMTok * r.cacheRead + Double(max(0, maxOutputTokens)) * r.outputPerMTok
    }

    /// Credits a request on AI Included / AI Pro costs at most (whole credits, at least 1), at the relay's
    /// rates. This is what is shown before a case read ("about 120 credits"); the relay reserves its own
    /// conservative worst case and charges the actual cost.
    public static func estimateCredits(inputTokens: Int, maxOutputTokens: Int, cachedTokens: Int = 0) -> Int {
        let m = micro(inputTokens: inputTokens, maxOutputTokens: maxOutputTokens, cachedTokens: cachedTokens, rates: relayRates)
        return max(1, Int((m / 10_000).rounded(.up)))
    }

    /// What the relay will RESERVE for a request of `inputCharacters` (characters ÷ 3 + 64 tokens, every
    /// token at the dearest rate it may be billed at): a request fits only if this fits the balance and
    /// the per-request or case-read limit. Mirror of worstCaseCost in relay/src/policy.ts.
    public static func relayReservation(inputCharacters: Int, images: Int = 0, maxOutputTokens: Int, cacheWrite1h: Bool = false, cacheWrite5m: Bool = false) -> Int {
        let r = relayRates
        let tokens = Double((inputCharacters + 2) / 3 + 64 + images * 1_600)
        let mult = cacheWrite1h ? r.cacheWrite1h : cacheWrite5m ? r.cacheWrite5m : 1
        let m = tokens * r.inputPerMTok * max(1, mult) + Double(min(max(1_024, maxOutputTokens), 24_000)) * r.outputPerMTok
        return max(1, Int((m / 10_000).rounded(.up)))
    }

    /// Own key: the estimated US-dollar cost of a request to `model` at Anthropic's published rates, or
    /// nil when the model's price is not in the table (another provider, or an unknown model).
    public static func estimateUSD(model: String, inputTokens: Int, maxOutputTokens: Int, cachedTokens: Int = 0) -> Double? {
        guard let r = rates[model] else { return nil }
        return micro(inputTokens: inputTokens, maxOutputTokens: maxOutputTokens, cachedTokens: cachedTokens, rates: r) / 1_000_000
    }

    /// A rough token count for text the app is about to send (≈ 4 characters per token; the relay's own
    /// reservation uses a more conservative 3).
    public static func approximateTokens(characters: Int) -> Int { max(1, (characters + 3) / 4) }

    /// The actual cost of an Anthropic reply from its `usage` object, in US dollars (own key: the local
    /// tally). Cache writes without a 5m/1h split are counted at the 1-hour rate, as the relay does.
    public static func actualUSD(model: String, usage: [String: Any]) -> Double? {
        guard let r = rates[model] else { return nil }
        func n(_ k: String, _ d: [String: Any] = usage) -> Double { Double(max(0, d[k] as? Int ?? 0)) }
        let split = usage["cache_creation"] as? [String: Any] ?? [:]
        let w5 = n("ephemeral_5m_input_tokens", split)
        let w1 = max(n("ephemeral_1h_input_tokens", split), n("cache_creation_input_tokens") - w5)
        let m = n("input_tokens") * r.inputPerMTok + w5 * r.inputPerMTok * r.cacheWrite5m + w1 * r.inputPerMTok * r.cacheWrite1h
            + n("cache_read_input_tokens") * r.inputPerMTok * r.cacheRead + n("output_tokens") * r.outputPerMTok
        return m / 1_000_000
    }

    /// "$0.42" / "under $0.01".
    public static func formatUSD(_ v: Double) -> String {
        if v < 0.01 { return "under $0.01" }
        return String(format: "$%.2f", v)
    }
}
