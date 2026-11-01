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
        // N3: a permanent purchase is proved by StoreKit's signed transaction, never by the cache.
        #expect(CachedEntitlement(.legacyUnlocked, at: t0).entitlement(now: day(9_999)) == .unknown)
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

    @Test("The local StoreKit configuration: one group — the edition (monthly, annual, two-week free introductory offer) one level below AI Included (monthly, annual, no free trial) — 3-day grace, the two legacy non-consumables kept as they were, and the 200-question consumable top-up")
    func storeKitConfiguration() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("StoreKit/Kalsmritikosh.storekit")
        let json = try #require(try JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [String: Any])
        let products = try #require(json["products"] as? [[String: Any]])
        #expect(Set(products.compactMap { $0["productID"] as? String }) == [PurchaseProducts.legacyUnlock, PurchaseProducts.legacyTrial, PurchaseProducts.aiTopUp200])
        for p in products {
            let topUp = p["productID"] as? String == PurchaseProducts.aiTopUp200
            #expect(p["type"] as? String == (topUp ? "Consumable" : "NonConsumable"), "legacy ids are never repurposed")
            if topUp { #expect(p["displayPrice"] as? String == "14.99") }
        }
        let groups = try #require(json["subscriptionGroups"] as? [[String: Any]])
        #expect(groups.count == 1)
        let subs = try #require(groups[0]["subscriptions"] as? [[String: Any]])
        #expect(Set(subs.compactMap { $0["productID"] as? String }) == Set(PurchaseProducts.subscriptions))
        let prices = [PurchaseProducts.monthly: "4.99", PurchaseProducts.annual: "39.99",
                      PurchaseProducts.aiMonthly: "24.99", PurchaseProducts.aiAnnual: "249.99"]
        for s in subs {
            let id = try #require(s["productID"] as? String)
            let plan = try #require(SubscriptionPlan(productID: id))
            #expect(s["groupNumber"] as? Int == (plan.includesAI ? 1 : 2), "AI Included is the higher level")
            #expect(s["familyShareable"] as? Bool == false, "not advertised for the new subscriptions")
            if plan.includesAI {
                #expect(s["introductoryOffer"] == nil, "no free trial includes the publisher's AI")
            } else {
                let intro = try #require(s["introductoryOffer"] as? [String: Any])
                #expect(intro["paymentMode"] as? String == "free" && intro["subscriptionPeriod"] as? String == "P2W")
            }
            #expect(s["recurringSubscriptionPeriod"] as? String == (plan.isAnnual ? "P1Y" : "P1M"))
            #expect(s["displayPrice"] as? String == prices[id])
        }
        let settings = try #require(json["settings"] as? [String: Any])
        #expect(settings["_billingGracePeriodEnabled"] as? Bool == true && settings["_billingGracePeriodInDays"] as? Int == 3)
    }
}

