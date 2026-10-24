//
//  Purchase.swift
//  Kalsmritikosh
//
//  How the app is sold (owner decision 2026-10-18): a free download with a 14-day trial, then
//  one $79 purchase that unlocks everything for good — no subscription, no yearly fee, every
//  Mac on the buyer's Apple account, Family Sharing on.
//
//  Both are App Store in-app purchases, the pattern Apple allows for trials of paid apps
//  (App Review Guideline 3.1.1): a free non-consumable "14-day trial" whose purchase date
//  starts the clock, and the non-consumable unlock. StoreKit (the system's App Store service)
//  signs and keeps the transactions, so a reinstall cannot restart the trial, and it answers
//  from its own cache when the Mac is offline. The app itself opens no connection: purchases,
//  restores and the receipt are handled by Apple.
//
//  When the trial has ended and nothing is bought, the main window shows the purchase screen.
//  Nothing is deleted or locked away: Settings ▸ Your data still backs up and exports the
//  whole archive, so a person's data is never held hostage.
//

import Foundation
import StoreKit
import os

nonisolated enum PurchaseProducts {
    static let unlock = "ecosanskritiinnovation.Kalsmritikosh.unlock"
    static let trial = "ecosanskritiinnovation.Kalsmritikosh.trial14"
    static let trialDays = 14
    static var all: [String] { [unlock, trial] }
}

/// Where this Mac stands. Pure, so the rules are tested without StoreKit.
nonisolated enum Entitlement: Equatable, Sendable {
    /// Bought (or shared through Family Sharing).
    case unlocked
    /// In the free trial, until this moment.
    case trial(endsAt: Date)
    /// The trial was used and has ended; nothing bought.
    case trialEnded
    /// Neither the trial nor the purchase exists yet (a first launch).
    case notStarted
    /// The App Store has not answered yet (or this build has no store at all). Treated as
    /// allowed: a person is never locked out because Apple's service was slow to reply.
    case unknown

    /// The full app may be used.
    var allowsUse: Bool {
        switch self {
        case .unlocked, .trial, .unknown: return true
        case .trialEnded, .notStarted: return false
        }
    }

    static func evaluate(unlockedAt: Date?, revokedUnlock: Bool, trialStartedAt: Date?, now: Date,
                         trialDays: Int = PurchaseProducts.trialDays) -> Entitlement {
        if unlockedAt != nil, !revokedUnlock { return .unlocked }
        guard let start = trialStartedAt else { return .notStarted }
        let ends = start.addingTimeInterval(TimeInterval(trialDays) * 86_400)
        return now < ends ? .trial(endsAt: ends) : .trialEnded
    }

    /// One verified StoreKit transaction, as the rules need it.
    struct Record: Equatable, Sendable {
        let productID: String
        let purchaseDate: Date
        let originalPurchaseDate: Date
        let revoked: Bool
    }

    /// The entitlement from this account's verified current transactions. `storeAnswered` is
    /// false when neither a transaction nor a product came back (offline first launch, or a build
    /// with no store): then nothing is known and the app stays usable.
    static func evaluate(records: [Record], storeAnswered: Bool, now: Date) -> Entitlement {
        if records.isEmpty && !storeAnswered { return .unknown }
        // Any standing unlock counts; a refunded one does not hide another that stands.
        let unlocks = records.filter { $0.productID == PurchaseProducts.unlock }
        let standing = unlocks.first { !$0.revoked }
        let trialStart = records.filter { $0.productID == PurchaseProducts.trial }.map(\.originalPurchaseDate).min()
        return evaluate(unlockedAt: (standing ?? unlocks.first)?.purchaseDate, revokedUnlock: standing == nil && !unlocks.isEmpty,
                        trialStartedAt: trialStart, now: now)
    }

    /// Whole days left in the trial (at least 1 while any time is left).
    func daysLeft(now: Date = Date()) -> Int? {
        guard case .trial(let ends) = self else { return nil }
        return max(1, Int((ends.timeIntervalSince(now) / 86_400).rounded(.up)))
    }
}

@MainActor
@Observable
final class PurchaseCenter {
    static let shared = PurchaseCenter()

    private(set) var entitlement: Entitlement = .unknown
    private(set) var unlockProduct: Product?
    private(set) var trialProduct: Product?
    private(set) var busy = false
    var message: String?

    /// The unit-test host never talks to the App Store and is always unlocked.
    static let isTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    private var updates: Task<Void, Never>?

    var priceText: String { unlockProduct?.displayPrice ?? "$79" }

    func start() {
        if Self.isTestHost { entitlement = .unlocked; return }
        guard updates == nil else { return }
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
            let products = try await Product.products(for: PurchaseProducts.all)
            unlockProduct = products.first { $0.id == PurchaseProducts.unlock }
            trialProduct = products.first { $0.id == PurchaseProducts.trial }
        } catch {
            KalsmritikoshLog.app.error("App Store products unavailable: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Read the signed transactions StoreKit holds for this Apple account.
    func refresh() async {
        if Self.isTestHost { entitlement = .unlocked; return }
        var records: [Entitlement.Record] = []
        for await result in Transaction.currentEntitlements {
            guard case .verified(let t) = result else { continue }   // an unverified transaction counts for nothing
            records.append(.init(productID: t.productID, purchaseDate: t.purchaseDate,
                                 originalPurchaseDate: t.originalPurchaseDate, revoked: t.revocationDate != nil))
        }
        entitlement = Entitlement.evaluate(records: records, storeAnswered: unlockProduct != nil || trialProduct != nil,
                                           now: Date())
    }

    func startTrial() async { await buy(trialProduct, what: "the free trial") }
    func buyUnlock() async { await buy(unlockProduct, what: "Investigations Made Easy") }

    private func buy(_ product: Product?, what: String) async {
        guard let product else {
            message = "The App Store is not reachable right now. Try again in a moment."
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
        case .unverified: return "The App Store could not confirm \(what). Nothing was charged twice; try Restore."
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
        if entitlement != .unlocked, message == nil { message = "No purchase was found for this Apple account." }
    }
}
