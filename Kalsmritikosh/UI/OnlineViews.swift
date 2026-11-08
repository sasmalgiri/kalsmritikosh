//
//  OnlineViews.swift
//  Kalsmritikosh
//
//  Online mode UI: the consent sheet (O-5), the always-visible Online badge with
//  one-click return to Private (O-3), the failure banner (O-7), and the Online
//  settings section with the outbound log.
//

import SwiftUI

/// O-5 — exactly what is about to leave the Mac.
struct OutboundConsentSheet: View {
    let preview: OutboundPreview
    @State private var consent = OutboundConsent.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("Send to \(preview.provider)?", systemImage: "icloud.and.arrow.up").font(.title3.bold())
                InfoPopoverButton(topic: "task-private-online")   // §6.8 — Online sends
            }
            Text(preview.aiIncluded
                 ? "This text will be sent through your AI plan (\(preview.host)) to \(preview.model). It is charged in credits at its actual cost; nothing is billed to you beyond the plan and the credit packs you bought. Nothing else leaves your Mac for this request."
                 : "This text will be sent to \(preview.host) (model \(preview.model)) with your own key, and billed to your provider account. Nothing else leaves your Mac for this request.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let cost = preview.costEstimate {
                Label(cost, systemImage: "creditcard").font(.caption.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("consent.costEstimate")
            }
            if preview.carriesDocuments {
                Label("This send includes text from your documents.", systemImage: "doc.text")
                    .font(.caption.weight(.semibold))
                if let terms = preview.providerTerms {
                    Text(terms).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 14) {
                Text("\(preview.bytes) bytes").font(.caption.monospacedDigit())
                if preview.maskedCount > 0 {
                    Text("\(preview.maskedCount) personal detail\(preview.maskedCount == 1 ? "" : "s") masked").font(.caption)
                }
            }
            ScrollView {
                Text(preview.text).font(.caption.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 240)
            .padding(6)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            HStack {
                Button("Don’t send") { consent.resolve(allow: false) }.keyboardShortcut(.cancelAction)
                Spacer()
                if !OnlineSettings.askEveryTime, !preview.carriesDocuments {
                    Button("Send and don’t ask again this session") { consent.resolve(allow: true, forSession: true) }
                }
                Button("Send") { consent.resolve(allow: true) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 620)
    }
}

/// O-3 + O-7 — shown at the top of the window while Online mode is in force or after a failure.
struct OnlineStatusBar: View {
    @Environment(AppState.self) private var appState
    @State private var status = OnlineStatus.shared
    @State private var meter = AICreditMeter.shared
    @State private var setup = AISetupCenter.shared
    @State private var version = 0

    var body: some View {
        let _ = version
        VStack(spacing: 0) {
            // UB1 — the last answer was search results: name the missing step, with its one action.
            if let cause = setup.lastOfflineCause { AISetupPrompt(cause: cause) }
            if ConnectivityMode.current == .online {
                HStack(spacing: 8) {
                    Label("Online — answers may use \(OnlineSettings.kind.displayName)", systemImage: "icloud")
                        .font(.caption.weight(.semibold))
                    // Plans and credits — the meter on every screen (Ask, the case file …) while Online is on.
                    if OnlineSettings.kind == .included, let line = meter.summaryLine {
                        Text("· " + line + (meter.resetText.map { " · \($0)" } ?? "")).font(.caption).foregroundStyle(.secondary)
                            .accessibilityIdentifier("online.creditMeter")
                    } else if OnlineSettings.kind == .anthropic {
                        Text("· own key: about \(AIPricing.formatUSD(OwnKeyBudget.spentUSD())) this month" + (OwnKeyBudget.monthlyLimitUSD.map { " of your \(AIPricing.formatUSD($0)) limit" } ?? ""))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Switch to Private") {
                        ConnectivityMode.set(.privateMode)
                        version &+= 1
                    }
                    .font(.caption)
                }
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(Color.blue.opacity(0.12))
            }
            if let failure = status.lastFailure {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        if let banner = status.accountBanner {
                            Label(banner, systemImage: "creditcard.trianglebadge.exclamationmark")
                                .font(.caption.weight(.semibold)).lineLimit(2)
                        }
                        Label("The online answer did not go through: \(failure)", systemImage: "exclamationmark.icloud")
                            .font(.caption).lineLimit(2)
                    }
                    Spacer()
                    // Plans and credits — a credit refusal (the app's own check or the relay's) offers the way out.
                    if status.lastFailureOffers.contains(.buyCredits), AIRegion.sellsAIProducts {
                        Menu("Buy credits") {
                            ForEach(PurchaseProducts.creditPacks, id: \.self) { id in
                                Button("\((PurchaseProducts.credits(inPack: id) ?? 0).formatted()) credits" + (PurchaseCenter.shared.packPrices[id].map { " (\($0))" } ?? "")) {
                                    Task { await PurchaseCenter.shared.buyCredits(id) }
                                }
                            }
                        }
                        .font(.caption).fixedSize()
                        .accessibilityIdentifier("online.failure.buyCredits")
                    }
                    if status.lastFailureOffers.contains(.upgrade), AIRegion.sellsAIProducts {
                        Button("Upgrade") { PurchaseCenter.shared.paywallRequested = "upgrade to AI Pro" }
                            .font(.caption)
                            .accessibilityIdentifier("online.failure.upgrade")
                    }
                    if ConnectivityMode.current == .online {
                        Button("Switch to Private") { ConnectivityMode.set(.privateMode); status.clear(); version &+= 1 }
                            .font(.caption)
                    }
                    Button("Dismiss") { status.clear() }.font(.caption)
                }
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(Color.orange.opacity(0.14))
            }
        }
    }
}

