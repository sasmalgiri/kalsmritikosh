//
//  PurchaseGate.swift
//  Kalsmritikosh
//
//  The subscription screen (App Store completion instructions §11) and the read-only strip.
//
//  Before anything was ever bought the subscription screen leads, but Help, the isolated sample
//  case, recovery (Settings ▸ Your data), Restore purchases and Manage subscription stay reachable
//  from it. After a trial or subscription ends the window stays usable: every case is readable,
//  exports, backups, recovery, Help and privacy controls work, and only a paid action — creating,
//  editing, analysing — opens this screen as a sheet (`PurchaseCenter.allowPaidAction`).
//
//  Prices, periods and trial eligibility come from StoreKit for this storefront and this Apple
//  account; when the store cannot be reached the screen says so and offers retry — it never shows
//  a made-up price. The disclosure follows Apple's guidance: the trial length, the price and period
//  that follow, automatic renewal, cancelling at least a day before the period ends, and where to
//  manage it. Terms and privacy are linked. Subscribing enables nothing else (not Online mode).
//

import SwiftUI

nonisolated enum PurchaseLinks {
    static let terms = URL(string: "https://sasmalgiri.github.io/kalsmritikosh/terms.html")!
    static let privacy = URL(string: "https://sasmalgiri.github.io/kalsmritikosh/privacy.html")!
}

struct PurchaseGate: ViewModifier {
    @State private var store = PurchaseCenter.shared

    func body(content: Content) -> some View {
        ZStack {
            // UI run i, I-3: as a safe-area inset the strip covered the Ask composer on surfaces pinned to
            // the viewport; as a layout row below the content it takes its own space.
            VStack(spacing: 0) {
                content
                statusStrip
            }
                .blur(radius: gatesWholeWindow ? 20 : 0)
                .allowsHitTesting(!gatesWholeWindow)
                .accessibilityHidden(gatesWholeWindow)   // UI run h: assistive tech must not drive the blurred window either
            if gatesWholeWindow {
                // UI run h, H-1: laid out freely over the split view, the screen was proposed a 5 000-pt
                // height and the card landed below the display. Pin it to the window's own size and
                // scroll inside it when the window is small (macOS 26 split-view sizing).
                GeometryReader { geo in
                    ScrollView {
                        PurchaseScreen(store: store, presentedAsSheet: false)
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: geo.size.height)
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                }
            }
        }
        .sheet(isPresented: Binding(get: { store.paywallRequested != nil }, set: { if !$0 { store.paywallRequested = nil } })) {
            PurchaseScreen(store: store, presentedAsSheet: true)
                .frame(minWidth: 560, minHeight: 520)
        }
        .task { store.start() }
    }

    /// A profile that never had access, or whose store has not answered with nothing verified cached,
    /// sees the whole-window screen (with retry); everyone else keeps the window (read-only when
    /// nothing paid stands).
    private var gatesWholeWindow: Bool { store.entitlement.leadsWithSubscriptionScreen && !SampleArchiveMode.isActive && !store.gateDismissedThisLaunch }

    @ViewBuilder private var statusStrip: some View {
        if SampleArchiveMode.isActive && !store.entitlement.allowsPaidUse {
            // §6.3 — the sample is free to work on; subscribing is for the person's own documents.
            strip(icon: "graduationcap", text: "Sample case: everything here can be tried without a subscription. Subscribe to work on your own documents.",
                  action: "See plans") { store.paywallRequested = "work on your own documents" }
        } else {
            entitlementStrip
        }
    }

