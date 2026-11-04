//
//  AICredits.swift
//  Kalsmritikosh
//
//  Plans and credits (owner decisions 2026-11-04) — what the person sees about AI cost:
//   • AICreditMeter: the AI plan's credits as the relay last reported them (this month's allowance
//     used/left, credit-pack balance, the reset date, the last request's cost), the estimate shown
//     before a large read, and the check that a request fits. The relay is the authority (it meters);
//     this only mirrors its receipts, which arrive with every reply (`kals`) and status check.
//   • OwnKeyBudget: own-key users (Workbench, or any plan with their own Anthropic key) — an estimated
//     dollar cost before a send and a monthly limit THE PERSON sets, enforced in the app from a local
//     tally of the `usage` Anthropic reports. Nothing here is sent anywhere.
//

import Foundation
import Observation
import os

@MainActor
@Observable
final class AICreditMeter {
    static let shared = AICreditMeter()

    /// The AI plan that stands (from verified StoreKit records; nil = none).
    private(set) var tier: PlanTier?
    /// The relay's last receipt (nil until the first status check or reply).
    private(set) var receipt: AIIncludedRelay.Receipt?
    private(set) var paused = false
    /// What the last request through the relay cost, and when.
    private(set) var lastCharged: Int?
    private(set) var lastChargedAt: Date?
    private(set) var updatedAt: Date?

    /// Credits left: this month's allowance plus credit packs (nil until the relay has answered once).
    var balance: Int? { receipt?.balance }
    var limits: AIPricing.PlanLimits? { tier?.limits }

    /// Estimated credits for a request (see AIPricing.estimateCredits).
    func estimateCredits(inputTokens: Int, maxOutputTokens: Int, cachedTokens: Int = 0) -> Int {
        AIPricing.estimateCredits(inputTokens: inputTokens, maxOutputTokens: maxOutputTokens, cachedTokens: cachedTokens)
    }

    /// The line shown before a large case read: "Reading this case: about 120 credits; you have 840."
    func caseReadPrompt(credits: Int) -> String {
        let have = balance.map { "you have \($0.formatted())" } ?? "your balance is shown after the first AI request this month"
        return "Reading this case: about \(credits.formatted()) credits; \(have)."
    }

    /// nil when a request of about `credits` may be tried; otherwise why not (said before anything is sent).
    func refusal(credits: Int, largeRead: Bool) -> String? {
        guard let l = limits else { return "No AI plan (AI Included or AI Pro) is active for this Apple account." }
        let ceiling = largeRead ? l.caseReadCredits : l.perRequestCredits
        if credits > ceiling {
            return largeRead
                ? "Reading this much at once needs about \(credits.formatted()) credits, more than \(tier?.name ?? "this plan")'s \(ceiling.formatted())-credit limit for one read. Select fewer documents\(tier == .aiIncluded ? " (AI Pro reads more at once)" : "")."
                : "This request needs about \(credits.formatted()) credits, more than the \(ceiling) one request may use. Select fewer passages."
        }
        if let b = balance, credits > b {
            return "This needs about \(credits.formatted()) credits and \(b.formatted()) are left. Buy a credit pack in Settings ▸ Online, wait for the monthly reset, or use your own key."
        }
        if paused { return "The AI service has reached this month's capacity and is paused until the 1st. Nothing is charged meanwhile." }
        return nil
    }

    func planChanged(_ t: PlanTier?) {
        guard t != tier else { return }
        tier = t
        if t == nil { receipt = nil; lastCharged = nil; lastChargedAt = nil }
    }

    func apply(_ s: AIIncludedRelay.Status) {
        apply(s.receipt)
        paused = s.paused
    }

    func apply(_ r: AIIncludedRelay.Receipt, at: Date = Date()) {
        receipt = r
        if let t = PlanTier(relayCode: r.plan) { tier = t }
        if let c = r.charged { lastCharged = c; lastChargedAt = at }
        updatedAt = at
    }

    /// A relay reply body (any layer, any actor): its `kals` receipt, when it carries one, is shown.
    nonisolated static func recordReceipt(responseBody: Data) {
        guard let r = AIIncludedRelay.receipt(in: responseBody) else { return }
        Task { @MainActor in AICreditMeter.shared.apply(r) }
    }

    /// One summary line for the Ask and case screens.
    var summaryLine: String? {
        guard let tier else { return nil }
        guard let r = receipt else { return "\(tier.name): \((tier.limits?.monthlyCredits ?? 0).formatted()) credits a month" }
        var s = "\(r.allowanceLeft.formatted()) of \(r.monthlyCredits.formatted()) credits left this month"
        if r.topUps > 0 { s += " · \(r.topUps.formatted()) in packs" }
        if let c = lastCharged { s += " · last request \(c) credit\(c == 1 ? "" : "s")" }
        return s
    }

