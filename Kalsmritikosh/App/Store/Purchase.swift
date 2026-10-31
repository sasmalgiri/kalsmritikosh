//
//  Purchase.swift
//  Kalsmritikosh
//
//  How the app is sold (owner decision 2026-10-30, App Store completion instructions §11): a free
//  download; one edition with all nine personas; an auto-renewable subscription — monthly or
//  annual, the same access either way — with a 14-day introductory free trial for subscribers
//  Apple finds eligible, renewing automatically unless cancelled. Apple sells, bills, renews,
//  refunds and restores; the app itself opens no connection for any of it and never sees payment
//  details. Subscribing enables nothing else: not Online mode, not any upload.
//
//  Two earlier products are honoured, never repurposed: the permanent unlock sold under the
//  2026-10-18 plan (`…unlock`, one purchase for good) takes precedence over everything, and the old
//  free 14-day product (`…trial14`) is a trial still running or ended — it is not consent to billing.
//
//  Entitlement comes only from VERIFIED StoreKit 2 transactions and renewal information. The last
//  verified state is cached so an offline launch keeps what was verified, through the latest
//  verified expiry or grace end, and no further: a store error never becomes an unlimited unlock,
//  and never removes still-valid access. When nothing paid stands, the person's work stays
//  readable and exportable (cases, backups, recovery, Help, privacy and erasure controls); only
//  creating, editing and analysing — the paid functions — wait for a subscription.
//

import Foundation
import StoreKit
import os

nonisolated enum PurchaseProducts {
    /// Adopted 2026-10-30: one subscription group, two durations, one access level.
    static let monthly = "ecosanskritiinnovation.Kalsmritikosh.edition.monthly"
    static let annual = "ecosanskritiinnovation.Kalsmritikosh.edition.annual"
    static let introductoryTrialDays = 14
    static var subscriptions: [String] { [monthly, annual] }

    /// Sold under the 2026-10-18 plan; kept for restore, reinstall and update — never a subscription.
    static let legacyUnlock = "ecosanskritiinnovation.Kalsmritikosh.unlock"
    static let legacyTrial = "ecosanskritiinnovation.Kalsmritikosh.trial14"
    static let legacyTrialDays = 14

    static var all: [String] { subscriptions + [legacyUnlock, legacyTrial] }

    /// Apple's page for upgrading, downgrading or cancelling (the in-app sheet does not exist on macOS).
    static let manageSubscriptionsURL = URL(string: "https://apps.apple.com/account/subscriptions")!
    /// Apple's current instructions for cancelling a subscription or trial.
    static let cancelInstructionsURL = URL(string: "https://support.apple.com/en-us/118428")!
}

/// Which duration a transaction is for.
nonisolated enum SubscriptionPlan: String, Equatable, Sendable, CaseIterable {
    case monthly, annual
    init?(productID: String) {
        switch productID {
        case PurchaseProducts.monthly: self = .monthly
        case PurchaseProducts.annual: self = .annual
        default: return nil
        }
    }
    var productID: String { self == .monthly ? PurchaseProducts.monthly : PurchaseProducts.annual }
    var periodNoun: String { self == .monthly ? "month" : "year" }
    var label: String { self == .monthly ? "Monthly" : "Annual" }
}