    @ViewBuilder private var entitlementStrip: some View {
        switch store.entitlement {
        case .introductoryTrial(_, _, let willRenew):
            strip(icon: "clock", text: "Free trial: \(store.entitlement.daysLeft() ?? 1) day(s) left. \(willRenew ? "It renews automatically unless cancelled a day before it ends." : "Renewal is off; nothing will be charged.")",
                  action: "Manage subscription") { NSWorkspace.shared.open(PurchaseProducts.manageSubscriptionsURL) }
        case .legacyTrial:
            strip(icon: "clock", text: "Free trial (earlier plan): \(store.entitlement.daysLeft() ?? 1) day(s) left. No charge follows it; subscribe when it ends to keep editing.",
                  action: "See plans") { store.paywallRequested = "keep editing after the trial" }
        case .grace:
            strip(icon: "exclamationmark.triangle", text: store.statusText, action: "Update payment") { NSWorkspace.shared.open(PurchaseProducts.manageSubscriptionsURL) }
        case .billingRetry, .lapsed:
            strip(icon: "lock.open", text: "Read-only: " + store.statusText, action: "Subscribe") { store.paywallRequested = "edit and analyse again" }
        case .notStarted, .unknown:
            if store.gateDismissedThisLaunch {
                strip(icon: "lock.open", text: store.entitlement == .unknown
                      ? "The App Store has not answered yet. Reading, Help, the sample case and backup work; adding documents, running jobs and asking wait for a plan."
                      : "No subscription yet. Reading, Help, the sample case and backup work; subscribe to add documents, run jobs and ask.",
                      action: "See plans") { store.gateDismissedThisLaunch = false }
            }
        default:
            EmptyView()
        }
    }

    private func strip(icon: String, text: String, action: String, _ run: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(action, action: run).disabled(store.busy)
        }
        .font(.callout)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.bar)
        .accessibilityIdentifier("purchase.strip")
    }
}

struct PurchaseScreen: View {
    let store: PurchaseCenter
    let presentedAsSheet: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var selected: SubscriptionPlan = .annual

