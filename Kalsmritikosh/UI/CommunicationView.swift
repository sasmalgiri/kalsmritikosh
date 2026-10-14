//
//  CommunicationView.swift
//  Kalsmritikosh
//
//  N-2 — who talks to whom, email volume by month, and replies whose original
//  message is not in the archive.
//

import SwiftUI
import Charts

struct CommunicationView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var report: CommunicationReport?
    @State private var loading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Who talks to whom").font(.title3.bold())
            if loading {
                ProgressView().frame(maxWidth: .infinity)
            } else if let r = report {
                if !r.monthly.isEmpty {
                    Chart(r.monthly, id: \.month) { m in
                        BarMark(x: .value("Month", m.month), y: .value("Emails", m.count))
                    }
                    .frame(height: 140)
                    .accessibilityLabel("Emails per month")
                }
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading) {
                        Text("Most frequent sender → recipient").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        List(r.pairs) { p in
                            HStack { Text("\(p.from) → \(p.to)").lineLimit(1); Spacer(); Text("\(p.count)").monospacedDigit() }
                                .font(.caption)
                        }
                    }
                    VStack(alignment: .leading) {
                        Text("Replies whose original is missing (\(r.missingOriginals.count))").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        List(r.missingOriginals) { m in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(m.document).font(.caption)
                                Text("Replies to \(m.missingID), which is not in your archive").font(.caption2).foregroundStyle(.orange)
                            }
                        }
                    }
                }
                .frame(minHeight: 280)
            } else {
                Text("No email participants found yet.").foregroundStyle(.secondary)
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(16)
        .frame(minWidth: 760, minHeight: 520)
        .task { report = await appState.communicationReport(); loading = false }
    }
}
