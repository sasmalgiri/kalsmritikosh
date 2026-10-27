//
//  StudioCaseControls.swift
//  Kalsmritikosh
//
//  A2/A3 for the studios that have their own screens (privilege log, workplace report, SIU
//  referral, forensic engagement, fact-check memo): the "Fill from case" menu, and the gate that
//  stops Copy / Export / Print while a filled field rests on neither a case document nor an
//  investigator-entry mark. The shared studio shell has the same behaviour built in.
//

import SwiftUI

/// "Fill from case" — lists the open cases and fills the model's empty fields from one.
struct StudioFillFromCaseMenu<M: CaseBackedStudio>: View {
    @Binding var model: M
    @Environment(AppState.self) private var appState
    @State private var choices: [StudioCaseChoice] = []
    @State private var filling = false
    @Binding var message: String?
    /// Binds the draft to the chosen case first (final brief §3.1); false stops the fill.
    var bind: ((StudioCaseChoice) async -> Bool)? = nil

    var body: some View {
        Menu {
            if choices.isEmpty {
                Text("No open cases")
            } else {
                ForEach(choices) { c in Button(c.title) { fill(c) } }
            }
        } label: {
            Label(filling ? "Filling…" : "Fill from case", systemImage: "tray.and.arrow.down")
        }
        .controlSize(.small)
        .disabled(filling)
        .task { choices = await appState.studioCaseChoices() }
        .guidance(GuidanceTip("Fill from case",
                              what: "Fills the empty fields from the case's own documents. Each filled field keeps the source it came from; anything you type or change is marked as your entry."))
    }

    private func fill(_ choice: StudioCaseChoice) {
        filling = true
        Task {
            defer { filling = false }
            if let bind, !(await bind(choice)) {
                message = "Not filled: this draft belongs to another case."
                return
            }
            guard let facts = await appState.studioCaseFacts(choice, includePrivileged: M.needsPrivilegedSources) else {
                message = "The case could not be read."
                return
            }
            var m = model
            let before = m.provenance?.count ?? 0
            m.prefill(from: facts)
            let filled = (m.provenance?.count ?? 0) - before
            StudioAudit.record(&m.history, "Filled \(filled) field(s) from case \u{201C}\(choice.title)\u{201D}")
            model = m
            message = filled > 0
                ? "Filled \(filled) field(s) from \u{201C}\(choice.title)\u{201D}; each keeps its source."
                : "Nothing new to fill from \u{201C}\(choice.title)\u{201D} — the case states none of the empty fields."
        }
    }
}

/// Holds a report action until the unsupported fields are resolved.
@MainActor @Observable
final class StudioProvenanceGate {
    var fields: [String] = []
    /// Field path → why its cited source did not resolve (final brief §3.2).
    var reasons: [String: String] = [:]
    var isPresented = false
    var checking = false
    private var pending: (() -> Void)?
    private var markAll: (() -> Void)?
    /// Set by the screen: resolves a draft's evidenced fields against its own case (draft id, values,
    /// provenance, privileged sources allowed). Unset, every evidenced field counts as unchecked.
    var resolve: ((UUID, [String: String], StudioProvenance?, Bool) async -> [String: String])?

    /// Run `action` once every filled field is either resolved to a source in the draft's case or
    /// marked as the investigator's entry; otherwise ask first, with the reason for each field.
    func run<M: CaseBackedStudio & StudioPersisted>(_ model: Binding<M>, _ action: @escaping () -> Void) {
        let m = model.wrappedValue
        let missing = StudioExportGate.unsupportedFields(m.gateValues, provenance: m.provenance)
        checking = true
        Task { @MainActor in
            defer { checking = false }
            let unresolved: [String: String]
            if let resolve {
                unresolved = await resolve(m.id, m.gateValues, m.provenance, M.needsPrivilegedSources)
            } else {
                unresolved = await StudioEvidenceResolver.unresolved(values: m.gateValues, provenance: m.provenance, context: nil)
            }
            guard !missing.isEmpty || !unresolved.isEmpty else { action(); return }
            fields = (missing + unresolved.keys.sorted()).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            reasons = unresolved
            pending = action
            let paths = fields
            markAll = {
                var m = model.wrappedValue
                var p = m.provenance
                StudioExportGate.markAsInvestigatorEntries(paths, provenance: &p)
                m.provenance = p
                StudioAudit.record(&m.history, "Marked \(paths.count) field(s) as investigator entries (\(unresolved.count) whose cited source did not resolve)")
                model.wrappedValue = m
            }
            isPresented = true
        }
    }

    func confirm() { markAll?(); pending?(); clear() }
    func clear() { pending = nil; markAll = nil; fields = []; reasons = [:]; isPresented = false }

    /// The alert's explanation: unsupported fields, then each unresolved source with its reason.
    var explanation: String {
        let plain = fields.filter { reasons[$0] == nil }
        var parts: [String] = []
        if !plain.isEmpty { parts.append("\(plain.count) filled field(s) are neither taken from the case's documents nor marked as your own entry.") }
        if !reasons.isEmpty {
            let shown = reasons.keys.sorted().prefix(4).map { "\($0): \(reasons[$0] ?? "")" }
            parts.append("\(reasons.count) field(s) cite a source that does not check out — \(shown.joined(separator: "; "))\(reasons.count > 4 ? " …" : "").")
        }
        parts.append("A report that leaves the app must say, for every line, which it is. Marking them as your entries prints them as yours, not as documentary evidence.")
        return parts.joined(separator: " ")
    }
}

extension View {
    /// The alert shown while a report action waits on the provenance gate.
    func studioProvenanceGate(_ gate: StudioProvenanceGate) -> some View {
        alert("Some entries have no source", isPresented: Binding(get: { gate.isPresented }, set: { if !$0 { gate.clear() } })) {
            Button("Mark as my entries and continue") { gate.confirm() }
            Button("Cancel", role: .cancel) { gate.clear() }
        } message: {
            Text(gate.explanation)
        }
    }
}