/// Settings ▸ Modules ▸ Online — provider, model, key, consent style, daily limit, and the log.
struct OnlineSettingsSection: View {
    @Environment(AppState.self) private var appState
    @State private var kind = OnlineSettings.kind
    @State private var model = OnlineSettings.model
    @State private var key = ""
    @State private var hasKey = OnlineSettings.apiKey(for: OnlineSettings.kind) != nil
    @State private var askEveryTime = OnlineSettings.askEveryTime
    @State private var documentTermsConfirmed = OnlineSettings.confirmedDocumentTerms(for: OnlineSettings.kind) == OnlineSettings.kind.documentTermsVersion
    @State private var capText = OnlineSettings.dailyByteCap.map(String.init) ?? ""
    @State private var log: [OutboundLogEntry] = []
    @State private var showLog = false
    @State private var retiredNotice = OnlineSettings.retiredProviderNotice
    /// UB1 — the one-step setup offered after a key is saved, or from "Turn on AI…" here.
    @State private var setupKind: OnlineProviderKind?
    @State private var setup = AISetupCenter.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Online AI").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            if let why = AIRegion.current.explanation {
                Label(why, systemImage: "globe").font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Release decisions 2026-11-04 (item 4) — an earlier OpenAI / Gemini choice was migrated.
            if let notice = retiredNotice {
                HStack(alignment: .top, spacing: 8) {
                    Label(notice, systemImage: "info.circle").font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Dismiss") { OnlineSettings.dismissRetiredProviderNotice(); retiredNotice = nil }
                        .font(.caption)
                }
                .accessibilityIdentifier("online.retiredProviderNotice")
            }
            if AIRegion.isBlocked {
                // Item 3 — where Online AI is blocked neither an AI plan nor an own key can be set up.
                Text("Neither an AI plan nor your own AI key can be used with an App Store account in this country, so there is nothing to set up here.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("online.blockedRegion")
            } else {
                providerControls
            }
            Toggle("Ask before every send", isOn: $askEveryTime)
                .onChange(of: askEveryTime) { _, v in OnlineSettings.askEveryTime = v }
            HStack {
                Text("Daily limit (bytes, blank = none, 0 = send nothing)").font(.caption)
                TextField("", text: $capText).textFieldStyle(.roundedBorder).frame(width: 120)
                    .onSubmit { OnlineSettings.dailyByteCap = Int(capText.trimmingCharacters(in: .whitespaces)) }
            }
            Button("What was sent…") {
                Task { log = (try? await appState.outboundLog?.recent()) ?? []; showLog = true }
            }
        }
        .onAppear { retiredNotice = OnlineSettings.retiredProviderNotice }
        .sheet(item: $setupKind) { k in
            AISetupSheet(kind: k) { refreshFromSettings() }.environment(appState)
        }
        .onChange(of: setup.version) { _, _ in refreshFromSettings() }
        .sheet(isPresented: $showLog) {
            VStack(alignment: .leading, spacing: 8) {
                Text("What was sent").font(.title3.bold())
                List(log) { e in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(e.sentAt.formatted()) · \(e.provider) · \(e.outcome) · \(e.bytesSent) bytes").font(.caption.weight(.semibold))
                        Text("SHA-256 \(e.payloadSHA256.prefix(16))…  masked \(e.maskedCount)").font(.caption2.monospaced()).foregroundStyle(.secondary)
                        Text(e.payloadText.prefix(400)).font(.caption2).foregroundStyle(.secondary)
                        if let d = e.detail { Text(d).font(.caption2).foregroundStyle(.orange) }
                    }
                }
                .frame(minHeight: 320)
                HStack { Spacer(); Button("Done") { showLog = false }.keyboardShortcut(.defaultAction) }
            }
            .padding(16).frame(width: 620)
        }
    }

    /// The provider (Claude with your own key, or an AI plan), its terms, and its key or plan status.
    @ViewBuilder private var providerControls: some View {
            Picker("Provider", selection: $kind) {
                ForEach(OnlineProviderKind.allCases.filter(\.isSelectable)) { Text($0.displayName).tag($0) }
            }
            .onChange(of: kind) { _, k in
                OnlineSettings.kind = k
                model = OnlineSettings.model
                hasKey = OnlineSettings.apiKey(for: k) != nil
                documentTermsConfirmed = OnlineSettings.confirmedDocumentTerms(for: k) == k.documentTermsVersion
            }
            // Review L2 — whether this provider may receive case documents, on whose terms.
            Text(kind.documentTerms).font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // UB1 — the one step instead of hidden switches: shown while AI cannot yet read for this provider.
            if let cause = setupCause, cause != .blockedStorefront, cause != .noPlanOrKey {
                HStack(alignment: .top, spacing: 8) {
                    Text(cause.note + ".").font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    if cause.actionTitle == "Turn on AI…" {
                        Button("Turn on AI…") { setupKind = kind }.font(.caption)
                            .accessibilityIdentifier("online.turnOnAI")
                    }
                }
            }
            if kind.mayReceiveDocuments {
                Toggle(kind.documentAttestation, isOn: Binding(
                    get: { documentTermsConfirmed },
                    set: { OnlineSettings.setDocumentTermsConfirmed($0, for: kind); documentTermsConfirmed = $0 }))
                    .font(.caption)
            }
            if kind.usesOwnKey {
                ownKeyFields
            } else {
                AIIncludedStatusView(store: PurchaseCenter.shared)
            }
    }

    /// What still stops AI for the provider shown here (nil = ready).
    private var setupCause: AISetupCause? { let _ = setup.version; return setupCauseFor(kind) }

    private func setupCauseFor(_ k: OnlineProviderKind) -> AISetupCause? {
        var s = AISetup.snapshot()
        s.kind = k
        if k == .anthropic { s.hasOwnKey = hasKey }
        return AISetup.cause(s)
    }

    private func refreshFromSettings() {
        kind = OnlineSettings.kind
        model = OnlineSettings.model
        hasKey = OnlineSettings.apiKey(for: kind) != nil
        documentTermsConfirmed = OnlineSettings.confirmedDocumentTerms(for: kind) == kind.documentTermsVersion
    }

    /// The person's own provider: model and key.
    private var ownKeyFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Model name (from your provider)", text: $model)
                .textFieldStyle(.roundedBorder)
                .onSubmit { OnlineSettings.model = model }
            HStack {
                SecureField(hasKey ? "Key saved — paste a new one to replace" : "API key", text: $key)
                    .textFieldStyle(.roundedBorder)
                Button("Save key") {
                    OnlineSettings.model = model
                    hasKey = OnlineSettings.setAPIKey(key, for: kind) && !key.isEmpty
                    key = ""
                    // UB1 — a saved Anthropic key: offer the same one-step setup as an AI plan.
                    if hasKey, kind == .anthropic, setupCauseFor(.anthropic) != nil { setupKind = .anthropic }
                }
                .disabled(key.isEmpty)
                if hasKey {
                    Button("Remove key") { OnlineSettings.setAPIKey(nil, for: kind); hasKey = false }
                }
            }
            Text("The key is kept in your Mac's Keychain and sent only to \(kind.host).")
                .font(.caption2).foregroundStyle(.secondary)
            if kind == .anthropic { OwnKeyBudgetView() }
        }
    }
}

