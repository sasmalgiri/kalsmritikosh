//
//  Purchase.swift
//  Kalsmritikosh
//
//  How the app is sold (owner decisions 2026-11-04, replacing 2026-10-30 §11 and 2026-11-01 A2): a free
//  download and ONE auto-renewable subscription group with three levels, each monthly or yearly —
//  StoreKit upgrades, downgrades and crossgrades within the group, so nobody holds two subscriptions:
//    • Workbench ($4.99 / $39.99; ₹249 / ₹1,999): every non-AI feature; Online AI only with the
//      person's own Anthropic key, billed by Anthropic. The ONLY plan with a 14-day introductory trial.
//    • AI Included ($39 / $389): everything in Workbench + 2,000 AI credits a month through the
//      publisher's relay (1 credit = US$0.01 of Claude cost). No trial.
//    • AI Pro ($99 / $989): everything + 6,000 credits a month and a larger whole-case read. No trial.
//  Yearly plans get the same monthly allowance each month (from the purchase anniversary — see
//  relay/src/policy.ts, the one authority for plan parameters). Credit packs (500 and 2,000, consumable)
//  never expire and are usable only with an AI plan. There are no earlier buyers: the 2026-10-18 lifetime
//  unlock and its free trial product no longer exist in the app.
//
//  Apple sells, bills, renews, refunds and restores; the app itself opens no connection for any of it
//  and never sees payment details. Subscribing enables nothing else: not Online mode, not any upload.
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
import AppKit
import CryptoKit
import Security
import os

nonisolated enum PurchaseProducts {
    /// Workbench (product ids kept from the 2026-10-30 edition; never sold before).
    static let monthly = "ecosanskritiinnovation.Kalsmritikosh.edition.monthly"
    static let annual = "ecosanskritiinnovation.Kalsmritikosh.edition.annual"
    static let introductoryTrialDays = 14
    /// AI Included — the same group, one level above Workbench. No introductory offer.
    static let aiMonthly = "ecosanskritiinnovation.Kalsmritikosh.ai.monthly"
    static let aiAnnual = "ecosanskritiinnovation.Kalsmritikosh.ai.annual"
    /// AI Pro — the same group, the top level. No introductory offer.
    static let proMonthly = "ecosanskritiinnovation.Kalsmritikosh.aipro.monthly"
    static let proAnnual = "ecosanskritiinnovation.Kalsmritikosh.aipro.annual"
    /// Consumable credit packs (credited by the relay; never expire).
    static let credits500 = "ecosanskritiinnovation.Kalsmritikosh.ai.credits500"
    static let credits2000 = "ecosanskritiinnovation.Kalsmritikosh.ai.credits2000"

    static var subscriptions: [String] { [monthly, annual, aiMonthly, aiAnnual, proMonthly, proAnnual] }
    static var creditPacks: [String] { [credits500, credits2000] }
    /// Credits in a pack (mirror of relay TOPUP_CREDITS), nil for anything else.
    static func credits(inPack id: String) -> Int? {
        switch id {
        case credits500: return AIPricing.credits500
        case credits2000: return AIPricing.credits2000
        default: return nil
        }
    }

    /// Every entitlement record the app reads (a consumable pack is never an entitlement).
    static var all: [String] { subscriptions }
    /// Everything the App Store is asked for.
    static var storeProducts: [String] { subscriptions + creditPacks }

    /// Apple's page for upgrading, downgrading or cancelling (the in-app sheet does not exist on macOS).
    static let manageSubscriptionsURL = URL(string: "https://apps.apple.com/account/subscriptions")!
    /// Apple's current instructions for cancelling a subscription or trial.
    static let cancelInstructionsURL = URL(string: "https://support.apple.com/en-us/118428")!
}

