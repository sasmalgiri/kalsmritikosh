//
//  AISetup.swift
//  Kalsmritikosh
//
//  Candidate review 7d720fe1 (UB1 / PB3 / US1, App Review 2.1): after buying AI Included or AI Pro, or
//  saving an Anthropic key, AI must work without hidden switches. AI answers in a case need six things:
//  an AI plan or an own key, Online mode, the AI switch ("Use AI to write answers" and the document
//  reading module), the provider's document terms accepted, a storefront where Online AI is allowed,
//  and — on an AI plan — the publisher's relay and credits. When one is missing, Ask names exactly that
//  one, with the single action that fixes it.
//
//  `enable` is the ONE step that turns AI reading on for a provider: it is run only from the setup
//  sheet, after the person read the provider's terms and chose "Allow AI to read case documents you
//  permit". It never sends anything: each case still asks once for its own documents (CaseReadConsent).
//

import Foundation
import Observation
import os

/// Why AI cannot answer now (nil = it can).
public nonisolated enum AISetupCause: String, Sendable, Equatable, CaseIterable {
    /// The App Store country is one where Online AI is not offered (or not yet confirmed).
    case blockedStorefront
    /// No AI plan for this Apple account and no Anthropic key saved.
    case noPlanOrKey
    /// Online mode is off (Private mode), or "Answers with your own cloud AI key" is off.
    case onlineOff
    /// "Use AI to write answers", the AI posture, or the document-reading module is off.
    case aiSwitchOff
    /// The provider's document terms were not accepted (or changed since).
    case termsNotAccepted
    /// AI plan: the publisher's relay is not in this build or the subscription is not verified yet.
    case relayUnavailable
    /// AI plan: this month's credits and the packs are used up, or the service is paused.
    case creditsUsed

    /// The short reason, written into the offline search results ("… so no answer is written").
    public var note: String {
        switch self {
        case .blockedStorefront: return "AI is not offered for App Store accounts in this country"
        case .noPlanOrKey:       return "No AI is set up — there is no AI plan and no Anthropic key"
        case .onlineOff:         return "Online mode is off, so the AI is not used"
        case .aiSwitchOff:       return "AI answers are switched off (Settings ▸ Modules ▸ Use AI to write answers)"
        case .termsNotAccepted:  return "The AI's document terms have not been accepted, so no document may be read"
        case .relayUnavailable:  return "The AI service could not be reached or the AI plan is not confirmed yet (Online AI needs macOS 26 or later)"
        case .creditsUsed:       return "This month's AI credits are used up"
        }
    }

    /// What to do, in one sentence.
    public var remedy: String {
        switch self {
        case .blockedStorefront: return "Search results and every case tool keep working; nothing can turn the AI on in this country."
        case .noPlanOrKey:       return "Choose AI Included or AI Pro, or save your own Anthropic key in Settings ▸ Online."
        case .onlineOff, .aiSwitchOff, .termsNotAccepted:
            return "Turn AI on in one step: review the AI's terms and allow it to read the case documents you permit."
        case .relayUnavailable:  return "Check the AI plan again (it needs a connection), or restore your purchases."
        case .creditsUsed:       return "Buy a credit pack, upgrade to AI Pro, or wait for the monthly reset."
        }
    }

    /// The one button that fixes it (nil: nothing in the app can).
    public var actionTitle: String? {
        switch self {
        case .blockedStorefront: return nil
        case .noPlanOrKey:       return "See plans"
        case .onlineOff, .aiSwitchOff, .termsNotAccepted: return "Turn on AI…"
        case .relayUnavailable:  return "Check AI plan"
        case .creditsUsed:       return "Buy credits"
        }
    }
}

