//
//  CaseEvidenceRequestsSection.swift
//  Kalsmritikosh
//
//  P1-B (owner's implementation plan 2026-11-04) — the case file's evidence requests: what was asked
//  for, from whom, for which allegation or question, the items expected and by when; what arrived
//  against each item (a duplicate copy is shown and not counted), what is still missing, the history of
//  asking and answering, a draft request letter to copy (the app sends nothing), and the person's
//  recorded decision — fulfilled, partly provided, refused or cannot be obtained. An arrival never
//  changes the status, and a finding that may need revisiting is named, never changed.
//

import SwiftUI
import AppKit
import os

/// The new-request form as values (testable): what it would create, or why it cannot yet.
struct EvidenceRequestForm: Equatable {
    var description = ""
    var custodian = ""
    var allegationID: UUID?
    var question = ""
    var monthly = true
    var from = Calendar.current.date(byAdding: .month, value: -2, to: Date()) ?? Date()
    var to = Date()
    var itemLines = ""
    var hasDue = false
    var due = Calendar.current.date(byAdding: .day, value: 14, to: Date()) ?? Date()

    var problem: String? {
        if description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Say what is requested." }
        if monthly, from > to { return "The first month is after the last." }
        return nil
    }

    /// The expected items: one per month in the period, or one per typed line.
    func items(calendar: Calendar = .current) -> [EvidenceRequestItemSpec] {
        if monthly { return EvidenceRequestItemSpec.monthly(description, from: from, to: to, calendar: calendar) }
        return itemLines.split(separator: "\n").map { EvidenceRequestItemSpec(label: String($0)) }
            .filter { !$0.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    func details(calendar: Calendar = .current) -> EvidenceRequestDetails? {
        guard problem == nil else { return nil }
        let items = items(calendar: calendar)
        func clean(_ s: String) -> String? { let t = s.trimmingCharacters(in: .whitespacesAndNewlines); return t.isEmpty ? nil : t }
        return EvidenceRequestDetails(description: description, allegationID: allegationID, question: clean(question),
                                      custodian: clean(custodian),
                                      periodStart: monthly ? items.first?.periodStart : nil, periodEnd: monthly ? items.last?.periodEnd : nil,
                                      dueAt: hasDue ? due : nil, items: items)
    }
}

struct CaseEvidenceRequestsSection: View {
    @Environment(AppState.self) private var appState
    let model: CaseFileModel
    let s: CaseFileSnapshot
    @State private var form = EvidenceRequestForm()
    @State private var showForm = false
    @State private var draft: DraftText?

    struct DraftText: Identifiable { let id = UUID(); let text: String }

    var body: some View {
        let closed = s.caseHeader.status == .closed
        CaseSection(title: "Evidence requests",
                    subtitle: "What you have asked for, from whom, and what has arrived. Whether a request is fulfilled is your recorded decision — an arrival never changes it, and nothing is sent from here.") {
            DisclosureGroup("New request", isExpanded: Binding(get: { showForm || model.requests.isEmpty }, set: { showForm = $0 })) {
                newRequestForm.disabled(closed)
            }
            .accessibilityIdentifier("case.requests.new")
            ForEach(model.requests) { file in
                EvidenceRequestRow(model: model, s: s, file: file, closed: closed) { text in draft = DraftText(text: text) }
            }
        }
        .sheet(item: $draft) { d in
            VStack(alignment: .leading, spacing: 10) {
                Text("Draft request").font(.headline)
                Text("Edit and send it yourself; the app does not send it. Copying it records nothing.").font(.caption).foregroundStyle(.secondary)
                ScrollView { Text(d.text).font(.body.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                HStack {
                    Spacer()
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(d.text, forType: .string)
                    }
                    Button("Close") { draft = nil }.keyboardShortcut(.cancelAction)
                }
            }
            .padding(16)
            .frame(width: 560, height: 460)
        }
    }

    @ViewBuilder private var newRequestForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("What is requested (e.g. Bank statements, account 1234)", text: $form.description)
            TextField("Custodian — who holds it", text: $form.custodian)
            Picker("For allegation", selection: $form.allegationID) {
                Text("None").tag(UUID?.none)
                ForEach(s.allegations) { Text("\($0.label) — \($0.text)").lineLimit(1).tag(Optional($0.id)) }
            }
            .frame(maxWidth: 460)
            TextField("Or the question it answers", text: $form.question)
            Toggle("One item per month", isOn: $form.monthly)
            if form.monthly {
                HStack {
                    DatePicker("From", selection: $form.from, displayedComponents: .date)
                    DatePicker("To", selection: $form.to, displayedComponents: .date)
                }
                let items = form.items()
                Text(items.isEmpty ? "No months in that period." : "\(items.count) item(s) expected: " + items.map(\.label).joined(separator: "; "))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                TextField("Expected items, one per line", text: $form.itemLines, axis: .vertical).lineLimit(2...6)
            }
            HStack {
                Toggle("Due date", isOn: $form.hasDue)
                if form.hasDue { DatePicker("", selection: $form.due, displayedComponents: .date).labelsHidden() }
                Spacer()
                Button("Create request") { create() }
                    .disabled(reason: form.problem, remedy: nil)
                    .accessibilityIdentifier("case.requests.create")
            }
            if let p = form.problem { Text(p).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(.top, 6)
    }

    private func create() {
        guard let details = form.details(), let analysis = appState.investigationAnalysis else { return }
        let caseID = model.caseID, actor = model.actor
        EvidenceRequestRow.perform(model, appState) {
            let r = try await analysis.createEvidenceRequest(caseID: caseID, details: details, actor: actor, at: Date())
            await MainActor.run { model.workspace.state.selectedRequestID = r.id }
        }
        form = EvidenceRequestForm()
        showForm = false
    }
}

/// One request: status, what is missing, what arrived, suggestions, history and the decision.
struct EvidenceRequestRow: View {
    @Environment(AppState.self) private var appState
    let model: CaseFileModel
    let s: CaseFileSnapshot
    let file: EvidenceRequestFile
    let closed: Bool
    let showDraft: (String) -> Void
    @State private var linkVersion: UUID?
    @State private var linkItem: UUID?
    @State private var eventText = ""
    @State private var decision: EvidenceRequestStatus = .fulfilled
    @State private var decisionNote = ""
    @State private var withdrawReason = ""

    var body: some View {
        let r = file.request
        let progress = file.progress
        DisclosureGroup(isExpanded: Binding(get: { model.workspace.state.selectedRequestID == r.id },
                                             set: { model.workspace.state.selectedRequestID = $0 ? r.id : nil })) {
            details(r, progress).padding(.top, 6)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(r.description).font(.callout.weight(.semibold))
                    Text(r.status.label).font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                    if r.isOverdue(at: Date()) { Text("Overdue").font(.caption2.weight(.semibold)).foregroundStyle(.red) }
                }
                Text(progress.summary).font(.caption).foregroundStyle(progress.outstanding.isEmpty ? Color.secondary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        }
        .padding(8)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("case.requests.row")
    }

    private var candidates: [EvidenceRequestCandidate] {
        s.custody.map { e in
            EvidenceRequestCandidate(sourceVersionID: e.sourceVersionID, knowledgeObjectID: model.objectByVersion[e.sourceVersionID],
                                     name: model.labels[e.sourceVersionID] ?? "Source \(e.sourceVersionID.uuidString.prefix(8))")
        }
    }

    private func name(_ version: UUID) -> String { model.labels[version] ?? "Source \(version.uuidString.prefix(8))" }

    @ViewBuilder private func details(_ r: EvidenceRequest, _ progress: EvidenceRequestProgress) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if let c = r.custodian { Text("From: \(c)") }
                if let aid = r.allegationID, let a = s.allegations.first(where: { $0.id == aid }) { Text("For \(a.label): \(a.text)").lineLimit(2) }
                if let q = r.question { Text("Answers: \(q)") }
                if let due = r.dueAt { Text("Due \(due.formatted(date: .abbreviated, time: .omitted))").foregroundStyle(r.isOverdue(at: Date()) ? .red : .primary) }
            }
            .font(.caption)
            if !file.items.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(file.items) { item in
                        let got = file.receipts.filter { $0.isActive && $0.itemID == item.id }
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: got.contains(where: \.counts) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(got.contains(where: \.counts) ? .green : .secondary).accessibilityHidden(true)
                            Text(item.label).font(.caption)
                            Text(got.isEmpty ? "missing" : got.map { name($0.sourceVersionID) + ($0.duplicateOf != nil ? " (duplicate copy, not counted)" : "") }.joined(separator: ", "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            let unassigned = file.receipts.filter { $0.isActive && $0.itemID == nil }
            if !unassigned.isEmpty {
                Text("Also linked: " + unassigned.map { name($0.sourceVersionID) + ($0.duplicateOf != nil ? " (duplicate copy)" : "") }.joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(EvidenceRequestRevisit.notices(file, allegations: s.allegations, hypotheses: []), id: \.self) { line in
                Label(line, systemImage: "arrow.triangle.2.circlepath").font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            let suggestions = EvidenceRequestMatcher.suggestions(for: file, candidates: candidates)
            if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("May answer this request (you decide)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(suggestions) { sug in
                        HStack {
                            Text("\(sug.candidate.name) — \(sug.why)").font(.caption).lineLimit(2)
                            Spacer()
                            Button("Link") { link(sug.candidate.sourceVersionID, object: sug.candidate.knowledgeObjectID, item: sug.itemID, origin: .suggestion) }
                                .controlSize(.small).disabled(closed)
                                .accessibilityLabel("Link \(sug.candidate.name)")
                        }
                    }
                }
            }
            HStack {
                Picker("Received document", selection: $linkVersion) {
                    Text("Choose…").tag(UUID?.none)
                    ForEach(candidates.filter { c in !file.receipts.contains { $0.isActive && $0.sourceVersionID == c.sourceVersionID } }, id: \.sourceVersionID) {
                        Text($0.name).lineLimit(1).tag(Optional($0.sourceVersionID))
                    }
                }
                .frame(maxWidth: 320)
                if !file.items.isEmpty {
                    Picker("For item", selection: $linkItem) {
                        Text("No particular item").tag(UUID?.none)
                        ForEach(file.items) { Text($0.label).lineLimit(1).tag(Optional($0.id)) }
                    }
                    .frame(maxWidth: 260)
                }
                Button("Link received document") {
                    if let v = linkVersion { link(v, object: model.objectByVersion[v], item: linkItem, origin: .manual) }
                }
                .disabled(reason: linkVersion == nil ? "Choose the document that arrived." : closed ? "The case is closed." : nil)
                .accessibilityIdentifier("case.requests.link")
            }
            Text("A linked document is checked against the case's scope. Linking never marks the request fulfilled.")
                .font(.caption2).foregroundStyle(.secondary)
            HStack {
                TextField("What happened (e.g. emailed the bank on 3 Nov)", text: $eventText)
                Button("Record sent") { record(.requested) }
                Button("Record reply") { record(.responded) }
                Button("Add note") { record(.note) }
            }
            .disabled(closed)
            HStack {
                Picker("Decision", selection: $decision) {
                    ForEach([EvidenceRequestStatus.confirmed, .partial, .refused, .unobtainable, .fulfilled, .cancelled], id: \.self) { Text($0.label).tag($0) }
                }
                .frame(maxWidth: 260)
                TextField("Why (needed for refused, cannot be obtained, or fulfilled with items missing)", text: $decisionNote)
                Button("Record decision") { decide() }
                    .disabled(reason: closed ? "The case is closed." : nil)
                    .accessibilityIdentifier("case.requests.decide")
            }
            HStack {
                Button("Draft request text…") {
                    let about = r.allegationID.flatMap { id in s.allegations.first { $0.id == id } }.map { "\($0.label) — \($0.text)" } ?? r.question
                    showDraft(EvidenceRequestDraft.text(file, caseTitle: s.caseHeader.title, about: about, requester: model.actor))
                }
                Spacer()
            }
            let active = file.receipts.filter(\.isActive)
            if !active.isEmpty {
                DisclosureGroup("Withdraw a wrong link") {
                    TextField("Why it was linked by mistake (required)", text: $withdrawReason)
                    ForEach(active) { rc in
                        HStack {
                            Text(name(rc.sourceVersionID)).font(.caption)
                            Spacer()
                            Button("Withdraw link") { withdraw(rc.id) }
                                .controlSize(.small)
                                .disabled(reason: withdrawReason.trimmingCharacters(in: .whitespaces).isEmpty ? "Say why first." : closed ? "The case is closed." : nil)
                        }
                    }
                }
                .font(.caption)
            }
            DisclosureGroup("History (\(file.events.count + (file.events.contains { $0.kind == .created } ? 0 : 1)))") {
                VStack(alignment: .leading, spacing: 2) {
                    if !file.events.contains(where: { $0.kind == .created }) {
                        Text("\(r.createdAt.formatted(date: .abbreviated, time: .shortened)) — Created by \(r.actor)").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(file.events) { e in
                        Text("\(e.occurredAt.formatted(date: .abbreviated, time: .shortened)) — \(e.kind.label)"
                             + (e.statusAfter.map { ": \($0.label)" } ?? "") + (e.detail.map { " — \($0)" } ?? "") + " (\(e.actor))")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption)
        }
    }

    // MARK: - Actions (each a paid case edit, recorded, then the case reloads)

    static func perform(_ model: CaseFileModel, _ app: AppState, _ body: @escaping @Sendable () async throws -> Void) {
        guard PurchaseCenter.shared.allowPaidAction("edit the case file") else { return }
        model.busy = true
        Task { @MainActor in
            defer { model.busy = false }
            do { try await body(); model.error = nil } catch { model.report(error) }
            await model.load(app)
        }
    }

    private func link(_ version: UUID, object: UUID?, item: UUID?, origin: EvidenceReceiptOrigin) {
        guard let analysis = appState.investigationAnalysis else { return }
        let id = file.id, actor = model.actor
        Self.perform(model, appState) {
            _ = try await analysis.linkReceivedSource(requestID: id, itemID: item, sourceVersionID: version, knowledgeObjectID: object,
                                                      origin: origin, actor: actor, at: Date())
        }
        linkVersion = nil; linkItem = nil
    }

    private func record(_ kind: EvidenceRequestEventKind) {
        guard let analysis = appState.investigationAnalysis else { return }
        let id = file.id, actor = model.actor, text = eventText
        Self.perform(model, appState) { try await analysis.recordRequestEvent(requestID: id, kind: kind, detail: text, actor: actor, at: Date()) }
        eventText = ""
    }

    private func decide() {
        guard let analysis = appState.investigationAnalysis else { return }
        let id = file.id, rev = file.request.revision, actor = model.actor, status = decision, note = decisionNote
        Self.perform(model, appState) {
            _ = try await analysis.decideRequest(requestID: id, expectedRevision: rev, status: status, note: note, actor: actor, at: Date())
        }
        decisionNote = ""
    }

    private func withdraw(_ receipt: UUID) {
        guard let analysis = appState.investigationAnalysis else { return }
        let actor = model.actor, why = withdrawReason
        Self.perform(model, appState) { try await analysis.withdrawReceivedSource(receiptID: receipt, reason: why, actor: actor, at: Date()) }
        withdrawReason = ""
    }
}
