//
//  IssueChronologyView.swift
//  Kalsmritikosh
//
//  N-1 — the chronology by issue: create a matter's issues, tag dated events,
//  filter by issue, and export a cited statement of facts or deposition outline.
//

import SwiftUI
import UniformTypeIdentifiers
import os

extension AppState {
    public var caseIssues: CaseIssuesRepository? {
        guard ProductModuleFlags.isEnabled(.issueChronology), let database else { return nil }
        return CaseIssuesRepository(database: database)
    }

    /// Recent dated events with their source file names and issue names.
    public func chronology(limit: Int = 500) async -> [ChronologyEntry] {
        guard let events, let database, let issuesRepo = caseIssues else { return [] }
        let list = (try? await events.recent(limit: limit)) ?? []
        let ids = Set(list.map(\.sourceObjectID))
        var names: [UUID: String] = [:]
        if !ids.isEmpty {
            let marks = ids.map { _ in "?" }.joined(separator: ",")
            for r in (try? await database.query(
                "SELECT ko.id, f.url FROM knowledge_objects ko JOIN files f ON f.id = ko.file_id WHERE ko.id IN (\(marks));",
                ids.map { .uuid($0) })) ?? [] {
                if let id = r.uuid(0), let u = r.string(1) { names[id] = URL(string: u)?.lastPathComponent ?? u }
            }
        }
        var out: [ChronologyEntry] = []
        for e in list {
            let issues = ((try? await issuesRepo.issues(for: .event, e.id)) ?? []).map(\.name)
            out.append(ChronologyEntry(id: e.id, date: e.date, title: e.title, summary: e.summary,
                                       source: names[e.sourceObjectID] ?? "Document", issues: issues))
        }
        return out
    }
}

struct IssueChronologyView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var issues: [CaseIssue] = []
    @State private var entries: [ChronologyEntry] = []
    @State private var filter: String = ""
    @State private var newIssue = ""
    @State private var matter = "Matter"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Issues and chronology").font(.title3.bold())
            HStack {
                TextField("New issue (e.g. Breach of contract)", text: $newIssue).textFieldStyle(.roundedBorder)
                Button("Add issue") { Task { _ = try? await appState.caseIssues?.create(name: newIssue, description: nil); newIssue = ""; await load() } }
                    .disabled(newIssue.trimmingCharacters(in: .whitespaces).isEmpty)
                Picker("Show", selection: $filter) {
                    Text("All events").tag("")
                    ForEach(issues) { Text($0.name).tag($0.name) }
                }
                .frame(width: 220)
            }
            List(entries.filter { filter.isEmpty || $0.issues.contains(filter) }) { e in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(e.date.formatted(date: .abbreviated, time: .omitted)) — \(e.title)").font(.callout)
                        Text(e.source + (e.issues.isEmpty ? "" : " · " + e.issues.joined(separator: ", ")))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Menu("Issue") {
                        ForEach(issues) { issue in
                            if e.issues.contains(issue.name) {
                                Button("Remove “\(issue.name)”") { Task { try? await appState.caseIssues?.unlink(issue.id, .event, e.id); await load() } }
                            } else {
                                Button("Tag “\(issue.name)”") { Task { try? await appState.caseIssues?.link(issue.id, .event, e.id); await load() } }
                            }
                        }
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                }
            }
            .frame(minHeight: 320)
            HStack {
                TextField("Matter / witness name", text: $matter).textFieldStyle(.roundedBorder).frame(width: 220)
                Button("Export statement of facts…") {
                    save(ChronologyDrafter.statementOfFacts(shown, title: matter, byIssue: filter.isEmpty), name: "statement-of-facts.md")
                }
                Button("Export deposition outline…") {
                    save(ChronologyDrafter.depositionOutline(shown, witness: matter), name: "deposition-outline.md")
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(minWidth: 760, minHeight: 520)
        .task { await load() }
    }

    private var shown: [ChronologyEntry] { entries.filter { filter.isEmpty || $0.issues.contains(filter) } }

    private func load() async {
        issues = (try? await appState.caseIssues?.all()) ?? []
        entries = await appState.chronology()
    }

    private func save(_ text: String, name: String) {
        #if canImport(AppKit)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try Data(text.utf8).write(to: url, options: .atomic) }
        catch { KalsmritikoshLog.ui.error("Chronology export failed: \(error.localizedDescription, privacy: .public)") }
        #endif
    }
}