public nonisolated enum AISetup {

    /// Everything the decision reads, so it is tested without the Mac's settings.
    public struct Snapshot: Sendable, Equatable {
        public var aiAllowedHere: Bool
        public var kind: OnlineProviderKind
        public var hasAIPlan: Bool
        public var hasOwnKey: Bool
        public var relayConfigured: Bool
        public var onlineInBuild: Bool
        public var onlineOn: Bool
        public var onlineAnswersOn: Bool
        public var aiSwitchOn: Bool
        public var regimeAllowsAI: Bool
        public var documentReadingOn: Bool
        /// The document terms accepted for each provider (its kind's current terms version).
        public var termsAccepted: Set<OnlineProviderKind>
        public var creditsLeft: Int?
        public var paused: Bool
        public init(aiAllowedHere: Bool, kind: OnlineProviderKind, hasAIPlan: Bool, hasOwnKey: Bool, relayConfigured: Bool,
                    onlineInBuild: Bool, onlineOn: Bool, onlineAnswersOn: Bool, aiSwitchOn: Bool, regimeAllowsAI: Bool,
                    documentReadingOn: Bool, termsAccepted: Set<OnlineProviderKind>, creditsLeft: Int? = nil, paused: Bool = false) {
            self.aiAllowedHere = aiAllowedHere; self.kind = kind; self.hasAIPlan = hasAIPlan; self.hasOwnKey = hasOwnKey
            self.relayConfigured = relayConfigured; self.onlineInBuild = onlineInBuild; self.onlineOn = onlineOn
            self.onlineAnswersOn = onlineAnswersOn; self.aiSwitchOn = aiSwitchOn; self.regimeAllowsAI = regimeAllowsAI
            self.documentReadingOn = documentReadingOn; self.termsAccepted = termsAccepted; self.creditsLeft = creditsLeft; self.paused = paused
        }
    }

    /// The provider AI should use: the chosen one when it can work, else the AI plan, else the own key.
    public static func target(_ s: Snapshot) -> OnlineProviderKind? {
        func works(_ k: OnlineProviderKind) -> Bool { k == .included ? s.hasAIPlan : (k == .anthropic && s.hasOwnKey) }
        if works(s.kind) { return s.kind }
        if s.hasAIPlan { return .included }
        if s.hasOwnKey { return .anthropic }
        return nil
    }

    /// The first missing step, in the order the person would fix them; nil = AI may read the case.
    public static func cause(_ s: Snapshot) -> AISetupCause? {
        guard s.aiAllowedHere else { return .blockedStorefront }
        guard let k = target(s) else { return .noPlanOrKey }
        if k == .included, !s.relayConfigured { return .relayUnavailable }
        // A build without the network helper cannot reach any AI service.
        guard s.onlineInBuild else { return .relayUnavailable }
        // The chosen provider is not the one that works (a plan bought while the own key is chosen):
        // the one-step setup switches it, the same step as Online off.
        if !s.onlineOn || !s.onlineAnswersOn || k != s.kind { return .onlineOff }
        if !s.aiSwitchOn || !s.regimeAllowsAI || !s.documentReadingOn { return .aiSwitchOff }
        if !s.termsAccepted.contains(k) { return .termsNotAccepted }
        if k == .included {
            if s.paused { return .creditsUsed }
            if let left = s.creditsLeft, left <= 0 { return .creditsUsed }
        }
        return nil
    }

    // MARK: - Live

    /// Online AI (an AI plan or the own key) goes through the network helper, which needs macOS 26: on an
    /// older Mac the AI plans are not sold and the setup says the AI service cannot be reached.
    public static var onlineAIRunsOnThisMac: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    /// The Mac's current state.
    @MainActor public static func snapshot() -> Snapshot {
        let kind = OnlineSettings.kind
        var accepted = Set<OnlineProviderKind>()
        for k in [OnlineProviderKind.anthropic, .included] where OnlineSettings.confirmedDocumentTerms(for: k) == k.documentTermsVersion {
            accepted.insert(k)
        }
        let meter = AICreditMeter.shared
        return Snapshot(aiAllowedHere: AIRegion.allowsAI, kind: kind,
                        hasAIPlan: PurchaseCenter.shared.entitlement.includesAI && AIIncludedAccess.subscriptionID != nil,
                        hasOwnKey: OnlineSettings.apiKey(for: .anthropic) != nil,
                        relayConfigured: AIIncludedRelay.isConfigured,
                        onlineInBuild: ConnectivityMode.onlineAvailableInThisBuild && onlineAIRunsOnThisMac,
                        onlineOn: ConnectivityMode.current == .online,
                        onlineAnswersOn: ProductModuleFlags.isEnabled(.onlineAnswers),
                        aiSwitchOn: EvidenceOnlyRelease.aiEnabled || EvidenceOnlyRelease.isTestHost,
                        regimeAllowsAI: FeatureFlags.aiRegimeValue().allowsAI,
                        documentReadingOn: KnowledgeModuleFlags.isEnabled(.onlineRecordReading),
                        termsAccepted: accepted, creditsLeft: meter.balance, paused: meter.paused)
    }

    @MainActor public static func currentCause() -> AISetupCause? { cause(snapshot()) }

    /// The switches `enable` writes, injectable so the step is tested without the Mac's settings.
    public struct Switches: Sendable {
        public var setKind: @Sendable (OnlineProviderKind) -> Void
        public var setOnline: @Sendable () -> Void
        public var setOnlineAnswers: @Sendable () -> Void
        public var setAIEnabled: @Sendable () -> Void
        public var ensureRegimeAllowsAI: @Sendable () -> Void
        public var setDocumentReading: @Sendable () -> Void
        public var acceptTerms: @Sendable (OnlineProviderKind) -> Void
        public init(setKind: @escaping @Sendable (OnlineProviderKind) -> Void, setOnline: @escaping @Sendable () -> Void,
                    setOnlineAnswers: @escaping @Sendable () -> Void, setAIEnabled: @escaping @Sendable () -> Void,
                    ensureRegimeAllowsAI: @escaping @Sendable () -> Void, setDocumentReading: @escaping @Sendable () -> Void,
                    acceptTerms: @escaping @Sendable (OnlineProviderKind) -> Void) {
            self.setKind = setKind; self.setOnline = setOnline; self.setOnlineAnswers = setOnlineAnswers
            self.setAIEnabled = setAIEnabled; self.ensureRegimeAllowsAI = ensureRegimeAllowsAI
            self.setDocumentReading = setDocumentReading; self.acceptTerms = acceptTerms
        }

        public static let live = Switches(
            setKind: { OnlineSettings.kind = $0 },
            setOnline: { ConnectivityMode.set(.online) },
            setOnlineAnswers: { ProductModuleFlags.setEnabled(.onlineAnswers, true) },
            setAIEnabled: { EvidenceOnlyRelease.aiEnabled = true },
            ensureRegimeAllowsAI: { if !FeatureFlags.aiRegimeValue().allowsAI { FeatureFlags.setAIRegime(.gated) } },
            setDocumentReading: { KnowledgeModuleFlags.setEnabled(.onlineRecordReading, true) },
            acceptTerms: { OnlineSettings.setDocumentTermsConfirmed(true, for: $0) })
    }

    /// The one step: the provider chosen, Online mode on, AI answers on, document reading on and the
    /// provider's document terms accepted. Run only after the person chose "Allow AI to read case
    /// documents you permit" on the setup sheet, which shows those terms. Sends nothing.
    public static func enable(_ kind: OnlineProviderKind, switches: Switches = .live) {
        switches.setKind(kind)
        switches.setOnline()
        switches.setOnlineAnswers()
        switches.setAIEnabled()
        switches.ensureRegimeAllowsAI()
        switches.setDocumentReading()
        switches.acceptTerms(kind)
        KalsmritikoshLog.app.notice("AI reading turned on for \(kind.rawValue, privacy: .public) by the person (setup sheet)")
    }
}