    /// The reset date as shown ("resets 15 Dec").
    var resetText: String? {
        guard let d = receipt?.periodEndsAt else { return nil }
        return "resets \(d.formatted(date: .abbreviated, time: .omitted))"
    }

    /// Install the case reader's hooks (CloudUsage.swift): the credit estimator, and the usage sink that
    /// keeps the own-key tally for whole-case reads.
    nonisolated static func installHooks() {
        CloudUsageMeter.install(creditEstimator: { input, maxOut, cached in
            AIPricing.estimateCredits(inputTokens: input, maxOutputTokens: maxOut, cachedTokens: cached)
        })
        CloudUsageMeter.install(sink: { usage in
            guard usage.provider == OnlineProviderKind.anthropic.rawValue else { return }
            OwnKeyBudget.record(usage: ["input_tokens": usage.inputTokens, "cache_creation_input_tokens": usage.cacheWriteTokens,
                                        "cache_read_input_tokens": usage.cacheReadTokens, "output_tokens": usage.outputTokens],
                                model: OnlineSettings.model)
        })
    }
}

/// Own key: the person's monthly limit and the local tally of what Anthropic reported (UTC calendar month).
nonisolated enum OwnKeyBudget {
    /// The send refused because the person's own monthly limit is reached.
    struct LimitReached: LocalizedError, Equatable {
        let reason: String
        var errorDescription: String? { reason }
    }
    static let limitKey = "kalsmritikosh.online.ownKeyMonthlyLimitUSD"
    static let tallyPrefix = "kalsmritikosh.online.ownKeySpendUSD."
    private static let lock = OSAllocatedUnfairLock()

    static var defaults: UserDefaults { AppDefaults.store }

    static func monthKey(_ d: Date) -> String {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC") ?? .current
        let p = c.dateComponents([.year, .month], from: d)
        return String(format: "%04d-%02d", p.year ?? 0, p.month ?? 0)
    }

    /// The person's monthly limit in US dollars (nil = no limit).
    static var monthlyLimitUSD: Double? {
        get { (defaults.object(forKey: limitKey) as? Double).flatMap { $0 > 0 ? $0 : nil } }
        set {
            if let v = newValue, v > 0 { defaults.set(v, forKey: limitKey) } else { defaults.removeObject(forKey: limitKey) }
        }
    }

    /// What Anthropic's replies this month add up to (estimated from their `usage`, at published prices).
    static func spentUSD(now: Date = Date()) -> Double {
        defaults.double(forKey: tallyPrefix + monthKey(now))
    }

    static func add(usd: Double, at: Date = Date()) {
        guard usd > 0 else { return }
        lock.withLock {
            let k = tallyPrefix + monthKey(at)
            defaults.set(defaults.double(forKey: k) + usd, forKey: k)
        }
    }

    /// Add one reply's usage (Anthropic `usage` object) to this month's tally.
    static func record(usage: [String: Any], model: String, at: Date = Date()) {
        if let v = AIPricing.actualUSD(model: model, usage: usage) { add(usd: v, at: at) }
    }

    /// Add one reply (its raw body) to the tally.
    static func record(responseBody: Data, model: String, at: Date = Date()) {
        guard let root = (try? JSONSerialization.jsonObject(with: responseBody)) as? [String: Any],
              let usage = root["usage"] as? [String: Any] else { return }
        record(usage: usage, model: model, at: at)
    }

    /// nil when a send may go; otherwise the clear reason it may not (the monthly limit is reached).
    static func refusal(now: Date = Date()) -> String? {
        guard let limit = monthlyLimitUSD else { return nil }
        let spent = spentUSD(now: now)
        guard spent >= limit else { return nil }
        return "Not sent: your monthly limit for your own AI key (\(AIPricing.formatUSD(limit))) is reached — about \(AIPricing.formatUSD(spent)) used this month (estimated from Anthropic's replies). Raise the limit in Settings ▸ Online, or wait for the new month."
    }

    /// The line shown before an own-key send ("Estimated cost: up to $0.42 on your Anthropic account").
    static func estimateLine(model: String, inputTokens: Int, maxOutputTokens: Int, cachedTokens: Int = 0) -> String? {
        guard let usd = AIPricing.estimateUSD(model: model, inputTokens: inputTokens, maxOutputTokens: maxOutputTokens, cachedTokens: cachedTokens) else { return nil }
        var s = "Estimated cost: up to \(AIPricing.formatUSD(usd)) on your Anthropic account (list prices; usually less)."
        if let limit = monthlyLimitUSD { s += " This month: about \(AIPricing.formatUSD(spentUSD())) of your \(AIPricing.formatUSD(limit)) limit." }
        return s
    }
}
