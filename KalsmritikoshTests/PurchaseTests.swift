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
}
