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
        /// Credits each allowance month on the monthly plan.
        public let monthlyCredits: Int
        /// Credits each allowance month on the yearly plan (AI Pro yearly: 5,400 — owner decision
        /// 2026-11-04, so a fully used yearly plan stays within its net revenue at 27 % VAT and 15 %).
        public let yearlyMonthlyCredits: Int
        public let perRequestCredits: Int
        public let caseReadCredits: Int
        public let dailyCredits: Int
        /// The plan's whole-case limit (estimated tokens of case text, `maxTokensForText`) before the
        /// credit/size cap (`caseReadTokenCeiling`). CaseReadLimits derives the app's limit from this.
        public let caseReadTokens: Int
        /// The credits of one allowance month on a monthly or a yearly plan (mirror of `monthlyAllowance`).
        public func monthly(yearly: Bool) -> Int { yearly ? yearlyMonthlyCredits : monthlyCredits }
    }
    /// AI Included.
    public static let aiIncluded = PlanLimits(monthlyCredits: 2_000, yearlyMonthlyCredits: 2_000, perRequestCredits: 400, caseReadCredits: 600, dailyCredits: 1_500, caseReadTokens: 300_000)
    /// AI Pro.
    public static let aiPro = PlanLimits(monthlyCredits: 6_000, yearlyMonthlyCredits: 5_400, perRequestCredits: 400, caseReadCredits: 3_000, dailyCredits: 4_000, caseReadTokens: 800_000)

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

    // MARK: The size estimator (mirror of CHARS_PER_TOKEN / TOKEN_OVERHEAD / IMAGE_TOKENS / maxTokensForText)
    //
    // ONE estimator for the app and the relay: at most one token per 3 characters, plus 64 per request,
    // plus 1,600 per image. The relay counts JavaScript string length (UTF-16 units); the app counts
    // UTF-8 bytes where it sizes case text, which are never fewer — so the app's estimate is never below
    // the relay's, and a read the app offers is never refused by the relay for its size.

    /// Characters per token in the conservative estimate (mirror of CHARS_PER_TOKEN).
    public static let charsPerToken = 3
    /// Tokens added once per request for the framing (mirror of TOKEN_OVERHEAD).
    public static let tokenOverhead = 64
    /// The token ceiling of one image (mirror of IMAGE_TOKENS).
    public static let imageTokens = 1_600
    /// The relay's output ceiling (mirror of MAX_OUTPUT_TOKENS).
    public static let maxOutputTokens = 24_000
    /// The largest ordinary request the relay forwards, in characters (mirror of MAX_INPUT_CHARS).
    public static let maxInputChars = 120_000
    /// The largest confirmed large read, in characters, task included (mirror of LARGE_READ_MAX_INPUT_CHARS).
    public static let largeReadMaxInputChars = 2_800_000

    /// Tokens a text of `characters` is at most worth (mirror of maxTokensForText).
    public static func maxTokensForText(characters: Int) -> Int {
        (max(0, characters) + charsPerToken - 1) / charsPerToken + tokenOverhead
    }

    /// Characters as the relay counts them (estimateMessagesInput): the system prompt — or the two
    /// characters `""` when there is none — and every text block, in UTF-16 units.
    public static func relayCharacters(system: String?, texts: [String]) -> Int {
        (system?.utf16.count ?? 2) + texts.reduce(0) { $0 + $1.utf16.count }
    }

    /// What the relay will RESERVE for a request of `inputCharacters` (the estimator above, every token
    /// at the dearest rate it may be billed at, the output at its clamped allowance): a request fits only
    /// if this fits the balance and the per-request or case-read limit. Mirror of worstCaseCost + creditsFor.
    public static func relayReservation(inputCharacters: Int, images: Int = 0, maxOutputTokens: Int, cacheWrite1h: Bool = false, cacheWrite5m: Bool = false) -> Int {
        let r = relayRates
        let tokens = Double(maxTokensForText(characters: inputCharacters) + images * imageTokens)
        let mult = cacheWrite1h ? r.cacheWrite1h : cacheWrite5m ? r.cacheWrite5m : 1
        let m = (tokens * r.inputPerMTok * max(1, mult) + Double(min(max(1_024, maxOutputTokens), Self.maxOutputTokens)) * r.outputPerMTok).rounded(.up)
        return max(1, Int((m / 10_000).rounded(.up)))
    }

    // MARK: The whole-case safety margin (app side)

    /// Masking may replace a name with a longer placeholder: the case text sent is allowed to grow by 5 %.
    public static let caseReadMaskGrowth = 1.05
    /// Room for the task after the case (a question with its rules, or an analysis task).
    public static let caseReadTaskAllowanceCharacters = 20_000

    /// Whether a whole-case read of `caseCharacters` of case text (UTF-8 bytes) is accepted by the relay
    /// in the worst case: grown by masking, plus the largest task, at the relay's output ceiling and the
    /// 1-hour cache write — within the large-read size limit AND the plan's case-read credit ceiling.
    public static func caseReadFits(caseCharacters: Int, creditCeiling: Int) -> Bool {
        let sent = Int((Double(max(0, caseCharacters)) * caseReadMaskGrowth).rounded(.up)) + caseReadTaskAllowanceCharacters
        guard sent <= largeReadMaxInputChars else { return false }
        return relayReservation(inputCharacters: sent, maxOutputTokens: maxOutputTokens, cacheWrite1h: true) <= creditCeiling
    }

    /// The largest whole-case size (estimated tokens of case text) whose read always fits `creditCeiling`
    /// and the relay's size limit (`caseReadFits` for the most text that estimates to that many tokens).
    public static func caseReadTokenCeiling(creditCeiling: Int) -> Int {
        func fits(_ tokens: Int) -> Bool { caseReadFits(caseCharacters: max(0, tokens - tokenOverhead) * charsPerToken, creditCeiling: creditCeiling) }
        var lo = 0, hi = largeReadMaxInputChars / charsPerToken + tokenOverhead
        guard fits(lo) else { return 0 }
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if fits(mid) { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// Own key: the worst-case US-dollar cost of a request to `model` (the same estimator, every input
    /// token at the dearest rate it may be billed at — a 1-hour cache write is 2× — plus the full output
    /// allowance), or nil when the model's price is not in the table.
    public static func worstCaseUSD(model: String, inputCharacters: Int, images: Int = 0, maxOutputTokens: Int,
                                    cacheWrite1h: Bool = false, cacheWrite5m: Bool = false) -> Double? {
        guard let r = rates[model] else { return nil }
        let tokens = Double(maxTokensForText(characters: inputCharacters) + images * imageTokens)
        let mult = cacheWrite1h ? r.cacheWrite1h : cacheWrite5m ? r.cacheWrite5m : 1
        return (tokens * r.inputPerMTok * max(1, mult) + Double(max(0, maxOutputTokens)) * r.outputPerMTok) / 1_000_000
    }

    /// Own key: the estimated US-dollar cost of a request to `model` at Anthropic's published rates, or
    /// nil when the model's price is not in the table (another provider, or an unknown model).
    public static func estimateUSD(model: String, inputTokens: Int, maxOutputTokens: Int, cachedTokens: Int = 0) -> Double? {
        guard let r = rates[model] else { return nil }
        return micro(inputTokens: inputTokens, maxOutputTokens: maxOutputTokens, cachedTokens: cachedTokens, rates: r) / 1_000_000
    }

    /// A typical (not worst-case) token count for text, ≈ 4 characters per token — only for the
    /// "usually" estimate shown; every limit and refusal uses `maxTokensForText`.
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

    // MARK: Refusals (mirror of REFUSALS.creditsUsed / dailyLimit / tooCostly in relay/src/policy.ts)

    /// The relay's words for the three refusals the app can also tell before sending (word for word).
    public static func creditsUsedMessage(estimate: Int, balance: Int) -> String {
        "This request needs up to \(estimate) credits and \(balance) are left (this month's allowance and your credit packs). Nothing was sent. Buy a credit pack, wait for the allowance to reset, or use your own AI key in Settings."
    }
    public static func dailyLimitMessage(limit: Int) -> String {
        "Today's AI limit of \(limit) credits for this plan is reached. Nothing was sent; it resets at midnight UTC."
    }
    public static func tooCostlyMessage(estimate: Int, ceiling: Int, large: Bool) -> String {
        large
            ? "Reading this much at once needs up to \(estimate) credits, more than this plan's \(ceiling)-credit limit for one read. Nothing was sent; select fewer documents (AI Pro reads more at once)."
            : "This request needs up to \(estimate) credits, more than the \(ceiling) one request may use. Nothing was sent; select fewer passages, or confirm it as a large read."
    }

    /// "$0.42" / "under $0.01".
    public static func formatUSD(_ v: Double) -> String {
        if v < 0.01 { return "under $0.01" }
        return String(format: "$%.2f", v)
    }
}

/// A request on AI Included / AI Pro the app refuses BEFORE sending, because the credit meter (the relay's
/// last receipt) already shows the relay would refuse it — with the relay's own code and words. The relay
/// stays the authority: when the meter is unknown or stale, nothing is refused here.
public nonisolated struct AIPlanRefusal: Error, LocalizedError, Equatable, Sendable {
    public enum Code: String, Sendable { case creditsUsed = "credits-used", dailyLimit = "daily-limit", tooCostly = "too-costly" }
    /// What the person can do about it (buttons next to the message).
    public enum Offer: String, Sendable, Equatable { case buyCredits, upgrade }
    public let code: Code
    public let message: String
    public let estimate: Int
    public let offers: [Offer]
    public init(code: Code, message: String, estimate: Int, offers: [Offer]) {
        self.code = code; self.message = message; self.estimate = estimate; self.offers = offers
    }
    public var errorDescription: String? { message }
}

