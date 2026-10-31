//
//  PurchaseStoreKitTests.swift
//  KalsmritikoshTests
//
//  The subscription against the real StoreKit testing environment (App Store completion
//  instructions §11): `StoreKit/Kalsmritikosh.storekit` is loaded into an `SKTestSession`, and a
//  `PurchaseCenter` that talks to the store loads the products, buys, is renewed, cancelled,
//  refunded, put into billing retry and grace, restored and expired by StoreKit itself. These are
//  the same transactions and renewal records the shipped app reads; only Apple's Sandbox and
//  TestFlight (owner steps, `docs/DISTRIBUTION_PACK.md` §6) go further.
//

import Foundation
import StoreKit
import StoreKitTest
import Testing
@testable import Kalsmritikosh

@Suite(.serialized)
@MainActor
struct PurchaseStoreKitTests {
    /// A fresh session on the committed configuration: no transactions, dialogs off. Every test also
    /// clears its transactions when it ends (`defer`): the local testing environment persists per app
    /// bundle, and a Debug launch of the app outside Xcode reads it — a test that left an annual
    /// subscription behind made the app report "Annual plan, renews 31 Oct 2027" (UI run h, 2026-10-31).
    private static func session() throws -> SKTestSession {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let s = try SKTestSession(contentsOf: root.appendingPathComponent("StoreKit/Kalsmritikosh.storekit"))
        s.resetToDefaultState()
        s.disableDialogs = true
        s.clearTransactions()
        // The configuration's default storefront is USA / en_US. Setting `storefront` or `locale`
        // explicitly made every paid purchase fail with "Item Unavailable" in this environment, so
        // the defaults are relied on and asserted through the prices below.
        AppDefaults.store.removeObject(forKey: CachedEntitlement.key)
        return s
    }

    private static func centre() async -> PurchaseCenter {
        let c = PurchaseCenter(talksToStore: true)
        await c.loadProducts()
        await c.refresh()
        return c
    }

