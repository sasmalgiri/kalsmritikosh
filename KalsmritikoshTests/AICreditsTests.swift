//
//  AICreditsTests.swift
//  KalsmritikoshTests
//
//  Plans and credits (owner decisions 2026-11-04) — the app's side: the price table and the estimates
//  (credits for an AI plan, dollars for an own key), the relay's receipt, the credit pack's account
//  token (identical to the relay's), the meter's checks and prompts, the own-key monthly limit, and the
//  app's mirror of relay/src/policy.ts. No network, no purchase.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("AI credits, estimates and the own-key limit", .serialized)
struct AICreditsTests {

    @Test("Estimates use Anthropic's published rates: $5 in, $25 out, cache reads 0.1×; 1 credit = $0.01, rounded up, at least 1")
    func estimates() {
        #expect(AIPricing.estimateCredits(inputTokens: 1_000_000, maxOutputTokens: 0) == 500)
        #expect(AIPricing.estimateCredits(inputTokens: 0, maxOutputTokens: 1_000_000) == 2_500)
        #expect(AIPricing.estimateCredits(inputTokens: 1_000_000, maxOutputTokens: 0, cachedTokens: 1_000_000) == 50)
        #expect(AIPricing.estimateCredits(inputTokens: 10, maxOutputTokens: 10) == 1)
        // A 200,000-token case read with a 10,000-token reply: $1.00 + $0.25 → 125 credits; again from the cache: 10 + 25.
        #expect(AIPricing.estimateCredits(inputTokens: 200_000, maxOutputTokens: 10_000) == 125)
        #expect(AIPricing.estimateCredits(inputTokens: 200_000, maxOutputTokens: 10_000, cachedTokens: 200_000) == 35)
        // Own key: dollars at the same table; unknown models have no estimate.
        #expect(AIPricing.estimateUSD(model: "claude-opus-5", inputTokens: 1_000_000, maxOutputTokens: 1_000_000) == 30)
        #expect(AIPricing.estimateUSD(model: "some-other-model", inputTokens: 1, maxOutputTokens: 1) == nil)
        // The relay's reservation is the conservative worst case (chars ÷ 3, dearest cache rate).
        let r = AIPricing.relayReservation(inputCharacters: 300_000, maxOutputTokens: 10_000)
        #expect(r == Int(((Double(100_064) * 5 + 10_000 * 25) / 10_000).rounded(.up)))
        #expect(AIPricing.relayReservation(inputCharacters: 300_000, maxOutputTokens: 10_000, cacheWrite1h: true) > r)
        #expect(AIPricing.formatUSD(0.004) == "under $0.01" && AIPricing.formatUSD(1.234) == "$1.23")
    }

    @Test("Actual cost from a reply's usage: cache writes 1.25× (5 min) / 2× (1 h, also when unsplit), reads 0.1×")
    func actualCost() {
        let u: [String: Any] = ["input_tokens": 2_000, "cache_read_input_tokens": 100_000, "cache_creation_input_tokens": 20_000,
                                "cache_creation": ["ephemeral_5m_input_tokens": 20_000, "ephemeral_1h_input_tokens": 0], "output_tokens": 3_000]
        #expect(abs((AIPricing.actualUSD(model: "claude-opus-5", usage: u) ?? 0) - 0.26) < 1e-9)
        let unsplit: [String: Any] = ["cache_creation_input_tokens": 1_000_000]
        #expect(AIPricing.actualUSD(model: "claude-opus-5", usage: unsplit) == 10)
    }

    @Test("The credit pack's appAccountToken is the relay's (same input, same UUID)")
    func accountToken() {
        // relay/test/relay.test.ts prints accountToken("2000000123456789") = b9902962-ab02-5bae-89c3-912998940720.
        #expect(AIIncludedRelay.accountToken(subscription: "2000000123456789").uuidString.lowercased() == "b9902962-ab02-5bae-89c3-912998940720")
        #expect(AIIncludedRelay.accountToken(subscription: "1") != AIIncludedRelay.accountToken(subscription: "2"))
    }

