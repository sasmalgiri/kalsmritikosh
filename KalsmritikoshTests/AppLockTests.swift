//
//  AppLockTests.swift
//  KalsmritikoshTests
//
//  S-5 — the app lock: it locks only when its module is on, locks on return only after the idle
//  limit, never leaves the person locked out of a Mac that cannot verify them, and stays locked
//  when verification fails or is cancelled.
//

import Testing
import Foundation
@testable import Kalsmritikosh

@MainActor
@Suite(.serialized) struct AppLockTests {

    /// Runs `body` with the app-lock module switched as given, restoring the stored choice.
    private func withAppLock(_ on: Bool, _ body: () async throws -> Void) async rethrows {
        let key = "kalsmritikosh.product.\(ProductModule.appLock.rawValue)"
        let prior = AppDefaults.store.object(forKey: key)
        ProductModuleFlags.setEnabled(.appLock, on)
        defer { AppDefaults.store.set(prior, forKey: key) }
        try await body()
    }

    private struct Cancelled: Error {}

    @Test("Locks only when the app-lock module is on")
    func locksOnlyWhenOn() async {
        await withAppLock(false) {
            let lock = AppLock()
            lock.lockIfEnabled()
            #expect(lock.locked == false)
        }
        await withAppLock(true) {
            let lock = AppLock()
            lock.lockIfEnabled()
            #expect(lock.locked == (ProductModuleFlags.disabledReason(.appLock) == nil))
        }
    }

    @Test("Coming back locks only after more than the idle limit away")
    func idleRule() {
        let away = Date(timeIntervalSince1970: 1_000_000)
        #expect(AppLock.shouldLockOnReturn(resignedAt: nil, now: away, idleMinutes: 5) == false)
        #expect(AppLock.shouldLockOnReturn(resignedAt: away, now: away.addingTimeInterval(299), idleMinutes: 5) == false)
        #expect(AppLock.shouldLockOnReturn(resignedAt: away, now: away.addingTimeInterval(300), idleMinutes: 5) == false)
        #expect(AppLock.shouldLockOnReturn(resignedAt: away, now: away.addingTimeInterval(301), idleMinutes: 5) == true)
        #expect(AppLock.shouldLockOnReturn(resignedAt: away, now: away.addingTimeInterval(61), idleMinutes: 1) == true)
    }

    @Test("The idle limit is never below one minute")
    func idleLimitFloor() {
        let prior = AppLock.idleMinutes
        defer { AppLock.idleMinutes = prior }
        AppLock.idleMinutes = 0
        #expect(AppLock.idleMinutes == 1)
        AppLock.idleMinutes = 15
        #expect(AppLock.idleMinutes == 15)
    }

    @Test("A Mac that cannot verify the person never leaves them locked out")
    func noAuthenticationUnlocks() async {
        await withAppLock(true) {
            let lock = AppLock()
            lock.lockIfEnabled()
            lock.authenticator = .init(unavailableReason: { "No password is set." }, evaluate: { Issue.record("must not ask"); return false })
            await lock.unlock()
            #expect(lock.locked == false)
            #expect(lock.lastError == "No password is set.")
        }
    }

    @Test("Successful verification unlocks and clears the error")
    func successUnlocks() async {
        await withAppLock(true) {
            let lock = AppLock()
            lock.lockIfEnabled()
            lock.authenticator = .init(unavailableReason: { nil }, evaluate: { true })
            await lock.unlock()
            #expect(lock.locked == false)
            #expect(lock.lastError == nil)
        }
    }

    @Test("Failed or cancelled verification keeps the app locked")
    func failureStaysLocked() async {
        await withAppLock(true) {
            guard ProductModuleFlags.disabledReason(.appLock) == nil else { return }
            let lock = AppLock()
            lock.lockIfEnabled()
            lock.authenticator = .init(unavailableReason: { nil }, evaluate: { false })
            await lock.unlock()
            #expect(lock.locked == true)

            lock.authenticator = .init(unavailableReason: { nil }, evaluate: { throw Cancelled() })
            await lock.unlock()
            #expect(lock.locked == true)
            #expect(lock.lastError != nil)
        }
    }
}
