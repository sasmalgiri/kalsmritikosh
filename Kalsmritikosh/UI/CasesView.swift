//
//  CasesView.swift
//  Kalsmritikosh
//
//  Investigations Made Easy — the Cases screen (C-8 caseload over cases) and the new-case sheet
//  (C-2 typed intake, C-10 templates). Opening a case shows its case file (CaseFileView).
//

import SwiftUI
import UserNotifications
import os

public struct CasesView: View {
    @Environment(AppState.self) private var appState
    @State private var rows: [CaseloadRow] = []
    @State private var loading = true
    @State private var showClosed = false
    @State private var showNew = false
    @State private var open: CaseloadRow?
    @State private var search = ""

    public init() {}

    public var body: some View {
        Group {
            if let open {
                CaseFileView(caseID: open.caseID, workspaceID: open.workspaceID, onBack: {
                    self.open = nil
                    Task { await load() }
                })
            } else {
                list
            }
        }
        .navigationTitle(open?.title ?? "Cases")
        .sheet(isPresented: $showNew) {
            NewCaseSheet { created in
                showNew = false
                Task {
                    await load()
                    if let created { open = rows.first { $0.caseID == created } }
                }
            }
            .environment(appState)
        }
        .task { await load() }
    }

    private var visible: [CaseloadRow] {
        rows.filter { showClosed || $0.stage.isActive }
            .filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || ($0.owner ?? "").localizedCaseInsensitiveContains(search) }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Cases").font(.title2.bold())
                    Text("Every investigation from intake to closure — what needs you next is at the top.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                TextField("Filter", text: $search).textFieldStyle(.roundedBorder).frame(width: 180)
                Toggle("Show closed", isOn: $showClosed).toggleStyle(.checkbox)
                Button { showNew = true } label: { Label("New case", systemImage: "plus") }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            .padding(20)
            summary.padding(.horizontal, 20).padding(.bottom, 8)
            Divider()
            if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if visible.isEmpty {
                ContentUnavailableView {
                    Label(rows.isEmpty ? "No cases yet" : "No matching cases", systemImage: "folder.badge.plus")
                } description: {
                    Text(rows.isEmpty ? "Start a case: record how the matter came in, pick the kind of investigation, and the plan and tasks are set up for you." : "Change the filter or show closed cases.")
                } actions: {
                    if rows.isEmpty { Button("New case") { showNew = true }.buttonStyle(.borderedProminent) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(visible) {
                    TableColumn("Case") { r in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.title).fontWeight(.medium)
                            if let k = CaseTemplate.template(id: r.kind) { Text(k.title).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                        }
                    }
                    TableColumn("Stage") { r in StageChip(stage: r.stage) }.width(110)
                    TableColumn("Severity") { r in Text(r.severity?.label ?? "—").foregroundStyle(severityColor(r.severity)) }.width(80)
                    TableColumn("Owner") { r in Text(r.owner ?? "—") }.width(120)
                    TableColumn("Next due") { r in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.nextDue.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "—")
                                .foregroundStyle((r.nextDue ?? .distantFuture) < Date() ? .red : .primary)
                            if let t = r.nextTask { Text(t).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                        }
                    }.width(min: 140, ideal: 200)
                    TableColumn("Tasks") { r in
                        HStack(spacing: 4) {
                            Text("\(r.openTasks) open")
                            if r.overdueTasks > 0 { Text("\(r.overdueTasks) overdue").foregroundStyle(.red) }
                        }
                    }.width(130)
                    TableColumn("Age") { r in Text("\(r.ageDays(at: Date())) d") }.width(50)
                    TableColumn("") { r in
                        Button("Open") { open = r }.accessibilityLabel("Open \(r.title)")
                    }.width(60)
                }
                .contextMenu(forSelectionType: CaseloadRow.ID.self) { _ in } primaryAction: { ids in
                    if let id = ids.first { open = rows.first { $0.caseID == id } }
                }
            }
        }
    }

    private var summary: some View {
        let active = rows.filter { $0.stage.isActive }
        let overdue = active.reduce(0) { $0 + $1.overdueTasks }
        let retention = rows.filter { ($0.retainUntil ?? .distantFuture) <= Date() }.count
        return HStack(spacing: 18) {
            metric("\(active.count)", "active")
            metric("\(active.filter { $0.stage == .intake || $0.stage == .triage }.count)", "awaiting triage")
            metric("\(overdue)", "overdue tasks", overdue > 0 ? .red : .primary)
            metric("\(active.reduce(0) { $0 + $1.outstandingHolds })", "holds not acknowledged")
            if retention > 0 { metric("\(retention)", "due for retention review", .orange) }
            Spacer()
        }
    }

    private func metric(_ value: String, _ label: String, _ color: Color = .primary) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(value).font(.title3.monospacedDigit().bold()).foregroundStyle(color)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func severityColor(_ s: CaseSeverity?) -> Color {
        switch s { case .critical: return .red; case .high: return .orange; default: return .primary }
    }

    private func load() async {
        defer { loading = false }
        guard let svc = appState.caseFiles else { return }
        do {
            rows = try await svc.caseload(includeArchived: false)
        } catch {
            KalsmritikoshLog.app.error("Caseload failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

struct StageChip: View {
    let stage: CaseStage
    var body: some View {
        Text(stage.label)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
            .accessibilityLabel("Stage: \(stage.label)")
    }
    private var color: Color {
        switch stage {
        case .intake, .triage: return .purple
        case .open, .inProgress: return .blue
        case .onHold: return .orange
        case .findings: return .teal
        case .closed: return .secondary
        case .declined, .referred: return .gray
        }
    }
}

// MARK: - New case

struct NewCaseSheet: View {
    @Environment(AppState.self) private var appState
    let done: (UUID?) -> Void

    @State private var title = ""
    @State private var workspaces: [Workspace] = []
    @State private var workspaceID: UUID?
    @State private var templateID = "workplace"
    @State private var bringDocuments = true
    @State private var intake = CaseIntake(receivedAt: Date(), channel: .email)
    @State private var hasIncidentDate = false
    @State private var error: String?
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("New case").font(.title2.bold()).padding([.top, .horizontal], 20)
            Form {
                Section("The case") {
                    TextField("Title", text: $title, prompt: Text("e.g. Complaint against the night-shift supervisor"))
                    Picker("Kind of investigation", selection: $templateID) {
                        ForEach(CaseTemplate.all) { Text($0.title).tag($0.id) }
                    }
                    Picker("Workspace", selection: $workspaceID) {
                        Text("New workspace for this case").tag(UUID?.none)
                        ForEach(workspaces) { Text($0.title).tag(Optional($0.id)) }
                    }
                    if workspaceID != nil { Toggle("Bring the workspace's documents into the case", isOn: $bringDocuments) }
                }
                Section("How it came in") {
                    DatePicker("Received", selection: Binding(get: { intake.receivedAt ?? Date() }, set: { intake.receivedAt = $0 }), displayedComponents: .date)
                    Picker("Channel", selection: Binding(get: { intake.channel ?? .other }, set: { intake.channel = $0 })) {
                        ForEach(CaseIntakeChannel.allCases) { Text($0.label).tag($0) }
                    }
                    Toggle("Anonymous — store no identity for the person reporting", isOn: $intake.anonymous)
                    if !intake.anonymous {
                        TextField("Reported by", text: binding(\.complainant))
                        TextField("Their contact", text: binding(\.complainantContact))
                    }
                }
                Section("What was reported") {
                    TextField("Summary", text: binding(\.allegationSummary), axis: .vertical).lineLimit(3...6)
                    TextField("When it happened", text: binding(\.incidentDate), prompt: Text("e.g. 3 March 2026, or March–April 2026"))
                    TextField("Where", text: binding(\.incidentLocation))
                    TextField("People named", text: binding(\.peopleNamed))
                }
                if let t = CaseTemplate.template(id: templateID) {
                    Section("Set up for you") {
                        Text("\(t.tasks.count) tasks with due dates, a plan you can edit, and starter allegation wording. Nothing is decided for you.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { done(nil) }.keyboardShortcut(.cancelAction)
                Button("Create case") { Task { await create() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || working)
            }
            .padding(20)
        }
        .frame(width: 560, height: 680)
        .task {
            workspaces = (try? await appState.workspaces?.all(includeArchived: false)) ?? []
            workspaceID = workspaces.first?.id
        }
    }

    private func binding(_ kp: WritableKeyPath<CaseIntake, String?>) -> Binding<String> {
        Binding(get: { intake[keyPath: kp] ?? "" }, set: { intake[keyPath: kp] = $0.isEmpty ? nil : $0 })
    }

    private func create() async {
        guard let cases = appState.investigationCases, let svc = appState.caseFiles, let wsRepo = appState.workspaces else {
            error = "The ledger isn't ready yet."; return
        }
        working = true; defer { working = false }
        let actor = InvestigatorProfile.name
        let now = Date()
        do {
            var wsID = workspaceID
            if wsID == nil {
                let ws = Workspace(title: title.trimmingCharacters(in: .whitespaces))
                try await wsRepo.upsert(ws)
                wsID = ws.id
            }
            guard let wsID else { return }
            let c = try await cases.createCase(workspaceID: wsID, title: title, purpose: intake.allegationSummary, actor: actor, at: now)
            if bringDocuments, workspaceID != nil {
                _ = try await appState.investigationWorkspaceIntake?.includeWorkspaceSources(caseID: c.id, actor: actor, at: now)
            }
            var profile = try await svc.file.profile(caseID: c.id)
            profile.intake = intake
            profile.owner = actor
            try await svc.file.saveProfile(profile, actor: actor, at: now)
            if let t = CaseTemplate.template(id: templateID) {
                try await svc.applyTemplate(t, caseID: c.id, workspaceID: wsID, actor: actor, at: now)
            }
            try await svc.file.recordTriage(caseID: c.id, CaseTriage(), actor: actor, at: now)   // intake → triage
            await CaseReminders.schedule(svc: svc, caseID: c.id, caseTitle: c.title)
            done(c.id)
        } catch {
            KalsmritikoshLog.app.error("New case failed: \(error.localizedDescription, privacy: .public)")
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Reminders (C-6)

/// Local notifications for case tasks with a due date: one on the morning of the due day. Nothing
/// leaves the Mac; reminders are re-scheduled whenever the case's tasks change.
enum CaseReminders {
    static func schedule(svc: CaseFileService, caseID: UUID, caseTitle: String) async {
        let center = UNUserNotificationCenter.current()
        do {
            guard try await center.requestAuthorization(options: [.alert, .sound]) else { return }
        } catch {
            KalsmritikoshLog.app.error("Reminder permission failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        let items = (try? await svc.caseTasks(caseID: caseID)) ?? []
        let prefix = "case-\(caseID.uuidString)-"
        let pending = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(prefix) }
        center.removePendingNotificationRequests(withIdentifiers: pending)
        let cal = Calendar.current
        for item in items where [.open, .inProgress, .blocked].contains(item.task.status) {
            guard let due = item.deadline?.value.date, due > Date() else { continue }
            var when = cal.dateComponents([.year, .month, .day], from: due)
            when.hour = 9
            let content = UNMutableNotificationContent()
            content.title = "Due today: \(item.task.title)"
            content.body = caseTitle
            let request = UNNotificationRequest(identifier: prefix + item.task.id.uuidString, content: content,
                                                trigger: UNCalendarNotificationTrigger(dateMatching: when, repeats: false))
            do { try await center.add(request) } catch {
                KalsmritikoshLog.app.error("Reminder failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

// MARK: - Saving exports

@MainActor
enum CaseFileSave {
    /// What happened to a save: written (with the file's SHA-256), cancelled, or failed. Only a written
    /// file may be logged as an export (implementation brief §5/§6: a cancelled save was logged as a
    /// successful export).
    enum Outcome: Equatable {
        case saved(fileName: String, sha256: String)
        case cancelled
        case failed(String)
    }

    @discardableResult
    static func save(_ text: String, name: String, ext: String) -> Outcome {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(name.replacingOccurrences(of: "/", with: "-")).\(ext)"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return .cancelled }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            // The bytes on disk, read back: the export record names what was actually written.
            let written = try Data(contentsOf: url)
            return .saved(fileName: url.lastPathComponent, sha256: CaseFileHash.sha256(String(decoding: written, as: UTF8.self)))
        } catch {
            KalsmritikoshLog.app.error("Case export failed: \(error.localizedDescription, privacy: .public)")
            NSAlert(error: error).runModal()
            return .failed(error.localizedDescription)
        }
    }
}
