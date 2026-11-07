//
//  CaseReadConsentSheet.swift
//  Kalsmritikosh
//
//  Plan A — the once-per-case AI permission sheet (see CaseReadConsent).
//

import SwiftUI

struct CaseReadConsentSheet: View {
    let request: CaseReadConsentRequest
    @State private var consent = CaseReadConsent.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Let the AI read this case?", systemImage: "doc.text.magnifyingglass").font(.title3.bold())
            Text(request.readsWhole
                 ? "To answer questions about this case, its documents below are sent to \(request.provider), which reads them and answers. Every statement it makes is checked against the documents before you see it. You are asked once for this case, and again only if its documents change."
                 : "This case is too large to read whole. For each question, the passages of the documents below most related to it are sent to \(request.provider). Every statement it makes is checked against the documents before you see it.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            // LS1 — the recipient company, the relay, the question rule and retention, on the permission screen.
            Text(AISetupText.destination(OnlineSettings.kind)).font(.caption.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("caseRead.destination")
            Text("Once you allow this case, your questions in it are sent without a further prompt. You can stop AI for this case at any time in its case file.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            // LS2 — the provider's terms are shown where the permission is asked.
            DisclosureGroup("The AI's terms: retention and use") {
                Text(OnlineSettings.kind.documentTerms).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption)
            // PS2 — the investigator is told the reader is unmeasured on this version.
            Text(AISetupText.accuracy).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 14) {
                Text("\(request.documents.count) document\(request.documents.count == 1 ? "" : "s")").font(.caption.weight(.semibold))
                Text(ByteCountFormatter.string(fromByteCount: Int64(request.totalBytes), countStyle: .file)).font(.caption.monospacedDigit())
                Text("about \(request.estimatedTokens.formatted()) tokens").font(.caption.monospacedDigit())
            }
            Text(request.estimate).font(.caption).fixedSize(horizontal: false, vertical: true)
            // Package B (P1-E) — what the plan has left, beside the estimate.
            if let balance = request.balance {
                Text(balance).font(.caption).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("caseRead.balance")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(request.documents.enumerated()), id: \.offset) { _, item in
                        HStack {
                            Text(item.name).font(.caption).lineLimit(1)
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: Int64(item.bytes), countStyle: .file)).font(.caption2.monospacedDigit())
                        }
                    }
                    // Package B (P0-A display) — what this Mac could not read is named, not silently left out.
                    if !request.notReadable.isEmpty {
                        Divider().padding(.vertical, 4)
                        Text("Not read, or read only in part, on this Mac (\(request.notReadable.count)) — what was not read cannot be sent").font(.caption.weight(.semibold))
                            .accessibilityIdentifier("caseRead.notReadable")
                        ForEach(Array(request.notReadable.enumerated()), id: \.offset) { _, item in
                            Text("\(item.name) — \(item.reason ?? "not read")").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if !request.excluded.isEmpty {
                        Divider().padding(.vertical, 4)
                        Text("Not sent (\(request.excluded.count))").font(.caption.weight(.semibold))
                        ForEach(Array(request.excluded.enumerated()), id: \.offset) { _, item in
                            Text("\(item.name) — \(item.reason ?? "withheld")").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 200)
            .padding(6)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            Text("Names and contact details are masked when masking is on; protected source identities never leave this Mac. Everything sent is recorded in Settings › Online.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Not now") { consent.resolve(allow: false) }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Allow for this case") { consent.resolve(allow: true) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 620)
    }
}
