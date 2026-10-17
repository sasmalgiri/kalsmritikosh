//
//  WhatIsMissingView.swift
//  Kalsmritikosh
//
//  I-2 — "What is missing": the gap layer (GapDetector → GapNodeRepository)
//  grouped by kind, each with the pattern that implies it, plus the gaps that
//  bear on a specific answer. Absence is always presented as an inference,
//  never as a fact; dismissing hides a gap but never deletes it.
//

import SwiftUI

extension AppState {
    /// Gaps tied to an answer: gaps on a cited document, or naming an entity the
    /// question or answer mentions. nil when the module is off.
    public func gaps(relevantTo answer: VerifiedAnswer, limit: Int = 5) async -> [GapNode]? {
        guard ProductModuleFlags.isEnabled(.gapMap), let gapNodes else { return nil }
        let all = await gapNodes.all()
        let cited = Set(answer.citations.map(\.objectID))
        let text = ((answer.resolvedQuestion ?? "") + " " + (answer.answerText ?? answer.body)).lowercased()
        let hits = all.filter { g in
            if let oid = g.evidenceObjectID, cited.contains(oid) { return true }
            if let e = g.nearEntity?.lowercased(), e.count >= 4, text.contains(e) { return true }
            return false
        }
        return Array(hits.prefix(limit))
    }
}

struct WhatIsMissingView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var gaps: [GapNode] = []
    @State private var loading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("What is missing").font(.title3.bold())
                Spacer()
                Button("Scan again") { Task { await appState.scanForGaps(); await load() } }
            }
            Text("Things your documents imply should exist but are not in the archive. Each is an inference from a pattern in your files, not a fact; dismissing one hides it but keeps it.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if loading {
                ProgressView().frame(maxWidth: .infinity)
            } else if gaps.isEmpty {
                Text("Nothing looks missing from the patterns found so far.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                let groups = Dictionary(grouping: gaps, by: \.kind)
                List {
                    ForEach(groups.keys.sorted { (groups[$0]?.count ?? 0) > (groups[$1]?.count ?? 0) }, id: \.self) { kind in
                        Section("\(kind.displayName) (\(groups[kind]?.count ?? 0))") {
                            ForEach(groups[kind] ?? []) { gap in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(gap.description).font(.callout)
                                    Text("Why: \(gap.reason)").font(.caption).foregroundStyle(.secondary)
                                    HStack(spacing: 10) {
                                        Text("Likelihood \(Int((gap.confidence * 100).rounded()))% — inferred")
                                            .font(.caption2).foregroundStyle(.tertiary)
                                        Button("Dismiss") {
                                            Task { await appState.gapNodes?.dismiss(gap.id); await load() }
                                        }
                                        .buttonStyle(.borderless).font(.caption2)
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                }
                .frame(minHeight: 320)
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(16)
        .frame(width: 560)
        .task { await load() }
    }

    private func load() async {
        loading = true
        gaps = await appState.gapNodes?.all() ?? []
        loading = false
    }
}
