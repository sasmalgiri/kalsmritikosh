#if DEBUG   // App Store completion §5 — the whole file, its launch argument and every hook to it are compiled out of Release
//
//  UIWalkSimulatedPlan.swift
//  Kalsmritikosh
//
//  GUI walk support (release gate ui-consent-and-plans, docs/evidence/gui-walk-2026-11-13/README.md):
//  the once-per-case permission sheet and the credit meter appear only with a verified AI plan, and the
//  walk rules forbid purchases, keys and sends. The launch argument `--ui-walk-simulated-plan=aiIncluded`
//  (or `=aiPro`) gives this process a simulated verified AI plan and a local credit-meter receipt, so the
//  real plan picker, credit meter, AI setup sheet and permission sheet render through their normal code.
//
//  What it can never do:
//   • send: the Online provider refuses every request before its outbound record and its transport
//     ("Walk simulation — nothing sent"), and the network helper client refuses every request too;
//   • buy: subscribe, credit packs and the pending-pack credit are refused before StoreKit is asked;
//   • persist: the AI switches the setup sheet turns on are held in this process's argument domain
//     (volatile, never written to disk); the case permission is kept in memory only; the simulated
//     entitlement is never written to the entitlement cache;
//   • touch the owner's ledger: honoured only together with `--acceptance-case` (the disposable ledger) or in
//     sample-archive mode (its own ledger); otherwise refused and logged;
//   • ship: the file and every reference to it sit inside `#if DEBUG` (scripts/release-check-debug-args.sh).
//

import Foundation
import os

