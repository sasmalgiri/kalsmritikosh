//
//  ImportAIConsentSheet.swift
//  Kalsmritikosh
//
//  Unified path AI-36 (owner 2026-11-22, round 2) — not tested yet. The once-per-import AI permission sheet
//  (see ImportAIConsent): what the import's AI steps send, where, and the estimated cost; Use AI / Import
//  without AI.
//

import SwiftUI

struct ImportAIConsentSheet: View {
    let request: ImportAIConsentRequest
    @State private var consent = ImportAIConsent.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Use AI while importing?", systemImage: "sparkles").font(.title3.bold())
            Text("With AI, the text of the documents in this import is sent to \(request.provider) so it can label passages, write a first summary card, distil what the documents say and read recordings. Without AI, the documents are imported with the app's own rules only; you can still ask questions with AI later.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(AISetupText.destination(OnlineSettings.kind)).font(.caption.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 14) {
                Text("\(request.files.formatted())\(request.countCapped ? "+" : "") file\(request.files == 1 ? "" : "s")").font(.caption.weight(.semibold))
                Text(ByteCountFormatter.string(fromByteCount: request.bytes, countStyle: .file)).font(.caption.monospacedDigit())
                Text("about \(request.estimatedTokens.formatted()) tokens").font(.caption.monospacedDigit())
            }
            Text(request.estimate).font(.caption).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("importAI.estimate")
            Text("You are asked once for this import. Names and contact details are masked when masking is on; protected source identities never leave this Mac. Everything sent is recorded in Settings › Online.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Import without AI") { consent.resolve(allow: false) }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Use AI for this import") { consent.resolve(allow: true) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 560)
    }
}
