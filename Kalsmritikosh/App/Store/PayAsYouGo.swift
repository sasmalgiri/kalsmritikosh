//
//  PayAsYouGo.swift
//  Kalsmritikosh
//
//  Pay as you go (owner decision 2026-11-15): the AI credit packs ($9.99 / 500, $34.99 / 2,000 — the same
//  consumables and prices) can be bought WITHOUT any subscription. The offer is three choices: Workbench with the
//  person's own Anthropic key; pay as you go (packs, no subscription); AI Included / AI Pro (unchanged).
//
//  How a pack-only customer's credits are kept (relay/src/index.ts `payAsYouGo`):
//   • The app makes ONE random UUID, the AI account token, keeps it in this Mac's Keychain and sets it as
//     `Product.PurchaseOption.appAccountToken` on every pack it buys while no AI plan stands. Apple signs it into
//     the transaction. An AI subscriber's packs keep the subscription's derived token
//     (`AIIncludedRelay.accountToken(subscription:)`), exactly as before, and are credited to the plan.
//   • The relay credits a pack once per transactionId to the account `token:<uuid>` (it re-checks with Apple), and
//     spends from that account only when the request carries a verified, unrefunded pack's signed transaction whose
//     token is that account. Refunds remove credits (App Store Server Notifications, or the app's report).
//   • On a new Mac (no token in the Keychain) the token is read back from the packs' `appAccountToken`: the app's
//     Info.plist sets `SKIncludeConsumableInAppPurchaseHistory`, so StoreKit lists finished consumables in
//     `Transaction.all`. The balance is then the relay's again. The app never adds credits itself: the meter only
//     mirrors the relay's receipts, and the relay credits each transaction once.
//
//  Gating: packs unlock AI asks only (Ask and AI assist going through the relay); every other paid function —
//  adding documents, editing, jobs — still follows the subscription (Workbench trial / read-only), `PaidUse`.
//
//  Nothing in this file touches the network.
//

import Foundation
import Security
import os

/// One credit-pack transaction, as the pay-as-you-go rules need it (from verified StoreKit transactions only).
nonisolated struct PackRecord: Equatable, Sendable {
    let transactionID: UInt64
    let productID: String
    let purchaseDate: Date
    let appAccountToken: UUID?
    let revoked: Bool
    /// Finished = the relay has credited it (a pack is finished only after that, or after a refund was reported).
    var finished: Bool = true
    /// StoreKit's signed form (JWS) — the pay-as-you-go credential the relay verifies.
    var signedTransaction: String? = nil
}