/// Autonomous completion mandate 2026-11-01 — N2 (expiry at the moment of use), N3 (the cache is not an
/// authority) and N4 (one paid-use boundary, sample case never imports). Time is injected; the Mac's clock
/// is never changed. Overrides are task-local, so these tests never disturb suites running alongside.
@Suite("Entitlement at the moment of use, cache trust and the paid boundary")
struct EntitlementBoundaryTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }

    @Test("An open app crossing the end of a trial, a paid period and a grace period refuses at that moment; cancelled-but-valid and a renewal keep access")
    @MainActor func crossesBoundaries() {
        var now = t0
        let center = PurchaseCenter(talksToStore: false)
        center.clock = { now }
        // A trial that ends in an hour.
        center.apply(.introductoryTrial(endsAt: at(3_600), plan: .monthly, willRenew: true))
        #expect(center.allowPaidAction("edit"))
        now = at(3_601)
        #expect(!center.allowPaidAction("edit"), "the trial ended while the app stayed open")
        #expect(center.entitlement == .lapsed(reason: .expired) && center.paywallRequested == "edit")
        // A cancelled plan stays valid until its end; then it refuses.
        center.paywallRequested = nil
        center.apply(.subscribed(expiresAt: at(7_200), plan: .annual, willRenew: false))
        #expect(center.allowPaidAction("edit"))
        now = at(7_200)
        #expect(!center.allowPaidAction("edit"))
        // Grace ends: billing failed.
        center.apply(.grace(until: at(9_000), plan: .monthly))
        #expect(center.allowPaidAction("edit"))
        now = at(9_000)
        #expect(!center.allowPaidAction("edit") && center.entitlement == .lapsed(reason: .billingFailed))
        // A renewal extends the period: access again.
        center.apply(.subscribed(expiresAt: at(100_000), plan: .monthly, willRenew: true))
        #expect(center.allowPaidAction("edit"))
        // Reading never depends on any of this.
        #expect(center.entitlement.allowsReadAccess)
    }

    @Test("The deadline flips the state on its own while the app stays open, with no paid action and no refresh")
    @MainActor func deadlineFires() async throws {
        let center = PurchaseCenter(talksToStore: false)
        center.clock = { Date() }
        center.apply(.subscribed(expiresAt: Date().addingTimeInterval(0.5), plan: .monthly, willRenew: true))
        #expect(center.entitlement.allowsPaidUse)
        try await Task.sleep(for: .seconds(2.5))
        #expect(center.entitlement == .lapsed(reason: .expired), "\(center.entitlement)")
    }

    @Test("The boundary applies the clock at the moment of the check, refuses imports in the sample case and lets the sample be worked on")
    func boundaryRules() {
        let active = Entitlement.subscribed(expiresAt: at(60), plan: .monthly, willRenew: true)
        #expect(PaidUse.refusal("edit", sample: false, entitlement: active, now: at(59)) == nil)
        #expect(PaidUse.refusal("edit", sample: false, entitlement: active, now: at(60)) != nil, "expired at use, without a refresh")
        #expect(PaidUse.refusal("edit", sample: false, entitlement: .lapsed(reason: .revoked), now: t0) != nil)
        #expect(PaidUse.refusal("edit", sample: false, entitlement: .unknown, now: t0) != nil, "an unanswered store is not an unlock")
        #expect(PaidUse.refusal("edit", sample: false, entitlement: .legacyUnlocked, now: at(1e9)) == nil)
        // The sample: working on the bundled documents is free; importing the person's files never is.
        #expect(PaidUse.refusal("run jobs", sample: true, entitlement: .notStarted, now: t0) == nil)
        #expect(PaidUse.refusal("add documents", importing: true, sample: true, entitlement: .legacyUnlocked, now: t0)?.reason.contains("Back to my archive") == true)
        // The refusal says what stays free.
        #expect(PaidUse.refusal("edit", sample: false, entitlement: .notStarted, now: t0)?.reason.contains("readable and exportable") == true)
    }

    @Test("Operations refuse at their own boundary: a Work Center run, a dataset, a case and an import cannot bypass a lapsed state")
    func serviceBoundary() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("pj-paid-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let db = try Database(url: temp.appendingPathComponent("p.sqlite"))
        try await SchemaMigrations.migrate(db)
        let wc = WorkCenterRepository(database: db)
        let datasets = WorkbenchDatasetRepository(database: db)
        let cases = InvestigationCaseRepository(database: db)
        try await PaidUse.TestOverride.$entitlement.withValue(.lapsed(reason: .expired)) {
            try await PaidUse.TestOverride.$sample.withValue(false) {
                await #expect(throws: PaidUse.Refused.self) {
                    _ = try await wc.createRun(defID: "x", title: "t", actor: "me", at: t0)
                }
                await #expect(throws: PaidUse.Refused.self) {
                    _ = try await datasets.createDataset(workspaceID: UUID(), title: "d", mode: .simple, actor: "me", at: t0)
                }
                await #expect(throws: PaidUse.Refused.self) {
                    _ = try await cases.createCase(workspaceID: UUID(), title: "c", actor: "me", at: t0)
                }
                #expect(PaidUse.refusal("read your folders", importing: true) != nil, "background reads skip silently")
            }
        }
        // Verified active: the boundary lets the operation through to its own validation.
        try await PaidUse.TestOverride.$entitlement.withValue(.subscribed(expiresAt: Date().addingTimeInterval(3_600), plan: .monthly, willRenew: true)) {
            try await PaidUse.TestOverride.$sample.withValue(false) {
                #expect(PaidUse.refusal("start a work-center run") == nil)
            }
        }
    }

    @Test("The cache is sealed: an edited preference, a forged lifetime unlock and a stale clock grant nothing")
    func cacheTrust() throws {
        let defaults = UserDefaults(suiteName: "pj-cache-\(UUID().uuidString)")!
        let secret = Data(repeating: 7, count: 32)
        let active = Entitlement.subscribed(expiresAt: at(86_400), plan: .monthly, willRenew: true)
        CachedEntitlement(active, at: t0).save(to: defaults, secret: secret)
        #expect(CachedEntitlement.load(from: defaults, secret: secret)?.entitlement(now: at(10)) == active)
        // Another installation's key, or none: nothing loads.
        #expect(CachedEntitlement.load(from: defaults, secret: Data(repeating: 8, count: 32)) == nil)
        #expect(CachedEntitlement.load(from: defaults, secret: nil) == nil)
        // Tampering with the stored bytes (the editable preference) breaks the seal.
        var raw = try #require(defaults.data(forKey: CachedEntitlement.key))
        raw[raw.count / 2] ^= 0x01
        defaults.set(raw, forKey: CachedEntitlement.key)
        #expect(CachedEntitlement.load(from: defaults, secret: secret) == nil)
        // A forged permanent state, even correctly sealed, grants nothing: only StoreKit proves it.
        CachedEntitlement(.legacyUnlocked, at: t0).save(to: defaults, secret: secret)
        #expect(CachedEntitlement.load(from: defaults, secret: secret)?.entitlement(now: at(10)) == .unknown)
        // A plain JSON preference in the old v1 format is not read.
        defaults.set(try JSONEncoder().encode(CachedEntitlement(.legacyUnlocked, at: t0)), forKey: "kalsmritikosh.purchase.verifiedEntitlement")
        CachedEntitlement(.notStarted, at: t0).save(to: defaults, secret: secret)
        #expect(CachedEntitlement.load(from: defaults, secret: secret)?.entitlement(now: t0) == .notStarted)
        // Clock rollback: the state is read as of the verification, never earlier — a cache verified after
        // its own end stays lapsed when the clock is set back.
        let late = CachedEntitlement(.subscribed(expiresAt: at(100), plan: .monthly, willRenew: true), at: at(200))
        #expect(late.entitlement(now: t0) == .lapsed(reason: .expired))
        // Malformed fields grant nothing.
        var broken = CachedEntitlement(active, at: t0); broken.until = nil
        #expect(broken.entitlement(now: t0) == .unknown)
    }

    @Test("Test-only configurations are reached through TestHost alone")
    func testHostBoundary() {
        #expect(TestHost.isActive, "this is the test host (Debug)")
        #expect(PurchaseCenter.isTestHost == TestHost.isActive && AppDefaults.isTestHost == TestHost.isActive)
    }
}