    @Test("A relay reply's receipt reaches the meter: allowance left, packs, the reset date and the last request's cost")
    @MainActor func receiptToMeter() {
        let body = #"{"content":[{"type":"text","text":"ok"}],"kals":{"plan":"ai","monthlyCredits":2000,"allowanceUsed":160,"allowanceLeft":1840,"topUps":500,"dailyUsed":160,"dailyLimit":1500,"perRequestCredits":400,"caseReadCredits":600,"periodStartsAt":"2026-11-15T10:00:00.000Z","periodEndsAt":"2026-12-15T10:00:00.000Z","charged":12,"reserved":60}}"#
        let r = try? #require(AIIncludedRelay.receipt(in: Data(body.utf8)))
        #expect(r?.charged == 12 && r?.reserved == 60 && r?.balance == 2_340)
        let m = AICreditMeter()
        m.planChanged(.aiIncluded)
        if let r { m.apply(r) }
        #expect(m.balance == 2_340 && m.lastCharged == 12 && m.tier == .aiIncluded)
        #expect(m.summaryLine == "1,840 of 2,000 credits left this month · 500 in packs · last request 12 credits")
        #expect(m.resetText?.hasPrefix("resets ") == true)
        #expect(m.caseReadPrompt(credits: 120) == "Reading this case: about 120 credits; you have 2,340.")
        #expect(AIIncludedRelay.receipt(in: Data(#"{"content":[]}"#.utf8)) == nil)
    }

    @Test("The meter says before sending when a request will not fit: the plan's limits and the balance")
    @MainActor func meterRefusals() {
        let m = AICreditMeter()
        #expect(m.refusal(credits: 5, largeRead: false)?.contains("No AI plan") == true)
        m.planChanged(.aiIncluded)
        #expect(m.refusal(credits: 50, largeRead: false) == nil, "balance not known yet: the relay decides")
        #expect(m.refusal(credits: 401, largeRead: false)?.contains("more than the 400 one request may use") == true)
        #expect(m.refusal(credits: 500, largeRead: true) == nil)
        #expect(m.refusal(credits: 700, largeRead: true)?.contains("AI Pro reads more at once") == true)
        m.apply(AIIncludedRelay.Receipt(plan: "ai", monthlyCredits: 2000, allowanceLeft: 30, topUps: 0, dailyUsed: 0, dailyLimit: 1500,
                                        perRequestCredits: 400, caseReadCredits: 600, periodEndsAt: nil, charged: nil, reserved: nil))
        #expect(m.refusal(credits: 50, largeRead: false)?.contains("Up to 50 credits are held while this runs (it usually costs far less), and you have 30") == true)
        m.planChanged(.aiPro)
        #expect(m.limits?.caseReadCredits == 3_000)
        m.planChanged(nil)
        #expect(m.balance == nil && m.summaryLine == nil)
        // The case reader's estimator hook is the same function.
        #expect(m.estimateCredits(inputTokens: 200_000, maxOutputTokens: 10_000) == AIPricing.estimateCredits(inputTokens: 200_000, maxOutputTokens: 10_000))
    }

