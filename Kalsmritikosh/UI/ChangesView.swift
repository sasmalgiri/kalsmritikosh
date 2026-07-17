//
//  ChangesView.swift
//  Kalsmritikosh
//
//  Proactive change-monitoring surface: "since you last checked, here's what's
//  new or resolved." Turns the ledger into an agent that tells you when the
//  important things shift as documents arrive — new contradictions, new gaps,
//  and how many resolved. Mark reviewed to set a fresh baseline.
//

import SwiftUI

public struct ChangesView: View {
    @Environment(AppState.self) private var appState
    @State private var report: ChangeReport?
    @State private var loading = false

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if loading {
                ProgressView("Comparing against your last check…").frame(maxWidth: .infinity)
            } else if let report {
                content(report)
            }
            Spacer()
        }
        .padding(16)
        .navigationTitle("What Changed")
        .task { await reload() }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text("What changed").font(.title3.bold())
                Text("New and resolved contradictions and gaps since your last review. Run the scans in Insights first for the freshest picture.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button {
                Task { await reload() }
            } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .controlSize(.small)
        }
    }

    @ViewBuilder
    private func content(_ r: ChangeReport) -> some View {
        // Summary banner.
        HStack(spacing: 12) {
            Image(systemName: r.hasChanges ? "bell.badge.fill" : "checkmark.circle.fill")
                .font(.system(size: 26))
                .foregroundStyle(r.hasChanges ? Color.orange : .green)
            VStack(alignment: .leading, spacing: 2) {
                if !r.hasBaseline {
                    Text("First review — this becomes your baseline.").font(.headline)
                    Text("Mark reviewed, then next time you'll see only what's new.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if r.hasChanges {
                    Text("\(r.newContradictions.count) new conflict(s), \(r.newGaps.count) new gap(s)")
                        .font(.headline)
                    Text("Resolved since last check: \(r.resolvedContradictionCount) conflict(s), \(r.resolvedGapCount) gap(s)"
                         + (r.previousDate.map { " · last reviewed \($0.formatted(date: .abbreviated, time: .shortened))" } ?? ""))
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Nothing new since your last review.").font(.headline)
                    if let d = r.previousDate {
                        Text("Last reviewed \(d.formatted(date: .abbreviated, time: .shortened)).")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            Button {
                Task { await acknowledge(r) }
            } label: { Label("Mark reviewed", systemImage: "checkmark.seal") }
                .buttonStyle(.borderedProminent)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((r.hasChanges ? Color.orange : Color.green).opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 12))

        List {
            if !r.newContradictions.isEmpty {
                Section("New conflicts") {
                    ForEach(r.newContradictions, id: \.id) { c in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(c.description).font(.callout.weight(.medium))
                            Text(c.claimA).font(.caption).foregroundStyle(.secondary)
                            Text(c.claimB).font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 2)
                    }
                }
            }
            if !r.newGaps.isEmpty {
                Section("New gaps") {
                    ForEach(r.newGaps, id: \.id) { g in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: g.kind.systemImage).foregroundStyle(Theme.brand)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(g.kind.displayName).font(.callout.weight(.medium))
                                Text(g.description).font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 2)
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    private func reload() async {
        loading = true
        let r = await appState.changeDigest()
        await MainActor.run { report = r; loading = false }
    }

    private func acknowledge(_ r: ChangeReport) async {
        await appState.acknowledgeChanges(r)
        await reload()
    }
}
