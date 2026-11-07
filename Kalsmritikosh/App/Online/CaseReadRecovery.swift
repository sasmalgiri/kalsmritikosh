//
//  CaseReadRecovery.swift
//  Kalsmritikosh
//
//  Package B (plan P1-E, scaffolding, 2026-11-06) — the words around an AI read of a case: the balance
//  beside the estimate, the progress line while it runs, what Cancel means for credits, and after a
//  failure the named cause with its ONE fix (out of credits → buy credits or upgrade; network → try
//  again; key refused → Settings; service paused or the day's limit → later). Display only: what is sent,
//  read, verified or charged is unchanged (the relay reserves, charges the actual cost and returns the
//  rest; a failed request is not charged). Nothing here touches the network.
//
//  Retries: the relay has no idempotency key. A retry after a FAILED request cannot double-charge (the
//  failure gave everything back); after a timeout or a cancel the first request may still have finished
//  on the provider's side and been charged its actual cost — the words say so instead of promising zero.
//

import Foundation

/// The cost lines shown before, during and after a case read on an AI plan.
public nonisolated enum CaseReadCostLines {
    /// "You have 1,840 credits left (this month's allowance and credit packs)." / not known yet.
    public static func balance(_ balance: Int?) -> String {
        guard let balance else { return "Your credits left are shown after the first AI request this month." }
        return "You have \(balance.formatted()) credits left (this month's allowance and credit packs)."
    }

    /// While a case is being read.
    public static func progress(planBalance: Int?, onPlan: Bool) -> String {
        guard onPlan else { return "The AI is reading this case. Your own key is billed by Anthropic for what it uses." }
        return "The AI is reading this case. The relay holds up to the estimate shown when you allowed this case, charges only what is used and returns the rest. " + balance(planBalance)
    }

    /// After Cancel.
    public static let cancelled = "Stopped waiting for the AI. Nothing more is sent for this question. If the AI had already started, only what it actually used is charged and the rest of what was held is returned; your balance updates with the next AI request."

    /// After a read on an AI plan that reported its cost.
    public static func charged(_ credits: Int, balance: Int?) -> String {
        "This read was charged \(credits.formatted()) credit\(credits == 1 ? "" : "s") (the actual cost)." + (balance.map { " \($0.formatted()) left." } ?? "")
    }
}

/// The one fix offered for a failed AI read.
public nonisolated enum CaseReadFix: String, Sendable, Equatable {
    case buyCredits, upgrade, retry, openSettings, tryLater

    public var title: String {
        switch self {
        case .buyCredits:   return "Buy credits…"
        case .upgrade:      return "See plans…"
        case .retry:        return "Try again"
        case .openSettings: return "Open Settings"
        case .tryLater:     return "OK"
        }
    }
}

/// What went wrong, in the person's words, with its one fix and what it means for credits.
public nonisolated struct CaseReadRecovery: Sendable, Equatable {
    public let cause: String
    public let fix: CaseReadFix
    public let charge: String

    /// The recovery for the last recorded AI failure (`OnlineStatus`), nil when it needs none (the person
    /// chose not to send, or nothing failed).
    public static func make(kind: OnlineFailure?, reason: String, offers: [AIPlanRefusal.Offer]) -> CaseReadRecovery? {
        let lower = reason.lowercased()
        let notCharged = "Nothing was charged for it."
        if offers.contains(.buyCredits) || lower.contains("credits and") && lower.contains("left") {
            return CaseReadRecovery(cause: "Not enough credits left for this read.", fix: .buyCredits,
                                    charge: notCharged + " A credit pack never expires; AI Pro holds more each month.")
        }
        if offers.contains(.upgrade) {
            return CaseReadRecovery(cause: "This read is larger than this plan allows at once.", fix: .upgrade, charge: notCharged)
        }
        if lower.contains("capacity") || lower.contains("paused") {
            return CaseReadRecovery(cause: "The AI service has reached this month's capacity and is paused until the 1st (UTC).", fix: .tryLater,
                                    charge: notCharged + " Everything else keeps working; your own Anthropic key can be used meanwhile.")
        }
        if lower.contains("today's ai limit") || lower.contains("daily") {
            return CaseReadRecovery(cause: "Today's AI limit for this plan is reached; it resets at midnight UTC.", fix: .tryLater, charge: notCharged)
        }
        guard let kind else { return nil }
        switch kind {
        case .declined, .notSent:
            return nil
        case .invalidKey:
            return CaseReadRecovery(cause: "Anthropic refused the API key.", fix: .openSettings, charge: notCharged)
        case .noCredit:
            return CaseReadRecovery(cause: "Your Anthropic account has no credit left.", fix: .openSettings,
                                    charge: notCharged + " Top it up at Anthropic, or use an AI plan.")
        case .network:
            return CaseReadRecovery(cause: "This Mac could not reach the AI service (network).", fix: .retry,
                                    charge: notCharged + " Trying again holds the estimate once more and charges only what is used.")
        case .timeout:
            return CaseReadRecovery(cause: "The AI did not reply in time.", fix: .retry,
                                    charge: "If it finished after this Mac stopped waiting, its actual use may still have been charged; the meter shows it after the next request. Trying again is a new read.")
        case .rateLimited:
            return CaseReadRecovery(cause: "The AI service is limiting requests right now.", fix: .retry,
                                    charge: notCharged + " Wait a minute, then try again.")
        case .providerError, .unreadable, .cutOff, .refused, .other:
            return CaseReadRecovery(cause: "The AI reading could not be used (\(kind.summary)).", fix: .retry,
                                    charge: "A failed request is not charged; trying again is a new read.")
        }
    }
}
