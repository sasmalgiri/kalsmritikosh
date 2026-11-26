//
//  ArchiveQuestionConsentSheet.swift
//  Kalsmritikosh
//
//  AI split AI-49 — the once-per-question permission sheet of a question asked outside a case (ArchiveQuestionConsent):
//  what the AI may read, the document cap, the estimated cost; "Let the AI read" / "Not now" (search results only).
//  Small expressions on purpose (Xcode 26 CI type-check budget).
//

import SwiftUI

struct ArchiveQuestionConsentSheet: View {
    let request: ArchiveQuestionConsentRequest
    @State private var consent = ArchiveQuestionConsent.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Let the AI read documents for this question?", systemImage: "sparkles").font(.title3.bold())
            Text(request.question).font(.callout.italic()).lineLimit(3)
            explanation
            Text(AISetupText.destination(OnlineSettings.kind)).font(.caption.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            counts
            Text(request.estimate).font(.caption).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("archiveQuestion.estimate")
            footnote
            buttons
        }
        .padding(16)
        .frame(width: 560)
    }

    private var explanation: some View {
        Text("The AI may search your archive and read the documents it finds for this question, up to \(request.maxDocuments) documents. Privileged and restricted documents are never sent. You are asked once for this question; the AI's reading steps then run without asking again.")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private var counts: some View {
        HStack(spacing: 14) {
            Text("Up to \(request.maxDocuments) documents").font(.caption.weight(.semibold))
            Text("\(request.found) found so far").font(.caption.monospacedDigit())
            if request.withheld > 0 {
                Text("\(request.withheld) never sent (privileged or restricted)").font(.caption.monospacedDigit())
            }
        }
    }

    private var footnote: some View {
        Text("Names and contact details are masked when masking is on; protected source identities never leave this Mac. Exactly what is sent is recorded in Settings › Online. Not now shows the search results without AI.")
            .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private var buttons: some View {
        HStack {
            Button("Not now") { consent.resolve(allow: false) }.keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("archiveQuestion.notNow")
            Spacer()
            Button("Let the AI read") { consent.resolve(allow: true) }.keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("archiveQuestion.allow")
        }
    }
}