/// Plans and credits (2026-11-04) — the AI plan in Settings ▸ Online: this month's allowance used and
/// left, the credit-pack balance, the reset date, the last request's cost, and the two packs.
struct AIIncludedStatusView: View {
    let store: PurchaseCenter
    @State private var meter = AICreditMeter.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let tier = store.entitlement.aiTier {
                AICreditMeterView(meter: meter, tier: tier)
                HStack {
                    Button("Check credits") { Task { await store.refreshAIStatus() } }.disabled(store.busy)
                    // Release decisions 2026-11-04 (item 3): packs are sold only where Online AI is allowed.
                    ForEach(AIRegion.sellsAIProducts ? PurchaseProducts.creditPacks : [], id: \.self) { id in
                        let credits = PurchaseProducts.credits(inPack: id) ?? 0
                        Button("Buy \(credits.formatted()) credits" + (store.packPrices[id].map { " (\($0))" } ?? "")) {
                            Task { await store.buyCredits(id) }
                        }
                        .disabled(store.busy || store.packPrices[id] == nil)
                        .help("A one-time App Store purchase. Credit packs never expire; they are spent after the month's credits while an AI plan is active, and stay with your Apple account on every Mac.")
                    }
                }
                Text("Checking sends only your subscription's signed App Store transaction (Apple's proof of the purchase) to the AI service — nothing from your cases.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("No AI plan is active for this Apple account. AI Included (2,000 credits a month) and AI Pro (6,000 a month; 5,400 on the yearly plan) need no AI account of your own; on Workbench, pick Claude (Anthropic) above and use your own Anthropic key.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if AIRegion.sellsAIProducts {
                    Button("See plans") { store.paywallRequested = "use the AI plans" }
                }
            }
            if let m = store.message { Text(m).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

/// The credit meter itself (Settings ▸ Online, and compact on the Ask and case screens).
struct AICreditMeterView: View {
    let meter: AICreditMeter
    let tier: PlanTier
    var compact = false

    var body: some View {
        let monthly = meter.receipt?.monthlyCredits ?? tier.limits?.monthlyCredits ?? 0
        VStack(alignment: .leading, spacing: 4) {
            if let r = meter.receipt {
                Text("\(tier.name): \(r.allowanceLeft.formatted()) of \(monthly.formatted()) credits left this month" + (meter.resetText.map { " (\($0))" } ?? ""))
                    .font(compact ? .caption : .callout)
                if !compact {
                    ProgressView(value: Double(max(0, monthly - r.allowanceLeft)), total: Double(max(1, monthly)))
                        .accessibilityLabel("\(monthly - r.allowanceLeft) of \(monthly) credits used this month")
                }
                Text("Credit packs: \(r.topUps.formatted()) credits (never expire)" + (meter.lastCharged.map { " · last request: \($0) credit\($0 == 1 ? "" : "s")" } ?? ""))
                    .font(.caption).foregroundStyle(.secondary)
                if meter.paused {
                    Text("The AI service has reached this month's capacity and is paused until the 1st. Nothing is charged meanwhile; everything else keeps working.")
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("\(tier.name): \(monthly.formatted()) credits a month. Choose “Check credits” to see what is left.")
                    .font(compact ? .caption : .callout)
            }
        }
        .accessibilityIdentifier("ai.creditMeter")
    }
}

/// Own key (Claude): the estimated spend this month and the person's own monthly limit.
struct OwnKeyBudgetView: View {
    @State private var limitText = OwnKeyBudget.monthlyLimitUSD.map { String(format: "%.2f", $0) } ?? ""
    @State private var spent = OwnKeyBudget.spentUSD()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Monthly limit for your own key (US$, blank = none)").font(.caption)
                TextField("", text: $limitText).textFieldStyle(.roundedBorder).frame(width: 90)
                    .onSubmit { OwnKeyBudget.monthlyLimitUSD = Double(limitText.trimmingCharacters(in: .whitespaces)) }
                Button("Set limit") { OwnKeyBudget.monthlyLimitUSD = Double(limitText.trimmingCharacters(in: .whitespaces)) }
                    .controlSize(.small)
            }
            Text("This month: about \(AIPricing.formatUSD(spent)) (estimated on this Mac from Anthropic's replies at its published prices; Anthropic's own bill is the record). When the limit is reached, nothing more is sent until the next month or until you raise it. Each send shows its estimated cost first.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { spent = OwnKeyBudget.spentUSD() }
    }
}