/// The three levels of the subscription group.
nonisolated enum PlanTier: String, Equatable, Sendable, CaseIterable, Comparable {
    case workbench, aiIncluded, aiPro
    var name: String {
        switch self {
        case .workbench: return "Workbench"
        case .aiIncluded: return "AI Included"
        case .aiPro: return "AI Pro"
        }
    }
    /// The relay's limits (nil for Workbench, which has no relay credits).
    var limits: AIPricing.PlanLimits? {
        switch self {
        case .workbench: return nil
        case .aiIncluded: return AIPricing.aiIncluded
        case .aiPro: return AIPricing.aiPro
        }
    }
    /// The relay's code for this tier in its receipts ("ai" / "pro").
    init?(relayCode: String) {
        switch relayCode {
        case "ai": self = .aiIncluded
        case "pro": self = .aiPro
        default: return nil
        }
    }
    /// What the plan includes, in plain words (App Review 3.1.2(c)): shown with every price.
    var includes: String {
        switch self {
        case .workbench:
            return "Every persona and job on your Mac — adding documents, the case file, timelines, jobs and exports. Online AI uses your own Anthropic key, billed to you by Anthropic. 14-day free trial for new subscribers."
        case .aiIncluded:
            return "Everything in Workbench, plus \(AIPricing.aiIncluded.monthlyCredits.formatted()) AI credits a month for Claude through the publisher's service — no AI account or key needed. 1 credit = US$0.01 of AI cost; a typical question uses a few credits, reading a whole case more. No free trial."
        case .aiPro:
            return "Everything in Workbench, plus \(AIPricing.aiPro.monthlyCredits.formatted()) AI credits a month and larger whole-case reads (up to \(AIPricing.aiPro.caseReadCredits.formatted()) credits at once). No free trial."
        }
    }
    static func < (a: PlanTier, b: PlanTier) -> Bool { a.rank < b.rank }
    private var rank: Int { self == .workbench ? 0 : self == .aiIncluded ? 1 : 2 }
}

/// Which plan and duration a transaction is for.
nonisolated enum SubscriptionPlan: String, Equatable, Sendable, CaseIterable {
    case monthly, annual, aiMonthly, aiAnnual, proMonthly, proAnnual
    init?(productID: String) {
        guard let p = Self.allCases.first(where: { $0.productID == productID }) else { return nil }
        self = p
    }
    var productID: String {
        switch self {
        case .monthly: return PurchaseProducts.monthly
        case .annual: return PurchaseProducts.annual
        case .aiMonthly: return PurchaseProducts.aiMonthly
        case .aiAnnual: return PurchaseProducts.aiAnnual
        case .proMonthly: return PurchaseProducts.proMonthly
        case .proAnnual: return PurchaseProducts.proAnnual
        }
    }
    var tier: PlanTier {
        switch self {
        case .monthly, .annual: return .workbench
        case .aiMonthly, .aiAnnual: return .aiIncluded
        case .proMonthly, .proAnnual: return .aiPro
        }
    }
    var isAnnual: Bool { self == .annual || self == .aiAnnual || self == .proAnnual }
    /// AI Included or AI Pro: the publisher's AI credits come with the plan.
    var includesAI: Bool { tier != .workbench }
    var periodNoun: String { isAnnual ? "year" : "month" }
    var label: String { "\(tier.name) \(isAnnual ? "yearly" : "monthly")" }
    /// The same plan with the other duration (for the yearly saving).
    var counterpart: SubscriptionPlan {
        switch self {
        case .monthly: return .annual
        case .annual: return .monthly
        case .aiMonthly: return .aiAnnual
        case .aiAnnual: return .aiMonthly
        case .proMonthly: return .proAnnual
        case .proAnnual: return .proMonthly
        }
    }
}

