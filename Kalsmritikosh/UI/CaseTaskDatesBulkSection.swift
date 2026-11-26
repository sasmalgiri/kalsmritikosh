//
//  CaseTaskDatesBulkSection.swift
//  Kalsmritikosh
//
//  Reachability recheck 2026-11-17 — the action services the Tasks section did not reach:
//  • ACTION-07: every date on an action says what it is — the investigator's target, a confirmed external deadline (only
//    with the authority that sets it) or a reminder — with its time zone; a template's proposed target says it is not set.
//  • ACTION-06: one change applied to several selected actions (reassign, defer, cancel, priority, or route by the rules),
//    each action reporting its own result; one failing does not stop the others.
//

import SwiftUI
import os

struct CaseTaskDatesBulkSection: View {
    @Environment(AppState.self) private var appState
    let model: CaseFileModel
    let tasks: [CaseTaskItem]
    @State private var dates: [UUID: [CaseActionDate]] = [:]
    @State private var dateTask: UUID?
    @State private var day = Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()
    @State private var basis: CaseDateBasis = .target
    @State private var authority = ""
    @State private var selected: Set<UUID> = []
    @State private var bulk: Bulk = .reassign
    @State private var who = ""
    @State private var reason = ""
    @State private var until = Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()
    @State private var priority: ProfessionalTaskPriority = .normal
    @State private var results: [CaseBulkItemResult] = []
    @State private var message: String?

    enum Bulk: String, CaseIterable, Identifiable { case reassign, deferUntil, cancel, priority, route
        var id: String { rawValue }
        var label: String {
            switch self {
            case .reassign: return "Reassign to"
            case .deferUntil: return "Defer until"
            case .cancel: return "Cancel"
            case .priority: return "Set priority"
            case .route: return "Route by the rules"
            }
        }
    }

    private var open: [CaseTaskItem] { tasks.filter { ![.completed, .cancelled].contains($0.task.status) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CaseSection(title: "Dates and what they are", subtitle: "A target is yours; an external deadline needs the notice, rule or order that sets it; nothing is inferred.") {
                ForEach(tasks) { t in
                    if let ds = dates[t.task.id], !ds.isEmpty {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(t.task.title).font(.caption.weight(.semibold))
                            ForEach(ds) { d in
                                Text("\(CaseFileDocuments.d(d.date)) (\(d.timeZone)) — \(d.label)" + (d.authority.map { " — set by \($0)" } ?? ""))
                                    .font(.caption).foregroundStyle(d.isProposal ? .secondary : .primary)
                            }
                        }
                    }
                }
                HStack {
                    Picker("Task", selection: $dateTask) {
                        Text("Choose a task").tag(UUID?.none)
                        ForEach(open) { t in Text(t.task.title).tag(Optional(t.task.id)) }
                    }
                    DatePicker("", selection: $day, displayedComponents: .date).labelsHidden()
                    Picker("Basis", selection: $basis) { ForEach(CaseDateBasis.allCases, id: \.self) { Text($0.label).tag($0) } }.frame(maxWidth: 300)
                }
                HStack {
                    if basis == .external { TextField("What sets it (notice, rule, order)", text: $authority) }
                    Spacer()
                    Button("Set the date") { Task { await setDate() } }.caseMapControlHelp("Set the date")
                        .disabled(reason: dateTask == nil ? "Choose a task." : (basis == .external && authority.trimmingCharacters(in: .whitespaces).isEmpty ? "Name what sets an external deadline." : nil))
                }
            }
            CaseSection(title: "Change several tasks at once", subtitle: "Each task reports its own result; one that cannot change does not stop the others.") {
                if open.isEmpty { Text("No open task.").foregroundStyle(.secondary) }
                ForEach(open) { t in
                    Toggle(t.task.title, isOn: Binding(get: { selected.contains(t.task.id) }, set: { if $0 { selected.insert(t.task.id) } else { selected.remove(t.task.id) } }))
                        .toggleStyle(.checkbox)
                }
                HStack {
                    Picker("Change", selection: $bulk) { ForEach(Bulk.allCases) { Text($0.label).tag($0) } }.frame(maxWidth: 220)
                    switch bulk {
                    case .reassign: TextField("Name", text: $who).frame(width: 140)
                    case .deferUntil: DatePicker("", selection: $until, displayedComponents: .date).labelsHidden()
                    case .priority: Picker("", selection: $priority) { ForEach(ProfessionalTaskPriority.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) } }.labelsHidden().frame(width: 110)
                    case .cancel, .route: EmptyView()
                    }
                    if [.reassign, .deferUntil, .cancel].contains(bulk) { TextField("Reason", text: $reason) }
                }
                Button("Apply to the selected tasks") { Task { await apply() } }.caseMapControlHelp("Apply to the selected tasks")
                    .disabled(reason: bulkBlocked)
                ForEach(results, id: \.taskID) { r in
                    Label("\(tasks.first { $0.task.id == r.taskID }?.task.title ?? "Task"): \(r.message)", systemImage: r.succeeded ? "checkmark.circle" : "xmark.circle")
                        .font(.caption).foregroundStyle(r.succeeded ? Color.primary : Color.red)
                }
            }
            if let message { Text(message).font(.caption).foregroundStyle(.red).padding(.horizontal) }
        }
        .task(id: tasks.map(\.task.id)) { await loadDates() }
    }

    private var bulkBlocked: String? {
        if selected.isEmpty { return "Select at least one task." }
        if bulk == .reassign, who.trimmingCharacters(in: .whitespaces).isEmpty { return "Name who takes them." }
        if [.reassign, .deferUntil, .cancel].contains(bulk), reason.trimmingCharacters(in: .whitespaces).isEmpty { return "Give the reason." }
        return nil
    }

    private func loadDates() async {
        guard let file = appState.caseFiles?.file else { return }
        var out: [UUID: [CaseActionDate]] = [:]
        do {
            for t in tasks { out[t.task.id] = try await file.actionDates(caseID: model.caseID, taskID: t.task.id) }
            dates = out
        } catch { KalsmritikoshLog.ui.error("Task dates not read: \(error.localizedDescription, privacy: .public)"); message = "Dates not read: \(error.localizedDescription)" }
    }
    private func setDate() async {
        guard let file = appState.caseFiles?.file, let t = dateTask else { return }
        do {
            _ = try await file.setActionDate(caseID: model.caseID, taskID: t, date: day, timeZone: .current, basis: basis,
                                             authority: basis == .external ? authority : nil, actor: model.actor)
            authority = ""; message = nil
            await loadDates()
        } catch { KalsmritikoshLog.ui.error("Task date not set: \(error.localizedDescription, privacy: .public)"); message = "Not set: \(error.localizedDescription)" }
    }
    private func apply() async {
        guard let svc = appState.caseFiles else { return }
        let op: CaseBulkActionOperation
        switch bulk {
        case .reassign: op = .reassign(to: who, reason: reason)
        case .deferUntil: op = .deferUntil(until, reason: reason)
        case .cancel: op = .cancel(reason: reason)
        case .priority: op = .setPriority(priority)
        case .route: op = .route
        }
        results = await svc.bulkActions(caseID: model.caseID, taskIDs: selected.sorted { $0.uuidString < $1.uuidString }, op, actor: model.actor)
        selected = []; reason = ""
        await model.load(appState)
    }
}
