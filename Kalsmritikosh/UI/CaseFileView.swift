//
//  CaseFileView.swift
//  Kalsmritikosh
//
//  Investigations Made Easy — one case, intake to closure: overview (stage, triage, owner, intake,
//  conflict check, retention, close), plan & allegations (with the evidence grid and dispositions),
//  tasks & deadlines, people & interviews (statement, attestation, credibility), evidence (exhibits,
//  custody, holds, redactions, review batches), chronology & journal, and the case log with exports.
//  Every change goes through CaseFileRepository / CaseFileService and is recorded in the case log.
//

import SwiftUI
import os

@MainActor @Observable
final class CaseFileModel {
    let caseID: UUID
    let workspaceID: UUID
    var snapshot: CaseFileSnapshot?
    var labels: [UUID: String] = [:]
    /// What the case documents name and the amounts they state (each with its sentence).
    var named: StudioCaseFacts?
    var error: String?
    var busy = false
    /// The custody manifest could not be read: reports must not present an empty custody record.
    var custodyReadFailed = false
    /// Stored evidence references that no longer resolve in this case (brief §4 repair queue).
    var unresolvedRefs: [UnresolvedCaseReference] = []

    init(caseID: UUID, workspaceID: UUID) { self.caseID = caseID; self.workspaceID = workspaceID }

    var actor: String { InvestigatorProfile.name }

    func load(_ app: AppState) async {
        guard let svc = app.caseFiles else { error = "The ledger isn't ready yet."; return }
        do {
            // A custody read that fails is not an empty custody record (implementation brief §6): the
            // case still opens, but the custody report refuses and every report says it is incomplete.
            var custody: [CustodyManifestEntry] = []
            custodyReadFailed = false
            if let custodyService = app.investigationCustody {
                do { custody = try await custodyService.manifest(caseID: caseID) } catch {
                    custodyReadFailed = true
                    KalsmritikoshLog.app.error("Case custody read failed: \(String(describing: error), privacy: .public)")
                }
            } else {
                custodyReadFailed = true
            }
            snapshot = try await svc.snapshot(caseID: caseID, custody: custody)
            labels = try await svc.file.sourceLabels(custody.map(\.sourceVersionID))
            do { unresolvedRefs = try await svc.file.unresolvedReferences(caseID: caseID) } catch {
                KalsmritikoshLog.app.error("Case reference check failed: \(String(describing: error), privacy: .public)")
            }
            if named == nil, let title = snapshot?.caseHeader.title {   // read once: it scans every case document
                named = await app.studioCaseFacts(StudioCaseChoice(id: caseID, workspaceID: workspaceID, title: title), includePrivileged: false)
            }
        } catch {
            report(error)
        }
    }

    /// Run a change, then reload; errors are shown and logged.
    func run(_ app: AppState, _ body: @escaping (CaseFileService) async throws -> Void) {
        guard let svc = app.caseFiles else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await body(svc)
                error = nil
            } catch {
                report(error)
            }
            await load(app)
        }
    }

    func report(_ e: Error) {
        KalsmritikoshLog.app.error("Case file: \(e.localizedDescription, privacy: .public)")
        error = e.localizedDescription
    }

    /// Evidence the person can point at: exhibits first, then every source in scope.
    var evidenceChoices: [(ref: String, label: String)] {
        guard let s = snapshot else { return [] }
        let exhibits = s.exhibits.filter { $0.withdrawnAt == nil }.map { ($0.sourceRef ?? "exhibit:\($0.number)", "\($0.number) — \($0.description)") }
        let taken = Set(exhibits.map(\.0))
        let sources = s.custody.map { ($0.sourceVersionID.uuidString, labels[$0.sourceVersionID] ?? "Source \($0.sourceVersionID.uuidString.prefix(8))") }
            .filter { !taken.contains($0.0) }
        return exhibits + sources
    }

    func label(for ref: String?) -> String {
        guard let ref else { return "—" }
        if let e = snapshot?.exhibits.first(where: { $0.sourceRef == ref || "exhibit:\($0.number)" == ref }) { return "\(e.number) — \(e.description)" }
        if let id = UUID(uuidString: ref), let l = labels[id] { return l }
        return ref
    }
}

enum CaseFileTab: String, CaseIterable, Identifiable {
    case overview = "Overview", plan = "Plan & allegations", tasks = "Tasks", people = "People & interviews"
    case evidence = "Evidence", chronology = "Chronology & notes", log = "Log & exports"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .overview: return "doc.text.magnifyingglass"
        case .plan: return "list.bullet.clipboard"
        case .tasks: return "checklist"
        case .people: return "person.2"
        case .evidence: return "archivebox"
        case .chronology: return "calendar.day.timeline.left"
        case .log: return "square.and.arrow.up"
        }
    }
}

public struct CaseFileView: View {
    @Environment(AppState.self) private var appState
    @State private var model: CaseFileModel
    @State private var tab: CaseFileTab = .overview
    let onBack: () -> Void