    @Test("Own key: a monthly limit the person sets, a local tally from Anthropic's usage, and a clear refusal once reached")
    func ownKeyLimit() {
        let saved = OwnKeyBudget.monthlyLimitUSD
        defer { OwnKeyBudget.monthlyLimitUSD = saved }
        let when = Date(timeIntervalSince1970: 946_684_800)   // January 2000: a month nothing real uses
        let key = OwnKeyBudget.tallyPrefix + OwnKeyBudget.monthKey(when)
        OwnKeyBudget.defaults.removeObject(forKey: key)
        defer { OwnKeyBudget.defaults.removeObject(forKey: key) }
        OwnKeyBudget.monthlyLimitUSD = nil
        #expect(OwnKeyBudget.refusal(now: when) == nil, "no limit set")
        OwnKeyBudget.monthlyLimitUSD = 1
        let reply = #"{"content":[],"usage":{"input_tokens":100000,"output_tokens":10000}}"#   // $0.50 + $0.25
        OwnKeyBudget.record(responseBody: Data(reply.utf8), model: "claude-opus-5", at: when)
        #expect(abs(OwnKeyBudget.spentUSD(now: when) - 0.75) < 1e-9)
        #expect(OwnKeyBudget.refusal(now: when) == nil)
        OwnKeyBudget.record(responseBody: Data(reply.utf8), model: "claude-opus-5", at: when)
        let why = OwnKeyBudget.refusal(now: when)
        #expect(why?.contains("monthly limit for your own AI key ($1.00) is reached") == true, "\(why ?? "nil")")
        OwnKeyBudget.monthlyLimitUSD = 0
        #expect(OwnKeyBudget.monthlyLimitUSD == nil, "0 or blank = no limit")
        #expect(OwnKeyBudget.estimateLine(model: "claude-opus-5", inputTokens: 2_000, maxOutputTokens: 10_000)?.hasPrefix("Estimated cost: up to $0.26") == true)
        #expect(OwnKeyBudget.estimateLine(model: "unknown", inputTokens: 1, maxOutputTokens: 1) == nil)
    }

    @Test("The consent dialog's estimate: credits on an AI plan, dollars on an own Claude key, nothing for other providers")
    func consentEstimate() async {
        let prompt = String(repeating: "word ", count: 2_000)
        let plan = await OnlineCloudProvider.costEstimate(kind: .included, model: "claude-opus-5", system: nil, prompt: prompt, images: [], maxTokens: 1_500)
        #expect(plan?.hasPrefix("Up to ") == true && plan?.contains("credits") == true, "\(plan ?? "nil")")
        let own = await OnlineCloudProvider.costEstimate(kind: .anthropic, model: "claude-opus-5", system: nil, prompt: prompt, images: [], maxTokens: 1_500)
        #expect(own?.hasPrefix("Estimated cost: up to $") == true)
        #expect(await OnlineCloudProvider.costEstimate(kind: .openai, model: "x", system: nil, prompt: prompt, images: [], maxTokens: 1_500) == nil)
    }

    @Test("The app's plan and price mirror matches relay/src/policy.ts, the one authority")
    func mirrorsRelayPolicy() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("relay/src/policy.ts")
        let ts = try String(contentsOf: url, encoding: .utf8).replacingOccurrences(of: "_", with: "")
        func plan(_ name: String, _ l: AIPricing.PlanLimits) {
            let line = ts.split(separator: "\n").first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("\(name):") && $0.contains("monthlyCredits") }.map(String.init) ?? ""
            for (k, v) in [("monthlyCredits", l.monthlyCredits), ("yearlyMonthlyCredits", l.yearlyMonthlyCredits), ("perRequestCredits", l.perRequestCredits), ("caseReadCredits", l.caseReadCredits), ("dailyCredits", l.dailyCredits)] {
                #expect(line.range(of: "\(k):\\s*\(v)\\b", options: .regularExpression) != nil, "\(name).\(k) = \(v) not in: \(line)")
            }
        }
        plan("ai", AIPricing.aiIncluded)
        plan("pro", AIPricing.aiPro)
        #expect(ts.contains("[PRODUCTS.credits500]: 500") && ts.contains("[PRODUCTS.credits2000]: 2000"))
        #expect(ts.contains(#""claude-opus-5": { inputPerMTok: 5, outputPerMTok: 25, cacheWrite5m: 1.25, cacheWrite1h: 2, cacheRead: 0.1, batch: 0.5 }"#))
        for id in PurchaseProducts.storeProducts where id != PurchaseProducts.monthly && id != PurchaseProducts.annual {
            #expect(ts.contains("\"\(id)\""), "\(id) missing from the relay's PRODUCTS")
        }
        #expect(AIPricing.rates["claude-opus-5"] == .init(inputPerMTok: 5, outputPerMTok: 25, cacheWrite5m: 1.25, cacheWrite1h: 2, cacheRead: 0.1, batch: 0.5))
    }
}
