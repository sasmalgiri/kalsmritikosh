//
//  AIIncludedTests.swift
//  KalsmritikoshTests
//
//  A2 — AI Included: which states include the publisher's AI, what the relay is told, how its requests
//  are built and its refusals read. No network: the relay client runs against a scripted transport.
//

import Testing
import Foundation
@testable import Kalsmritikosh

@Suite("AI Included (A2)")
struct AIIncludedTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func day(_ n: Double) -> Date { t0.addingTimeInterval(n * 86_400) }
    private func record(_ plan: SubscriptionPlan, days: Double, id: UInt64, revoked: Bool = false, intro: Bool = false) -> Entitlement.Record {
        .init(productID: plan.productID, purchaseDate: t0, originalPurchaseDate: t0, expirationDate: day(days),
              revoked: revoked, isIntroductoryOffer: intro, originalID: id)
    }

    @Test("Only a paid AI Included / AI Pro period or its grace includes AI — never a trial, Workbench, or a lapsed state")
    func includesAI() {
        let renew = Entitlement.Renewal(willAutoRenew: true)
        let ai = Entitlement.evaluate(records: [record(.aiMonthly, days: 30, id: 77)], renewal: renew, storeAnswered: true, now: day(3))
        #expect(ai.includesAI && ai.allowsPaidUse)
        #expect(Entitlement.aiSubscriptionID(records: [record(.aiMonthly, days: 30, id: 77)], entitlement: ai) == "77")
        let edition = Entitlement.evaluate(records: [record(.annual, days: 365, id: 5)], renewal: renew, storeAnswered: true, now: day(3))
        #expect(!edition.includesAI && edition.allowsPaidUse)
        #expect(Entitlement.aiSubscriptionID(records: [record(.annual, days: 365, id: 5)], entitlement: edition) == nil)
        let trial = Entitlement.evaluate(records: [record(.aiAnnual, days: 14, id: 9, intro: true)], renewal: renew, storeAnswered: true, now: day(3))
        #expect(!trial.includesAI, "the owner's rule: no included AI in the free trial")
        #expect(Entitlement.grace(until: day(40), plan: .aiAnnual).includesAI)
        #expect(!Entitlement.billingRetry(plan: .aiMonthly).includesAI)
        #expect(!Entitlement.lapsed(reason: .expired).includesAI && !Entitlement.testHostUnlocked.includesAI)
        #expect(Entitlement.grace(until: day(40), plan: .proMonthly).aiTier == .aiPro)
        // Upgraded from the edition to AI Included: the AI subscription's own id is what the relay gets.
        let both = [record(.monthly, days: 10, id: 1), record(.aiMonthly, days: 40, id: 2)]
        let up = Entitlement.evaluate(records: both, renewal: renew, storeAnswered: true, now: day(12))
        #expect(up.includesAI && Entitlement.aiSubscriptionID(records: both, entitlement: up) == "2")
    }

    @Test("Plans: two durations at each level; credit packs are never subscriptions; every AI price carries the credit terms")
    func plans() {
        #expect(SubscriptionPlan(productID: PurchaseProducts.aiMonthly) == .aiMonthly)
        #expect(SubscriptionPlan(productID: PurchaseProducts.proAnnual) == .proAnnual)
        #expect(SubscriptionPlan(productID: PurchaseProducts.credits2000) == nil, "a credit pack is never a subscription")
        #expect(SubscriptionPlan.aiAnnual.isAnnual && SubscriptionPlan.aiAnnual.periodNoun == "year" && SubscriptionPlan.aiAnnual.counterpart == .aiMonthly)
        #expect(PurchaseProducts.storeProducts.contains(PurchaseProducts.credits500) && !PurchaseProducts.all.contains(PurchaseProducts.credits500))
        let offer = PlanOffer(plan: .aiAnnual, displayPrice: "$389.00", periodText: "1 year", eligibleForTrial: false, trialDays: nil)
        #expect(offer.disclosure.hasPrefix("$389.00 per year, charged now.") && offer.disclosure.contains("keeps only counts and credits"))
        #expect(offer.disclosure.contains("2,000 AI credits a month") && offer.disclosure.contains("same allowance every month") && offer.disclosure.contains("never expire"))
        let pro = PlanOffer(plan: .proMonthly, displayPrice: "$99.00", periodText: "1 month", eligibleForTrial: false, trialDays: nil)
        #expect(pro.disclosure.contains("6,000 AI credits a month") && pro.disclosure.contains("3,000"))
        let wb = PlanOffer(plan: .monthly, displayPrice: "$4.99", periodText: "1 month", eligibleForTrial: true, trialDays: 14)
        #expect(!wb.disclosure.contains("credits"), "Workbench has no relay credits")
        #expect(PlanTier.workbench.includes.contains("your own Anthropic key") && PlanTier.aiIncluded.includes.contains("No free trial"))
    }

    @Test("The relay request carries only the subscription number — never a key — and a non-number is never sent")
    func requestBuilding() throws {
        let r = try OnlineRequestBuilder.build(kind: .included, model: "claude-opus-5", apiKey: "2000000123456789",
                                               system: "S", prompt: "When was the invoice paid?", maxTokens: 100_000)
        #expect(r.url.hasSuffix("/v1/messages"))
        #expect(r.headers["x-kals-subscription"] == "2000000123456789")
        #expect(r.headers["x-api-key"] == nil && r.headers["authorization"] == nil)
        let body = try #require(try JSONSerialization.jsonObject(with: r.body) as? [String: Any])
        #expect(body["max_tokens"] as? Int == OnlineRequestBuilder.anthropicMaxTokens(100_000) && body["system"] as? String == "S")
        #expect(OnlineRequestBuilder.anthropicMaxTokens(100_000) <= 24_000, "within the relay's output ceiling")
        #expect(r.headers["x-kals-large-read"] == nil, "a large read is only ever marked after confirmation")
        let large = try AIIncludedRelay.$confirmedLargeRead.withValue(true) {
            try OnlineRequestBuilder.build(kind: .included, model: "claude-opus-5", apiKey: "2000000123456789", system: nil, prompt: "p", maxTokens: 2_000)
        }
        #expect(large.headers["x-kals-large-read"] == "confirmed")
        #expect(throws: AIIncludedRelay.RelayError.notSubscribed) {
            try OnlineRequestBuilder.build(kind: .included, model: "m", apiKey: "sk-ant-secret", system: nil, prompt: "p", maxTokens: 10)
        }
        #expect(!OnlineProviderKind.included.usesOwnKey && OnlineProviderKind.included.mayReceiveDocuments)
        #expect(OnlineProviderKind.included.isSelectable == AIIncludedRelay.isConfigured)
        #expect(!OnlineProviderKind.allowedHosts.contains(""))
    }

    @Test("The relay's refusals reach the person in its own words; other errors keep their usual meaning")
    func refusals() throws {
        let used = #"{"error":{"code":"credits-used","message":"This request needs up to 60 credits and 12 are left.","estimate":60,"balance":12}}"#
        #expect(throws: OnlineRequestBuilder.ParseError.relay("This request needs up to 60 credits and 12 are left.")) {
            try OnlineRequestBuilder.parse(kind: .included, response: OutboundHTTPResponse(status: 402, body: Data(used.utf8)))
        }
        for code in ["daily-limit", "too-costly"] {
            #expect(AIIncludedRelay.refusal(in: Data(#"{"error":{"code":"\#(code)","message":"m"}}"#.utf8)) == "m")
        }
        let paused = #"{"error":{"code":"capacity-paused","message":"paused until the 1st"}}"#
        #expect(throws: OnlineRequestBuilder.ParseError.relay("paused until the 1st")) {
            try OnlineRequestBuilder.parse(kind: .included, response: OutboundHTTPResponse(status: 503, body: Data(paused.utf8)))
        }
        // Anthropic's own error passed through the relay is not mistaken for a relay refusal.
        #expect(throws: OnlineRequestBuilder.ParseError.server(529)) {
            try OnlineRequestBuilder.parse(kind: .included, response: OutboundHTTPResponse(status: 529, body: Data(#"{"error":{"type":"overloaded_error","message":"x"}}"#.utf8)))
        }
        let ok = #"{"content":[{"type":"text","text":"On 3 May."}],"stop_reason":"end_turn"}"#
        #expect(try OnlineRequestBuilder.parse(kind: .included, response: OutboundHTTPResponse(status: 200, body: Data(ok.utf8))) == "On 3 May.")
    }

    @Test("Status, availability and top-up replies are read strictly")
    func relayReplies() throws {
        let status = try AIIncludedRelay.parseStatus(OutboundHTTPResponse(status: 200, body: Data(#"{"active":true,"paused":false,"kals":{"plan":"pro","monthlyCredits":6000,"allowanceUsed":100,"allowanceLeft":5900,"topUps":500,"dailyUsed":100,"dailyLimit":4000,"perRequestCredits":400,"caseReadCredits":3000,"periodStartsAt":"2026-11-15T10:00:00.000Z","periodEndsAt":"2026-12-15T10:00:00.000Z"}}"#.utf8)))
        #expect(status.receipt.balance == 6_400 && status.receipt.plan == "pro" && !status.paused && status.receipt.charged == nil)
        #expect(status.receipt.periodEndsAt == ISO8601DateFormatter().date(from: "2026-12-15T10:00:00Z"))
        #expect(try AIIncludedRelay.parseSellable(OutboundHTTPResponse(status: 200, body: Data(#"{"sellable":false}"#.utf8))) == false)
        #expect(try AIIncludedRelay.parseTopUp(OutboundHTTPResponse(status: 200, body: Data(#"{"credited":false,"revoked":false,"kals":{}}"#.utf8))) == .onAccount,
                "already credited is still on the account: the transaction may be finished")
        #expect(try AIIncludedRelay.parseTopUp(OutboundHTTPResponse(status: 200, body: Data(#"{"credited":false,"revoked":true}"#.utf8))) == .revoked)
        #expect(throws: AIIncludedRelay.RelayError.refused("The request was not in the expected form: not a valid top-up")) {
            try AIIncludedRelay.parseTopUp(OutboundHTTPResponse(status: 400, body: Data(#"{"error":{"code":"bad-request","message":"The request was not in the expected form: not a valid top-up"}}"#.utf8)))
        }
        #expect(throws: AIIncludedRelay.RelayError.unreadable) {
            try AIIncludedRelay.parseStatus(OutboundHTTPResponse(status: 502, body: Data("<html>".utf8)))
        }
    }

    @Test("Online settings: AI Included has no key of its own and its model is the relay's")
    func settings() {
        #expect(!OnlineSettings.setAPIKey("sk-ant-anything", for: .included), "no key is ever stored for AI Included")
        if !AIIncludedRelay.isConfigured { #expect(OnlineSettings.apiKey(for: .included) == nil) }
        #expect(OnlineProviderKind.included.defaultModel == "claude-opus-5")
    }

    @Test("A3: AI is off by App Store country — blocked and unknown countries refuse, every AI send refuses there, settings and plans follow")
    func regionSwitch() async throws {
        #expect(AIRegion.decision(countryCode: "USA") == .allowed)
        #expect(AIRegion.decision(countryCode: "ind") == .allowed)
        guard case .blocked(let c, _) = AIRegion.decision(countryCode: "CHN") else { Issue.record("CHN must be blocked"); return }
        #expect(c == "CHN")
        #expect(AIRegion.decision(countryCode: nil) == .unknown && AIRegion.decision(countryCode: "").explanation != nil,
                "an unanswered store never opens a blocked feature")
        #expect(AIRegion.allowsAI, "the unit-test host reads as an allowed storefront")
        try await AIRegion.TestOverride.$country.withValue("CHN") {
            #expect(!AIRegion.allowsAI && !OnlineSettings.cloudAllowed)
            #expect(!OnlineProviderKind.included.isSelectable)
            let req = try OnlineRequestBuilder.build(kind: .anthropic, model: "claude-opus-5", apiKey: "k", system: nil, prompt: "p", maxTokens: 10)
            do {
                _ = try await NetworkHelperClient.send(req)
                Issue.record("an AI send must not leave in a blocked country")
            } catch let e as NetworkHelperError {
                // A build without the helper refuses first; with it, the region refusal is the reason.
                if case .failed(let why) = e { #expect(why.contains("not available for App Store accounts in this country")) }
            }
        }
    }
}
