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
        // Unified path IN-16 (owner 2026-11-22) — not tested yet: the case's documents go on the deep-study queue too.
        let queued = await appState.enqueueDeepStudy(caseID: caseID)
        notice = n == 0 && queued == 0
            ? "Nothing was studied: the app has no memory distiller ready, or nothing new was found for these people."
            : "\(n) person(s) studied or queued for deeper study" + (queued > 0 ? ", and \(queued) document(s) of the case queued for deep study in the background" : "")
                + ". Their distilled memory refreshes in Ask and the briefing."
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

/// Unified path AI-37 (owner 2026-11-22, round 2) — not tested yet. The case's kept AI suggestions on a screen.
struct CaseAISuggestionsTool: View {
    @Environment(AppState.self) private var appState
    let caseID: UUID
    @State private var state: CaseToolState = .loading
    @State private var kept: (body: String, items: Int, dropped: Int, at: Date)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CaseToolStateView(state: state)
            if let kept {
                Text("\(kept.items) suggestion(s) kept" + (kept.dropped > 0 ? ", \(kept.dropped) left out (they did not cite or quote the case's documents)" : "")
                     + " · \(kept.at.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
                Text(kept.body.replacingOccurrences(of: "## AI suggestions\n", with: ""))
                    .font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
        .task { await load() }
    }

    private func load() async {
        guard let db = appState.database else {
            state = .failed(reason: "the ledger isn't open yet.", next: "Wait for the case to finish opening, then reopen Case tools."); return
        }
        do {
            kept = try await CaseBriefingRepository(database: db).latestAISuggestions(caseID: caseID)
            state = kept == nil ? .empty(what: "No AI suggestions yet.", next: "Ask a question in this case with AI set up; the suggestions are made once per set of case documents, after the answer.") : .ready
        } catch {
            KalsmritikoshLog.ui.error("AI suggestions not read: \(error.localizedDescription, privacy: .public)")
            state = .failed(reason: error.localizedDescription, next: "Reopen Case tools.")
        }
    }
}

/// Unified path REASON-17 (owner 2026-11-22, round 2) — not tested yet. The scope ledger with a Stale badge.
struct CaseScopeCheckTool: View {
    @Environment(AppState.self) private var appState
    let caseID: UUID
    @State private var state: CaseToolState = .loading
    @State private var rows: [InvestigationAnswerService.ScopeArtifactStatus] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CaseToolStateView(state: state)
            if !rows.isEmpty {
                let stale = rows.filter(\.stale).count
                Text(stale == 0 ? "Everything below was made under the case's current scope." : "\(stale) of \(rows.count) item(s) were made under an earlier scope.")
                    .font(.headline)
                ForEach(rows) { r in
                    HStack {
                        Text(Self.label(r.kind)).font(.callout)
                        Text(String(r.artifactID.prefix(8))).font(.caption.monospaced()).foregroundStyle(.secondary)
                        Text(r.recordedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if r.stale {
                            Text("Stale").font(.caption2.weight(.semibold))
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Color.orange.opacity(0.18), in: Capsule()).foregroundStyle(.orange)
                                .help("Made before the case's documents or scope changed. Check it again before relying on it.")
                        }
                    }
                }
            }
        }
        .task { await load() }
    }

    static func label(_ k: InvestigationScopeArtifactKind) -> String {
        switch k {
        case .ask: return "Answer"
        case .methodRun: return "Method"
        case .workbenchDataset: return "Data set"
        case .workProduct: return "Work product"
        }
    }

    private func load() async {
        guard let answers = appState.investigationAnswers else {
            state = .failed(reason: "the ledger isn't open yet.", next: "Wait for the case to finish opening, then reopen Case tools."); return
        }
        do {
            rows = try await answers.scopeArtifactStatus(caseID: caseID).sorted { $0.recordedAt > $1.recordedAt }
            state = rows.isEmpty ? .empty(what: "Nothing has been made in this case yet.", next: "Ask a question or run a method; it appears here with its scope.") : .ready
        } catch {
            KalsmritikoshLog.ui.error("Scope check not read: \(error.localizedDescription, privacy: .public)")
            state = .failed(reason: error.localizedDescription, next: "Reopen Case tools.")
        }
    }
}
