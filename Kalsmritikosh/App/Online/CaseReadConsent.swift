//
//  CaseReadConsent.swift
//  Kalsmritikosh
//
//  Plan A (owner, 2026-11-04) — the once-per-case permission sheet (App Store guideline 5.1.2(i)):
//  the first AI use in a case lists exactly which documents go to the AI provider (names, count, size),
//  which do not and why (privileged, restricted …), and the estimated cost of the first read; Allow /
//  Not now. Allow is stored per case, pinned to the document set (CaseReadPermissionStore); the sheet
//  comes back only when the case's documents change (or after the optional re-ask time).
//  Archive-wide (non-case) sends keep the per-send preview (OutboundConsent).
//

import Foundation
import Observation

@MainActor
@Observable
public final class CaseReadConsent {
    public static let shared = CaseReadConsent()

    public private(set) var pending: CaseReadConsentRequest?
    private var continuation: CheckedContinuation<Bool, Never>?
    /// A test host (the case bench) answers for the person; nil in the app.
    public var scriptedAnswer: Bool?

    public func request(_ request: CaseReadConsentRequest) async -> Bool {
        if let scriptedAnswer { return scriptedAnswer }
        while pending != nil { try? await Task.sleep(nanoseconds: 200_000_000) }
        return await withCheckedContinuation { c in
            continuation = c
            pending = request
        }
    }

    public func resolve(allow: Bool) {
        pending = nil
        continuation?.resume(returning: allow)
        continuation = nil
    }
}

/// How much case text is read whole, by plan or setting.
public nonisolated enum CaseReadLimits {
    /// The plan's whole-case limit in tokens (the billing layer sets it: AI Included ≈ 300k, AI Pro ≈ 800k).
    public static let planLimitKey = "kalsmritikosh.caseRead.planLimit"
    /// The person's own-key limit in tokens (default 300k).
    public static let ownKeyLimitKey = "kalsmritikosh.caseRead.ownKeyLimit"

    public static func current() -> Int {
        let key = OnlineSettings.kind == .included ? planLimitKey : ownKeyLimitKey
        let stored = UserDefaults.standard.integer(forKey: key)
        return stored > 0 ? stored : CaseWholeReading.defaultLimit
    }
}