    private var offer: PlanOffer? { store.offers.first { $0.plan == selected } }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: store.entitlement.hadAccessBefore ? "lock.open" : "sparkles")
                .scaledFont(36, relativeTo: .largeTitle).foregroundStyle(.secondary)
            Text(title).font(.title2.bold()).multilineTextAlignment(.center)
            Text(lead).multilineTextAlignment(.center).frame(maxWidth: 480).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if store.productsUnavailable || store.offers.isEmpty {
                VStack(spacing: 8) {
                    Text("The App Store did not return the plans and prices for your storefront, so none can be shown and nothing can be subscribed to yet. Nothing is charged until a plan is shown and chosen. Reading, exporting, backing up, Help and the sample case work meanwhile.")
                        .font(.callout).multilineTextAlignment(.center).frame(maxWidth: 440).foregroundStyle(.secondary)
                    Button("Try again") { Task { await store.loadProducts(); await store.refresh() } }.disabled(store.busy)
                }
            } else {
                plans
                if let offer {
                    Button(offer.actionTitle) { Task { await store.subscribe(offer.plan); if store.entitlement.allowsPaidUse, presentedAsSheet { dismiss() } } }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(store.busy)
                        .accessibilityIdentifier("purchase.subscribe")
                    Text(offer.disclosure).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 460)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("purchase.disclosure")
                    if offer.eligibleForTrial {
                        Link("How to cancel a trial or subscription (Apple)", destination: PurchaseProducts.cancelInstructionsURL).font(.caption)
                    }
                }
            }

            HStack(spacing: 18) {
                Button("Restore purchases") { Task { await store.restore(); if store.entitlement.allowsPaidUse, presentedAsSheet { dismiss() } } }
                    .buttonStyle(.link).disabled(store.busy)
                Button("Manage subscription") { NSWorkspace.shared.open(PurchaseProducts.manageSubscriptionsURL) }.buttonStyle(.link)
                Link("Terms", destination: PurchaseLinks.terms).font(.callout)
                Link("Privacy", destination: PurchaseLinks.privacy).font(.callout)
            }
            if store.busy { ProgressView().controlSize(.small) }
            if let m = store.message { Text(m).font(.caption).foregroundStyle(.secondary).frame(maxWidth: 440).multilineTextAlignment(.center) }

            Divider().frame(maxWidth: 480)
            // What never waits for a purchase.
            HStack(spacing: 16) {
                Button { SampleArchiveMode.enter() } label: { Label("Try a sample case", systemImage: "sparkles") }
                    .help("Opens the bundled sample in its own separate ledger. Nothing is mixed with your documents; no purchase is needed.")
                Button { leave(); SurfaceOpener.open(.guide) } label: { Label("Help", systemImage: "questionmark.circle") }
                    .help("Searchable offline help, the Get started guide and the tutorial — no subscription needed.")
                    .accessibilityIdentifier("purchase.help")
                Button { leave(); SurfaceOpener.open(.settings) } label: { Label("Backup & recovery", systemImage: "externaldrive") }
                    .help("Settings ▸ Your data: complete backup, recovery key, export and erasure never need a subscription.")
                    .accessibilityIdentifier("purchase.backup")
            }
            .buttonStyle(.bordered).controlSize(.small)
            Text(footer).font(.caption2).foregroundStyle(.tertiary).multilineTextAlignment(.center).frame(maxWidth: 460)
            if presentedAsSheet {
                Button("Not now") { dismiss() }.buttonStyle(.link).font(.caption)
            } else {
                Button("Look around first (read-only)") { leave() }.buttonStyle(.link).font(.caption)
                    .help("Use the window without a plan: everything is readable; adding documents, running jobs and asking will offer the plans again.")
                    .accessibilityIdentifier("purchase.lookAround")
            }
        }
        .padding(32)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("purchase.screen")
        .onAppear { if let first = store.offers.first(where: { $0.plan == .annual }) ?? store.offers.first { selected = first.plan } }
    }

    /// Leave the screen: a sheet is dismissed; the leading whole-window screen gives way to the
    /// read-only window for this launch (§6.11 — help and recovery are reachable before purchase).
    private func leave() {
        if presentedAsSheet { dismiss() } else { store.gateDismissedThisLaunch = true }
    }

    private var plans: some View {
        HStack(spacing: 12) {
            ForEach(store.offers) { o in
                Button { selected = o.plan } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(o.plan.label).font(.headline)
                            Spacer()
                            if selected == o.plan { Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint) }
                        }
                        Text("\(o.displayPrice) per \(o.plan.periodNoun)").font(.title3.weight(.semibold))
                        if o.plan == .annual {
                            Text("Charged once a year" + (store.annualSavingPercent.map { " · about \($0)% less than twelve monthly charges" } ?? ""))
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("Charged every month").font(.caption).foregroundStyle(.secondary)
                        }
                        Text(o.eligibleForTrial ? "14-day free trial, then this price" : "No free trial on this account").font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(12).frame(width: 220, alignment: .leading)
                    .background(selected == o.plan ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected == o.plan ? Color.accentColor : .clear, lineWidth: 1.5))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("purchase.plan.\(o.plan.rawValue)")
                .accessibilityLabel("\(o.plan.label) plan, \(o.displayPrice) per \(o.plan.periodNoun)\(o.eligibleForTrial ? ", 14-day free trial" : "")")
            }
        }
    }

    private var title: String {
        if let what = store.paywallRequested, store.entitlement.hadAccessBefore { return "Subscribe to \(what)" }
        switch store.entitlement {
        case .lapsed, .billingRetry: return "Your work is safe and readable — subscribe to keep editing"
        case .legacyTrial: return "Keep going after the free trial"
        default: return "Investigations Made Easy — one edition, all nine personas"
        }
    }

    private var lead: String {
        switch store.entitlement {
        case .lapsed, .billingRetry:
            return "Every case stays readable; export, complete backup, recovery, Help and privacy controls keep working. A subscription is needed only to create, edit and analyse again."
        default:
            return "Every persona and every job is included. On-device features need no AI-provider key; optional Online AI uses your own provider account and may cost extra. Monthly and annual plans give the same access."
        }
    }

    private var footer: String {
        "Payment, renewal, refunds and restore are handled by Apple through the App Store; Investigations Made Easy itself opens no connection for them and never sees your payment details. Subscribing does not turn on Online mode or send anything anywhere. The subscription works on the Macs signed in with your Apple account; your archive is not copied between them."
    }
}

extension View {
    func purchaseGate() -> some View { modifier(PurchaseGate()) }
}
