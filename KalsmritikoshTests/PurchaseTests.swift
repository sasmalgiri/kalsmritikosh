//
//  PurchaseTests.swift
//  KalsmritikoshTests
//
//  The trial-and-unlock rules (Purchase.swift), without the App Store.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Free trial and one purchase")
struct PurchaseTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("Bought means unlocked for good; a refunded purchase does not count")
    func unlock() {
        #expect(Entitlement.evaluate(unlockedAt: start, revokedUnlock: false, trialStartedAt: nil, now: start) == .unlocked)
        #expect(Entitlement.evaluate(unlockedAt: start, revokedUnlock: false, trialStartedAt: start,
                                     now: start.addingTimeInterval(400 * 86_400)) == .unlocked)
        #expect(Entitlement.evaluate(unlockedAt: start, revokedUnlock: true, trialStartedAt: nil, now: start) == .notStarted)
    }

    @Test("The trial runs 14 days from when it was started, then ends")
    func trial() {
        let day13 = Entitlement.evaluate(unlockedAt: nil, revokedUnlock: false, trialStartedAt: start,
                                         now: start.addingTimeInterval(13 * 86_400 + 3600))
        #expect(day13 == .trial(endsAt: start.addingTimeInterval(14 * 86_400)))
        #expect(day13.daysLeft(now: start.addingTimeInterval(13 * 86_400 + 3600)) == 1)
        #expect(Entitlement.evaluate(unlockedAt: nil, revokedUnlock: false, trialStartedAt: start, now: start).daysLeft(now: start) == 14)
        #expect(Entitlement.evaluate(unlockedAt: nil, revokedUnlock: false, trialStartedAt: start,
                                     now: start.addingTimeInterval(14 * 86_400)) == .trialEnded)
        #expect(Entitlement.evaluate(unlockedAt: nil, revokedUnlock: false, trialStartedAt: nil, now: start) == .notStarted)
    }

    @Test("Who may use the app: bought, in trial, or the store has not answered — never locked out by a slow reply")
    func allowsUse() {
        #expect(Entitlement.unlocked.allowsUse)
        #expect(Entitlement.trial(endsAt: start).allowsUse)
        #expect(Entitlement.unknown.allowsUse)
        #expect(!Entitlement.trialEnded.allowsUse)
        #expect(!Entitlement.notStarted.allowsUse)
    }

    @Test("The test host is always unlocked and never asks the App Store")
    @MainActor func testHost() {
        #expect(PurchaseCenter.isTestHost)
        PurchaseCenter.shared.start()
        #expect(PurchaseCenter.shared.entitlement == .unlocked)
    }

    // MARK: - R-1 purchase flow: StoreKit transactions → entitlement → what the person is told

    private func record(_ id: String, at date: Date, revoked: Bool = false) -> Entitlement.Record {
        .init(productID: id, purchaseDate: date, originalPurchaseDate: date, revoked: revoked)
    }

    @Test("First launch: no transactions — locked behind the purchase screen only once the store has answered")
    func firstLaunch() {
        #expect(Entitlement.evaluate(records: [], storeAnswered: false, now: start) == .unknown)
        #expect(Entitlement.evaluate(records: [], storeAnswered: true, now: start) == .notStarted)
    }

    @Test("Starting the trial, then buying: trial runs, then the unlock wins for good")
    func trialThenBuy() {
        let trial = record(PurchaseProducts.trial, at: start)
        #expect(Entitlement.evaluate(records: [trial], storeAnswered: true, now: start.addingTimeInterval(86_400))
                == .trial(endsAt: start.addingTimeInterval(14 * 86_400)))
        #expect(Entitlement.evaluate(records: [trial], storeAnswered: true, now: start.addingTimeInterval(15 * 86_400)) == .trialEnded)
        let bought = record(PurchaseProducts.unlock, at: start.addingTimeInterval(20 * 86_400))
        #expect(Entitlement.evaluate(records: [trial, bought], storeAnswered: true, now: start.addingTimeInterval(400 * 86_400)) == .unlocked)
    }

    @Test("A refund ends the unlock; the trial clock does not restart")
    func refund() {
        let trial = record(PurchaseProducts.trial, at: start)
        let refunded = record(PurchaseProducts.unlock, at: start.addingTimeInterval(86_400), revoked: true)
        #expect(Entitlement.evaluate(records: [trial, refunded], storeAnswered: true, now: start.addingTimeInterval(30 * 86_400)) == .trialEnded)
        #expect(Entitlement.evaluate(records: [refunded], storeAnswered: true, now: start) == .notStarted)
        // A second purchase that stands is not hidden by the refunded one.
        let again = record(PurchaseProducts.unlock, at: start.addingTimeInterval(40 * 86_400))
        #expect(Entitlement.evaluate(records: [refunded, again], storeAnswered: true, now: start.addingTimeInterval(41 * 86_400)) == .unlocked)
    }

    @Test("Transactions for other products count for nothing")
    func otherProducts() {
        let stray = record("com.example.other", at: start)
        #expect(Entitlement.evaluate(records: [stray], storeAnswered: true, now: start) == .notStarted)
    }

    @Test("What the person is told after a purchase attempt")
    @MainActor func outcomeMessages() {
        #expect(PurchaseCenter.message(for: .verified, what: "x") == nil)
        #expect(PurchaseCenter.message(for: .cancelled, what: "x") == nil)
        #expect(PurchaseCenter.message(for: .unverified, what: "the free trial")?.contains("could not confirm the free trial") == true)
        #expect(PurchaseCenter.message(for: .pending, what: "x")?.contains("Ask to Buy") == true)
    }

    @Test("The StoreKit configuration sells exactly the products the app asks for, as decided")
    func storeKitConfiguration() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("StoreKit/Kalsmritikosh.storekit")
        let data = try Data(contentsOf: url)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let products = try #require(json["products"] as? [[String: Any]])
        #expect(Set(products.compactMap { $0["productID"] as? String }) == Set(PurchaseProducts.all))
        for p in products {
            #expect(p["type"] as? String == "NonConsumable")
            #expect(p["familyShareable"] as? Bool == true)
            let price = p["displayPrice"] as? String
            #expect(price == (p["productID"] as? String == PurchaseProducts.unlock ? "79.0" : "0.0"))
        }
        #expect((json["subscriptionGroups"] as? [Any])?.isEmpty == true)   // no subscription
    }
}
