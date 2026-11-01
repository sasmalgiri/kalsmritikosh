//
//  AIRegion.swift
//  Kalsmritikosh
//
//  A3 (owner decision 2026-11-01) — one global release, with generative AI switched off by App Store
//  country where it may not be offered. The country is the App Store storefront of the person's Apple
//  account (StoreKit's `Storefront`), the same country Apple sells and bills in — never the Mac's
//  locale, IP address or location, which this app does not read.
//
//  Where AI is off, everything on-device keeps working; only the generative AI sends stop (AI Included
//  and the person's own key alike), and AI Included is not offered. The relay enforces the same list on
//  the storefront Apple records for the subscription (relay/src/policy.ts AI_BLOCKED_STOREFRONTS).
//
//  Unknown country (the store has not answered yet on this Mac and none was ever recorded): AI waits —
//  the same rule as the subscription itself, so an unanswered store never opens a blocked feature.
//

import Foundation
import StoreKit
import os

nonisolated enum AIRegion {
    /// App Store storefronts (ISO 3166-1 alpha-3) where generative AI is switched off, and why.
    /// Keep identical to AI_BLOCKED_STOREFRONTS in relay/src/policy.ts (ci/guards/relay-host-match.sh).
    static let blocked: [String: String] = [
        "CHN": "Generative AI services offered in mainland China need a filing and approval this app does not have.",
    ]

    enum Decision: Equatable, Sendable {
        case allowed
        case blocked(country: String, reason: String)
        case unknown

        var allowsAI: Bool { self == .allowed }

        /// What the person is told when AI is not available here.
        var explanation: String? {
            switch self {
            case .allowed: return nil
            case .blocked(_, let reason):
                return "Online AI is not available for App Store accounts in this country. \(reason) Everything on this Mac keeps working."
            case .unknown:
                return "Online AI waits until the App Store confirms your account's country. Everything on this Mac keeps working; try again when connected."
            }
        }
    }

    static func decision(countryCode: String?) -> Decision {
        guard let code = countryCode?.uppercased(), !code.isEmpty else { return .unknown }
        if let reason = blocked[code] { return .blocked(country: code, reason: reason) }
        return .allowed
    }

    private static let lastKey = "kalsmritikosh.aiRegion.storefront"
    private static let state = OSAllocatedUnfairLock<String?>(initialState: UserDefaults.standard.string(forKey: lastKey))

    /// The storefront country last confirmed by the App Store (kept between launches).
    static var countryCode: String? {
        #if DEBUG
        if let c = TestOverride.country { return c }
        if TestHost.isActive { return "USA" }   // the unit-test host never asks the store
        #endif
        return state.withLock { $0 }
    }

    static var current: Decision { decision(countryCode: countryCode) }
    static var allowsAI: Bool { current.allowsAI }

    static func record(_ code: String) {
        state.withLock { $0 = code }
        UserDefaults.standard.set(code, forKey: lastKey)
    }

    #if DEBUG
    enum TestOverride {
        @TaskLocal static var country: String?
    }
    #endif

    /// Read the storefront now and follow changes (the person switches the Apple account's country).
    static func start() {
        Task.detached {
            if let s = await Storefront.current { record(s.countryCode) }
            for await s in Storefront.updates { record(s.countryCode) }
        }
    }
}