/// Where this Apple account stands. Pure, so the rules are tested without StoreKit.
nonisolated enum Entitlement: Equatable, Sendable {
    /// The unit-test host's own state (TestHost only): paid functions open, no AI plan. Never produced
    /// from a store answer or the cache; a shipped build never reaches it.
    case testHostUnlocked
    /// A subscription's introductory free period; the selected plan renews at `endsAt` unless cancelled.
    case introductoryTrial(endsAt: Date, plan: SubscriptionPlan, willRenew: Bool)
    /// A paid period; `willRenew` false = cancelled but active until `expiresAt`.
    case subscribed(expiresAt: Date, plan: SubscriptionPlan, willRenew: Bool)
    /// Apple's verified billing grace period after a failed renewal: still entitled, until `until`.
    case grace(until: Date, plan: SubscriptionPlan)
    /// Billing retry with no grace: not entitled to paid functions until payment recovers.
    case billingRetry(plan: SubscriptionPlan)
    /// Nothing paid stands any more (expired, refunded/revoked, or billing failed).
    case lapsed(reason: LapseReason)
    /// The store answered and this account never had anything.
    case notStarted
    /// The store has not answered yet and nothing verified is cached. Not an unlock: paid actions
    /// wait, the subscription screen says the store could not be reached and offers retry, while
    /// reading, Help, the sample and recovery stay open (a verified cached state is used instead
    /// whenever one exists — see `PurchaseCenter.refresh`).
    case unknown

    nonisolated enum LapseReason: String, Equatable, Sendable { case expired, revoked, billingFailed }

    /// Paid functions (creating, editing, analysing) may be used. Only a VERIFIED state grants them:
    /// an unanswered store is never an unlimited unlock (UI run f, F-1).
    var allowsPaidUse: Bool {
        switch self {
        case .testHostUnlocked, .introductoryTrial, .subscribed, .grace: return true
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
        case .introductoryTrial(let d, _, _), .subscribed(let d, _, _), .grace(let d, _): return d
        default: return nil
        }
    }

    var plan: SubscriptionPlan? {
        switch self {
        case .introductoryTrial(_, let p, _), .subscribed(_, let p, _), .grace(_, let p), .billingRetry(let p): return p
        default: return nil
        }
    }

    /// The publisher's AI credits come with the current state: a paid AI Included / AI Pro period or its
    /// grace. Never a trial (no AI plan has one), never a lapsed state.
    var includesAI: Bool { aiTier != nil }

    /// The AI plan level that stands now (nil = no AI credits).
    var aiTier: PlanTier? {
        switch self {
        case .subscribed(_, let p, _), .grace(_, let p): return p.includesAI ? p.tier : nil
        default: return nil
        }
    }

    /// One verified StoreKit transaction, as the rules need it.
    struct Record: Equatable, Sendable {
        let productID: String
        let purchaseDate: Date
        let originalPurchaseDate: Date
        /// Subscriptions: when this period ends (nil for the non-consumables).
        var expirationDate: Date? = nil
        let revoked: Bool
        /// Subscriptions: this transaction is the introductory free period.
        var isIntroductoryOffer: Bool = false
        /// The App Store original transaction id (identifies an AI subscriber to the relay; the same for
        /// every transaction of the subscription group).
        var originalID: UInt64? = nil
        /// Apple replaced this period by an immediate upgrade within the group: it no longer counts.
        var upgraded: Bool = false
    }

    /// The AI plan's original transaction id when `entitlement` includes AI — what the relay is told,
    /// and nothing else about the person.
    static func aiSubscriptionID(records: [Record], entitlement: Entitlement) -> String? {
        guard entitlement.includesAI else { return nil }
        let ai = records.filter { !$0.revoked && !$0.upgraded && SubscriptionPlan(productID: $0.productID)?.includesAI == true }
        return ai.max(by: { ($0.expirationDate ?? .distantPast) < ($1.expirationDate ?? .distantPast) })?.originalID.map(String.init)
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
        // The subscription group: the latest period that was neither refunded nor replaced by an upgrade
        // decides (a Workbench year upgraded to AI Included keeps its old expiry on record, but no longer
        // counts; a downgrade takes effect at renewal, so the higher plan stands until then).
        let subs = records.filter { SubscriptionPlan(productID: $0.productID) != nil }
        if let latest = subs.filter({ !$0.revoked && !$0.upgraded }).max(by: { ($0.expirationDate ?? .distantPast) < ($1.expirationDate ?? .distantPast) }),
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
            case .grace: return .lapsed(reason: .billingFailed)
            default: return .lapsed(reason: .expired)
            }
        }
        return self
    }
}