nonisolated enum PayAsYouGo {

    /// Packs are offered (with or without a plan) only where AI is sold, on a Mac where Online AI runs, and only
    /// when this build has the publisher's relay.
    static func offered(relayConfigured: Bool = AIIncludedRelay.isConfigured,
                        sellsAI: Bool = AIRegion.sellsAIProducts && AISetup.onlineAIRunsOnThisMac) -> Bool {
        relayConfigured && sellsAI
    }

    /// The appAccountToken a pack is bought with: while an AI plan stands, the plan's derived token (the pack is the
    /// plan's, as before); otherwise this Mac's pay-as-you-go token (made on first use). nil = no token could be kept.
    static func purchaseToken(aiSubscriptionID: String?, accountToken: () -> UUID?) -> UUID? {
        if let sub = aiSubscriptionID, AIIncludedRelay.isValidSubscription(sub) { return AIIncludedRelay.accountToken(subscription: sub) }
        return accountToken()
    }

    /// Where a bought pack goes.
    enum Route: Equatable, Sendable {
        /// Bought with the current AI plan's token: credited to the plan (the plan's signed transaction is the credential).
        case subscription
        /// Bought with this Mac's pay-as-you-go token: credited to that account (the pack's own signed transaction).
        case payAsYouGo
        /// Refunded and no account here to report it to: finished (the relay removes it through Apple's notification).
        case finishRefunded
        /// Bought for an AI plan that is not confirmed now: kept unfinished, credited once the plan is confirmed.
        case waitForPlan
    }

    static func route(packToken: UUID?, revoked: Bool, aiSubscriptionID: String?, hasSubscriptionCredential: Bool, accountToken: UUID?) -> Route {
        if let sub = aiSubscriptionID, hasSubscriptionCredential, let t = packToken, t == AIIncludedRelay.accountToken(subscription: sub) { return .subscription }
        if let mine = accountToken, let t = packToken, t == mine { return .payAsYouGo }
        if revoked { return .finishRefunded }
        return .waitForPlan
    }

    /// A new Mac: the pay-as-you-go token Apple signed into the newest pack that was NOT bought with one of this
    /// account's AI subscriptions (their packs carry the subscription's derived token). nil = none to recover.
    static func recoverToken(packs: [PackRecord], subscriptionIDs: [String]) -> UUID? {
        let derived = Set(subscriptionIDs.filter(AIIncludedRelay.isValidSubscription).map { AIIncludedRelay.accountToken(subscription: $0) })
        return packs.filter { $0.appAccountToken != nil && !derived.contains($0.appAccountToken!) }
            .max { $0.purchaseDate < $1.purchaseDate }?.appAccountToken
    }

    /// The pack whose signed transaction is the pay-as-you-go credential: the newest unrefunded pack bought with
    /// `token`, preferring one already credited (finished) — the relay spends only for a pack on its record.
    static func credential(packs: [PackRecord], token: UUID?) -> PackRecord? {
        guard let token else { return nil }
        let mine = packs.filter { $0.appAccountToken == token && !$0.revoked && $0.signedTransaction != nil }
        let newest: ([PackRecord]) -> PackRecord? = { $0.max { $0.purchaseDate < $1.purchaseDate } }
        return newest(mine.filter(\.finished)) ?? newest(mine)
    }

    /// What Restore says about pay as you go when no AI plan stands (nil = nothing to add).
    static func restoreNote(packs: [PackRecord], recovered: Bool, keychainFailed: Bool) -> String? {
        if recovered { return "Restored: your pay-as-you-go credits. The balance is shown once the AI service has answered (Settings ▸ Online ▸ Check credits)." }
        if keychainFailed { return "Pay-as-you-go credit packs were found, but this Mac's Keychain could not keep their account. Nothing is lost; try Restore purchases again." }
        if !packs.isEmpty { return "Credit packs were found for this Apple account, but they were bought with an AI plan, so they stay with that plan. There is no pay-as-you-go balance to restore." }
        return nil
    }

    /// AI asks (Ask, AI assist) may run on pack credits alone: a pay-as-you-go credential is known, the relay is in
    /// this build, and Online AI is on with AI credits as the provider. Everything else still follows the subscription.
    static func unlocksAIAsks(hasCredential: Bool, relayConfigured: Bool, providerIsCredits: Bool, cloudAllowed: Bool) -> Bool {
        hasCredential && relayConfigured && providerIsCredits && cloudAllowed
    }

    /// The live decision (any actor): the published credential and the Mac's Online settings.
    static var liveUnlocksAIAsks: Bool {
        unlocksAIAsks(hasCredential: AIIncludedAccess.payAsYouGoSignedTransaction != nil, relayConfigured: AIIncludedRelay.isConfigured,
                      providerIsCredits: OnlineSettings.kind == .included, cloudAllowed: OnlineSettings.cloudAllowed)
    }

    /// The plan picker's description of choice 2 (prices from StoreKit; never a made-up price).
    static func offerText(packPrices: [String: String]) -> String {
        let packs = PurchaseProducts.creditPacks.map { id in
            "\((PurchaseProducts.credits(inPack: id) ?? 0).formatted()) credits" + (packPrices[id].map { " for \($0)" } ?? "")
        }.joined(separator: " or ")
        return "No subscription: buy AI credits when you need them — \(packs), one-time purchases. Pack credits never expire. "
            + "1 credit = US$0.01 of AI cost; a credit pays for questions answered by Claude through the publisher's service. "
            + PlanTier.creditUseNote
            + " Pay as you go covers Online AI only: adding documents, editing and jobs need Workbench (14-day free trial)."
    }
}

/// The pay-as-you-go account token: one random UUID per Mac, in the Keychain (never synced, this device only). It is
/// not a secret on its own — the relay spends only for a pack Apple signed with it — and holds nothing about a case.
/// The unit-test host keeps it in memory (per test task when a test sets `testStore`), never in the person's Keychain.
nonisolated enum AIAccountToken {
    private static let service = "ecosanskritiinnovation.Kalsmritikosh.aiAccountToken"
    private static let account = "token-v1"

    /// The test host's store (TestHost only).
    final class MemoryStore: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock<UUID?>(initialState: nil)
        init(_ t: UUID? = nil) { lock.withLock { $0 = t } }
        var token: UUID? { get { lock.withLock { $0 } } set { lock.withLock { $0 = newValue } } }
    }
    private static let hostStore = MemoryStore()
    /// A test's own store for its task (so parallel suites never share a token).
    @TaskLocal static var testStore: MemoryStore?

    private static var memory: MemoryStore? {
        if let s = testStore { return s }
        return TestHost.isActive ? hostStore : nil
    }

    /// The token kept on this Mac (nil = none yet).
    static func current() -> UUID? {
        if let m = memory { return m.token }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data, let s = String(data: data, encoding: .utf8) { return UUID(uuidString: s) }
        if status != errSecItemNotFound { KalsmritikoshLog.app.error("AI account token unreadable: \(status, privacy: .public)") }
        return nil
    }

    /// The token, made on first use (a pack is about to be bought without an AI plan). nil = the Keychain refused.
    static func getOrCreate() -> UUID? {
        if let t = current() { return t }
        let t = UUID()
        return adopt(t) ? t : nil
    }

    /// Keep `token` (a new one, or one recovered from this Apple account's packs).
    @discardableResult
    static func adopt(_ token: UUID) -> Bool {
        if let m = memory { m.token = token; return true }
        let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account, kSecValueData as String: Data(token.uuidString.utf8),
                                   kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        SecItemDelete(item as CFDictionary)
        let status = SecItemAdd(item as CFDictionary, nil)
        if status != errSecSuccess { KalsmritikoshLog.app.error("AI account token not saved: \(status, privacy: .public)") }
        return status == errSecSuccess
    }

    /// Forget the token on this Mac (tests: a "new Mac"). The credits stay with the relay and come back on Restore.
    static func clear() {
        if let m = memory { m.token = nil; return }
        let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(item as CFDictionary)
    }
}