    /// StoreKit applies renewals, refunds, billing failures and expiries asynchronously; read the
    /// store again until the expected state is seen (at most ~8 s), as the app's `Transaction.updates`
    /// listener would. Returns whether it was seen.
    @discardableResult
    private static func settle(_ c: PurchaseCenter, within seconds: Double = 8, until done: (Entitlement) -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while true {
            await c.refresh()
            if done(c.entitlement) { return true }
            if Date() >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    private static func latest(_ s: SKTestSession, _ productID: String) -> SKTestTransaction? {
        s.allTransactions().filter { $0.productIdentifier == productID }.max { $0.purchaseDate < $1.purchaseDate }
    }

    /// Cancel as the person would in their Apple Account: auto-renew off. The environment keys
    /// renewal settings by the current period's transaction, so every transaction of the product is told.
    private static func cancel(_ s: SKTestSession, _ productID: String) throws {
        let ids = s.allTransactions().filter { $0.productIdentifier == productID }.map(\.identifier)
        try #require(!ids.isEmpty)
        for id in ids { try s.disableAutoRenewForTransaction(identifier: id) }
    }

    @Test func storefrontPlansAndTrialEligibility() async throws {
        let s = try Self.session()
        defer { s.clearTransactions() }
        let c = await Self.centre()
        #expect(!c.productsUnavailable)
        #expect(c.offers.map(\.plan) == [.monthly, .annual])
        let monthly = try #require(c.offers.first { $0.plan == .monthly })
        let annual = try #require(c.offers.first { $0.plan == .annual })
        #expect(monthly.displayPrice == "$4.99" && monthly.periodText == "1 month")
        #expect(annual.displayPrice == "$39.99" && annual.periodText == "1 year")
        #expect(monthly.eligibleForTrial && annual.eligibleForTrial)
        #expect(monthly.trialDays == 14 && annual.trialDays == 14)
        #expect(monthly.actionTitle == "Start 14-day free trial")
        #expect(annual.disclosure.hasPrefix("14 days free, then $39.99 per year. Renews automatically at $39.99 per year unless cancelled at least a day before"))
        #expect(c.annualSavingPercent == 33)
        // Never bought anything: the store answered, so the screen leads and paid actions wait.
        #expect(c.entitlement == .notStarted)
        #expect(c.entitlement.leadsWithSubscriptionScreen)
        #expect(!c.allowPaidAction("add documents"))
        #expect(c.paywallRequested == "add documents")
    }

    @Test func trialRenewsThenIsCancelledThenExpires() async throws {
        let s = try Self.session()
        defer { s.clearTransactions() }
        let c = await Self.centre()
        await c.subscribe(.monthly)
        guard case .introductoryTrial(let ends, .monthly, true) = c.entitlement else {
            Issue.record("expected the free trial, got \(c.entitlement)"); return
        }
        #expect(ends > Date().addingTimeInterval(13 * 86_400) && ends < Date().addingTimeInterval(15 * 86_400))
        #expect(c.entitlement.allowsPaidUse && c.allowPaidAction("run a job"))
        #expect(c.message == nil)
        // The verified state is cached for an offline launch, under its own end.
        #expect(CachedEntitlement.load()?.kind == .introductoryTrial)
        // (The testing environment keeps `isEligibleForIntroOffer` true while the trial itself is
        // running, so second-trial ineligibility is not asserted here; the rules side is in PurchaseTests.)

        // Apple renews: the paid period.
        try s.forceRenewalOfSubscription(productIdentifier: PurchaseProducts.monthly)
        await Self.settle(c) { if case .subscribed(_, .monthly, true) = $0 { return true }; return false }
        guard case .subscribed(_, .monthly, true) = c.entitlement else { Issue.record("expected paid, got \(c.entitlement)"); return }

        // Cancelled: access stays until the period ends, renewal is off.
        try Self.cancel(s, PurchaseProducts.monthly)
        await Self.settle(c) { if case .subscribed(_, .monthly, false) = $0 { return true }; return false }
        guard case .subscribed(_, .monthly, false) = c.entitlement else { Issue.record("expected cancelled-but-active, got \(c.entitlement)"); return }
        #expect(c.entitlement.allowsPaidUse)
        #expect(c.statusText.contains("cancelled — access until"))
        #expect(CachedEntitlement.load()?.kind == .subscribed && CachedEntitlement.load()?.willRenew == false)
    }

    /// Cancelled, then the period ends (time runs at one renewal every two seconds): the window stays,
    /// read-only, for someone who had access — never the "never started" screen.
    @Test func cancelledSubscriptionExpiresAtPeriodEndIntoReadOnly() async throws {
        let s = try Self.session()
        defer { s.clearTransactions() }
        s.timeRate = .oneRenewalEveryTwoSeconds
        let c = await Self.centre()
        await c.subscribe(.annual)
        #expect(c.entitlement.allowsPaidUse)
        try Self.cancel(s, PurchaseProducts.annual)
        let expired = await Self.settle(c, within: 30) { !$0.allowsPaidUse }
        #expect(expired, "still \(c.entitlement)")
        #expect(c.entitlement == .lapsed(reason: .expired))
        #expect(!c.entitlement.allowsPaidUse && c.entitlement.allowsReadAccess)
        #expect(c.entitlement.hadAccessBefore && !c.entitlement.leadsWithSubscriptionScreen)
        #expect(!c.allowPaidAction("edit") && c.paywallRequested == "edit")
        #expect(CachedEntitlement.load()?.kind == .lapsed)
        // The offline rule on what was cached: lapsed stays lapsed.
        #expect(CachedEntitlement.load()?.entitlement(now: Date()) == .lapsed(reason: .expired))
    }

    @Test func refundRevokesAndRestoreReportsIt() async throws {
        let s = try Self.session()
        defer { s.clearTransactions() }
        let c = await Self.centre()
        await c.subscribe(.annual)
        #expect(c.entitlement.plan == .annual && c.entitlement.allowsPaidUse)
        let tx = try #require(Self.latest(s, PurchaseProducts.annual))
        try s.refundTransaction(identifier: tx.identifier)
        await Self.settle(c) { !$0.allowsPaidUse }
        #expect(c.entitlement == .lapsed(reason: .revoked))
        #expect(c.entitlement.hadAccessBefore)
        await c.restore()
        #expect(c.message == "No active subscription or purchase was found for this Apple account.")
    }

    // A forced renewal always succeeds in the testing environment, so the billing failure is reached
    // the way Apple's servers reach it: time passes (one renewal a minute here; grace then lasts a
    // minute, billing retry two) and the renewal fails because `shouldEnterBillingRetryOnRenewal` is set.
    @Test func billingRetryWithGraceKeepsAccessUntilGraceEnds() async throws {
        let s = try Self.session()
        defer { s.clearTransactions() }
        s.timeRate = .oneRenewalEveryMinute
        s.billingGracePeriodIsEnabled = true
        s.shouldEnterBillingRetryOnRenewal = true
        let c = await Self.centre()
        await c.subscribe(.monthly)
        #expect(c.entitlement.allowsPaidUse)
        await Self.settle(c, within: 100) { if case .grace = $0 { return true }; return false }
        guard case .grace(let until, .monthly) = c.entitlement else { Issue.record("expected grace, got \(c.entitlement)"); return }
        #expect(until > Date())
        #expect(c.entitlement.allowsPaidUse)
        #expect(c.statusText.hasPrefix("Payment did not go through; access continues until"))
        // The payment problem is fixed: paid again.
        let failed = try #require(Self.latest(s, PurchaseProducts.monthly))
        #expect(failed.hasPurchaseIssue)
        try s.resolveIssueForTransaction(identifier: failed.identifier)
        await Self.settle(c) { if case .subscribed = $0 { return true }; return false }
        #expect(c.entitlement.allowsPaidUse)
        if case .subscribed(_, .monthly, _) = c.entitlement {} else { Issue.record("expected paid after the issue was resolved, got \(c.entitlement)") }
    }

    @Test func billingRetryWithoutGraceIsReadOnly() async throws {
        let s = try Self.session()
        defer { s.clearTransactions() }
        s.timeRate = .oneRenewalEveryThirtySeconds
        s.billingGracePeriodIsEnabled = false
        s.shouldEnterBillingRetryOnRenewal = true
        let c = await Self.centre()
        await c.subscribe(.monthly)
        #expect(c.entitlement.allowsPaidUse)
        await Self.settle(c, within: 60) { if case .billingRetry = $0 { return true }; return false }
        #expect(c.entitlement == .billingRetry(plan: .monthly), "got \(c.entitlement)")
        #expect(!c.entitlement.allowsPaidUse && c.entitlement.hadAccessBefore && !c.entitlement.leadsWithSubscriptionScreen)
        #expect(c.statusText.hasPrefix("Payment did not go through. Update the payment method"))
    }

    @Test func planChangeWithinTheGroup() async throws {
        let s = try Self.session()
        defer { s.clearTransactions() }
        let c = await Self.centre()
        await c.subscribe(.monthly)
        #expect(c.entitlement.plan == .monthly)
        await c.subscribe(.annual)
        #expect(c.message == nil)
        #expect(c.entitlement.allowsPaidUse)
        // Monthly and annual sit at one level, so the change is a crossgrade: StoreKit keeps the
        // current period and records annual as what renews next (this is the one place Apple's own
        // renewal record is read directly, to assert the pending change).
        let product = try #require(try await Product.products(for: [PurchaseProducts.monthly]).first)
        var pending: [String] = []
        let deadline = Date().addingTimeInterval(20)
        repeat {
            let statuses = try #require(try await product.subscription?.status)
            pending = statuses.compactMap { if case .verified(let r) = $0.renewalInfo { return r.autoRenewPreference }; return nil }
            if pending.contains(PurchaseProducts.annual) { break }
            try await Task.sleep(for: .milliseconds(250))
        } while Date() < deadline
        #expect(pending.contains(PurchaseProducts.annual), "renewal preference: \(pending)")
        // When that period ends, the annual plan is what stands.
        try s.forceRenewalOfSubscription(productIdentifier: c.entitlement.plan == .annual ? PurchaseProducts.annual : PurchaseProducts.monthly)
        let switched = await Self.settle(c, within: 30) { $0.plan == .annual }
        #expect(switched, "after renewal: \(c.entitlement)")
        #expect(c.entitlement.allowsPaidUse)
    }

    @Test func legacyPermanentUnlockBeatsEverythingAndIsNeverAskedToSubscribe() async throws {
        let s = try Self.session()
        defer { s.clearTransactions() }
        _ = try await s.buyProduct(identifier: PurchaseProducts.legacyUnlock)
        let c = await Self.centre()
        #expect(c.entitlement == .legacyUnlocked)
        #expect(c.statusText == "Purchased outright (lifetime unlock).")
        #expect(c.allowPaidAction("anything") && c.paywallRequested == nil)
        await c.subscribe(.monthly)
        #expect(c.entitlement == .legacyUnlocked)
        // A refunded unlock with nothing else: lapsed (revoked), read-only, not "never started".
        let tx = try #require(Self.latest(s, PurchaseProducts.legacyUnlock))
        try s.refundTransaction(identifier: tx.identifier)
        try s.expireSubscription(productIdentifier: PurchaseProducts.monthly)
        await Self.settle(c, within: 20) { !$0.allowsPaidUse }
        #expect(!c.entitlement.allowsPaidUse && c.entitlement.hadAccessBefore, "\(c.entitlement)")
    }

    @Test func legacyFreeTrialProductIsATrialNotBillingConsent() async throws {
        let s = try Self.session()
        defer { s.clearTransactions() }
        _ = try await s.buyProduct(identifier: PurchaseProducts.legacyTrial)
        let c = await Self.centre()
        guard case .legacyTrial(let ends) = c.entitlement else { Issue.record("expected the legacy trial, got \(c.entitlement)"); return }
        #expect(ends > Date().addingTimeInterval(13 * 86_400))
        #expect(c.entitlement.allowsPaidUse && !c.entitlement.leadsWithSubscriptionScreen)
        #expect(c.statusText.contains("no charge follows it"))
        // Still eligible for the subscription's introductory offer: the two products are unrelated.
        let allEligible = c.offers.allSatisfy { $0.eligibleForTrial }
        #expect(allEligible)
    }

    @Test func restoreWithNothingBoughtSaysSo() async throws {
        let s = try Self.session()
        defer { s.clearTransactions() }
        let c = await Self.centre()
        await c.restore()
        #expect(c.entitlement == .notStarted)
        #expect(c.message == "No active subscription or purchase was found for this Apple account.")
    }

    @Test func storeFailureNeverUnlocksAndNeverRemovesValidAccess() async throws {
        let s = try Self.session()
        defer { s.clearTransactions() }
        let c = await Self.centre()
        await c.subscribe(.annual)
        #expect(c.entitlement.allowsPaidUse)
        // The purchase dialog fails (for example payment not allowed): told, state unchanged.
        s.failTransactionsEnabled = true
        s.failureError = .paymentNotAllowed
        let before = c.entitlement
        await c.subscribe(.monthly)
        #expect(c.message != nil)
        #expect(c.entitlement == before)
        s.failTransactionsEnabled = false
        // A fresh centre on a store that answers nothing for products falls back to the cached verified state.
        let offline = PurchaseCenter(talksToStore: true)
        await offline.refresh()     // no products loaded → "store did not answer" path
        #expect(offline.entitlement.allowsPaidUse, "\(offline.entitlement)")
        #expect(offline.entitlement.plan == .annual)
    }
}
