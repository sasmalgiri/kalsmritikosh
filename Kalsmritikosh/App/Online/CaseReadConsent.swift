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

/// How much case text is read whole, by plan or setting. AI Included / AI Pro: derived from the current
/// verified plan (AICreditMeter.verifiedTier — StoreKit's verified entitlement, or the relay's receipt)
/// and the ONE source of plan parameters (AIPricing, the mirror of relay/src/policy.ts), capped so the
/// worst-case reservation of such a read always fits the plan's case-read credits and the relay's size
/// limit — the relay never refuses a read the app offered. Nothing about the plan is stored.
/// Own key (Workbench, or any plan with the person's own key): the person's setting, default 300k.
public nonisolated enum CaseReadLimits {
    /// The person's own-key limit in tokens (default 300k).
    public static let ownKeyLimitKey = "kalsmritikosh.caseRead.ownKeyLimit"

    public static func current() -> Int {
        limit(kind: OnlineSettings.kind, tier: AICreditMeter.verifiedTier,
              ownKeySetting: UserDefaults.standard.integer(forKey: ownKeyLimitKey))
    }

    /// The whole-case limit (estimated tokens of case text) for a provider kind and plan.
    static func limit(kind: OnlineProviderKind, tier: PlanTier?, ownKeySetting: Int) -> Int {
        guard kind == .included else { return ownKeySetting > 0 ? ownKeySetting : CaseWholeReading.defaultLimit }
        // No verified AI plan known yet: the smaller plan's limit (the relay decides whether to serve at all).
        let plan = tier?.limits ?? AIPricing.aiIncluded
        return min(plan.caseReadTokens, AIPricing.caseReadTokenCeiling(creditCeiling: plan.caseReadCredits))
    }
}