/// Where this Apple account stands. Pure, so the rules are tested without StoreKit.
nonisolated enum Entitlement: Equatable, Sendable {
    /// The 2026-10-18 permanent unlock, verified and not revoked: everything, for good.
    case legacyUnlocked
    /// The old free 14-day product, still running (no billing is attached to it).
    case legacyTrial(endsAt: Date)
    /// A subscription's introductory free period; the selected plan renews at `endsAt` unless cancelled.
    case introductoryTrial(endsAt: Date, plan: SubscriptionPlan, willRenew: Bool)
    /// A paid period; `willRenew` false = cancelled but active until `expiresAt`.
    case subscribed(expiresAt: Date, plan: SubscriptionPlan, willRenew: Bool)
    /// Apple's verified billing grace period after a failed renewal: still entitled, until `until`.
    case grace(until: Date, plan: SubscriptionPlan)
    /// Billing retry with no grace: not entitled to paid functions until payment recovers.
    case billingRetry(plan: SubscriptionPlan)
    /// Nothing paid stands any more (expired, refunded/revoked, or the legacy trial ended).
    case lapsed(reason: LapseReason)
    /// The store answered and this account never had anything.
    case notStarted
    /// The store has not answered yet and nothing verified is cached. Not an unlock: paid actions
    /// wait, the subscription screen says the store could not be reached and offers retry, while
    /// reading, Help, the sample and recovery stay open (a verified cached state is used instead
    /// whenever one exists — see `PurchaseCenter.refresh`).
    case unknown

    nonisolated enum LapseReason: String, Equatable, Sendable { case expired, revoked, legacyTrialEnded, billingFailed }

    /// Paid functions (creating, editing, analysing) may be used. Only a VERIFIED state grants them:
    /// an unanswered store is never an unlimited unlock (UI run f, F-1).
    var allowsPaidUse: Bool {
        switch self {
        case .legacyUnlocked, .legacyTrial, .introductoryTrial, .subscribed, .grace: return true
        case .billingRetry, .lapsed, .notStarted, .unknown: return false
        }
    }

    /// The whole-window subscription screen leads: nothing was ever bought, or the store has not
    /// answered and nothing verified is cached. Everyone else keeps the window.
    var leadsWithSubscriptionScreen: Bool {
        switch self {
        case .notStarted, .unknown: return true
        default: return false
        }
    }

    /// Reading, exporting, backing up, recovering, Help and privacy controls are never gated.
    var allowsReadAccess: Bool { true }

    /// The person has work from an earlier paid state (the window stays usable, read-only) rather
    /// than never having started (the purchase screen leads).
    var hadAccessBefore: Bool {
        switch self {
        case .billingRetry, .lapsed: return true
        default: return false
        }
    }

    /// When the verified state stops being valid on its own (offline, the cache may not extend it).
    var verifiedUntil: Date? {
        switch self {
        case .legacyTrial(let d), .introductoryTrial(let d, _, _), .subscribed(let d, _, _), .grace(let d, _): return d
        default: return nil
        }
    }

    var plan: SubscriptionPlan? {
        switch self {
        case .introductoryTrial(_, let p, _), .subscribed(_, let p, _), .grace(_, let p), .billingRetry(let p): return p
        default: return nil
        }
    }

    /// One verified StoreKit transaction (or legacy transaction), as the rules need it.
    struct Record: Equatable, Sendable {
        let productID: String
        let purchaseDate: Date
        let originalPurchaseDate: Date
        /// Subscriptions: when this period ends (nil for the non-consumables).
        var expirationDate: Date? = nil
        let revoked: Bool
        /// Subscriptions: this transaction is the introductory free period.
        var isIntroductoryOffer: Bool = false
    }

    /// Verified renewal information for the subscription group (nil when StoreKit gave none).
    struct Renewal: Equatable, Sendable {
        var willAutoRenew: Bool
        var isInBillingRetry: Bool = false
        var gracePeriodExpiration: Date? = nil
        var revoked: Bool = false
        var expired: Bool = false
    }

    /// The rules. `storeAnswered` is false when neither a transaction nor a product came back
    /// (offline first launch, or a build with no store): then nothing is known.
    static func evaluate(records: [Record], renewal: Renewal?, storeAnswered: Bool, now: Date) -> Entitlement {
        // 1. A standing permanent unlock beats everything (a refunded one does not hide another that stands).
        let unlocks = records.filter { $0.productID == PurchaseProducts.legacyUnlock }
        if unlocks.contains(where: { !$0.revoked }) { return .legacyUnlocked }

        // 2. The subscription group: the latest non-revoked period decides.
        let subs = records.filter { SubscriptionPlan(productID: $0.productID) != nil }
        if let latest = subs.filter({ !$0.revoked }).max(by: { ($0.expirationDate ?? .distantPast) < ($1.expirationDate ?? .distantPast) }),
           let plan = SubscriptionPlan(productID: latest.productID) {
            let expires = latest.expirationDate ?? latest.purchaseDate
            let willRenew = renewal?.willAutoRenew ?? true
            if now < expires {
                return latest.isIntroductoryOffer ? .introductoryTrial(endsAt: expires, plan: plan, willRenew: willRenew)
                                                  : .subscribed(expiresAt: expires, plan: plan, willRenew: willRenew)
            }
            // Past the period: a verified grace keeps access; a retry without grace does not.
            if let grace = renewal?.gracePeriodExpiration, now < grace { return .grace(until: grace, plan: plan) }
            if renewal?.isInBillingRetry == true { return .billingRetry(plan: plan) }
            return .lapsed(reason: renewal?.isInBillingRetry == false && renewal?.willAutoRenew == true ? .billingFailed : .expired)
        }
        if !subs.isEmpty { return .lapsed(reason: .revoked) }   // every subscription period was refunded or revoked

        // 3. The old free trial product.
        if let start = records.filter({ $0.productID == PurchaseProducts.legacyTrial }).map(\.originalPurchaseDate).min() {
            let ends = start.addingTimeInterval(TimeInterval(PurchaseProducts.legacyTrialDays) * 86_400)
            return now < ends ? .legacyTrial(endsAt: ends) : .lapsed(reason: .legacyTrialEnded)
        }
        if !unlocks.isEmpty { return .lapsed(reason: .revoked) }   // only a refunded unlock
        return storeAnswered ? .notStarted : .unknown
    }

    /// Whole days left in a trial or paid period (at least 1 while any time is left).
    func daysLeft(now: Date = Date()) -> Int? {
        guard let ends = verifiedUntil else { return nil }
        return max(1, Int((ends.timeIntervalSince(now) / 86_400).rounded(.up)))
    }

    /// The offline rule: a cached verified state keeps its access only until its own verified end;
    /// after that the cache says `lapsed`, never `unknown`, so an outage cannot extend access.
    func asCached(now: Date) -> Entitlement {
        if let until = verifiedUntil, now >= until {
            switch self {
            case .legacyTrial: return .lapsed(reason: .legacyTrialEnded)
            case .grace: return .lapsed(reason: .billingFailed)
            default: return .lapsed(reason: .expired)
            }
        }
        return self
    }
}