/// Where a request to show the setup sheet is posted (a verified AI purchase or restore, a saved key,
/// or the "Turn on AI…" button on a search result). The sheet is presented by PurchaseGate.
@MainActor
@Observable
public final class AISetupCenter {
    public static let shared = AISetupCenter()
    /// The provider the sheet offers to turn on; nil = no sheet.
    public var offer: OnlineProviderKind?
    /// Bumped after `enable`, so views re-read the settings and the app re-installs its readers.
    public private(set) var version = 0
    /// The missing step behind the last answer shown as search results (the prompt above the window).
    public var lastOfflineCause: AISetupCause?

    /// Offer the sheet for `kind` unless AI already works for it.
    public func offerIfNeeded(_ kind: OnlineProviderKind) {
        var s = AISetup.snapshot()
        s.kind = kind
        if kind == .included { s.hasAIPlan = true }
        if kind == .anthropic { s.hasOwnKey = true }
        guard AISetup.cause(s) != nil, AISetup.cause(s) != .blockedStorefront else { return }
        offer = kind
    }

    public func enabled() { version &+= 1; offer = nil; lastOfflineCause = nil }

    /// Ask answered with search results: record why (nil = AI was ready; nothing to show).
    @discardableResult
    public func noteOffline() -> AISetupCause? {
        let c = AISetup.currentCause()
        lastOfflineCause = c
        return c
    }
}
