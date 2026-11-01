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

    @Test("Only a paid AI Included period or its grace includes AI — never the trial, the edition, or a lapsed state")
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
        #expect(!Entitlement.lapsed(reason: .expired).includesAI && !Entitlement.legacyUnlocked.includesAI)
        // Upgraded from the edition to AI Included: the AI subscription's own id is what the relay gets.
        let both = [record(.monthly, days: 10, id: 1), record(.aiMonthly, days: 40, id: 2)]
        let up = Entitlement.evaluate(records: both, renewal: renew, storeAnswered: true, now: day(12))
        #expect(up.includesAI && Entitlement.aiSubscriptionID(records: both, entitlement: up) == "2")
    }

    @Test("Plans: two durations at each level, AI Included above the edition")
    func plans() {
        #expect(SubscriptionPlan(productID: PurchaseProducts.aiMonthly) == .aiMonthly)
        #expect(SubscriptionPlan(productID: PurchaseProducts.aiTopUp200) == nil, "a top-up is never a subscription")
        #expect(SubscriptionPlan.aiAnnual.isAnnual && SubscriptionPlan.aiAnnual.periodNoun == "year" && SubscriptionPlan.aiAnnual.counterpart == .aiMonthly)
        #expect(PurchaseProducts.storeProducts.contains(PurchaseProducts.aiTopUp200) && !PurchaseProducts.all.contains(PurchaseProducts.aiTopUp200))
        let offer = PlanOffer(plan: .aiAnnual, displayPrice: "₹19,999", periodText: "1 year", eligibleForTrial: false, trialDays: nil)
        #expect(offer.disclosure.hasPrefix("₹19,999 per year, charged now.") && offer.disclosure.contains("keeps only counts"))
    }

    @Test("The relay request carries only the subscription number — never a key — and a non-number is never sent")
    func requestBuilding() throws {
        let r = try OnlineRequestBuilder.build(kind: .included, model: "claude-opus-5", apiKey: "2000000123456789",
                                               system: "S", prompt: "When was the invoice paid?", maxTokens: 100_000)
        #expect(r.url.hasSuffix("/v1/messages"))
        #expect(r.headers["x-kals-subscription"] == "2000000123456789")
        #expect(r.headers["x-api-key"] == nil && r.headers["authorization"] == nil)
        let body = try #require(try JSONSerialization.jsonObject(with: r.body) as? [String: Any])
        #expect(body["max_tokens"] as? Int == 4096 && body["system"] as? String == "S")
        #expect(throws: AIIncludedRelay.RelayError.notSubscribed) {
            try OnlineRequestBuilder.build(kind: .included, model: "m", apiKey: "sk-ant-secret", system: nil, prompt: "p", maxTokens: 10)
        }
        #expect(!OnlineProviderKind.included.usesOwnKey && OnlineProviderKind.included.mayReceiveDocuments)
        #expect(OnlineProviderKind.included.isSelectable == AIIncludedRelay.isConfigured)
        #expect(!OnlineProviderKind.allowedHosts.contains(""))
    }

    @Test("The relay's refusals reach the person in its own words; other errors keep their usual meaning")
    func refusals() throws {
        let used = #"{"error":{"code":"quota-used","message":"This month's AI Included questions are used up."}}"#
        #expect(throws: OnlineRequestBuilder.ParseError.relay("This month's AI Included questions are used up.")) {
            try OnlineRequestBuilder.parse(kind: .included, response: OutboundHTTPResponse(status: 429, body: Data(used.utf8)))
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
        let status = try AIIncludedRelay.parseStatus(OutboundHTTPResponse(status: 200, body: Data(#"{"active":true,"remaining":{"monthly":212,"topUps":200},"paused":false}"#.utf8)))
        #expect(status == .init(monthly: 212, topUps: 200, paused: false) && status.total == 412)
        #expect(try AIIncludedRelay.parseSellable(OutboundHTTPResponse(status: 200, body: Data(#"{"sellable":false}"#.utf8))) == false)
        #expect(try AIIncludedRelay.parseTopUp(OutboundHTTPResponse(status: 200, body: Data(#"{"credited":false,"remaining":{}}"#.utf8))),
                "already credited is still on the account: the transaction may be finished")
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
