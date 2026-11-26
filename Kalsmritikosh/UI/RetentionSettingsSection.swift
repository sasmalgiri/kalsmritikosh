//
//  RetentionSettingsSection.swift
//  Kalsmritikosh
//
//  ALCOA ALC-20 (owner 2026-11-24) — Settings ▸ Retention: the retention register. Each class of record with how long
//  it is kept (a default, or the person's change with who / when / why), and a review that lists how many rows are past
//  their period and how many a legal hold keeps. Nothing is deleted from here; removing records is an erasure.
//  Small expressions on purpose (Xcode 26 CI type-check budget).
//

import SwiftUI
import os

struct RetentionSettingsSection: View {
    @Environment(AppState.self) private var appState
    @State private var entries: [RetentionRegister.Entry] = []
    @State private var reviews: [String: RetentionRegister.Review] = [:]
    @State private var editing: String?
    @State private var years = 7
    @State private var keepUntilErased = false
    @State private var reason = ""
    @State private var notice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("How long each kind of record is kept. The app never deletes on its own: a record past its period is listed here as due for review, and records of a case under a legal hold are never due. Removing records is an erasure, which you do.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(entries) { e in row(e) }
            if let editing { editor(editing) }
            HStack {
                Button("Review what is past its period") { Task { await review() } }
                    .disabled(appState.database == nil)
                    .help("Counts records past their retention period; nothing is deleted")
                if let notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .task { await load() }
    }

    private func row(_ e: RetentionRegister.Entry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(e.tableClass.label).font(.callout)
                Spacer()
                Text(e.periodText).font(.caption.monospacedDigit())
                Button("Change") { start(e) }.controlSize(.small)
                    .disabled(e.tableClass.id == "auditChain" || e.tableClass.id == "custody")
                    .help("Change how long this kind of record is kept (your reason is kept)")
            }
            Text(RetentionText.detail(e, review: reviews[e.id])).font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func editor(_ id: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Keep until erased", isOn: $keepUntilErased)
            Stepper("Keep for \(years) year(s)", value: $years, in: 1...50).disabled(keepUntilErased)
            TextField("Why (kept with the change)", text: $reason).textFieldStyle(.roundedBorder)
            HStack {
                Button("Save") { Task { await save(id) } }.keyboardShortcut(.defaultAction)
                Button("Cancel") { editing = nil }
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.06), in: .rect(cornerRadius: 6))
    }

    private func start(_ e: RetentionRegister.Entry) {
        editing = e.id
        keepUntilErased = e.keepDays == nil
        years = max(1, (e.keepDays ?? 2_557) / 365)
        reason = ""
    }

    private func load() async {
        guard let db = appState.database else { return }
        do { entries = try await RetentionRegister(database: db).entries() } catch {
            KalsmritikoshLog.ui.error("Retention register not read: \(error.localizedDescription, privacy: .private)")
            notice = error.localizedDescription
        }
    }

    private func save(_ id: String) async {
        guard let db = appState.database else { return }
        do {
            try await RetentionRegister(database: db).set(classID: id, keepDays: keepUntilErased ? nil : years * 365,
                                                          by: InvestigatorProfile.name, reason: reason)
            editing = nil
            notice = "Saved; the earlier setting is kept."
            await load()
        } catch {
            KalsmritikoshLog.ui.error("Retention change not saved: \(error.localizedDescription, privacy: .private)")
            notice = error.localizedDescription
        }
    }

    private func review() async {
        guard let db = appState.database else { return }
        do {
            let list = try await RetentionRegister(database: db).review()
            reviews = Dictionary(list.map { ($0.classID, $0) }, uniquingKeysWith: { a, _ in a })
            notice = "Reviewed \(ExportDateStyle.stamp(Date())). Nothing was deleted."
        } catch {
            KalsmritikoshLog.ui.error("Retention review failed: \(error.localizedDescription, privacy: .private)")
            notice = error.localizedDescription
        }
    }
}

/// The register's wording (testable without a view).
nonisolated enum RetentionText {
    static func detail(_ e: RetentionRegister.Entry, review: RetentionRegister.Review?) -> String {
        var s = e.tableClass.why
        if let by = e.setBy { s += " Set by \(by)" + (e.setAt.map { " on \(ExportDateStyle.day($0))" } ?? "") + (e.reason.map { ": \($0)" } ?? "") + "." }
        else { s += " (default)" }
        if let r = review { s += " Past its period: \(r.due); kept by a legal hold: \(r.heldBack)." }
        return s
    }
}
