//
//  CaseMapUnifiedTools.swift
//  Kalsmritikosh
//
//  Unified-path program S3 (owner 2026-11-22) — two Case tools that connect built-but-unused code:
//  "Study deeper" (AI-28, the on-demand Tier 3 deep study) and "Check against saved lists" (IN-20,
//  CaseEnrichment's local adapter). Not tested yet (owner 2026-11-22: implement now, test later).
//

import SwiftUI
import os

/// Unified path AI-28 (owner 2026-11-22) — not tested yet.
struct CaseStudyDeeperTool: View {
    @Environment(AppState.self) private var appState
    let caseID: UUID
    @State private var people: [CasePersonIdentityView] = []
    @State private var state: CaseToolState = .loading
    @State private var running = false
    @State private var notice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CaseToolStateView(state: state)
            if !people.isEmpty {
                Text("\(people.count) person(s) in the case").font(.headline)
                ForEach(people.prefix(25), id: \.person.id) { v in
                    Text(v.person.name).font(.callout)
                }
                Button(running ? "Studying…" : "Study these people deeper") { Task { await run() } }
                    .disabled(running)
                    .help("Rebuild what the app has distilled about each person from the documents, now.")
                    .accessibilityIdentifier("case.tools.studyDeeper.run")
            }
            if let notice { Text(notice).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
        .task { await load() }
    }

    private func load() async {
        guard let file = appState.caseFiles?.file else {
            state = .failed(reason: "the ledger isn't open yet.", next: "Wait for the case to finish opening, then reopen Case tools."); return
        }
        do {
            people = try await file.identityViews(caseID: caseID)
            state = people.isEmpty ? .empty(what: "No people are recorded in this case.", next: "Add people in People in the case, then come back.") : .ready
        } catch {
            KalsmritikoshLog.ui.error("Study deeper: people not read: \(error.localizedDescription, privacy: .public)")
            state = .failed(reason: error.localizedDescription, next: "Reopen Case tools.")
        }
    }

    private func run() async {
        running = true
        defer { running = false }
        let n = await appState.studyDeeper(subjects: people.map { (kind: .person, identifier: $0.person.name) },
                                           triggeringObjectID: nil)
        notice = n == 0
            ? "Nothing was studied: the app has no memory distiller ready, or nothing new was found for these people."
            : "\(n) person(s) studied or queued for deeper study. Their distilled memory refreshes in Ask and the briefing."
    }
}

/// Unified path IN-20 (owner 2026-11-22) — not tested yet.
struct CaseLocalEnrichmentTool: View {
    @Environment(AppState.self) private var appState
    let caseID: UUID
    @State private var people: [CasePersonIdentityView] = []
    @State private var state: CaseToolState = .loading
    @State private var results: [(name: String, result: CaseEnrichmentResult)] = []
    @State private var running = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CaseToolStateView(state: state)
            if !people.isEmpty {
                Button(running ? "Checking…" : "Check \(people.count) person(s) against the saved lists") { Task { await run() } }
                    .disabled(running)
                    .help("Match each name against the sanctions lists saved on this Mac. Nothing is sent.")
                    .accessibilityIdentifier("case.tools.enrichment.run")
            }
            ForEach(Array(results.enumerated()), id: \.offset) { _, r in
                VStack(alignment: .leading, spacing: 2) {
                    Text(r.name).font(.callout.weight(.semibold))
                    Text(r.result.summary).font(.caption).foregroundStyle(r.result.status == .matches ? .orange : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(Array(r.result.candidates.prefix(5).enumerated()), id: \.offset) { _, c in
                        Text("• \(c.label) — \(c.detail)\(c.exact ? "" : " (similar name)")").font(.caption2)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .task { await load() }
    }

    private func load() async {
        guard let file = appState.caseFiles?.file else {
            state = .failed(reason: "the ledger isn't open yet.", next: "Wait for the case to finish opening, then reopen Case tools."); return
        }
        do {
            people = try await file.identityViews(caseID: caseID)
            state = people.isEmpty ? .empty(what: "No people are recorded in this case.", next: "Add people in People in the case, then come back.") : .ready
        } catch {
            KalsmritikoshLog.ui.error("Local enrichment: people not read: \(error.localizedDescription, privacy: .public)")
            state = .failed(reason: error.localizedDescription, next: "Reopen Case tools.")
        }
    }

    private func run() async {
        running = true
        defer { running = false }
        var out: [(name: String, result: CaseEnrichmentResult)] = []
        for v in people.prefix(50) {
            out.append((v.person.name, await appState.localSanctionsCheck(v.person.name)))
        }
        results = out
    }
}