/// The last verified state, kept between launches (never an unverified or unlimited one).
///
/// N3 (mandate 2026-11-01): the cache is a convenience for an offline launch, not an authority.
/// • It is sealed with an HMAC whose key lives in the Keychain, so an edited preference is ignored.
/// • It holds only time-limited states, each with its own verified end.
/// • A clock set back before the moment of verification is read as that moment, so it cannot extend a
///   time-limited state.
nonisolated struct CachedEntitlement: Codable, Equatable, Sendable {
    enum Kind: String, Codable { case introductoryTrial, subscribed, grace, billingRetry, lapsed, notStarted }
    var kind: Kind
    var until: Date?
    var plan: String?
    var willRenew: Bool?
    var reason: String?
    var verifiedAt: Date

    init(_ e: Entitlement, at: Date) {
        verifiedAt = at
        switch e {
        case .introductoryTrial(let d, let p, let r): kind = .introductoryTrial; until = d; plan = p.rawValue; willRenew = r
        case .subscribed(let d, let p, let r): kind = .subscribed; until = d; plan = p.rawValue; willRenew = r
        case .grace(let d, let p): kind = .grace; until = d; plan = p.rawValue
        case .billingRetry(let p): kind = .billingRetry; plan = p.rawValue
        case .lapsed(let why): kind = .lapsed; reason = why.rawValue
        case .notStarted, .unknown, .testHostUnlocked: kind = .notStarted
        }
    }

    /// Back to an entitlement, applying the offline rule at `now` (never earlier than the verification).
    func entitlement(now: Date) -> Entitlement {
        let at = max(now, verifiedAt)
        let p = plan.flatMap(SubscriptionPlan.init(rawValue:))
        let e: Entitlement
        switch kind {
        case .introductoryTrial:
            guard let until, let p else { return .unknown }
            e = .introductoryTrial(endsAt: until, plan: p, willRenew: willRenew ?? true)
        case .subscribed:
            guard let until, let p else { return .unknown }
            e = .subscribed(expiresAt: until, plan: p, willRenew: willRenew ?? true)
        case .grace:
            guard let until, let p else { return .unknown }
            e = .grace(until: until, plan: p)
        case .billingRetry: e = .billingRetry(plan: p ?? .monthly)
        case .lapsed: e = .lapsed(reason: reason.flatMap(Entitlement.LapseReason.init(rawValue:)) ?? .expired)
        case .notStarted: e = .notStarted
        }
        return e.asCached(now: at)
    }

    /// v2: an HMAC-sealed envelope (the v1 plain JSON is no longer read).
    static let key = "kalsmritikosh.purchase.verifiedEntitlement.v2"

    private struct Envelope: Codable { let payload: Data; let mac: Data }

    static func load(from defaults: UserDefaults = AppDefaults.store, secret: Data? = PurchaseCacheSecret.key()) -> CachedEntitlement? {
        guard let secret, let data = defaults.data(forKey: key),
              let env = try? JSONDecoder().decode(Envelope.self, from: data) else { return nil }
        let expected = Data(HMAC<SHA256>.authenticationCode(for: env.payload, using: SymmetricKey(data: secret)))
        guard expected == env.mac else {
            KalsmritikoshLog.app.error("Purchase cache failed its integrity check; ignored")
            return nil
        }
        return try? JSONDecoder().decode(CachedEntitlement.self, from: env.payload)
    }

    func save(to defaults: UserDefaults = AppDefaults.store, secret: Data? = PurchaseCacheSecret.key()) {
        guard let secret, let payload = try? JSONEncoder().encode(self) else { return }
        let mac = Data(HMAC<SHA256>.authenticationCode(for: payload, using: SymmetricKey(data: secret)))
        if let data = try? JSONEncoder().encode(Envelope(payload: payload, mac: mac)) { defaults.set(data, forKey: Self.key) }
    }
}

