//
//  PayAsYouGoTests.swift
//  KalsmritikoshTests
//
//  Pay as you go (owner decision 2026-11-15): AI credit packs without a subscription. The rules without StoreKit —
//  which token a pack is bought with, where it is credited, how a new Mac recovers the token, which pack is the
//  credential, what packs open (AI asks only), the meter for a pack-only account, the words, the plan-picker text and
//  the Info.plist key. The StoreKit journey is PlanJourneySimulationTests.payAsYouGoJourney; the relay's side is
//  relay/test/relay.test.ts ("pay as you go: …").
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Pay as you go — credit packs without a subscription")
struct PayAsYouGoTests {
    static let sub = "2000000123456789"
    static let mine = UUID(uuidString: "6F1C2D3E-4B5A-4C6D-8E7F-0123456789AB")!
    static let other = UUID(uuidString: "0A0B0C0D-1E1F-4A2B-9C3D-4E5F60718293")!
    static func pack(_ id: UInt64, _ token: UUID?, daysAgo: Double, revoked: Bool = false, finished: Bool = true) -> PackRecord {
        PackRecord(transactionID: id, productID: PurchaseProducts.credits500, purchaseDate: Date(timeIntervalSince1970: 1_800_000_000 - daysAgo * 86_400),
                   appAccountToken: token, revoked: revoked, finished: finished, signedTransaction: "h.p\(id).s")
    }

    @Test("Purchase token: an AI subscriber's pack keeps the subscription's derived token; with no AI plan, this Mac's token")
    func purchaseToken() {
        var made = 0
        let derived = PayAsYouGo.purchaseToken(aiSubscriptionID: Self.sub, accountToken: { made += 1; return Self.mine })
        #expect(derived == AIIncludedRelay.accountToken(subscription: Self.sub) && made == 0, "the plan's packs go to the plan, as before")
        #expect(PayAsYouGo.purchaseToken(aiSubscriptionID: nil, accountToken: { Self.mine }) == Self.mine)
        #expect(PayAsYouGo.purchaseToken(aiSubscriptionID: nil, accountToken: { nil }) == nil, "no token kept: nothing is bought")
        #expect(PayAsYouGo.purchaseToken(aiSubscriptionID: "not-a-number", accountToken: { Self.mine }) == Self.mine)
    }

