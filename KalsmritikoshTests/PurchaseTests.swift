//
//  PurchaseTests.swift
//  KalsmritikoshTests
//
//  App Store completion instructions 2026-10-30 §11 — the subscription rules (Purchase.swift)
//  without the App Store: monthly/annual at one level, the introductory trial, cancelled-but-active,
//  verified grace, billing retry, expiry, refund/revocation, the legacy permanent unlock and the
//  legacy free trial, the offline cache rule, the paywall copy from real values, and the local
//  StoreKit configuration.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Subscriptions, the introductory trial and the legacy purchases")
struct PurchaseTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func day(_ n: Double) -> Date { t0.addingTimeInterval(n * 86_400) }

    private func sub(_ plan: SubscriptionPlan, from: Date, days: Double, intro: Bool = false, revoked: Bool = false) -> Entitlement.Record {
        .init(productID: plan.productID, purchaseDate: from, originalPurchaseDate: from, expirationDate: from.addingTimeInterval(days * 86_400),
              revoked: revoked, isIntroductoryOffer: intro)
    }
    private func legacy(_ id: String, at: Date, revoked: Bool = false) -> Entitlement.Record {
        .init(productID: id, purchaseDate: at, originalPurchaseDate: at, revoked: revoked)
    }

    @Test("First launch: unknown until the store answers, then not started; the test host is unlocked")
    @MainActor func firstLaunch() {
        #expect(Entitlement.evaluate(records: [], renewal: nil, storeAnswered: false, now: t0) == .unknown)
        #expect(Entitlement.evaluate(records: [], renewal: nil, storeAnswered: true, now: t0) == .notStarted)
        #expect(!Entitlement.unknown.allowsPaidUse, "an unanswered store is never an unlimited unlock (UI run f, F-1)")
        #expect(Entitlement.unknown.leadsWithSubscriptionScreen && Entitlement.unknown.allowsReadAccess && !Entitlement.unknown.hadAccessBefore)
        #expect(!Entitlement.notStarted.allowsPaidUse && !Entitlement.notStarted.hadAccessBefore && Entitlement.notStarted.leadsWithSubscriptionScreen)
        #expect(!Entitlement.lapsed(reason: .expired).leadsWithSubscriptionScreen, "a lapsed profile keeps its window, read-only")
        #expect(PurchaseCenter.isTestHost)
        PurchaseCenter.shared.start()
        #expect(PurchaseCenter.shared.entitlement == .legacyUnlocked)
    }

    @Test("Introductory trial, then the paid period, then cancelled-but-active, then expired — both plans give the same access")
    func trialThenPaidThenCancelled() {
        for plan in SubscriptionPlan.allCases {
            let trial = sub(plan, from: t0, days: 14, intro: true)
            let renewing = Entitlement.Renewal(willAutoRenew: true)
            let e1 = Entitlement.evaluate(records: [trial], renewal: renewing, storeAnswered: true, now: day(3))
            #expect(e1 == .introductoryTrial(endsAt: day(14), plan: plan, willRenew: true) && e1.allowsPaidUse && e1.daysLeft(now: day(3)) == 11)
            // Renewal switched off during the trial: still entitled until the end, nothing charged after.
            let off = Entitlement.evaluate(records: [trial], renewal: .init(willAutoRenew: false), storeAnswered: true, now: day(13))
            #expect(off == .introductoryTrial(endsAt: day(14), plan: plan, willRenew: false) && off.allowsPaidUse)
            // The paid period after the trial.
            let paid = sub(plan, from: day(14), days: plan == .monthly ? 30 : 365)
            let e2 = Entitlement.evaluate(records: [trial, paid], renewal: renewing, storeAnswered: true, now: day(20))
            #expect(e2 == .subscribed(expiresAt: plan == .monthly ? day(44) : day(379), plan: plan, willRenew: true))
            // Cancelled but active: access to the verified expiry, then lapsed.
            let cancelled = Entitlement.evaluate(records: [trial, paid], renewal: .init(willAutoRenew: false), storeAnswered: true, now: day(20))
            #expect(cancelled == .subscribed(expiresAt: plan == .monthly ? day(44) : day(379), plan: plan, willRenew: false) && cancelled.allowsPaidUse)
            let after = Entitlement.evaluate(records: [trial, paid], renewal: .init(willAutoRenew: false, expired: true), storeAnswered: true, now: day(400))
            #expect(after == .lapsed(reason: .expired) && !after.allowsPaidUse && after.hadAccessBefore && after.allowsReadAccess)
        }
    }

    @Test("Grace keeps access until Apple's verified grace end; billing retry without grace does not; recovery restores it")
    func graceAndRetry() {
        let paid = sub(.monthly, from: t0, days: 30)
        let grace = Entitlement.Renewal(willAutoRenew: true, isInBillingRetry: true, gracePeriodExpiration: day(33))
        #expect(Entitlement.evaluate(records: [paid], renewal: grace, storeAnswered: true, now: day(31)) == .grace(until: day(33), plan: .monthly))
        #expect(Entitlement.evaluate(records: [paid], renewal: grace, storeAnswered: true, now: day(31)).allowsPaidUse)
        let retry = Entitlement.Renewal(willAutoRenew: true, isInBillingRetry: true, gracePeriodExpiration: nil)
        let r = Entitlement.evaluate(records: [paid], renewal: retry, storeAnswered: true, now: day(31))
        #expect(r == .billingRetry(plan: .monthly) && !r.allowsPaidUse && r.hadAccessBefore)
        // Grace over, still retrying: lapsed for billing, not "expired by choice".
        #expect(Entitlement.evaluate(records: [paid], renewal: grace, storeAnswered: true, now: day(34)) == .billingRetry(plan: .monthly))
        // Payment recovered: a new period.
        let recovered = sub(.monthly, from: day(35), days: 30)
        #expect(Entitlement.evaluate(records: [paid, recovered], renewal: .init(willAutoRenew: true), storeAnswered: true, now: day(36)) == .subscribed(expiresAt: day(65), plan: .monthly, willRenew: true))
    }

    @Test("A refund or revocation ends the subscription; a plan switch is one subscription, the latest verified period decides")
    func refundAndSwitch() {
        let refunded = sub(.annual, from: t0, days: 365, revoked: true)
        let e = Entitlement.evaluate(records: [refunded], renewal: .init(willAutoRenew: false), storeAnswered: true, now: day(10))
        #expect(e == .lapsed(reason: .revoked) && !e.allowsPaidUse && e.hadAccessBefore)
        let monthly = sub(.monthly, from: t0, days: 30)
        let annual = sub(.annual, from: day(30), days: 365)
        #expect(Entitlement.evaluate(records: [monthly, annual], renewal: .init(willAutoRenew: true), storeAnswered: true, now: day(40)) == .subscribed(expiresAt: day(395), plan: .annual, willRenew: true))
    }

    @Test("The legacy permanent unlock wins over everything and is never asked to subscribe; a refunded one does not")
    func legacyUnlock() {
        let unlock = legacy(PurchaseProducts.legacyUnlock, at: t0)
        let expiredSub = sub(.monthly, from: t0, days: 30)
        #expect(Entitlement.evaluate(records: [unlock, expiredSub], renewal: .init(willAutoRenew: false, expired: true), storeAnswered: true, now: day(400)) == .legacyUnlocked)
        #expect(Entitlement.legacyUnlocked.allowsPaidUse)
        let refunded = legacy(PurchaseProducts.legacyUnlock, at: t0, revoked: true)
        #expect(Entitlement.evaluate(records: [refunded], renewal: nil, storeAnswered: true, now: t0) == .lapsed(reason: .revoked))
        let again = legacy(PurchaseProducts.legacyUnlock, at: day(5))
        #expect(Entitlement.evaluate(records: [refunded, again], renewal: nil, storeAnswered: true, now: day(6)) == .legacyUnlocked)
    }

    @Test("The old free trial product is a trial, not billing consent: it runs its 14 days and ends; no charge follows")
    func legacyTrial() {
        let trial = legacy(PurchaseProducts.legacyTrial, at: t0)
        let running = Entitlement.evaluate(records: [trial], renewal: nil, storeAnswered: true, now: day(13))
        #expect(running == .legacyTrial(endsAt: day(14)) && running.allowsPaidUse && running.plan == nil)
        let ended = Entitlement.evaluate(records: [trial], renewal: nil, storeAnswered: true, now: day(14))
        #expect(ended == .lapsed(reason: .legacyTrialEnded) && !ended.allowsPaidUse && ended.hadAccessBefore)
        // Subscribing after it: the subscription decides.
        let sub1 = sub(.annual, from: day(20), days: 365, intro: true)
        #expect(Entitlement.evaluate(records: [trial, sub1], renewal: .init(willAutoRenew: true), storeAnswered: true, now: day(21)) == .introductoryTrial(endsAt: day(385), plan: .annual, willRenew: true))
    }

    @Test("Offline rule: the cached verified state keeps access only to its own verified end, then reads lapsed — never unknown, never unlimited")
    func offlineCache() {
        let active = Entitlement.subscribed(expiresAt: day(30), plan: .monthly, willRenew: true)
        let cached = CachedEntitlement(active, at: t0)
        #expect(cached.entitlement(now: day(10)) == active)
        #expect(cached.entitlement(now: day(31)) == .lapsed(reason: .expired))
        #expect(CachedEntitlement(.grace(until: day(3), plan: .annual), at: t0).entitlement(now: day(4)) == .lapsed(reason: .billingFailed))
        #expect(CachedEntitlement(.legacyTrial(endsAt: day(2)), at: t0).entitlement(now: day(3)) == .lapsed(reason: .legacyTrialEnded))
        #expect(CachedEntitlement(.legacyUnlocked, at: t0).entitlement(now: day(9_999)) == .legacyUnlocked)
        #expect(CachedEntitlement(.unknown, at: t0).entitlement(now: t0) == .notStarted, "an unknown state is never cached as access")
        // Round trip through the isolated preference store.
        let defaults = AppDefaults.store
        defaults.removeObject(forKey: CachedEntitlement.key)
        cached.save(to: defaults)
        #expect(CachedEntitlement.load(from: defaults) == cached)
        defaults.removeObject(forKey: CachedEntitlement.key)
        // Clock rollback cannot extend access past the verified end either (the end is absolute).
        #expect(cached.entitlement(now: day(-100)) == active, "an earlier clock shows the verified state, not more than it")
    }

    @Test("Paywall copy comes from real storefront values: trial action and disclosure for the eligible, plain subscribe for the rest; annual saving only from matching prices")
    func paywallCopy() {
        let eligible = PlanOffer(plan: .annual, displayPrice: "$39.99", periodText: "1 year", eligibleForTrial: true, trialDays: 14)
        #expect(eligible.actionTitle == "Start 14-day free trial")
        #expect(eligible.disclosure.hasPrefix("14 days free, then $39.99 per year. Renews automatically at $39.99 per year unless cancelled at least a day before the period ends."))
        let ineligible = PlanOffer(plan: .monthly, displayPrice: "₹249", periodText: "1 month", eligibleForTrial: false, trialDays: 14)
        #expect(ineligible.actionTitle == "Subscribe ₹249 per month" && !ineligible.disclosure.contains("free"))
        #expect(PlanOffer.annualSaving(monthly: 4.99, annual: 39.99) == 33)
        #expect(PlanOffer.annualSaving(monthly: 249, annual: 1999) == 33)
        #expect(PlanOffer.annualSaving(monthly: 3, annual: 40) == nil, "no saving is not a saving")
        #expect(PlanOffer.annualSaving(monthly: 0, annual: 40) == nil)
    }

    @Test("What the person is told after a purchase attempt")
    @MainActor func outcomeMessages() {
        #expect(PurchaseCenter.message(for: .verified, what: "x") == nil)
        #expect(PurchaseCenter.message(for: .cancelled, what: "x") == nil)
        #expect(PurchaseCenter.message(for: .unverified, what: "the annual plan")?.contains("could not confirm the annual plan") == true)
        #expect(PurchaseCenter.message(for: .pending, what: "x")?.contains("Ask to Buy") == true)
    }

    @Test("A paid action asks the gate; a refusal opens the paywall and runs nothing; reading never asks")
    @MainActor func paidActionGate() {
        let center = PurchaseCenter.shared
        center.start()
        center.paywallRequested = nil
        #expect(center.allowPaidAction("edit") && center.paywallRequested == nil, "the test host is unlocked")
        #expect(Entitlement.lapsed(reason: .expired).allowsReadAccess && Entitlement.notStarted.allowsReadAccess)
    }

    @Test("The local StoreKit configuration: one group, monthly and annual at the same level with a two-week free introductory offer, 3-day grace, and the two legacy non-consumables kept as they were")
    func storeKitConfiguration() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("StoreKit/Kalsmritikosh.storekit")
        let json = try #require(try JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [String: Any])
        let products = try #require(json["products"] as? [[String: Any]])
        #expect(Set(products.compactMap { $0["productID"] as? String }) == [PurchaseProducts.legacyUnlock, PurchaseProducts.legacyTrial])
        for p in products { #expect(p["type"] as? String == "NonConsumable", "legacy ids are never repurposed") }
        let groups = try #require(json["subscriptionGroups"] as? [[String: Any]])
        #expect(groups.count == 1)
        let subs = try #require(groups[0]["subscriptions"] as? [[String: Any]])
        #expect(Set(subs.compactMap { $0["productID"] as? String }) == Set(PurchaseProducts.subscriptions))
        for s in subs {
            #expect(s["groupNumber"] as? Int == 1, "one access level")
            #expect(s["familyShareable"] as? Bool == false, "not advertised for the new subscriptions")
            let intro = try #require(s["introductoryOffer"] as? [String: Any])
            #expect(intro["paymentMode"] as? String == "free" && intro["subscriptionPeriod"] as? String == "P2W")
            let period = s["recurringSubscriptionPeriod"] as? String
            #expect(period == (s["productID"] as? String == PurchaseProducts.monthly ? "P1M" : "P1Y"))
            #expect(s["displayPrice"] as? String == (s["productID"] as? String == PurchaseProducts.monthly ? "4.99" : "39.99"))
        }
        let settings = try #require(json["settings"] as? [String: Any])
        #expect(settings["_billingGracePeriodEnabled"] as? Bool == true && settings["_billingGracePeriodInDays"] as? Int == 3)
    }
}