/// The last verified state, kept between launches (never an unverified or unlimited one).
nonisolated struct CachedEntitlement: Codable, Equatable, Sendable {
    enum Kind: String, Codable { case legacyUnlocked, legacyTrial, introductoryTrial, subscribed, grace, billingRetry, lapsed, notStarted }
    var kind: Kind
    var until: Date?
    var plan: String?
    var willRenew: Bool?
    var reason: String?
    var verifiedAt: Date

    init(_ e: Entitlement, at: Date) {
        verifiedAt = at
        switch e {
        case .legacyUnlocked: kind = .legacyUnlocked
        case .legacyTrial(let d): kind = .legacyTrial; until = d
        case .introductoryTrial(let d, let p, let r): kind = .introductoryTrial; until = d; plan = p.rawValue; willRenew = r
        case .subscribed(let d, let p, let r): kind = .subscribed; until = d; plan = p.rawValue; willRenew = r
        case .grace(let d, let p): kind = .grace; until = d; plan = p.rawValue
        case .billingRetry(let p): kind = .billingRetry; plan = p.rawValue
        case .lapsed(let why): kind = .lapsed; reason = why.rawValue
        case .notStarted, .unknown: kind = .notStarted
        }
    }

    /// Back to an entitlement, applying the offline rule at `now`.
    func entitlement(now: Date) -> Entitlement {
        let p = plan.flatMap(SubscriptionPlan.init(rawValue:))
        let e: Entitlement
        switch kind {
        case .legacyUnlocked: e = .legacyUnlocked
        case .legacyTrial: e = .legacyTrial(endsAt: until ?? now)
        case .introductoryTrial: e = .introductoryTrial(endsAt: until ?? now, plan: p ?? .monthly, willRenew: willRenew ?? true)
        case .subscribed: e = .subscribed(expiresAt: until ?? now, plan: p ?? .monthly, willRenew: willRenew ?? true)
        case .grace: e = .grace(until: until ?? now, plan: p ?? .monthly)
        case .billingRetry: e = .billingRetry(plan: p ?? .monthly)
        case .lapsed: e = .lapsed(reason: reason.flatMap(Entitlement.LapseReason.init(rawValue:)) ?? .expired)
        case .notStarted: e = .notStarted
        }
        return e.asCached(now: now)
    }

    static let key = "kalsmritikosh.purchase.verifiedEntitlement"
    static func load(from defaults: UserDefaults = AppDefaults.store) -> CachedEntitlement? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(CachedEntitlement.self, from: data)
    }
    func save(to defaults: UserDefaults = AppDefaults.store) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) }
    }
}

