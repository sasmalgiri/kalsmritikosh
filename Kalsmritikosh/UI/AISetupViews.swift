//
//  AISetupViews.swift
//  Kalsmritikosh
//
//  Candidate review 7d720fe1 (UB1, LS1, PS2): the one-step AI setup sheet — shown after a verified AI
//  plan purchase or restore, after saving an Anthropic key, or from "Turn on AI…" — and the prompt that
//  names the missing step when Ask answered with search results.
//

import SwiftUI

/// The provider's terms, where the case documents go, and one button that turns AI reading on.
struct AISetupSheet: View {
    let kind: OnlineProviderKind
    var onDone: () -> Void = {}
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(kind == .included ? "Turn on AI for your AI plan" : "Turn on AI with your Anthropic key",
                  systemImage: "sparkles").font(.title3.bold())
            Text(AISetupText.lead)
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            Text(AISetupText.destination(kind))
                .font(.callout.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("aiSetup.destination")
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text("The AI's document terms").font(.caption.weight(.semibold))
                    Text(kind.documentTerms).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("By allowing, you confirm: \(kind.documentAttestation).").font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("aiSetup.attestation")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 120, maxHeight: 200)
            .padding(6)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            Text(AISetupText.accuracy).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(AISetupText.turnsOn(regime: FeatureFlags.aiRegimeValue())).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 14) {
                Link("Privacy policy", destination: PurchaseLinks.privacy).font(.caption)
                Link("Terms", destination: PurchaseLinks.terms).font(.caption)
            }
            HStack {
                Button("Not now") { finish() }.keyboardShortcut(.cancelAction)
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button(AISetupText.allowButton) {
                    working = true
                    Task {
                        await appState.enableAIReading(kind)
                        working = false
                        finish()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(working)
                .accessibilityIdentifier("aiSetup.allow")
            }
        }
        .padding(16)
        .frame(width: 600)
        .accessibilityIdentifier("aiSetup.sheet")
    }

    private func finish() { onDone(); dismiss() }
}

/// The setup sheet's words (tested: they name the recipient, the relay and the once-per-case rule).
nonisolated enum AISetupText {
    static let allowButton = "Allow AI to read case documents you permit"
    static let lead = "To answer questions about a case, the AI reads that case's documents. Nothing is sent now. In each case you are asked once, with the list of documents that would go and the ones that never go (privileged material, protected identities); your questions in an allowed case are then sent without a further prompt. You can stop AI for one case in its case file, or switch to Private at any time."
    static let accuracy = "Every statement the AI makes is checked against the quote it cites before you see it. This version's accuracy has not been measured — check each answer against its source before relying on it."
    /// LN3 (Package B 2026-11-06) — exactly what the button changes: when the AI setting is “Fully private —
    /// no AI”, the setup also switches it to “AI · evidence-gated” (AISetup.ensureRegimeAllowsAI), and says so.
    static func turnsOn(regime: AIRegime) -> String {
        let base = "This turns on Online mode, “Use AI to write answers” and AI reading of case documents (Settings ▸ Modules), and records that you accepted the terms above."
        guard regime == .fullyPrivate else { return base + " Nothing else changes." }
        return base + " It also changes the AI setting from “\(AIRegime.fullyPrivate.label)” to “\(AIRegime.gated.label)” (Settings ▸ Modules ▸ AI), because no AI can answer while Fully private is on. Nothing else changes."
    }

    static func destination(_ kind: OnlineProviderKind) -> String {
        kind == .included
            ? "Where it goes: to Anthropic (Claude Opus 5.5) through the publisher's relay, which keeps only counts and credits, never content; recordings you choose to transcribe go to Google (Gemini). Charged in your plan's credits."
            : "Where it goes: directly to Anthropic (Claude) with your own key, billed to your Anthropic account. The publisher receives nothing."
    }
}

/// After Ask answered with search results: which setup step is missing, and the one button that fixes it.
struct AISetupPrompt: View {
    let cause: AISetupCause
    @State private var center = AISetupCenter.shared

    var body: some View {
        HStack(spacing: 8) {
            Label(cause.note + ". " + cause.remedy, systemImage: "sparkles")
                .font(.caption).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("aiSetup.prompt.\(cause.rawValue)")
            Spacer()
            if let title = cause.actionTitle {
                switch cause {
                case .creditsUsed:
                    if AIRegion.sellsAIProducts {
                        Menu(title) {
                            ForEach(PurchaseProducts.creditPacks, id: \.self) { id in
                                Button("\((PurchaseProducts.credits(inPack: id) ?? 0).formatted()) credits" + (PurchaseCenter.shared.packPrices[id].map { " (\($0))" } ?? "")) {
                                    Task { await PurchaseCenter.shared.buyCredits(id) }
                                }
                            }
                        }
                        .font(.caption).fixedSize()
                    }
                default:
                    Button(title) { act() }.font(.caption)
                        .accessibilityIdentifier("aiSetup.prompt.action")
                }
            }
            Button("Dismiss") { center.lastOfflineCause = nil }.font(.caption)
        }
        .padding(.horizontal, 12).padding(.vertical, 5)
        .background(Color.purple.opacity(0.10))
    }

    private func act() {
        switch cause {
        case .noPlanOrKey:
            PurchaseCenter.shared.paywallRequested = "use the AI plans"
        case .onlineOff, .aiSwitchOff, .termsNotAccepted:
            center.offer = AISetup.target(AISetup.snapshot()) ?? .included
        case .relayUnavailable:
            Task { await PurchaseCenter.shared.refreshAIStatus() }
        case .creditsUsed, .blockedStorefront:
            break
        }
    }
}