    @Test("Route: the plan's pack to the plan, a pay-as-you-go pack to the token account, a refunded stray finished, anything else waits")
    func route() {
        let planToken = AIIncludedRelay.accountToken(subscription: Self.sub)
        #expect(PayAsYouGo.route(packToken: planToken, revoked: false, aiSubscriptionID: Self.sub, hasSubscriptionCredential: true, accountToken: Self.mine) == .subscription)
        #expect(PayAsYouGo.route(packToken: Self.mine, revoked: false, aiSubscriptionID: Self.sub, hasSubscriptionCredential: true, accountToken: Self.mine) == .payAsYouGo,
                "a pack bought before subscribing stays on the pay-as-you-go account")
        #expect(PayAsYouGo.route(packToken: Self.mine, revoked: true, aiSubscriptionID: nil, hasSubscriptionCredential: false, accountToken: Self.mine) == .payAsYouGo,
                "a refunded pay-as-you-go pack is reported to the relay")
        #expect(PayAsYouGo.route(packToken: planToken, revoked: false, aiSubscriptionID: nil, hasSubscriptionCredential: false, accountToken: Self.mine) == .waitForPlan)
        #expect(PayAsYouGo.route(packToken: planToken, revoked: true, aiSubscriptionID: nil, hasSubscriptionCredential: false, accountToken: Self.mine) == .finishRefunded)
        #expect(PayAsYouGo.route(packToken: Self.other, revoked: false, aiSubscriptionID: nil, hasSubscriptionCredential: false, accountToken: Self.mine) == .waitForPlan)
        #expect(PayAsYouGo.route(packToken: Self.mine, revoked: false, aiSubscriptionID: nil, hasSubscriptionCredential: false, accountToken: nil) == .waitForPlan)
    }

    @Test("A new Mac recovers the token from the newest pack not bought with an AI plan; none when every pack is a plan's")
    func recoverToken() {
        let planToken = AIIncludedRelay.accountToken(subscription: Self.sub)
        let packs = [Self.pack(1, Self.other, daysAgo: 30), Self.pack(2, Self.mine, daysAgo: 3), Self.pack(3, planToken, daysAgo: 1), Self.pack(4, nil, daysAgo: 0)]
        #expect(PayAsYouGo.recoverToken(packs: packs, subscriptionIDs: [Self.sub]) == Self.mine)
        #expect(PayAsYouGo.recoverToken(packs: [Self.pack(3, planToken, daysAgo: 1)], subscriptionIDs: [Self.sub]) == nil)
        #expect(PayAsYouGo.recoverToken(packs: [], subscriptionIDs: []) == nil)
    }

    @Test("The credential: the newest unrefunded pack of this token, preferring one the relay has credited")
    func credential() {
        let packs = [Self.pack(1, Self.mine, daysAgo: 10), Self.pack(2, Self.mine, daysAgo: 1, finished: false),
                     Self.pack(3, Self.mine, daysAgo: 0, revoked: true), Self.pack(4, Self.other, daysAgo: 0)]
        #expect(PayAsYouGo.credential(packs: packs, token: Self.mine)?.transactionID == 1)
        #expect(PayAsYouGo.credential(packs: [Self.pack(2, Self.mine, daysAgo: 1, finished: false)], token: Self.mine)?.transactionID == 2)
        #expect(PayAsYouGo.credential(packs: packs, token: nil) == nil)
        #expect(PayAsYouGo.credential(packs: [Self.pack(3, Self.mine, daysAgo: 0, revoked: true)], token: Self.mine) == nil)
    }

    @Test("Restore says plainly what it found: pay-as-you-go credits back, a Keychain failure, packs that belong to a plan, or nothing")
    func restoreNote() {
        #expect(PayAsYouGo.restoreNote(packs: [], recovered: true, keychainFailed: false)?.hasPrefix("Restored: your pay-as-you-go credits.") == true)
        #expect(PayAsYouGo.restoreNote(packs: [Self.pack(1, Self.mine, daysAgo: 1)], recovered: false, keychainFailed: true)?.contains("Keychain") == true)
        #expect(PayAsYouGo.restoreNote(packs: [Self.pack(1, Self.mine, daysAgo: 1)], recovered: false, keychainFailed: false)?.contains("bought with an AI plan") == true)
        #expect(PayAsYouGo.restoreNote(packs: [], recovered: false, keychainFailed: false) == nil)
    }

    @Test("Gating: packs open AI asks only (relay in the build, Online on with AI credits); importing, jobs and editing still need the subscription")
    func gating() {
        #expect(PayAsYouGo.unlocksAIAsks(hasCredential: true, relayConfigured: true, providerIsCredits: true, cloudAllowed: true))
        for (c, r, p, o) in [(false, true, true, true), (true, false, true, true), (true, true, false, true), (true, true, true, false)] {
            #expect(!PayAsYouGo.unlocksAIAsks(hasCredential: c, relayConfigured: r, providerIsCredits: p, cloudAllowed: o))
        }
        for e: Entitlement in [.notStarted, .lapsed(reason: .expired), .billingRetry(plan: .monthly)] {
            #expect(PaidUse.refusal("ask questions", sample: false, entitlement: e, aiAsk: true, payAsYouGo: true) == nil, "\(e)")
            #expect(PaidUse.refusal("ask questions", sample: false, entitlement: e, aiAsk: true, payAsYouGo: false) != nil, "\(e)")
            #expect(PaidUse.refusal("attach documents", importing: true, sample: false, entitlement: e, aiAsk: true, payAsYouGo: true) != nil)
            #expect(PaidUse.refusal("run jobs", sample: false, entitlement: e, payAsYouGo: true) != nil, "packs open AI asks only")
            #expect(PaidUse.refusal("edit the case file", sample: false, entitlement: e, aiAsk: false, payAsYouGo: true) != nil)
        }
        #expect(PaidUse.refusal("run jobs", sample: false, entitlement: .subscribed(expiresAt: .distantFuture, plan: .monthly, willRenew: true)) == nil)
    }

    @Test("The token lives in one place per Mac: made once, adopted on recovery, cleared on a 'new Mac'")
    func tokenStore() {
        AIAccountToken.$testStore.withValue(AIAccountToken.MemoryStore()) {
            #expect(AIAccountToken.current() == nil)
            let t = AIAccountToken.getOrCreate()
            #expect(t != nil && AIAccountToken.getOrCreate() == t, "made once")
            AIAccountToken.clear()
            #expect(AIAccountToken.current() == nil)
            #expect(AIAccountToken.adopt(Self.mine) && AIAccountToken.current() == Self.mine)
        }
    }

    @MainActor
    @Test("The meter for a pack-only account: its limits, the pack balance, no reset date, and the relay's pay-as-you-go words")
    func meter() throws {
        let m = AICreditMeter()
        #expect(m.limits == nil && m.summaryLine == nil)
        m.payAsYouGoChanged(true)
        #expect(m.limits == AIPricing.payAsYouGo && m.summaryLine == "Pay as you go: your credit-pack balance is shown after the first check")
        let body = Data(#"{"active":true,"kals":{"plan":"payg","monthlyCredits":0,"allowanceUsed":0,"allowanceLeft":0,"topUps":340,"dailyUsed":20,"dailyLimit":1500,"perRequestCredits":400,"caseReadCredits":600,"packsOnly":true}}"#.utf8)
        let r = try #require(AIIncludedRelay.receipt(in: body))
        #expect(r.plan == "payg" && r.balance == 340 && r.periodEndsAt == nil)
        let now = Date()
        m.apply(r, at: now)
        #expect(m.tier == nil && m.payAsYouGo && m.balance == 340)
        #expect(m.summaryLine == "Pay as you go: 340 credits left in packs")
        let used = try #require(m.localRefusal(reserved: 341, largeRead: false, now: now))
        #expect(used.code == .creditsUsed && used.offers == [.buyCredits] && used.message == AIPricing.creditsUsedPacksMessage(estimate: 341, balance: 340))
        #expect(m.localRefusal(reserved: 300, largeRead: false, now: now) == nil)
        #expect(m.localRefusal(reserved: 601, largeRead: true, now: now)?.code == .tooCostly, "AI Included's 600-credit whole-case read")
        m.apply(AIIncludedRelay.Receipt(plan: "payg", monthlyCredits: 0, allowanceLeft: 0, topUps: 5_000, dailyUsed: 1_490, dailyLimit: 1_500,
                                        perRequestCredits: 400, caseReadCredits: 600, periodEndsAt: nil, charged: 3, reserved: 40), at: now)
        let daily = try #require(m.localRefusal(reserved: 20, largeRead: false, now: now))
        #expect(daily.code == .dailyLimit && daily.message == AIPricing.dailyLimitPacksMessage(limit: 1_500) && daily.offers.isEmpty)
        #expect(m.refusal(credits: 6_000, largeRead: false)?.contains("more than the 400") == true)
        // An AI plan takes over; turning pay as you go off drops a pack-only receipt.
        m.planChanged(.aiIncluded)
        #expect(m.limits == AIPricing.aiIncluded && m.receipt == nil)
        let n = AICreditMeter()
        n.apply(r)
        n.payAsYouGoChanged(false)
        #expect(n.receipt == nil && n.limits == nil)
    }

    @Test("Words: the consent sheet's pack balance, the plan-picker text (prices from StoreKit, never expire, what a credit buys, Workbench for the rest)")
    func words() {
        #expect(CaseReadCostLines.balance(840, packsOnly: true) == "You have 840 credits left in your credit packs (pay as you go; they never expire).")
        #expect(CaseReadCostLines.balance(840) == "You have 840 credits left (this month's allowance and credit packs).")
        #expect(CaseReadCostLines.progress(planBalance: 12, onPlan: true, packsOnly: true).hasSuffix("You have 12 credits left in your credit packs (pay as you go; they never expire)."))
        let t = PayAsYouGo.offerText(packPrices: [PurchaseProducts.credits500: "$9.99", PurchaseProducts.credits2000: "$34.99"])
        for part in ["No subscription", "500 credits for $9.99 or 2,000 credits for $34.99", "never expire", "1 credit = US$0.01 of AI cost",
                     "questions answered by Claude", "Workbench (14-day free trial)"] {
            #expect(t.contains(part), "\(part) — \(t)")
        }
        #expect(!PayAsYouGo.offerText(packPrices: [:]).contains("for $"), "no price is made up before StoreKit answers")
        #expect(!PayAsYouGo.offered(relayConfigured: false, sellsAI: true) && !PayAsYouGo.offered(relayConfigured: true, sellsAI: false))
        #expect(PayAsYouGo.offered(relayConfigured: true, sellsAI: true))
    }

    @Test("Recovery on a new Mac needs StoreKit to list finished consumables: the app's Info.plist sets SKIncludeConsumableInAppPurchaseHistory")
    func infoPlistKey() throws {
        #expect(Bundle.main.object(forInfoDictionaryKey: "SKIncludeConsumableInAppPurchaseHistory") as? Bool == true)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let plist = try String(contentsOf: root.appendingPathComponent("Kalsmritikosh/Info.plist"), encoding: .utf8)
        #expect(plist.contains("<key>SKIncludeConsumableInAppPurchaseHistory</key>\n\t<true/>"))
    }

    @Test("The pack-only limits and receipt code mirror relay/src/policy.ts (PAYG, PAYG_PLAN, PAYG_DAILY_CREDITS)")
    func mirrorsRelay() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let ts = try String(contentsOf: root.appendingPathComponent("relay/src/policy.ts"), encoding: .utf8)
        let l = AIPricing.payAsYouGo
        #expect(ts.contains("export const PAYG: PlanPolicy = { label: \"Pay as you go\", monthlyCredits: \(l.monthlyCredits), yearlyMonthlyCredits: \(l.yearlyMonthlyCredits), perRequestCredits: \(l.perRequestCredits), caseReadCredits: \(l.caseReadCredits), dailyCredits: 1_500, caseReadTokens: 300_000 };"))
        #expect(l.dailyCredits == 1_500 && l.caseReadTokens == 300_000)
        #expect(ts.contains("export const PAYG_PLAN = \"\(AIPricing.payAsYouGoPlanCode)\";"))
        #expect(ts.contains("export const PAYG_DAILY_CREDITS = 1_500;"))
        #expect(l.perRequestCredits == AIPricing.aiIncluded.perRequestCredits && l.caseReadCredits == AIPricing.aiIncluded.caseReadCredits)
    }
}