/// What the paywall shows for one plan, from StoreKit's own localised values (never a hard-coded price).
nonisolated struct PlanOffer: Equatable, Sendable, Identifiable {
    var id: SubscriptionPlan { plan }
    let plan: SubscriptionPlan
    /// StoreKit's localised display price for one period, e.g. "$4.99" or "₹1,999".
    let displayPrice: String
    /// The period as sold ("1 month", "1 year").
    let periodText: String
    /// True when StoreKit says this customer is eligible for the group's introductory offer.
    let eligibleForTrial: Bool
    /// The introductory offer's length in days when configured (nil when none is configured).
    let trialDays: Int?

    /// The call-to-action for this plan, from eligibility — never a trial promise to the ineligible.
    var actionTitle: String {
        if eligibleForTrial, let d = trialDays { return "Start \(d)-day free trial" }
        return "Subscribe \(displayPrice) per \(plan.periodNoun)"
    }

    /// The disclosure Apple's guidance and the instruction ask for, with real values.
    var disclosure: String {
        let renew = "Renews automatically at \(displayPrice) per \(plan.periodNoun) unless cancelled at least a day before the period ends. Manage or cancel through your Apple Account."
        if eligibleForTrial, let d = trialDays {
            return "\(d) days free, then \(displayPrice) per \(plan.periodNoun). \(renew)"
        }
        return "\(displayPrice) per \(plan.periodNoun), charged now. \(renew)"
    }

    /// The annual plan's saving against twelve monthly charges, from the two matching storefront
    /// prices; nil when the prices are not comparable numbers. Secondary information only.
    static func annualSaving(monthly: Decimal, annual: Decimal) -> Int? {
        guard monthly > 0, annual > 0 else { return nil }
        let twelve = monthly * 12
        guard twelve > annual else { return nil }
        let fraction = NSDecimalNumber(decimal: (twelve - annual) / twelve).doubleValue
        return Int((fraction * 100).rounded())
    }
}

@MainActor
@Observable
final class PurchaseCenter {
    static let shared = PurchaseCenter()

    private(set) var entitlement: Entitlement = .unknown
    private(set) var offers: [PlanOffer] = []
    /// The annual saving (per cent) when both storefront prices are known; shown second.
    private(set) var annualSavingPercent: Int?
    /// True while the products could not be loaded: the paywall shows retry, never a made-up price.
    private(set) var productsUnavailable = false
    private(set) var busy = false
    var message: String?
    /// Set by a paid action that was refused: the paywall opens over the current screen.
    var paywallRequested: String?

    /// The unit-test host never talks to the App Store and is always unlocked.
    static let isTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    private var updates: Task<Void, Never>?
    private var products: [String: Product] = [:]

