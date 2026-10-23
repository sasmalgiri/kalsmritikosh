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
    var isPresented = false
    private var pending: (() -> Void)?
    private var markAll: (() -> Void)?

    /// Run `action` now, or ask first when some filled fields have no source and no mark.
    func run<M: CaseBackedStudio>(_ model: Binding<M>, _ action: @escaping () -> Void) {
        let missing = StudioExportGate.unsupportedFields(model.wrappedValue.gateValues, provenance: model.wrappedValue.provenance)
        guard !missing.isEmpty else { action(); return }
        fields = missing
        pending = action
        markAll = {
            var m = model.wrappedValue
            var p = m.provenance
            let marked = StudioExportGate.markUnsupportedAsInvestigatorEntries(m.gateValues, provenance: &p)
            m.provenance = p
            StudioAudit.record(&m.history, "Marked \(marked.count) field(s) as investigator entries")
            model.wrappedValue = m
        }
        isPresented = true
    }

    func confirm() { markAll?(); pending?(); clear() }
    func clear() { pending = nil; markAll = nil; fields = []; isPresented = false }
}

extension View {
    /// The alert shown while a report action waits on the provenance gate.
    func studioProvenanceGate(_ gate: StudioProvenanceGate) -> some View {
        alert("Some entries have no source", isPresented: Binding(get: { gate.isPresented }, set: { if !$0 { gate.clear() } })) {
            Button("Mark as my entries and continue") { gate.confirm() }
            Button("Cancel", role: .cancel) { gate.clear() }
        } message: {
            Text("\(gate.fields.count) filled field(s) are neither taken from the case's documents nor marked as your own entry. A report that leaves the app must say, for every line, which it is.")
        }
    }
}
