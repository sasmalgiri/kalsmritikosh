//
//  CaseAccessLogSection.swift
//  Kalsmritikosh
//
//  ALCOA ALC-11 (owner 2026-11-24) — Case log ▸ Access log: who opened the case, an original or an export, made an
//  export, reviewed AI findings; when, in the recorder's time zone. Content-free. The case's exports are listed; opening
//  one's record is itself an access event ("viewed an export"). Small expressions on purpose (CI type-check budget).
//

import SwiftUI
import os

struct CaseAccessLogSection: View {
    @Environment(AppState.self) private var appState
    let caseID: UUID
    let actor: String
    @State private var entries: [CaseAccessLog.Entry] = []
    @State private var outputs: [CaseOutputRecord] = []
    @State private var shown: UUID?
    @State private var problem: String?

    var body: some View {
        CaseSection(title: "Access log", subtitle: "Who opened the case, an original or an export, made an export or reviewed AI findings — when, and in which time zone. Names and contents are never recorded here; it can't be edited and is erased with the case.") {
            if let problem { Text(problem).font(.caption).foregroundStyle(.orange) }
            exportsList
            ForEach(entries.reversed().prefix(300)) { e in
                Text(CaseAccessLog.line(e)).font(.caption).fixedSize(horizontal: false, vertical: true)
            }
        }
        .task { await load() }
    }

    @ViewBuilder private var exportsList: some View {
        if !outputs.isEmpty {
            Text("Exports made").font(.caption.bold())
            ForEach(outputs.prefix(50)) { o in exportRow(o) }
        }
    }

    private func exportRow(_ o: CaseOutputRecord) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("\(o.kind.rawValue) · \(o.route.rawValue) · \(CaseFileDocuments.t(o.releasedAt))").font(.caption)
                Button(shown == o.id ? "Hide" : "View record") { Task { await view(o) } }.controlSize(.small)
            }
            if shown == o.id { Text(recordLine(o)).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled) }
        }
    }

    private func recordLine(_ o: CaseOutputRecord) -> String {
        "Status \(o.status.rawValue) · by \(o.releasedBy) · snapshot SHA-256 \(o.snapshotSHA256.prefix(16))… · file SHA-256 \(o.fileSHA256.map { String($0.prefix(16)) + "…" } ?? "none")"
    }

    private func view(_ o: CaseOutputRecord) async {
        if shown == o.id { shown = nil; return }
        shown = o.id
        await CaseAccessLog.note(appState.database, caseID: caseID, kind: .exportViewed, subject: o.id, actor: actor)
        await load()
    }

    private func load() async {
        guard let db = appState.database else { return }
        do {
            entries = try await CaseAccessLog.events(db, caseID: caseID)
            outputs = try await appState.caseOutputs?.outputs(caseID: caseID) ?? []
            problem = nil
        } catch {
            KalsmritikoshLog.ui.error("Access log not read: \(error.localizedDescription, privacy: .private)")
            problem = "The access log could not be read (\(error.localizedDescription))."
        }
    }
}