nonisolated enum UIWalkSimulatedPlan {
    static let argumentPrefix = "--ui-walk-simulated-plan="
    /// The disposable-ledger argument it must accompany (AcceptanceCaseGUIFixture.launchArgument).
    static let acceptanceArgument = "--acceptance-case"

    enum Plan: String, Sendable, CaseIterable, Equatable {
        case aiIncluded, aiPro

        var subscription: SubscriptionPlan { self == .aiIncluded ? .aiMonthly : .proMonthly }
        var tier: PlanTier { subscription.tier }
        var limits: AIPricing.PlanLimits { self == .aiIncluded ? AIPricing.aiIncluded : AIPricing.aiPro }
        var relayCode: String { self == .aiIncluded ? "ai" : "pro" }
    }

    /// What the launch arguments ask for.
    enum Decision: Equatable, Sendable {
        case notRequested
        case active(Plan)
        case refused(String)
    }

    /// The credits shown as already used this month (the meter shows some use, not a fresh month).
    static let creditsUsed = 350
    /// Stands in for the AI period's signed transaction. It has the JWS shape the app checks, but carries no
    /// Apple signature, so a relay would refuse it; and nothing is ever sent with it.
    static let signedTransaction = "uiwalk-simulated-plan.not-signed.nothing-sent"
    static let subscriptionID = "ui-walk-simulated"
    /// The one refusal every send and purchase gets.
    static let refusalText = "Walk simulation — nothing sent. This Debug launch simulates an AI plan for a GUI walk; no request leaves this Mac and nothing is charged."

    struct NothingSent: LocalizedError, Equatable {
        var errorDescription: String? { UIWalkSimulatedPlan.refusalText }
    }

    // MARK: The decision (pure)

    static func decide(arguments: [String], sampleMode: Bool) -> Decision {
        let values = arguments.filter { $0.hasPrefix(argumentPrefix) }.map { String($0.dropFirst(argumentPrefix.count)) }
        guard let raw = values.last else { return .notRequested }
        guard let plan = Plan(rawValue: raw) else {
            let known = Plan.allCases.map(\.rawValue).joined(separator: ", ")
            return .refused("unknown plan '\(raw)' (use \(known))")
        }
        let disposable = arguments.contains(acceptanceArgument)
        guard disposable || sampleMode else {
            return .refused("allowed only with \(acceptanceArgument) or in sample-archive mode, never on the owner's ledger")
        }
        return .active(plan)
    }

    // MARK: The process's state

    private static let launchState = OSAllocatedUnfairLock<Plan?>(initialState: nil)
    /// A test's own simulated plan (its task only; nothing global changes).
    @TaskLocal static var testPlan: Plan?

    /// The plan activated at launch (never set in the unit-test host).
    static var launchPlan: Plan? { launchState.withLock { $0 } }
    static var activePlan: Plan? { testPlan ?? launchPlan }
    static var isActive: Bool { activePlan != nil }

    /// The case permissions the sheet stores while the simulation runs (memory only, never the defaults).
    static let permissions = OSAllocatedUnfairLock<[UUID: CaseReadPermission]>(initialState: [:])

    /// The refusal a send gets at the dispatch boundary (nil = no simulation).
    static func dispatchRefusal() -> NothingSent? { isActive ? NothingSent() : nil }

    // MARK: The simulated plan and receipt

    static func entitlement(_ plan: Plan, now: Date) -> Entitlement {
        .subscribed(expiresAt: now.addingTimeInterval(30 * 86_400), plan: plan.subscription, willRenew: true)
    }

    static func receipt(_ plan: Plan, now: Date) -> AIIncludedRelay.Receipt {
        let l = plan.limits
        let left = l.monthlyCredits - creditsUsed
        return AIIncludedRelay.Receipt(plan: plan.relayCode, monthlyCredits: l.monthlyCredits, allowanceLeft: left, topUps: 0,
                                       dailyUsed: creditsUsed, dailyLimit: l.dailyCredits, perRequestCredits: l.perRequestCredits,
                                       caseReadCredits: l.caseReadCredits, periodEndsAt: now.addingTimeInterval(30 * 86_400),
                                       charged: nil, reserved: nil)
    }

    // MARK: Launch

    /// Read the launch arguments once (KalsmritikoshApp.init) and, when allowed, put the simulated plan into
    /// the app's purchase centre and credit meter. Refused or absent: nothing changes; a refusal is logged.
    @MainActor @discardableResult
    static func activate(arguments: [String], sampleMode: Bool, center: PurchaseCenter, meter: AICreditMeter,
                         publishProcessWide: Bool, now: Date = Date()) -> Plan? {
        switch decide(arguments: arguments, sampleMode: sampleMode) {
        case .notRequested:
            return nil
        case .refused(let why):
            KalsmritikoshLog.app.error("UI walk simulated plan refused: \(why, privacy: .public)")
            return nil
        case .active(let plan):
            if publishProcessWide { launchState.withLock { $0 = plan } }
            center.applyUIWalkSimulation(plan, meter: meter, now: now)
            KalsmritikoshLog.app.notice("UI walk simulated plan active: \(plan.rawValue, privacy: .public) — nothing can be sent or bought in this process")
            return plan
        }
    }

    // MARK: Switches kept in memory

    /// Run `body` (a writer of the app's own preferences — the AI setup sheet's one step) so that what it
    /// changes is visible to this process only: the changed keys are copied into the argument domain
    /// (volatile) and their stored values are put back at once. Returns the volatile values.
    @discardableResult
    static func keepInMemory(defaults: UserDefaults = .standard, domain: String? = Bundle.main.bundleIdentifier,
                             volatile: ([String: Any]) -> Void = { mergeIntoArgumentDomain($0) },
                             _ body: () -> Void) -> [String: Any] {
        guard let domain else {
            KalsmritikoshLog.app.error("UI walk simulated plan: no preference domain — the switches were not changed")
            return [:]
        }
        let before = defaults.persistentDomain(forName: domain) ?? [:]
        body()
        let after = defaults.persistentDomain(forName: domain) ?? [:]
        var changed: [String: Any] = [:]
        var removed: [String] = []
        for key in Set(before.keys).union(after.keys) {
            let old = before[key] as AnyObject?
            let new = after[key] as AnyObject?
            if let old, let new, old.isEqual(new) { continue }
            if let value = after[key] { changed[key] = value } else { removed.append(key) }
            if let value = before[key] { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        if !removed.isEmpty {
            KalsmritikoshLog.app.notice("UI walk simulated plan: \(removed.count, privacy: .public) removed preference(s) left as stored")
        }
        volatile(changed)
        return changed
    }

    static func mergeIntoArgumentDomain(_ values: [String: Any]) {
        guard !values.isEmpty else { return }
        let d = UserDefaults.standard
        var merged = d.volatileDomain(forName: UserDefaults.argumentDomain)
        for (k, v) in values { merged[k] = v }
        d.removeVolatileDomain(forName: UserDefaults.argumentDomain)
        d.setVolatileDomain(merged, forName: UserDefaults.argumentDomain)
    }
}

extension PurchaseCenter {
    /// UI walk: a purchase is refused before StoreKit is asked (nothing bought, nothing sent).
    func uiWalkRefusesPurchase() -> Bool {
        guard UIWalkSimulatedPlan.launchPlan != nil else { return false }
        message = UIWalkSimulatedPlan.refusalText
        return true
    }
}
#endif