    func start() {
        if Self.isTestHost { entitlement = .legacyUnlocked; return }
        guard updates == nil else { return }
        // The last verified state carries the person through an offline launch, under its own rule.
        if let cached = CachedEntitlement.load() { entitlement = cached.entitlement(now: Date()) }
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                if case .verified(let t) = result { await t.finish() }
                await self?.refresh()
            }
        }
        Task { await loadProducts(); await refresh() }
    }

    func loadProducts() async {
        do {
            let loaded = try await Product.products(for: PurchaseProducts.all)
            products = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0) })
            var out: [PlanOffer] = []
            for plan in SubscriptionPlan.allCases {
                guard let p = products[plan.productID], let info = p.subscription else { continue }
                let eligible = await info.isEligibleForIntroOffer
                let intro = info.introductoryOffer
                let days: Int? = intro.map { offer in
                    switch offer.period.unit {
                    case .day: return offer.period.value
                    case .week: return offer.period.value * 7
                    case .month: return offer.period.value * 30
                    case .year: return offer.period.value * 365
                    @unknown default: return offer.period.value
                    }
                }
                out.append(PlanOffer(plan: plan, displayPrice: p.displayPrice, periodText: Self.periodText(info.subscriptionPeriod),
                                     eligibleForTrial: eligible && intro != nil && intro?.paymentMode == .freeTrial, trialDays: days))
            }
            offers = out
            productsUnavailable = out.count < SubscriptionPlan.allCases.count
            if let m = products[PurchaseProducts.monthly], let a = products[PurchaseProducts.annual] {
                annualSavingPercent = PlanOffer.annualSaving(monthly: m.price, annual: a.price)
            }
        } catch {
            KalsmritikoshLog.app.error("App Store products unavailable: \(error.localizedDescription, privacy: .public)")
            productsUnavailable = true
        }
    }

    nonisolated static func periodText(_ period: Product.SubscriptionPeriod) -> String {
        let unit: String
        switch period.unit {
        case .day: unit = "day"
        case .week: unit = "week"
        case .month: unit = "month"
        case .year: unit = "year"
        @unknown default: unit = "period"
        }
        return period.value == 1 ? "1 \(unit)" : "\(period.value) \(unit)s"
    }

    /// Read the signed transactions and renewal information StoreKit holds for this Apple account.
    func refresh() async {
        if Self.isTestHost { entitlement = .legacyUnlocked; return }
        var records: [Entitlement.Record] = []
        for await result in Transaction.currentEntitlements {
            guard case .verified(let t) = result else { continue }   // an unverified transaction counts for nothing
            records.append(.init(productID: t.productID, purchaseDate: t.purchaseDate, originalPurchaseDate: t.originalPurchaseDate,
                                 expirationDate: t.expirationDate, revoked: t.revocationDate != nil,
                                 isIntroductoryOffer: t.offer?.type == .introductory))
        }
        var renewal: Entitlement.Renewal?
        if let any = products[PurchaseProducts.monthly] ?? products[PurchaseProducts.annual], let info = any.subscription,
           let statuses = try? await info.status {
            // The group's current status: StoreKit returns one per subscription in the group; the
            // most entitled verified one is the group's state.
            for status in statuses {
                guard case .verified(let r) = status.renewalInfo else { continue }
                var ren = Entitlement.Renewal(willAutoRenew: r.willAutoRenew, isInBillingRetry: r.isInBillingRetry,
                                              gracePeriodExpiration: r.gracePeriodExpirationDate)
                ren.revoked = status.state == .revoked
                ren.expired = status.state == .expired
                if renewal == nil || status.state == .subscribed || status.state == .inGracePeriod { renewal = ren }
            }
        }
        let now = Date()
        let fresh = Entitlement.evaluate(records: records, renewal: renewal, storeAnswered: !products.isEmpty, now: now)
        if fresh == .unknown {
            // The store did not answer: keep the cached verified state under its own rule.
            entitlement = CachedEntitlement.load()?.entitlement(now: now) ?? .unknown
            return
        }
        entitlement = fresh
        CachedEntitlement(fresh, at: now).save()
    }

    /// Subscribe to a plan (StoreKit applies the introductory offer only to the eligible).
    func subscribe(_ plan: SubscriptionPlan) async {
        await buy(products[plan.productID], what: "the \(plan.label.lowercased()) plan")
    }

    private func buy(_ product: Product?, what: String) async {
        guard let product else {
            message = "The App Store is not reachable right now, so the price and the plan cannot be confirmed. Try again in a moment."
            return
        }
        busy = true
        defer { busy = false }
        do {
            switch try await product.purchase() {
            case .success(let verification):
                guard case .verified(let t) = verification else {
                    message = Self.message(for: .unverified, what: what)
                    return
                }
                await t.finish()
                message = Self.message(for: .verified, what: what)
            case .userCancelled: message = Self.message(for: .cancelled, what: what)
            case .pending: message = Self.message(for: .pending, what: what)
            @unknown default: break
            }
        } catch {
            KalsmritikoshLog.app.error("Purchase failed: \(error.localizedDescription, privacy: .public)")
            message = error.localizedDescription
        }
        await refresh()
    }

    /// What a purchase attempt ended in, as the person is told.
    enum Outcome { case verified, unverified, cancelled, pending }

    nonisolated static func message(for outcome: Outcome, what: String) -> String? {
        switch outcome {
        case .verified, .cancelled: return nil
        case .unverified: return "The App Store could not confirm \(what). Nothing was charged twice; try Restore purchases."
        case .pending: return "Waiting for approval (for example Ask to Buy). It will unlock by itself once approved."
        }
    }

    /// Ask the App Store for this account's purchases again.
    func restore() async {
        busy = true
        defer { busy = false }
        do { try await AppStore.sync() } catch {
            KalsmritikoshLog.app.error("Restore failed: \(error.localizedDescription, privacy: .public)")
            message = error.localizedDescription
        }
        await refresh()
        if message == nil {
            switch entitlement {
            case .unknown: message = "The App Store did not answer, so nothing could be restored. Check the connection and try again."
            case .notStarted, .lapsed, .billingRetry: message = "No active subscription or purchase was found for this Apple account."
            default: message = "Restored: " + statusText
            }
        }
    }

    /// A paid action (create, edit, analyse) asks here first. When nothing paid stands, the paywall
    /// is requested and the action does not run. Reading, exporting, backing up, recovering, Help and
    /// privacy controls never ask.
    @discardableResult
    func allowPaidAction(_ what: String) -> Bool {
        if entitlement.allowsPaidUse { return true }
        paywallRequested = what
        return false
    }

    /// One sentence on the current state, for the status strip and Settings.
    var statusText: String {
        let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .none
        switch entitlement {
        case .legacyUnlocked: return "Purchased outright (lifetime unlock)."
        case .legacyTrial(let d): return "Free trial (earlier plan) until \(df.string(from: d)); no charge follows it."
        case .introductoryTrial(let d, let plan, let r):
            return r ? "Free trial until \(df.string(from: d)); the \(plan.label.lowercased()) plan then renews unless cancelled a day before."
                     : "Free trial until \(df.string(from: d)); renewal is off, so nothing will be charged."
        case .subscribed(let d, let plan, let r):
            return r ? "\(plan.label) plan, renews \(df.string(from: d))." : "\(plan.label) plan, cancelled — access until \(df.string(from: d))."
        case .grace(let d, _): return "Payment did not go through; access continues until \(df.string(from: d)) while Apple retries."
        case .billingRetry: return "Payment did not go through. Update the payment method in your Apple Account to continue."
        case .lapsed(let why):
            switch why {
            case .expired: return "Subscription ended. Your work stays readable and exportable; subscribe again to edit and analyse."
            case .revoked: return "The purchase was refunded or revoked. Your work stays readable and exportable."
            case .legacyTrialEnded: return "The free trial ended. Your work stays readable and exportable."
            case .billingFailed: return "Renewal failed. Your work stays readable and exportable; update the payment method to continue."
            }
        case .notStarted: return "Not subscribed."
        case .unknown: return "The App Store has not confirmed a plan for this account yet (offline, or the store did not answer). Reading, export, backup, recovery and Help work; subscribing or editing waits for the store. Try again or Restore purchases."
        }
    }
}