/// The key that seals the purchase cache: a per-installation random secret in the Keychain. The unit-test
/// host uses a per-process key in memory, never the person's Keychain.
nonisolated enum PurchaseCacheSecret {
    private static let service = "ecosanskritiinnovation.Kalsmritikosh.purchaseCache"
    private static let account = "hmac-v1"
    private static let testKey = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }

    static func key() -> Data? {
        if TestHost.isActive { return testKey }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: AnyObject?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data { return data }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        let secret = Data(bytes)
        let add: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                  kSecAttrAccount as String: account, kSecValueData as String: secret,
                                  kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        SecItemDelete(add as CFDictionary)
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess ? secret : nil
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
        var renew = "Renews automatically at \(displayPrice) per \(plan.periodNoun) unless cancelled at least a day before the period ends. Manage or cancel through your Apple Account."
        if plan.includesAI { renew += " " + Self.aiTerms(plan.tier) }
        if eligibleForTrial, let d = trialDays {
            return "\(d) days free, then \(displayPrice) per \(plan.periodNoun). \(renew)"
        }
        return "\(displayPrice) per \(plan.periodNoun), charged now. \(renew)"
    }

    /// What an AI plan is and is not, shown with every AI plan price.
    static func aiTerms(_ tier: PlanTier) -> String {
        let l = tier.limits ?? AIPricing.aiIncluded
        return "Includes \(l.monthlyCredits.formatted()) AI credits a month (1 credit = US$0.01 of AI cost at Anthropic's published prices; yearly plans get the same allowance every month, renewing on the day of purchase). Credits pay for questions answered by Claude Opus 5 (Anthropic; if Anthropic declines a request, another Claude model may answer it) and for transcription of recordings by Google Gemini, through the publisher's service; each request is charged what it actually cost, and the app shows the estimate before a large read. One request may use up to \(l.perRequestCredits) credits, a confirmed whole-case read up to \(l.caseReadCredits.formatted()), and up to \(l.dailyCredits.formatted()) a day. Unused monthly credits do not carry over; credit packs (500 or 2,000) never expire and are spent after the month's credits, while an AI plan is active. The service has a monthly capacity: if it is reached it pauses until the 1st (UTC), nothing is charged, and everything else keeps working. Questions, passages and recordings go to Anthropic's and Google's commercial APIs; the publisher keeps only counts and credits."
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

/// A2 — the AI Included subscription number, readable from any layer (the Online provider sends it to
/// the relay as its "key"). Published by PurchaseCenter only from verified transactions; nil whenever
/// the current state does not include AI.
nonisolated enum AIIncludedAccess {
    private static let state = OSAllocatedUnfairLock<String?>(initialState: nil)
    static func publish(_ id: String?) { state.withLock { $0 = id } }
    static var subscriptionID: String? { state.withLock { $0 } }
}

/// The paid-use boundary any layer can ask, on or off the main actor (N2/N4, mandate 2026-11-01).
/// PurchaseCenter publishes its state here; services and repositories that create, edit or analyse call
/// `require` at the operation itself, so no screen, menu, intent or importer can skip the decision.
/// Time is applied at the moment of the check: an entitlement whose verified end has passed refuses
/// even if the app has stayed open (and offline) since.
nonisolated enum PaidUse {
    struct Refused: LocalizedError, Equatable {
        let what: String
        let reason: String
        var errorDescription: String? { reason }
    }

    private struct Snapshot: Sendable { var entitlement: Entitlement }
    private static let snapshot = OSAllocatedUnfairLock(initialState: Snapshot(entitlement: TestHost.isActive ? .testHostUnlocked : .unknown))
    /// The clock the boundary reads; tests inject one (never the Mac's clock settings).
    nonisolated(unsafe) static var clock: @Sendable () -> Date = { Date() }

    static func publish(_ e: Entitlement) { snapshot.withLock { $0.entitlement = e } }
    static var current: Entitlement {
        #if DEBUG
        if let e = TestOverride.entitlement { return e }
        #endif
        return snapshot.withLock { $0.entitlement }
    }

    #if DEBUG
    /// Per-task overrides for tests (Debug builds only): a test sets them for its own task, so suites
    /// running in parallel never see each other's state, and nothing global is changed.
    enum TestOverride {
        @TaskLocal static var entitlement: Entitlement?
        @TaskLocal static var sample: Bool?
        @TaskLocal static var now: Date?
    }
    #endif

    private static var sampleNow: Bool {
        #if DEBUG
        if let s = TestOverride.sample { return s }
        #endif
        return SampleArchiveMode.isActive
    }
    private static var clockNow: Date {
        #if DEBUG
        if let d = TestOverride.now { return d }
        #endif
        return clock()
    }

    /// nil when `what` may run now; otherwise the reason it may not.
    /// `importing`: bringing documents in. The sample case is a preview of the bundled documents only —
    /// it never takes the person's own files, whatever the subscription.
    static func refusal(_ what: String, importing: Bool = false, sample: Bool? = nil,
                        entitlement: Entitlement? = nil, now: Date? = nil) -> Refused? {
        let sample = sample ?? sampleNow
        if sample {
            if importing {
                return Refused(what: what, reason: "The sample case holds only its bundled documents. Choose “Back to my archive” to add your own.")
            }
            return nil   // working on the bundled sample is the free preview
        }
        let e = (entitlement ?? current).asCached(now: now ?? clockNow)
        if e.allowsPaidUse { return nil }
        return Refused(what: what, reason: "A subscription is needed to \(what). Your work stays readable and exportable; backups, recovery and Help stay open.")
    }

    /// Throws when `what` may not run now, and asks the window to show the subscription sheet.
    static func require(_ what: String, importing: Bool = false) throws {
        guard let refused = refusal(what, importing: importing) else { return }
        #if DEBUG
        if TestOverride.entitlement != nil { throw refused }   // a test's own state: no window to notify
        #endif
        Task { @MainActor in PurchaseCenter.shared.noteRefusal(refused) }
        throw refused
    }
}

@MainActor
@Observable
final class PurchaseCenter {
    static let shared = PurchaseCenter(publishes: true)

    private(set) var entitlement: Entitlement = .unknown {
        didSet { if publishes { PaidUse.publish(entitlement) } }
    }
    /// The clock every decision reads; tests inject one (N2 — never the Mac's clock settings).
    var clock: () -> Date = { PaidUse.clock() }
    private(set) var offers: [PlanOffer] = []
    /// The yearly saving (per cent) per level when both storefront prices are known; shown second.
    private(set) var annualSavings: [PlanTier: Int] = [:]
    var annualSavingPercent: Int? { annualSavings[.workbench] }
    var aiAnnualSavingPercent: Int? { annualSavings[.aiIncluded] }
    /// The credit packs as the storefront sells them (product id → display price; empty until loaded).
    private(set) var packPrices: [String: String] = [:]
    /// The AI subscription number from verified transactions (nil when the state has no AI).
    private(set) var aiSubscriptionID: String? {
        didSet { if publishes { AIIncludedAccess.publish(aiSubscriptionID) } }
    }
    /// Whether the relay is selling AI plans this month (tests inject an answer; never the network there).
    var aiSellable: @Sendable () async throws -> Bool = { try await AIIncludedRelay.sellable() }
    /// True while the products could not be loaded: the paywall shows retry, never a made-up price.
    private(set) var productsUnavailable = false
    private(set) var busy = false
    var message: String?
    /// Set by a paid action that was refused: the paywall opens over the current screen.
    var paywallRequested: String?
    /// §6.11 — the person chose Help, Backup & recovery or "Look around first" on the leading subscription
    /// screen: for this launch the window is usable read-only (strip + sheet on paid actions) instead of
    /// blurred, so help, recovery, the sample and reading are really reachable before any purchase.
    var gateDismissedThisLaunch = false

    /// The unit-test host never talks to the App Store and is always unlocked — except a centre a
    /// test makes with `talksToStore: true` inside an `SKTestSession` (`PurchaseStoreKitTests`).
    /// In Release this is always false (`TestHost`): a shipped build never takes the store-less path.
    static let isTestHost = TestHost.isActive
    private let talksToStore: Bool
    private var updates: Task<Void, Never>?
    private var watchers: [Task<Void, Never>] = []
    private var deadline: Task<Void, Never>?
    private var products: [String: Product] = [:]

    /// Only the app's own centre feeds the `PaidUse` boundary; a centre a test makes stays private to it.
    private let publishes: Bool

    init(talksToStore: Bool = false, publishes: Bool = false) {
        self.talksToStore = talksToStore || !Self.isTestHost
        self.publishes = publishes
    }

    /// Set the state and arm the moment it ends on its own (N2): a trial, paid period or grace that runs
    /// out while the app stays open — even offline — is applied then, not at the next launch.
    func apply(_ e: Entitlement) {
        if entitlement != e { entitlement = e }
        deadline?.cancel()
        guard let until = e.verifiedUntil else { deadline = nil; return }
        let wait = max(0, until.timeIntervalSince(clock())) + 1
        deadline = Task { [weak self] in
            // Continuous time: a Mac asleep past the deadline wakes to the change (and wake re-checks too).
            try? await Task.sleep(for: .seconds(min(wait, 86_400)))
            guard !Task.isCancelled, let self else { return }
            self.reevaluate()
            if self.talksToStore { await self.refresh() } else { self.apply(self.entitlement) }
        }
    }

    /// Apply the clock to the current verified state (expiry, end of trial, end of grace).
    func reevaluate() {
        let now = entitlement.asCached(now: clock())
        if now != entitlement { apply(now) }
    }

    /// A refused paid action: the subscription sheet opens over the current screen, or — for an import in
    /// the sample — the reason is shown instead.
    func noteRefusal(_ r: PaidUse.Refused) {
        if SampleArchiveMode.isActive { message = r.reason } else { paywallRequested = r.what }
    }

    func start() {
        if !talksToStore { apply(.testHostUnlocked); return }
        guard updates == nil else { return }
        AICreditMeter.installHooks()
        AIRegion.start()
        // The last verified state carries the person through an offline launch, under its own rule.
        if let cached = CachedEntitlement.load() { apply(cached.entitlement(now: clock())) }
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                // A credit pack is finished only once the relay has credited it (after the refresh that
                // confirms the AI subscription it belongs to) — or, refunded, once the relay removed it.
                if case .verified(let t) = result {
                    if PurchaseProducts.credits(inPack: t.productID) != nil { await self?.refresh(); await self?.creditTopUp(t); continue }
                    await t.finish()
                }
                await self?.refresh()
            }
        }
        // Waking from sleep and coming back to the app re-apply the clock and ask the store again.
        let wake = NSWorkspace.shared.notificationCenter.notifications(named: NSWorkspace.didWakeNotification)
        let active = NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification)
        watchers = [
            Task { [weak self] in for await _ in wake { self?.reevaluate(); await self?.refresh() } },
            Task { [weak self] in for await _ in active { self?.reevaluate(); await self?.refresh() } },
        ]
        Task { await loadProducts(); await refresh(); await creditPendingTopUps() }
    }

    func loadProducts() async {
        do {
            let loaded = try await Product.products(for: PurchaseProducts.storeProducts)
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
            // Workbench's two plans must be there; the AI plans are offered only when their products are.
            productsUnavailable = out.filter { !$0.plan.includesAI }.count < 2
            var savings: [PlanTier: Int] = [:]
            for plan in SubscriptionPlan.allCases where !plan.isAnnual {
                if let m = products[plan.productID], let a = products[plan.counterpart.productID],
                   let pct = PlanOffer.annualSaving(monthly: m.price, annual: a.price) { savings[plan.tier] = pct }
            }
            annualSavings = savings
            packPrices = Dictionary(uniqueKeysWithValues: PurchaseProducts.creditPacks.compactMap { id in products[id].map { (id, $0.displayPrice) } })
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
        if !talksToStore { apply(.testHostUnlocked); return }
        var records: [Entitlement.Record] = []
        var seen: [UInt64: Int] = [:]
        func record(_ t: Transaction) {
            let r = Entitlement.Record(productID: t.productID, purchaseDate: t.purchaseDate, originalPurchaseDate: t.originalPurchaseDate,
                                       expirationDate: t.expirationDate, revoked: t.revocationDate != nil,
                                       isIntroductoryOffer: t.offer?.type == .introductory, originalID: t.originalID,
                                       upgraded: t.isUpgraded)
            if let i = seen[t.id] {
                // The same transaction read twice: a revocation seen on either read stands.
                if r.revoked { records[i] = r }
            } else {
                seen[t.id] = records.count
                records.append(r)
            }
        }
        for await result in Transaction.currentEntitlements {
            guard case .verified(let t) = result else { continue }   // an unverified transaction counts for nothing
            record(t)
        }
        // `currentEntitlements` drops what has expired or been refunded. The latest transaction of
        // each product is read too, so an expired or refunded subscriber is told "your work stays
        // readable, subscribe to edit again" (read-only window) and not treated as someone who
        // never started (whole-window screen). Unverified ones still count for nothing.
        for id in PurchaseProducts.all {
            if case .verified(let t)? = await Transaction.latest(for: id) { record(t) }
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
        let now = clock()
        let fresh = Entitlement.evaluate(records: records, renewal: renewal, storeAnswered: !products.isEmpty, now: now)
        if fresh == .unknown {
            // The store did not answer: keep the cached verified state under its own rule.
            apply(CachedEntitlement.load()?.entitlement(now: now) ?? .unknown)
            aiSubscriptionID = nil   // the relay re-checks with Apple anyway; offline nothing could reach it
            AICreditMeter.shared.planChanged(nil)
            return
        }
        apply(fresh)
        aiSubscriptionID = Entitlement.aiSubscriptionID(records: records, entitlement: fresh)
        AICreditMeter.shared.planChanged(fresh.aiTier)
        CachedEntitlement(fresh, at: now).save()
    }

    /// Subscribe to a plan (StoreKit applies the introductory offer only to the eligible).
    func subscribe(_ plan: SubscriptionPlan) async {
        // An AI plan is not sold to someone new once the month's service capacity is nearly used (the
        // relay says so; nothing about the person is sent). A current AI subscriber changing plan is not new.
        if plan.includesAI, let why = AIRegion.current.explanation {
            message = why
            return
        }
        if plan.includesAI, !entitlement.includesAI, talksToStore {
            let open: Bool
            do { open = try await aiSellable() } catch {
                KalsmritikoshLog.app.error("AI Included availability check failed: \(error.localizedDescription, privacy: .public)")
                message = "The AI service could not be reached to confirm it is open to new subscribers. Nothing was charged; try again in a minute, or choose Workbench."
                return
            }
            guard open else {
                message = "The AI plans have reached this month's capacity and are not taking new subscribers until the 1st. Nothing was charged. Workbench is available, and its Online AI can use your own Anthropic key."
                return
            }
        }
        await buy(products[plan.productID], what: "the \(plan.label.lowercased()) plan")
    }

    /// Buy a credit pack (500 or 2,000 credits; never expire). It is bought FOR the current AI
    /// subscription (`appAccountToken`, which the relay checks), and finished only once the relay has
    /// credited it; one that could not be credited stays unfinished and is credited at the next launch.
    func buyCredits(_ productID: String) async {
        guard PurchaseProducts.credits(inPack: productID) != nil else { return }
        guard entitlement.includesAI, let sub = aiSubscriptionID else {
            message = "Credit packs are for AI Included and AI Pro subscribers. Choose an AI plan first."
            return
        }
        guard let product = products[productID] else {
            message = "The App Store is not reachable right now, so the credit pack cannot be confirmed. Try again in a moment."
            return
        }
        busy = true
        defer { busy = false }
        do {
            switch try await product.purchase(options: [.appAccountToken(AIIncludedRelay.accountToken(subscription: sub))]) {
            case .success(let verification):
                guard case .verified(let t) = verification else {
                    message = Self.message(for: .unverified, what: "the credit pack")
                    return
                }
                await creditTopUp(t)
            case .userCancelled: break
            case .pending: message = Self.message(for: .pending, what: "the credit pack")
            @unknown default: break
            }
        } catch {
            KalsmritikoshLog.app.error("Credit pack purchase failed: \(error.localizedDescription, privacy: .public)")
            message = error.localizedDescription
        }
    }

    /// Credit a verified pack with the relay, then finish it. Never finished uncredited. A refunded pack is
    /// reported to the relay (which re-checks with Apple and removes its remaining credits), then finished.
    func creditTopUp(_ t: Transaction) async {
        guard let credits = PurchaseProducts.credits(inPack: t.productID) else { return }
        guard let sub = aiSubscriptionID else {
            if t.revocationDate != nil { await t.finish(); return }
            message = "The credit pack was bought; it will be added once an AI plan is confirmed for this account."
            return
        }
        do {
            switch try await AIIncludedRelay.creditTopUp(subscription: sub, transactionID: String(t.id)) {
            case .onAccount:
                await t.finish()
                message = "\(credits.formatted()) credits added. Credit packs never expire."
            case .revoked:
                await t.finish()
                message = "A refunded credit pack was removed from your balance."
            }
            await refreshAIStatus()
        } catch {
            KalsmritikoshLog.app.error("Credit pack credit failed: \(error.localizedDescription, privacy: .public)")
            message = "The credit pack was bought but the AI service could not add it yet (\(error.localizedDescription)). It is kept and added automatically next time the app opens."
        }
    }

    /// Credit any bought-but-uncredited packs (an earlier credit failed, or the app quit).
    func creditPendingTopUps() async {
        guard talksToStore, aiSubscriptionID != nil else { return }
        for await result in Transaction.unfinished {
            if case .verified(let t) = result, PurchaseProducts.credits(inPack: t.productID) != nil { await creditTopUp(t) }
        }
    }

    /// Ask the relay for the plan's credits (one request carrying only the subscription number).
    func refreshAIStatus() async {
        guard let sub = aiSubscriptionID else { AICreditMeter.shared.planChanged(entitlement.aiTier); return }
        do { AICreditMeter.shared.apply(try await AIIncludedRelay.status(subscription: sub)) } catch {
            KalsmritikoshLog.app.error("AI credit status failed: \(error.localizedDescription, privacy: .public)")
            message = error.localizedDescription
        }
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
    /// The decision is `PaidUse.refusal` at this moment (N2): the clock is applied first, so an expired
    /// period refuses even if no refresh ran since. §6.3/§6.11 — the isolated sample case is the free
    /// preview of the bundled documents; it never takes the person's own files (`importing`, N4).
    @discardableResult
    func allowPaidAction(_ what: String, importing: Bool = false) -> Bool {
        reevaluate()
        guard let refused = PaidUse.refusal(what, importing: importing, entitlement: entitlement, now: clock()) else { return true }
        noteRefusal(refused)
        if talksToStore, !SampleArchiveMode.isActive { Task { await refresh() } }   // a renewal may already be on record
        return false
    }

    /// One sentence on the current state, for the status strip and Settings.
    var statusText: String {
        let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .none
        switch entitlement {
        case .testHostUnlocked: return "Test host (no store)."
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
            case .billingFailed: return "Renewal failed. Your work stays readable and exportable; update the payment method to continue."
            }
        case .notStarted: return "Not subscribed."
        case .unknown: return "The App Store has not confirmed a plan for this account yet (offline, or the store did not answer). Reading, export, backup, recovery and Help work; subscribing or editing waits for the store. Try again or Restore purchases."
        }
    }
}
