//
//  RegistersView.swift
//  Kalsmritikosh
//
//  REGISTERS (owner request 2026-08-20) — the day-to-day, human-input,
//  editable-with-history tools that persona research surfaced as recurring
//  gaps: the Interview & Statement Log (INT), the Records Request / FOIA
//  Tracker (REQ), and the Research Log (LOG). ONE shared surface parameterized
//  by WCRegister (the same way personas are lenses over shared engines): pick a
//  register → see its records (numbered, searchable, newest first) → add a new
//  record from its typed form → open any record to EDIT it, with every field
//  change sealed to an on-screen change history (migration v106). Records are
//  numbered documents (INT/REQ/LOG-YEAR-####) and appear in the Work Center
//  register too, so they're quotable and findable by number or any value typed.
//

import SwiftUI
#if os(macOS)
import AppKit
#endif

public struct RegistersView: View {
    @Environment(AppState.self) private var appState

    @State private var selectedType: String = WCRegisterCatalog.all.first?.docType ?? "INT"
    @State private var records: [WCDocument] = []
    @State private var search = ""
    @State private var editing: WCDocument?     // an existing record opened for edit
    @State private var creating = false         // the new-record sheet
    @State private var errorMessage: String?

    public init() {}

    private var register: WCRegister {
        WCRegisterCatalog.register(selectedType) ?? WCRegisterCatalog.interviewLog
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                registerPicker
                purposeCard
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.red)
                }
                recordsSection
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .task(id: selectedType) { await reload() }
        .sheet(isPresented: $creating) {
            RegisterRecordEditor(register: register, existing: nil) { await reload() }
                .environment(appState)
        }
        .sheet(item: $editing) { doc in
            RegisterRecordEditor(register: register, existing: doc) { await reload() }
                .environment(appState)
        }
    }

    // MARK: Header + register picker

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Logs & Trackers")
                .font(.largeTitle.weight(.bold))
            Text("Your everyday records — each entry is editable and keeps its full change history, so an amended record still shows who changed what, and when.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var registerPicker: some View {
        Picker("Register", selection: $selectedType) {
            ForEach(WCRegisterCatalog.all) { reg in
                Label(reg.name, systemImage: WCDocType.icon(reg.docType)).tag(reg.docType)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private var purposeCard: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: WCDocType.icon(register.docType))
                .font(.title2).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(register.name).font(.headline)
                Text(register.purpose).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("For: \(register.persona)").font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            Button {
                errorMessage = nil
                creating = true
            } label: { Label("New entry", systemImage: "plus") }
            .buttonStyle(.borderedProminent)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.tint.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: Records list

    private var filteredRecords: [WCDocument] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return records }
        return records.filter { doc in
            if doc.docNumber.lowercased().contains(q) || doc.title.lowercased().contains(q) { return true }
            return (doc.fieldValues[1] ?? [:]).values.contains { $0.lowercased().contains(q) }
        }
    }

    @ViewBuilder
    private var recordsSection: some View {
        HStack {
            Text("\(records.count) \(records.count == 1 ? "entry" : "entries")")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Spacer()
            if !records.isEmpty {
                TextField("Search entries", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 240)
            }
        }
        if records.isEmpty {
            ContentUnavailableView {
                Label("No entries yet", systemImage: WCDocType.icon(register.docType))
            } description: {
                Text("Add your first \(register.name.lowercased()) entry — it gets a number and stays editable.")
            } actions: {
                Button("New entry") { creating = true }.buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity)
        } else {
            VStack(spacing: 8) {
                ForEach(filteredRecords) { doc in recordRow(doc) }
            }
        }
    }

    private func recordRow(_ doc: WCDocument) -> some View {
        let values = doc.fieldValues[1] ?? [:]
        let statusValue = register.statusKey.flatMap { values[$0] } ?? ""
        return Button {
            errorMessage = nil
            editing = doc
        } label: {
            HStack(spacing: 12) {
                Image(systemName: WCDocType.icon(doc.docType)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(doc.title).font(.callout.weight(.semibold)).foregroundStyle(.primary)
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        Text(doc.docNumber).font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        if !statusValue.isEmpty {
                            Text(statusValue)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(.tint.opacity(0.15), in: Capsule())
                                .foregroundStyle(.tint)
                        }
                        if doc.updatedAt.timeIntervalSince(doc.createdAt) > 1 {
                            Label("edited", systemImage: "pencil")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
                Spacer()
                Text(doc.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2).foregroundStyle(.tertiary)
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open to view or edit — changes are saved with a history entry")
    }

    // MARK: Data

    private func reload() async {
        guard let repo = appState.workCenter else { return }
        records = (try? await repo.records(type: selectedType)) ?? []
    }
}

// MARK: - Record editor (create + edit, with change history)

struct RegisterRecordEditor: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let register: WCRegister
    /// nil = create a new record; non-nil = edit this existing record.
    let existing: WCDocument?
    let onSaved: () async -> Void

    @State private var draft: [String: String] = [:]
    @State private var editNote = ""
    @State private var history: [WCRecordEdit] = []
    @State private var errorMessage: String?
    @State private var saving = false
    @State private var savedFlash = false

    private var isEditing: Bool { existing != nil }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(isEditing ? "Edit entry" : "New \(register.name.lowercased()) entry",
                      systemImage: WCDocType.icon(register.docType))
                    .font(.headline)
                if let existing { Text(existing.docNumber).font(.caption.monospaced()).foregroundStyle(.secondary) }
                Spacer()
                if savedFlash {
                    Label("Saved", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.green)
                }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout).foregroundStyle(.red)
                    }
                    ForEach(register.fields) { field in fieldInput(field) }

                    if isEditing {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Reason for this change (optional)").font(.callout.weight(.medium))
                            TextField("e.g. corrected the date after re-checking", text: $editNote)
                                .textFieldStyle(.roundedBorder)
                            Text("Recorded with the change so the history explains itself.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }

                    HStack {
                        Spacer()
                        Button(isEditing ? "Save changes" : "Create entry") { save() }
                            .buttonStyle(.borderedProminent)
                            .disabled(saving)
                    }

                    if isEditing { historySection }
                }
                .padding(16)
                .frame(maxWidth: 620, alignment: .leading)
            }
        }
        .frame(minWidth: 560, minHeight: 560)
        .task {
            if let existing { draft = existing.fieldValues[1] ?? [:] }
            await loadHistory()
        }
    }

    // MARK: History

    @ViewBuilder
    private var historySection: some View {
        Divider().padding(.vertical, 4)
        Label("Change history", systemImage: "clock.arrow.circlepath")
            .font(.callout.weight(.semibold))
        if history.isEmpty {
            Text("No edits yet — this entry is unchanged since it was created.")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(history) { edit in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(fieldLabel(edit.fieldKey)).font(.caption.weight(.semibold))
                            Spacer()
                            Text("\(edit.editedAt.formatted(date: .abbreviated, time: .shortened))\(edit.editor.isEmpty ? "" : " · \(edit.editor)")")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                        HStack(alignment: .top, spacing: 6) {
                            Text(edit.oldValue.isEmpty ? "(empty)" : edit.oldValue)
                                .font(.caption2).foregroundStyle(.secondary).strikethrough()
                            Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
                            Text(edit.newValue.isEmpty ? "(empty)" : edit.newValue)
                                .font(.caption2)
                        }
                        if !edit.note.isEmpty {
                            Text(edit.note).font(.caption2).foregroundStyle(.tertiary).italic()
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private func fieldLabel(_ key: String) -> String {
        register.fields.first { $0.key == key }?.label ?? key
    }

    // MARK: Field inputs

    @ViewBuilder
    private func fieldInput(_ field: WCField) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(field.label).font(.callout.weight(.medium))
                if field.required {
                    Text("required")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(.orange.opacity(0.18), in: Capsule())
                }
            }
            switch field.kind {
            case .text, .number:
                TextField(field.placeholder, text: binding(field.key)).textFieldStyle(.roundedBorder)
            case .longText:
                TextEditor(text: binding(field.key))
                    .font(.callout).frame(minHeight: 70)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            case .choice:
                Picker(field.label, selection: binding(field.key)) {
                    Text("—").tag("")
                    ForEach(field.options, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden().pickerStyle(.menu)
            case .bool:
                Picker(field.label, selection: binding(field.key)) {
                    Text("—").tag("")
                    Text("Yes").tag("Yes")
                    Text("No").tag("No")
                }
                .labelsHidden().pickerStyle(.segmented).frame(maxWidth: 220)
            case .date:
                DatePicker("", selection: dateBinding(field.key), displayedComponents: .date)
                    .datePickerStyle(.compact).labelsHidden()
            case .dateRange:
                TextField(field.placeholder, text: binding(field.key)).textFieldStyle(.roundedBorder)
            }
            Text(field.help).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func binding(_ key: String) -> Binding<String> {
        Binding(get: { draft[key] ?? "" }, set: { draft[key] = $0 })
    }

    private var dayFormatter: DateFormatter {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f
    }
    private func dateBinding(_ key: String) -> Binding<Date> {
        Binding(
            get: { dayFormatter.date(from: draft[key] ?? "") ?? Date() },
            set: { draft[key] = dayFormatter.string(from: $0) })
    }

    // MARK: Save

    private var actorName: String {
        #if os(macOS)
        let name = NSFullUserName()
        return name.isEmpty ? "Owner" : name
        #else
        return "Owner"
        #endif
    }

    private func save() {
        guard let repo = appState.workCenter else { errorMessage = "Records store unavailable."; return }
        let missing = register.missingRequired(draft)
        guard missing.isEmpty else {
            errorMessage = "Fill the required field\(missing.count == 1 ? "" : "s") first: \(missing.joined(separator: ", "))."
            return
        }
        let values = draft.filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let title = register.title(for: values)
        errorMessage = nil; saving = true
        Task {
            defer { saving = false }
            do {
                if let existing {
                    let changed = try await repo.updateRecord(
                        docID: existing.id, title: title, values: values,
                        editor: actorName, note: editNote.trimmingCharacters(in: .whitespacesAndNewlines),
                        at: Date())
                    editNote = ""
                    await loadHistory()
                    if changed == 0 { errorMessage = "No changes to save." } else { flash() }
                } else {
                    _ = try await repo.createRecord(
                        type: register.docType, title: title, values: values,
                        actor: actorName, at: Date())
                    await onSaved()
                    dismiss()
                    return
                }
                await onSaved()
            } catch {
                errorMessage = "Could not save: \(error)"
            }
        }
    }

    private func loadHistory() async {
        guard let repo = appState.workCenter, let existing else { return }
        history = (try? await repo.editHistory(docID: existing.id)) ?? []
    }

    private func flash() {
        withAnimation { savedFlash = true }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            withAnimation { savedFlash = false }
        }
    }
}
