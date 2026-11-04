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
            HStack(spacing: 14) {
                Text("\(request.documents.count) document\(request.documents.count == 1 ? "" : "s")").font(.caption.weight(.semibold))
                Text(ByteCountFormatter.string(fromByteCount: Int64(request.totalBytes), countStyle: .file)).font(.caption.monospacedDigit())
                Text("about \(request.estimatedTokens.formatted()) tokens").font(.caption.monospacedDigit())
            }
            Text(request.estimate).font(.caption).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(request.documents.enumerated()), id: \.offset) { _, item in
                        HStack {
                            Text(item.name).font(.caption).lineLimit(1)
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: Int64(item.bytes), countStyle: .file)).font(.caption2.monospacedDigit())
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
