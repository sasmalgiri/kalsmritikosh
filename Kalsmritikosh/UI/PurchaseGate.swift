//
//  PurchaseGate.swift
//  Kalsmritikosh
//
//  The purchase screen over the main window when the app may not be used yet (trial not
//  started) or any more (trial ended, nothing bought), and the trial strip while the trial
//  runs. Settings stays open in every state, so backing up and exporting the archive always
//  works.
//

import SwiftUI

struct PurchaseGate: ViewModifier {
    @State private var store = PurchaseCenter.shared

    func body(content: Content) -> some View {
        ZStack {
            content
                .blur(radius: store.entitlement.allowsUse ? 0 : 20)
                .allowsHitTesting(store.entitlement.allowsUse)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if let days = store.entitlement.daysLeft() { trialStrip(days) }
                }
            if !store.entitlement.allowsUse { PurchaseScreen(store: store) }
        }
        .task { store.start() }
    }

    private func trialStrip(_ days: Int) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "clock")
            Text("Free trial: \(days) day\(days == 1 ? "" : "s") left.")
            Spacer()
            Button("Buy for \(store.priceText)") { Task { await store.buyUnlock() } }
                .disabled(store.busy)
        }
        .font(.callout)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.bar)
    }
}

struct PurchaseScreen: View {
    let store: PurchaseCenter

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: store.entitlement == .trialEnded ? "hourglass.bottomhalf.filled" : "sparkles")
                .font(.system(size: 40)).foregroundStyle(.secondary)
            Text(store.entitlement == .trialEnded ? "Your free trial has ended" : "Try Kalsmritikosh free for 14 days")
                .font(.title2.bold())
            Text(store.entitlement == .trialEnded
                 ? "Buy Kalsmritikosh once to keep using everything — no subscription and no yearly fee, on every Mac signed in with your Apple account. Your archive is untouched, and Settings ▸ Your data still backs it up and exports it."
                 : "Everything is included in the trial. After 14 days, buy it once to keep it — no subscription and no yearly fee. Starting the trial costs nothing and nothing is charged afterwards.")
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
                .foregroundStyle(.secondary)
            if store.entitlement == .notStarted {
                Button("Start free trial") { Task { await store.startTrial() } }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(store.busy)
                Button("Buy now for \(store.priceText)") { Task { await store.buyUnlock() } }
                    .disabled(store.busy)
            } else {
                Button("Buy for \(store.priceText)") { Task { await store.buyUnlock() } }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(store.busy)
            }
            Button("Restore purchase") { Task { await store.restore() } }
                .buttonStyle(.link).disabled(store.busy)
            if store.busy { ProgressView().controlSize(.small) }
            if let m = store.message { Text(m).font(.caption).foregroundStyle(.secondary).frame(maxWidth: 420) }
            Text("Payment and restore are handled by Apple through the App Store; Kalsmritikosh itself opens no connection.")
                .font(.caption2).foregroundStyle(.tertiary).multilineTextAlignment(.center).frame(maxWidth: 420)
        }
        .padding(36)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .accessibilityElement(children: .contain)
    }
}

extension View {
    func purchaseGate() -> some View { modifier(PurchaseGate()) }
}