    public init(caseID: UUID, workspaceID: UUID, onBack: @escaping () -> Void) {
        _model = State(initialValue: CaseFileModel(caseID: caseID, workspaceID: workspaceID))
        self.onBack = onBack
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Button(action: onBack) { Label("Cases", systemImage: "chevron.left") }
                    .buttonStyle(.borderless)
                    .keyboardShortcut("[", modifiers: .command)
                if let s = model.snapshot {
                    Text(s.caseHeader.title).font(.title3.bold()).lineLimit(1)
                    StageChip(stage: s.caseHeader.status == .closed ? .closed : s.profile.stage)
                }
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            Picker("Section", selection: $tab) {
                ForEach(CaseFileTab.allCases) { Label($0.rawValue, systemImage: $0.icon).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)
            if let e = model.error {
                Text(e).foregroundStyle(.red).font(.callout).padding(.horizontal, 20).padding(.top, 8)
            }
            Divider().padding(.top, 10)
            if let s = model.snapshot {
                ScrollView {
                    Group {
                        switch tab {
                        case .overview: CaseOverviewTab(model: model, s: s)
                        case .plan: CasePlanTab(model: model, s: s)
                        case .tasks: CaseTasksTab(model: model, s: s)
                        case .people: CasePeopleTab(model: model, s: s)
                        case .evidence: CaseEvidenceTab(model: model, s: s)
                        case .chronology: CaseChronologyTab(model: model, s: s)
                        case .log: CaseLogTab(model: model, s: s)
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: 980, alignment: .leading)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .environment(model)
        .task {
            await model.load(appState)
            try? await appState.caseFiles?.file.logAction(caseID: model.caseID, action: "viewed", detail: nil, actor: model.actor)
        }
    }
}

// MARK: - Shared bits

struct CaseSection<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        .padding(.bottom, 12)
    }
}

struct EvidencePicker: View {
    @Environment(CaseFileModel.self) private var model
    let title: String
    @Binding var ref: String
    var body: some View {
        Picker(title, selection: $ref) {
            Text("None").tag("")
            ForEach(model.evidenceChoices, id: \.ref) { Text($0.label).tag($0.ref) }
        }
    }
}

private func opt(_ s: String) -> String? {
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    return t.isEmpty ? nil : t
}

// MARK: - Overview

struct CaseOverviewTab: View {
    @Environment(AppState.self) private var appState
    let model: CaseFileModel
    let s: CaseFileSnapshot
    @State private var profile: CaseProfile?
    @State private var triage = CaseTriage()
    @State private var teamText = ""
    @State private var declared = ""
    @State private var waive = ""
    @State private var closeRationale = ""
    @State private var unresolved = ""
    @State private var stageReason = ""
    @State private var eraseReason = ""
    @State private var eraseBasis = ""
    @State private var eraseDocuments = false
    @State private var confirmErase = false
    @State private var eraseStatus: String?

    var body: some View {
        let closed = s.caseHeader.status == .closed
        let steps = CaseNextSteps.compute(s, unresolvedReferences: model.unresolvedRefs.count, custodyReadFailed: model.custodyReadFailed)
        VStack(alignment: .leading, spacing: 0) {
            if !steps.isEmpty {
                CaseSection(title: "Next steps", subtitle: "From what this case holds now. They suggest; you decide.") {
                    ForEach(steps.prefix(6)) { step in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: "arrow.right.circle").foregroundStyle(.tint).accessibilityHidden(true)
                            Text(step.text)
                            Spacer()
                            Text(Self.tabName(step.place)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if steps.count > 6 { Text("and \(steps.count - 6) more").font(.caption).foregroundStyle(.secondary) }
                }
            }
            CaseSection(title: "Stage", subtitle: "Move the case along. Closing is a recorded decision below.") {
                HStack {
                    StageChip(stage: closed ? .closed : s.profile.stage)
                    TextField("Reason (optional)", text: $stageReason).frame(maxWidth: 260)
                    ForEach(s.profile.stage.next) { next in
                        Button("Move to \(next.label)") {
                            let r = opt(stageReason)
                            model.run(appState) { try await $0.file.moveStage(caseID: model.caseID, to: next, reason: r, actor: model.actor) }
                            stageReason = ""
                        }
                    }
                }
            }
            CaseSection(title: "Triage", subtitle: "Rate it and decide whether to investigate. Declining or referring needs a reason.") {
                Picker("Severity", selection: $triage.severity) {
                    Text("Not rated").tag(CaseSeverity?.none)
                    ForEach(CaseSeverity.allCases) { Text($0.label).tag(Optional($0)) }
                }.frame(maxWidth: 300)
                TextField("Risk factors", text: Binding(get: { triage.riskNote ?? "" }, set: { triage.riskNote = opt($0) }), axis: .vertical)
                Picker("Decision", selection: $triage.decision) {
                    Text("Not decided").tag(CaseTriageDecision?.none)
                    ForEach(CaseTriageDecision.allCases) { Text($0.label).tag(Optional($0)) }
                }.frame(maxWidth: 300)
                TextField("Reason", text: Binding(get: { triage.reason ?? "" }, set: { triage.reason = opt($0) }))
                HStack {
                    if let by = s.profile.triage.decidedBy {
                        Text("Decided by \(by) on \(CaseFileDocuments.d(s.profile.triage.decidedAt))").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Record triage") {
                        let t = triage
                        model.run(appState) { try await $0.file.recordTriage(caseID: model.caseID, t, actor: model.actor) }
                    }
                }
            }
            if let binding = Binding($profile) {
                CaseSection(title: "Who is working on it") {
                    TextField("Owner", text: Binding(get: { binding.wrappedValue.owner ?? "" }, set: { binding.wrappedValue.owner = opt($0) }))
                    TextField("Team (comma-separated)", text: $teamText)
                    TextField("Reviewer", text: Binding(get: { binding.wrappedValue.reviewer ?? "" }, set: { binding.wrappedValue.reviewer = opt($0) }))
                }
                CaseSection(title: "Intake", subtitle: binding.wrappedValue.intake.anonymous ? "Anonymous intake: no identity is stored." : nil) {
                    DatePicker("Received", selection: Binding(get: { binding.wrappedValue.intake.receivedAt ?? s.caseHeader.createdAt },
                                                              set: { binding.wrappedValue.intake.receivedAt = $0 }), displayedComponents: .date)
                    Picker("Channel", selection: Binding(get: { binding.wrappedValue.intake.channel ?? .other }, set: { binding.wrappedValue.intake.channel = $0 })) {
                        ForEach(CaseIntakeChannel.allCases) { Text($0.label).tag($0) }
                    }.frame(maxWidth: 300)
                    Toggle("Anonymous", isOn: binding.intake.anonymous)
                    if !binding.wrappedValue.intake.anonymous {
                        field("Reported by", binding.intake.complainant)
                        field("Their contact", binding.intake.complainantContact)
                    }
                    field("What was reported", binding.intake.allegationSummary, multi: true)
                    field("When it happened", binding.intake.incidentDate)
                    field("Where", binding.intake.incidentLocation)
                    field("People named", binding.intake.peopleNamed)
                }
                CaseSection(title: "Retention", subtitle: "When the review date passes the case shows in Cases for review. Nothing is deleted automatically.") {
                    field("Policy", binding.retentionPolicy)
                    Toggle("Review date", isOn: Binding(get: { binding.wrappedValue.retainUntil != nil },
                                                         set: { binding.wrappedValue.retainUntil = $0 ? (Calendar.current.date(byAdding: .year, value: 6, to: Date()) ?? Date()) : nil }))
                    if binding.wrappedValue.retainUntil != nil {
                        DatePicker("Review on", selection: Binding(get: { binding.wrappedValue.retainUntil ?? Date() }, set: { binding.wrappedValue.retainUntil = $0 }), displayedComponents: .date)
                    }
                }
                HStack {
                    Spacer()
                    Button("Save") {
                        var p = binding.wrappedValue
                        p.team = teamText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                        let row = p
                        model.run(appState) { try await $0.file.saveProfile(row, actor: model.actor) }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("s", modifiers: .command)
                }
                .padding(.bottom, 12)
            }
            CaseSection(title: "Conflict-of-interest check",
                        subtitle: "Compares the investigator and anyone they declare a relationship with against the people in this case. A match is recorded; a person may waive it with a reason.") {
                TextField("Declared relationships (names, comma-separated)", text: $declared)
                TextField("Waiver reason (only if there is a match and it is acceptable)", text: $waive)
                HStack {
                    ForEach(s.conflicts.suffix(3)) { c in
                        Text("\(c.investigator): \(c.result.rawValue)\(c.matched.map { " (\($0))" } ?? "")").font(.caption)
                            .foregroundStyle(c.result == .conflict ? .red : .secondary)
                    }
                    Spacer()
                    Button("Run check for \(model.actor)") {
                        let names = declared.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                        let w = opt(waive)
                        model.run(appState) { _ = try await $0.file.runConflictCheck(caseID: model.caseID, investigator: model.actor, declaredRelationships: names, waiveNote: w, actor: model.actor) }
                    }
                }
            }
            CaseSection(title: closed ? "Reopen the case" : "Close the case",
                        subtitle: closed ? "Reopening is a new recorded decision; the closure stays in the record."
                                         : "A recorded decision with your reasons and anything left unresolved. It is sealed with the case scope.") {
                TextField(closed ? "Why reopen" : "Closing rationale", text: $closeRationale, axis: .vertical).lineLimit(2...5)
                if !closed {
                    TextField("Left unresolved (one per line)", text: $unresolved, axis: .vertical).lineLimit(1...4)
                    let pending = s.allegations.filter { $0.disposition == .pending }.count
                    if pending > 0 { Text("\(pending) allegation(s) have no disposition yet.").font(.caption).foregroundStyle(.orange) }
                }
                HStack {
                    Spacer()
                    Button(closed ? "Reopen" : "Close case") { closeOrReopen(closed) }
                        .disabled(closeRationale.trimmingCharacters(in: .whitespaces).isEmpty)
                    if closed, s.profile.archivedAt == nil {
                        Button("Archive") { model.run(appState) { try await $0.file.archive(caseID: model.caseID, actor: model.actor) } }
                    }
                }
            }
            CaseSection(title: "Erase this case",
                        subtitle: "Removes everything recorded for this case — its work, notes, results and history — and keeps only a record that it was erased (who, when, why; never the content). A legal hold refuses it. Documents another case or workspace uses are always kept.") {
                TextField("Why erase (required)", text: $eraseReason)
                TextField("Legal basis (optional)", text: $eraseBasis)
                Toggle("Also erase the documents only this case uses", isOn: $eraseDocuments)
                HStack {
                    if let eraseStatus { Text(eraseStatus).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Button("Erase case…", role: .destructive) { confirmErase = true }
                        .disabled(eraseReason.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .confirmationDialog("Erase this case permanently?", isPresented: $confirmErase) {
                Button("Erase", role: .destructive) {
                    let reason = eraseReason, basis = opt(eraseBasis), docs = eraseDocuments
                    Task {
                        do {
                            let out = try await appState.eraseCase(model.caseID, eraseExclusiveSources: docs, reason: reason,
                                                                   legalBasis: basis, actor: model.actor)
                            eraseStatus = out.summary
                        } catch { eraseStatus = error.localizedDescription }
                    }
                }
            } message: {
                Text(eraseDocuments ? "The case and the documents only it uses are removed. This cannot be undone."
                                    : "The case is removed; its documents stay in your library. This cannot be undone.")
            }
        }
        .onAppear { sync() }
        .onChange(of: s.profile) { sync() }
    }

    private func field(_ title: String, _ b: Binding<String?>, multi: Bool = false) -> some View {
        TextField(title, text: Binding(get: { b.wrappedValue ?? "" }, set: { b.wrappedValue = opt($0) }), axis: multi ? .vertical : .horizontal)
    }

    private func sync() {
        profile = s.profile
        triage = s.profile.triage
        teamText = s.profile.team.joined(separator: ", ")
    }

    static func tabName(_ place: CaseNextStep.Place) -> String {
        switch place {
        case .overview: return CaseFileTab.overview.rawValue
        case .plan: return CaseFileTab.plan.rawValue
        case .tasks: return CaseFileTab.tasks.rawValue
        case .people: return CaseFileTab.people.rawValue
        case .evidence: return CaseFileTab.evidence.rawValue
        case .log: return CaseFileTab.log.rawValue
        }
    }

    private func closeOrReopen(_ closed: Bool) {
        guard let closure = appState.investigationClosure else { return }
        let rationale = closeRationale, items = unresolved.split(separator: "\n").map(String.init)
        let caseID = model.caseID, actor = model.actor
        model.run(appState) { svc in
            guard let header = try await svc.caseHeader(caseID) else { throw CaseFileError.caseNotFound(caseID) }
            if closed {
                _ = try await closure.reopenCase(caseID: caseID, expectedRevision: header.revision, rationale: rationale, actor: actor, at: Date())
            } else {
                _ = try await closure.closeCase(caseID: caseID, expectedRevision: header.revision, rationale: rationale, unresolvedItems: items,
                                                workProductRunID: nil, receiptSeal: nil, actor: actor, at: Date())
            }
            try await svc.file.markClosed(caseID: caseID, reopened: closed, actor: actor)
        }
        closeRationale = ""; unresolved = ""
    }
}

// MARK: - Plan & allegations

struct CasePlanTab: View {
    @Environment(AppState.self) private var appState
    let model: CaseFileModel
    let s: CaseFileSnapshot
    @State private var plan = CasePlan()
    @State private var newAllegation = ""
    @State private var decisions: [UUID: (AllegationDisposition, String)] = [:]
    @State private var gridRef: [UUID: String] = [:]
    @State private var gridStance: [UUID: GridStance] = [:]
    @State private var gridNote: [UUID: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CaseSection(title: "Investigation plan", subtitle: "How the case will be run. Scope is on the case itself.") {
                planField("Method", \.method)
                planField("Evidence to collect", \.evidenceToCollect)
                planField("Interviews", \.interviewsToHold)
                planField("Notes", \.notes)
                HStack {
                    Menu("Apply a template") {
                        ForEach(CaseTemplate.all) { t in
                            Button(t.title) {
                                model.run(appState) { try await $0.applyTemplate(t, caseID: model.caseID, workspaceID: model.workspaceID, actor: model.actor) }
                            }
                        }
                    }.fixedSize()
                    Spacer()
                    Button("Save plan") {
                        var p = s.profile; p.plan = plan
                        let row = p
                        model.run(appState) { try await $0.file.saveProfile(row, actor: model.actor) }
                    }.buttonStyle(.borderedProminent)
                }
            }
            CaseSection(title: "Allegations", subtitle: "For each allegation, link the evidence that supports or contradicts it, then record your finding and why.") {
                HStack {
                    TextField("Add an allegation", text: $newAllegation)
                    Button("Add") {
                        let t = newAllegation
                        model.run(appState) { _ = try await $0.file.addAllegation(caseID: model.caseID, text: t, actor: model.actor) }
                        newAllegation = ""
                    }.disabled(newAllegation.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                ForEach(s.allegations) { a in allegationRow(a) }
            }
        }
        .onAppear { plan = s.profile.plan }
    }

    private func planField(_ title: String, _ kp: WritableKeyPath<CasePlan, String?>) -> some View {
        TextField(title, text: Binding(get: { plan[keyPath: kp] ?? "" }, set: { plan[keyPath: kp] = opt($0) }), axis: .vertical).lineLimit(1...6)
    }

    @ViewBuilder private func allegationRow(_ a: CaseAllegation) -> some View {
        let ev = s.grid.filter { $0.allegationID == a.id }
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(a.label).font(.headline.monospacedDigit())
                Text(a.text)
                Spacer()
                Text(a.disposition.label).font(.caption.bold())
                    .foregroundStyle(a.disposition == .substantiated ? .red : (a.disposition == .pending ? .secondary : .primary))
            }
            ForEach(GridStance.allCases) { st in
                let items = ev.filter { $0.stance == st }
                if !items.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(st.label) (\(items.count))").font(.caption.bold()).foregroundStyle(st == .supports ? .green : (st == .contradicts ? .red : .secondary))
                        ForEach(items) { e in
                            HStack {
                                Text("• \(e.label ?? model.label(for: e.evidenceRef))").font(.callout)
                                if let n = e.note { Text("— \(n)").font(.caption).foregroundStyle(.secondary) }
                                Spacer()
                                Button("Remove") {
                                    model.run(appState) { try await $0.file.retractAllegationEvidence(caseID: model.caseID, id: e.id, actor: model.actor) }
                                }.buttonStyle(.borderless).font(.caption)
                            }
                        }
                    }
                }
            }
            HStack {
                EvidencePicker(title: "Evidence", ref: Binding(get: { gridRef[a.id] ?? "" }, set: { gridRef[a.id] = $0 })).frame(maxWidth: 320)
                Picker("", selection: Binding(get: { gridStance[a.id] ?? .supports }, set: { gridStance[a.id] = $0 })) {
                    ForEach(GridStance.allCases) { Text($0.label).tag($0) }
                }.labelsHidden().frame(width: 120)
                TextField("Why", text: Binding(get: { gridNote[a.id] ?? "" }, set: { gridNote[a.id] = $0 }))
                Button("Link") {
                    let ref = gridRef[a.id] ?? "", st = gridStance[a.id] ?? .supports, note = opt(gridNote[a.id] ?? "")
                    let label = model.label(for: ref)
                    model.run(appState) { try await $0.file.addAllegationEvidence(caseID: model.caseID, allegationID: a.id, evidenceRef: ref, label: label, stance: st, note: note, actor: model.actor) }
                    gridRef[a.id] = ""; gridNote[a.id] = ""
                }.disabled((gridRef[a.id] ?? "").isEmpty)
            }
            HStack {
                Picker("Finding", selection: Binding(get: { decisions[a.id]?.0 ?? a.disposition }, set: { decisions[a.id] = ($0, decisions[a.id]?.1 ?? a.rationale ?? "") })) {
                    ForEach(AllegationDisposition.allCases) { Text($0.label).tag($0) }
                }.frame(maxWidth: 260)
                TextField("Rationale", text: Binding(get: { decisions[a.id]?.1 ?? a.rationale ?? "" }, set: { decisions[a.id] = (decisions[a.id]?.0 ?? a.disposition, $0) }))
                Button("Record finding") {
                    let d = decisions[a.id] ?? (a.disposition, a.rationale ?? "")
                    model.run(appState) { try await $0.file.decide(allegationID: a.id, caseID: model.caseID, disposition: d.0, rationale: d.1, actor: model.actor) }
                }
            }
            if let by = a.decidedBy { Text("Recorded by \(by) on \(CaseFileDocuments.d(a.decidedAt))").font(.caption).foregroundStyle(.secondary) }
            Divider()
        }
    }
}

// MARK: - Tasks

struct CaseTasksTab: View {
    @Environment(AppState.self) private var appState
    let model: CaseFileModel
    let s: CaseFileSnapshot
    @State private var title = ""
    @State private var assignee = ""
    @State private var hasDue = true
    @State private var due = Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()
    @State private var priority: ProfessionalTaskPriority = .normal

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CaseSection(title: "Add a task", subtitle: "Due dates become reminders on this Mac on the morning they are due.") {
                HStack {
                    TextField("Task", text: $title)
                    TextField("Assignee", text: $assignee).frame(width: 160)
                    Picker("", selection: $priority) { ForEach(ProfessionalTaskPriority.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) } }
                        .labelsHidden().frame(width: 100)
                }
                HStack {
                    Toggle("Due", isOn: $hasDue)
                    if hasDue { DatePicker("", selection: $due, displayedComponents: .date).labelsHidden() }
                    Spacer()
                    Button("Add task") {
                        let t = title, a = opt(assignee) ?? model.actor, d = hasDue ? due : nil, p = priority
                        let title = s.caseHeader.title
                        model.run(appState) { svc in
                            try await svc.addTask(caseID: model.caseID, workspaceID: model.workspaceID, title: t, priority: p, assignee: a, due: d, actor: model.actor)
                            await CaseReminders.schedule(svc: svc, caseID: model.caseID, caseTitle: title)
                        }
                        self.title = ""
                    }.buttonStyle(.borderedProminent).disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            CaseSection(title: "Tasks", subtitle: "\(s.tasks.filter { $0.task.status == .completed }.count) of \(s.tasks.count) done") {
                if s.tasks.isEmpty { Text("No tasks yet.").foregroundStyle(.secondary) }
                ForEach(s.tasks) { item in row(item) }
            }
        }
    }

    private func row(_ item: CaseTaskItem) -> some View {
        let done = item.task.status == .completed
        let overdue = item.isOverdue(at: Date())
        return HStack {
            Button {
                let id = item.task.id
                model.run(appState) { svc in
                    if done { try await svc.reopenTask(caseID: model.caseID, taskID: id, actor: model.actor) }
                    else { try await svc.completeTask(caseID: model.caseID, taskID: id, actor: model.actor) }
                }
            } label: { Image(systemName: done ? "checkmark.circle.fill" : "circle") }
                .buttonStyle(.borderless)
                .accessibilityLabel(done ? "Mark \(item.task.title) not done" : "Mark \(item.task.title) done")
            VStack(alignment: .leading, spacing: 2) {
                Text(item.task.title).strikethrough(done)
                HStack(spacing: 8) {
                    if let d = item.deadline { Text("Due \(CaseFileDocuments.d(d.value.date))").foregroundStyle(overdue ? .red : .secondary) }
                    if overdue { Text("Overdue").bold().foregroundStyle(.red) }
                    if let o = item.task.owner { Text(o).foregroundStyle(.secondary) }
                    if item.task.priority == .high || item.task.priority == .critical { Text(item.task.priority.rawValue.capitalized).foregroundStyle(.orange) }
                }.font(.caption)
            }
            Spacer()
            if !done {
                Menu("Due") {
                    ForEach([1, 3, 7, 14, 30], id: \.self) { days in
                        Button("In \(days) day\(days == 1 ? "" : "s")") {
                            let id = item.task.id, when = Calendar.current.date(byAdding: .day, value: days, to: Date()) ?? Date()
                            let title = s.caseHeader.title
                            model.run(appState) { svc in
                                try await svc.setDue(caseID: model.caseID, taskID: id, due: when, actor: model.actor)
                                await CaseReminders.schedule(svc: svc, caseID: model.caseID, caseTitle: title)
                            }
                        }
                    }
                }.fixedSize()
                Menu("Status") {
                    ForEach([ProfessionalTaskStatus.open, .inProgress, .blocked, .cancelled], id: \.self) { st in
                        Button(st.rawValue.capitalized) {
                            let id = item.task.id
                            model.run(appState) { try await $0.setTaskStatus(caseID: model.caseID, taskID: id, to: st, actor: model.actor) }
                        }.disabled(st == item.task.status)
                    }
                }.fixedSize()
            }
        }
    }
}

// MARK: - People & interviews

struct CasePeopleTab: View {
    @Environment(AppState.self) private var appState
    let model: CaseFileModel
    let s: CaseFileSnapshot
    @State private var name = ""
    @State private var role: CasePersonRole = .witness
    @State private var contact = ""
    @State private var contactPerson: UUID?
    @State private var contactMode = "Phone"
    @State private var contactNote = ""
    @State private var editing: CaseInterview?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CaseSection(title: "People in the case") {
                HStack {
                    TextField("Name", text: $name)
                    Picker("", selection: $role) { ForEach(CasePersonRole.allCases) { Text($0.label).tag($0) } }.labelsHidden().frame(width: 130)
                    TextField("Contact", text: $contact).frame(width: 180)
                    Button("Add") {
                        let n = name, r = role, c = opt(contact)
                        model.run(appState) { _ = try await $0.file.addPerson(caseID: model.caseID, name: n, role: r, entityID: nil, contact: c, notes: nil, actor: model.actor) }
                        name = ""; contact = ""
                    }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                ForEach(CasePersonRole.allCases) { r in
                    let ppl = s.people.filter { $0.role == r }
                    if !ppl.isEmpty {
                        Text(r.label + (ppl.count > 1 ? "s" : "")).font(.caption.bold()).foregroundStyle(.secondary)
                        ForEach(ppl) { p in
                            HStack {
                                Text(p.name)
                                if let c = p.contact { Text(c).font(.caption).foregroundStyle(.secondary) }
                                let n = s.contacts.filter { $0.personID == p.id }.count
                                if n > 0 { Text("\(n) contact(s)").font(.caption).foregroundStyle(.secondary) }
                                Spacer()
                                Button("Plan interview") {
                                    let pid = p.id
                                    model.run(appState) { _ = try await $0.file.addInterview(caseID: model.caseID, personID: pid, questions: nil, actor: model.actor) }
                                }.buttonStyle(.borderless)
                                Button("Remove") {
                                    let pid = p.id
                                    model.run(appState) { try await $0.file.retractPerson(caseID: model.caseID, id: pid, actor: model.actor) }
                                }.buttonStyle(.borderless).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            if let named = model.named?.named, !named.isEmpty {
                CaseSection(title: "Named in the case documents", subtitle: "People and organisations the documents name. Add the ones who matter, in the role you decide.") {
                    let have = Set(s.people.map { $0.name.lowercased() })
                    ForEach(named, id: \.value) { n in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(n.value)
                                if let q = n.refs.first?.quote { Text("\u{201C}\(q.prefix(160))\u{201D}").font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            if have.contains(n.value.lowercased()) {
                                Text("In the case").font(.caption).foregroundStyle(.secondary)
                            } else {
                                Menu("Add as…") {
                                    ForEach(CasePersonRole.allCases) { r in
                                        Button(r.label) {
                                            let name = n.value
                                            model.run(appState) { _ = try await $0.file.addPerson(caseID: model.caseID, name: name, role: r, entityID: nil, contact: nil, notes: nil, actor: model.actor) }
                                        }
                                    }
                                }.fixedSize()
                            }
                        }
                    }
                }
            }
            CaseSection(title: "Contact log", subtitle: "Every attempt to reach a person, with when and how.") {
                HStack {
                    Picker("Person", selection: $contactPerson) {
                        Text("Choose").tag(UUID?.none)
                        ForEach(s.people) { Text($0.name).tag(Optional($0.id)) }
                    }.frame(maxWidth: 240)
                    TextField("How", text: $contactMode).frame(width: 110)
                    TextField("Note", text: $contactNote)
                    Button("Log") {
                        guard let pid = contactPerson else { return }
                        let m = contactMode, n = opt(contactNote)
                        model.run(appState) { try await $0.file.addContact(caseID: model.caseID, personID: pid, at: Date(), mode: m, note: n, actor: model.actor) }
                        contactNote = ""
                    }.disabled(contactPerson == nil)
                }
                ForEach(s.contacts.suffix(10).reversed()) { c in
                    Text("\(CaseFileDocuments.t(c.at)) · \(s.person(c.personID)?.name ?? "—") · \(c.mode)\(c.note.map { " — \($0)" } ?? "")").font(.caption)
                }
            }
            CaseSection(title: "Interviews", subtitle: "Plan → schedule → hold → summarise → statement confirmed by the interviewee.") {
                if s.interviews.isEmpty { Text("No interviews yet — plan one from a person above.").foregroundStyle(.secondary) }
                ForEach(s.interviews) { iv in
                    HStack {
                        Text(s.person(iv.personID)?.name ?? "Interview")
                        Text(iv.status.label).font(.caption.bold())
                        if let d = iv.scheduledAt { Text(CaseFileDocuments.t(d)).font(.caption).foregroundStyle(.secondary) }
                        if iv.status == .attested && !iv.statementIntact { Text("Statement changed after attestation").font(.caption).foregroundStyle(.red) }
                        Spacer()
                        Button("Open") { editing = iv }
                    }
                }
            }
        }
        .sheet(item: $editing) { iv in
            InterviewEditor(model: model, s: s, interview: iv) { editing = nil }.environment(appState)
        }
    }
}

struct InterviewEditor: View {
    @Environment(AppState.self) private var appState
    let model: CaseFileModel
    let s: CaseFileSnapshot
    @State var interview: CaseInterview
    let done: () -> Void
    @State private var attestedBy = ""
    @State private var correction = ""
    @State private var correctionReason = ""
    @State private var correctionConfirmedBy = ""
    @State private var factor: CredibilityFactor = .consistency
    @State private var assessment: CredibilityAssessment = .neutral
    @State private var credNote = ""
    @State private var credRef = ""

    var body: some View {
        let attested = interview.status == .attested
        VStack(alignment: .leading, spacing: 0) {
            Text("Interview — \(s.person(interview.personID)?.name ?? "")").font(.title3.bold()).padding(20)
            Form {
                Section("Arrangements") {
                    Picker("Status", selection: $interview.status) {
                        ForEach(InterviewStatus.allCases.filter { $0 != .attested || attested }) { Text($0.label).tag($0) }
                    }.disabled(attested)
                    DatePicker("When", selection: Binding(get: { interview.scheduledAt ?? Date() }, set: { interview.scheduledAt = $0 }))
                        .disabled(attested)
                    TextField("How (in person, video, phone)", text: str(\.mode)).disabled(attested)
                    TextField("Where", text: str(\.location)).disabled(attested)
                    TextField("Questions", text: str(\.questions), axis: .vertical).lineLimit(3...10)
                }
                Section("Recording and transcript") {
                    EvidencePicker(title: "Recording", ref: str(\.recordingRef)).disabled(attested)
                    EvidencePicker(title: "Transcript", ref: str(\.transcriptRef)).disabled(attested)
                    Text("Add the recording to the case's sources; its transcript is made on this Mac and can be chosen here.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Summary") {
                    TextField("What was said, in your words", text: str(\.summary), axis: .vertical).lineLimit(3...12)
                }
                Section(attested ? "Statement (confirmed — can't be changed)" : "Statement") {
                    TextField("The interviewee's statement", text: str(\.statementText), axis: .vertical).lineLimit(4...20).disabled(attested)
                    if attested {
                        Text("Confirmed by \(interview.attestedBy ?? "") on \(CaseFileDocuments.t(interview.attestedAt))").font(.caption)
                        Text(interview.statementIntact ? "Text matches the confirmed fingerprint." : "The text no longer matches the confirmed fingerprint.")
                            .font(.caption).foregroundStyle(interview.statementIntact ? .green : .red)
                    } else {
                        HStack {
                            TextField("Confirmed by (interviewee's name)", text: $attestedBy)
                            Button("Record confirmation") {
                                let iv = interview, by = attestedBy
                                model.run(appState) { svc in
                                    try await svc.file.updateInterview(iv, actor: model.actor)
                                    try await svc.file.attest(interviewID: iv.id, caseID: model.caseID, attestedBy: by, actor: model.actor)
                                }
                                done()
                            }.disabled(attestedBy.trimmingCharacters(in: .whitespaces).isEmpty || (interview.statementText ?? "").isEmpty)
                        }
                    }
                    Button("Export statement for signature…") {
                        CaseFileSave.save(CaseFileDocuments.statement(s, interview: interview, by: model.actor), name: "Statement - \(s.person(interview.personID)?.name ?? "interview")", ext: "md")
                    }
                }
                if attested {
                    Section("Corrections") {
                        let mine = s.addenda.filter { $0.interviewID == interview.id }
                        if mine.isEmpty {
                            Text("A confirmed statement is never edited. If the interviewee corrects it, record the correction here; it is kept with the statement, in order.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(mine) { a in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(a.text).font(.callout)
                                Text("Reason: \(a.reason) · recorded \(CaseFileDocuments.t(a.recordedAt)) by \(a.recordedBy)").font(.caption).foregroundStyle(.secondary)
                                if let at = a.confirmedAt {
                                    Text("Confirmed by \(a.confirmedBy ?? "") on \(CaseFileDocuments.t(at))").font(.caption)
                                } else {
                                    HStack {
                                        TextField("Confirmed by (interviewee's name)", text: $correctionConfirmedBy)
                                        Button("Record confirmation") {
                                            let id = a.id, by = correctionConfirmedBy
                                            model.run(appState) { try await $0.file.confirmAddendum(caseID: model.caseID, id: id, confirmedBy: by, actor: model.actor) }
                                            correctionConfirmedBy = ""
                                        }.disabled(correctionConfirmedBy.trimmingCharacters(in: .whitespaces).isEmpty)
                                    }
                                }
                            }
                        }
                        TextField("The correction, in the interviewee's words", text: $correction, axis: .vertical).lineLimit(2...8)
                        TextField("Why it is being corrected", text: $correctionReason)
                        Button("Add correction") {
                            let id = interview.id, text = correction, why = correctionReason
                            model.run(appState) { try await $0.file.addStatementAddendum(caseID: model.caseID, interviewID: id, text: text, reason: why, actor: model.actor) }
                            correction = ""; correctionReason = ""
                        }.disabled(correction.trimmingCharacters(in: .whitespaces).isEmpty || correctionReason.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                Section("Credibility", content: {
                    ForEach(s.credibility.filter { $0.interviewID == interview.id }) { c in
                        Text("\(c.factor.label): \(c.assessment.label)\(c.note.map { " — \($0)" } ?? "")").font(.callout)
                    }
                    Picker("Factor", selection: $factor) { ForEach(CredibilityFactor.allCases) { Text($0.label).tag($0) } }
                    Text(factor.prompt).font(.caption).foregroundStyle(.secondary)
                    Picker("Assessment", selection: $assessment) { ForEach(CredibilityAssessment.allCases) { Text($0.label).tag($0) } }
                    TextField("Note", text: $credNote)
                    EvidencePicker(title: "Evidence", ref: $credRef)
                    Button("Add credibility note") {
                        let f = factor, a = assessment, n = opt(credNote), r = opt(credRef), id = interview.id
                        model.run(appState) { try await $0.file.addCredibility(caseID: model.caseID, interviewID: id, factor: f, assessment: a, note: n, evidenceRef: r, actor: model.actor) }
                        credNote = ""
                    }
                })
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Close") { done() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    let iv = interview
                    model.run(appState) { try await $0.file.updateInterview(iv, actor: model.actor) }
                    done()
                }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }.padding(20)
        }
        .frame(width: 640, height: 760)
    }

    private func str(_ kp: WritableKeyPath<CaseInterview, String?>) -> Binding<String> {
        Binding(get: { interview[keyPath: kp] ?? "" }, set: { interview[keyPath: kp] = opt($0) })
    }
}

// MARK: - Evidence

struct CaseEvidenceTab: View {
    @Environment(AppState.self) private var appState
    let model: CaseFileModel
    let s: CaseFileSnapshot
    @State private var exDesc = ""
    @State private var exWhere = ""
    @State private var custodian = ""
    @State private var noticeText = ""
    @State private var redDoc = ""
    @State private var redWhere = ""
    @State private var redWhy = ""
    @State private var batchSize = 50

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !model.unresolvedRefs.isEmpty {
                CaseSection(title: "References to repair",
                            subtitle: "\(model.unresolvedRefs.count) piece(s) of evidence in this case point at something that isn't a source, exhibit or note of this case. They are kept as written; relink or retract each one.") {
                    ForEach(model.unresolvedRefs) { u in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(u.record): “\(model.label(for: u.ref))”").lineLimit(2)
                            Text(u.problem.prefix(1).uppercased() + u.problem.dropFirst() + ".").font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
            }
            CaseSection(title: "Sources in the case", subtitle: "\(s.custody.count) document(s) in scope, each with its content fingerprint.") {
                ForEach(s.custody.prefix(200), id: \.sourceVersionID) { e in
                    let ref = e.sourceVersionID.uuidString
                    let ex = s.exhibits.first { $0.sourceRef == ref && $0.withdrawnAt == nil }
                    HStack {
                        Text(model.labels[e.sourceVersionID] ?? ref).lineLimit(1)
                        Spacer()
                        if let ex { Text(ex.number).font(.caption.bold()) } else {
                            Button("Register as exhibit") {
                                let label = model.labels[e.sourceVersionID] ?? "Document", hash = e.contentHash
                                model.run(appState) { _ = try await $0.file.addExhibit(caseID: model.caseID, number: nil, description: label, sourceRef: ref, sha256: hash, collectedBy: model.actor, collectedAt: Date(), collectedWhere: nil, actor: model.actor) }
                            }.buttonStyle(.borderless)
                        }
                    }
                }
                if s.custody.count > 200 { Text("…and \(s.custody.count - 200) more").font(.caption).foregroundStyle(.secondary) }
            }
            CaseSection(title: "Exhibit register") {
                HStack {
                    TextField("Physical or other exhibit (description)", text: $exDesc)
                    TextField("Collected where", text: $exWhere).frame(width: 180)
                    Button("Register") {
                        let d = exDesc, w = opt(exWhere)
                        model.run(appState) { _ = try await $0.file.addExhibit(caseID: model.caseID, number: nil, description: d, sourceRef: nil, sha256: nil, collectedBy: model.actor, collectedAt: Date(), collectedWhere: w, actor: model.actor) }
                        exDesc = ""; exWhere = ""
                    }.disabled(exDesc.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                ForEach(s.exhibits) { e in
                    HStack {
                        Text(e.number).font(.callout.monospaced().bold())
                        Text(e.description).strikethrough(e.withdrawnAt != nil)
                        if let w = e.collectedWhere { Text(w).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        if e.withdrawnAt == nil {
                            Button("Withdraw") {
                                let id = e.id
                                model.run(appState) { try await $0.file.withdrawExhibit(caseID: model.caseID, id: id, actor: model.actor) }
                            }.buttonStyle(.borderless).foregroundStyle(.secondary)
                        }
                    }
                }
                HStack {
                    Spacer()
                    Button("Export exhibit list…") { CaseFileSave.save(CaseFileDocuments.exhibitListCSV(s), name: "Exhibits - \(s.caseHeader.title)", ext: "csv") }
                    Button("Export custody report…") { CaseFileSave.save(CaseFileDocuments.custodyReport(s, by: model.actor), name: "Custody - \(s.caseHeader.title)", ext: "md") }
                        .disabled(model.custodyReadFailed)
                        .help(model.custodyReadFailed ? "The custody record could not be read." : "")
                }
            }
            CaseSection(title: "Preservation (hold) notices", subtitle: "Issue a notice per custodian, record when they acknowledge, release it when the matter ends.") {
                HStack {
                    TextField("Custodian", text: $custodian)
                    Button("Draft notice") {
                        noticeText = CaseFileDocuments.holdNoticeTemplate(caseTitle: s.caseHeader.title, custodian: custodian, organisation: InvestigatorProfile.organisation, issuer: model.actor)
                    }.disabled(custodian.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if !noticeText.isEmpty {
                    TextEditor(text: $noticeText).font(.callout).frame(minHeight: 180)
                    HStack {
                        Spacer()
                        Button("Save notice to send…") { CaseFileSave.save(noticeText, name: "Preservation notice - \(custodian)", ext: "txt") }
                        Button("Record as issued") {
                            let c = custodian, t = noticeText, rem = Calendar.current.date(byAdding: .day, value: 7, to: Date())
                            let pid = s.people.first { $0.name.caseInsensitiveCompare(c) == .orderedSame }?.id
                            model.run(appState) { try await $0.file.issueHold(caseID: model.caseID, custodian: c, personID: pid, noticeText: t, reminderDue: rem, actor: model.actor) }
                            noticeText = ""; custodian = ""
                        }.buttonStyle(.borderedProminent)
                    }
                }
                ForEach(s.holds) { h in
                    HStack {
                        Text(h.custodian)
                        Text("issued \(CaseFileDocuments.d(h.issuedAt))").font(.caption).foregroundStyle(.secondary)
                        if let a = h.acknowledgedAt { Text("acknowledged \(CaseFileDocuments.d(a))").font(.caption).foregroundStyle(.green) }
                        else if h.releasedAt == nil { Text("not acknowledged").font(.caption).foregroundStyle(.orange) }
                        if let r = h.releasedAt { Text("released \(CaseFileDocuments.d(r))").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        if h.acknowledgedAt == nil && h.releasedAt == nil {
                            Button("Acknowledged") {
                                let id = h.id
                                model.run(appState) { try await $0.file.acknowledgeHold(caseID: model.caseID, id: id, acknowledgedAt: Date(), actor: model.actor) }
                            }.buttonStyle(.borderless)
                        }
                        if h.releasedAt == nil {
                            Button("Release") {
                                let id = h.id
                                model.run(appState) { try await $0.file.releaseHold(caseID: model.caseID, id: id, reason: "Matter concluded", actor: model.actor) }
                            }.buttonStyle(.borderless)
                        }
                    }
                }
            }
            CaseSection(title: "Redaction log", subtitle: "What was redacted, where and why — produced with any redacted set.") {
                HStack {
                    EvidencePicker(title: "Document", ref: $redDoc).frame(maxWidth: 260)
                    TextField("Where (page, paragraph)", text: $redWhere).frame(width: 160)
                    TextField("Reason (e.g. personal data, privilege)", text: $redWhy)
                    Button("Log") {
                        let d = redDoc, w = redWhere, y = redWhy
                        model.run(appState) { try await $0.file.logRedaction(caseID: model.caseID, sourceRef: d, location: w, reason: y, actor: model.actor) }
                        redWhere = ""; redWhy = ""
                    }.disabled(redDoc.isEmpty || redWhere.isEmpty || redWhy.isEmpty)
                }
                ForEach(s.redactions) { r in Text("\(model.label(for: r.sourceRef)) · \(r.location) · \(r.reason) · \(r.redactedBy)").font(.caption) }
                if !s.redactions.isEmpty {
                    HStack { Spacer(); Button("Export redaction log…") { CaseFileSave.save(CaseFileDocuments.redactionLogCSV(s), name: "Redactions - \(s.caseHeader.title)", ext: "csv") } }
                }
            }
            CaseSection(title: "Review batches", subtitle: "Split the case's documents into batches; a second person checks each finished batch.") {
                HStack {
                    Stepper("Batch size \(batchSize)", value: $batchSize, in: 10...500, step: 10)
                    Spacer()
                    Button("Create batches from the sources in scope") {
                        let refs = s.custody.map { $0.sourceVersionID.uuidString }, size = batchSize
                        model.run(appState) { _ = try await $0.file.createBatches(caseID: model.caseID, sourceRefs: refs, size: size, reviewer: model.actor, actor: model.actor) }
                    }.disabled(s.custody.isEmpty)
                }
                ForEach(s.batches) { b in
                    HStack {
                        Text(b.name)
                        Text("\(b.sourceRefs.count) docs · \(b.status.label)").font(.caption).foregroundStyle(.secondary)
                        if let r = b.reviewer { Text("reviewer \(r)").font(.caption).foregroundStyle(.secondary) }
                        if let q = b.qcReviewer { Text("QC \(q)").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        if b.status == .open {
                            Button("First pass done") {
                                let id = b.id
                                model.run(appState) { try await $0.file.advanceBatch(caseID: model.caseID, id: id, to: .firstPassDone, qcNote: nil, actor: model.actor) }
                            }.buttonStyle(.borderless)
                        } else if b.status == .firstPassDone {
                            Button("QC done") {
                                let id = b.id
                                model.run(appState) { try await $0.file.advanceBatch(caseID: model.caseID, id: id, to: .qcDone, qcNote: nil, actor: model.actor) }
                            }.buttonStyle(.borderless)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Chronology & journal

struct CaseChronologyTab: View {
    @Environment(AppState.self) private var appState
    let model: CaseFileModel
    let s: CaseFileSnapshot
    @State private var kind: CaseJournalKind = .chronology
    @State private var when = Date()
    @State private var text = ""
    @State private var ref = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CaseSection(title: "Add an entry", subtitle: "Chronology entries are events you establish (marked as investigator entries beside the automatic timeline). Notes are your dated working journal.") {
                Picker("", selection: $kind) {
                    Text("Chronology event").tag(CaseJournalKind.chronology)
                    Text("Journal note").tag(CaseJournalKind.note)
                }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 320)
                if kind == .chronology { DatePicker("When it happened", selection: $when) }
                TextField(kind == .chronology ? "What happened" : "Note", text: $text, axis: .vertical).lineLimit(2...8)
                EvidencePicker(title: "Source", ref: $ref)
                HStack {
                    Spacer()
                    Button("Add") {
                        let k = kind, t = text, d = kind == .chronology ? when : nil, r = opt(ref)
                        model.run(appState) { _ = try await $0.file.addJournal(caseID: model.caseID, kind: k, text: t, eventDate: d, evidenceRef: r, actor: model.actor) }
                        text = ""; ref = ""
                    }.buttonStyle(.borderedProminent).disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            list("Chronology (investigator entries)", s.journal.filter { $0.kind == .chronology })
            list("Journal", s.journal.filter { $0.kind == .note }.reversed())
        }
    }

    private func list(_ title: String, _ entries: [CaseJournalEntry]) -> some View {
        CaseSection(title: title) {
            if entries.isEmpty { Text("Nothing yet.").foregroundStyle(.secondary) }
            ForEach(entries) { e in
                HStack(alignment: .top) {
                    Text(CaseFileDocuments.d(e.eventDate ?? e.createdAt)).font(.caption.monospacedDigit()).frame(width: 100, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(e.text)
                        HStack(spacing: 6) {
                            Text(e.author)
                            if let r = e.evidenceRef { Text("· \(model.label(for: r))") }
                        }.font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Retract") {
                        let id = e.id
                        model.run(appState) { try await $0.file.retractJournal(caseID: model.caseID, id: id, actor: model.actor) }
                    }.buttonStyle(.borderless).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Log & exports

struct CaseLogTab: View {
    @Environment(AppState.self) private var appState
    let model: CaseFileModel
    let s: CaseFileSnapshot
    @State private var personName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CaseSection(title: "Export", subtitle: "Each export is recorded in the case log.") {
                HStack {
                    Button("Case file report…") { export(CaseFileDocuments.caseFileReport(s, named: model.named, by: model.actor), "Case file - \(s.caseHeader.title)", "md", "caseFileReport") }
                    Button("Case log…") { export(CaseFileDocuments.actionLogCSV(s), "Case log - \(s.caseHeader.title)", "csv", "caseLog") }
                    Button("Exhibit list…") { export(CaseFileDocuments.exhibitListCSV(s), "Exhibits - \(s.caseHeader.title)", "csv", "exhibitList") }
                    Button("Custody report…") { export(CaseFileDocuments.custodyReport(s, by: model.actor), "Custody - \(s.caseHeader.title)", "md", "custodyReport") }
                }
            }
            CaseSection(title: "Personal data about someone", subtitle: "For a data-subject request: everything this case file records about one named person. Documents that mention them are found with Search and the person's dossier.") {
                HStack {
                    Picker("Person", selection: $personName) {
                        Text("Choose").tag("")
                        ForEach(Array(Set(s.people.map(\.name))).sorted(), id: \.self) { Text($0).tag($0) }
                    }.frame(maxWidth: 300)
                    Button("Export…") { export(CaseFileDocuments.personDataExport(s, name: personName, by: model.actor), "Personal data - \(personName)", "md", "personDataExport") }
                        .disabled(personName.isEmpty)
                }
            }
            CaseSection(title: "Case log", subtitle: "Every change, view and export, in order. It can't be edited.") {
                ForEach(s.actions.reversed().prefix(300)) { a in
                    HStack(alignment: .top) {
                        Text("#\(a.sequence)").font(.caption.monospacedDigit()).frame(width: 44, alignment: .leading)
                        Text(CaseFileDocuments.t(a.at)).font(.caption).frame(width: 140, alignment: .leading)
                        Text(a.actor).font(.caption).frame(width: 120, alignment: .leading)
                        Text(a.action + (a.detail.map { " — \($0)" } ?? "")).font(.caption)
                    }
                }
            }
        }
    }

    private func export(_ text: String, _ name: String, _ ext: String, _ action: String) {
        if model.custodyReadFailed, action == "custodyReport" {
            let alert = NSAlert()
            alert.messageText = "The custody record could not be read"
            alert.informativeText = "A custody report can't be exported until the custody record reads correctly. Nothing was exported."
            alert.runModal()
            return
        }
        // A case-file report is a working draft, never an approved findings report; a report built
        // while custody could not be read says so at the top.
        var body = text
        if action == "caseFileReport" {
            body = "> DRAFT case file — not an approved findings report.\n\n" + body
        }
        if model.custodyReadFailed, ext == "md" {
            body = "> INCOMPLETE — the custody record could not be read when this was exported.\n\n" + body
        }
        let outcome = CaseFileSave.save(body, name: name, ext: ext)
        let caseID = model.caseID, actor = model.actor
        switch outcome {
        case .saved(let fileName, let sha256):
            Task {
                do {
                    try await appState.caseFiles?.file.logAction(caseID: caseID, action: "exported",
                                                                 detail: "\(action) · \(fileName) · sha256 \(sha256.prefix(16))", actor: actor)
                } catch {
                    KalsmritikoshLog.app.error("Export log failed: \(String(describing: error), privacy: .public)")
                }
            }
        case .failed(let why):
            Task {
                do { try await appState.caseFiles?.file.logAction(caseID: caseID, action: "exportFailed", detail: "\(action) · \(why)", actor: actor) } catch {
                    KalsmritikoshLog.app.error("Export-failure log failed: \(String(describing: error), privacy: .public)")
                }
            }
        case .cancelled:
            break   // nothing was written; nothing is recorded as exported
        }
    }
}
