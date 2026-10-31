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
                Section("Fill from") {
                    ForEach(choices) { c in Button(c.title) { fill(c) } }
                }
                // Review step 5: a draft can belong to a case without anything being filled from it.
                if bind != nil {
                    Section("Assign to case without filling") {
                        ForEach(choices) { c in Button(c.title) { assign(c) } }
                    }
                }
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

    private func assign(_ choice: StudioCaseChoice) {
        guard let bind else { return }
        filling = true
        Task {
            defer { filling = false }
            message = await bind(choice)
                ? "Assigned to \u{201C}\(choice.title)\u{201D}; nothing was filled. Its sources are now checked against that case."
                : "Not assigned: this draft belongs to another case."
        }
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

    /// Run `action` with the EXACT value that was validated, once every filled field is either
    /// resolved to a source in the draft's case or marked as the investigator's entry; otherwise ask
    /// first, with the reason for each field. If the draft changes while it is being checked, nothing
    /// runs (review R2) — the person exports again.
    func run<M: CaseBackedStudio & StudioPersisted>(_ model: Binding<M>, _ action: @escaping (M) -> Void) {
        let m = model.wrappedValue
        let missing = StudioExportGate.unsupportedFields(m.gateValues, provenance: m.provenance)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let validated = try? encoder.encode(m)
        checking = true
        Task { @MainActor in
            defer { checking = false }
            let unresolved: [String: String]
            if let resolve {
                unresolved = await resolve(m.id, m.gateValues, m.provenance, M.needsPrivilegedSources)
            } else {
                unresolved = await StudioEvidenceResolver.unresolved(values: m.gateValues, provenance: m.provenance, context: nil)
            }
            // The live draft must still be the one that was checked.
            guard let validated, (try? encoder.encode(model.wrappedValue)) == validated else {
                notice = "The draft changed while it was being checked, so nothing was done. Try again."
                isPresented = true
                return
            }
            guard !missing.isEmpty || !unresolved.isEmpty else { action(m); return }
            fields = (missing + unresolved.keys.sorted()).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            reasons = unresolved
            let paths = fields, failed = Set(unresolved.keys)
            pending = { action(model.wrappedValue) }
            markAll = {
                var m = model.wrappedValue
                var p = m.provenance
                StudioExportGate.markAsInvestigatorEntries(paths, unresolved: failed, provenance: &p)
                m.provenance = p
                StudioAudit.record(&m.history, "Marked \(paths.count) field(s) as investigator entries (\(failed.count) whose cited source did not resolve)")
                model.wrappedValue = m
            }
            isPresented = true
        }
    }

    /// A message shown instead of the field list (the draft changed during the check).
    var notice: String?

    func confirm() { markAll?(); pending?(); clear() }
    func clear() { pending = nil; markAll = nil; fields = []; reasons = [:]; notice = nil; isPresented = false }

    /// The alert's explanation: unsupported fields, then each unresolved source with its reason.
    var explanation: String {
        if let notice { return notice }
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
        alert(gate.notice == nil ? "Some entries have no source" : "Nothing was done", isPresented: Binding(get: { gate.isPresented }, set: { if !$0 { gate.clear() } })) {
            if gate.notice == nil { Button("Mark as my entries and continue") { gate.confirm() } }
            Button(gate.notice == nil ? "Cancel" : "OK", role: .cancel) { gate.clear() }
        } message: {
            Text(gate.explanation)
        }
    }
}

/// Review L4 — Remove keeps a draft in the record; Erase removes its content, with a reason, and is
/// refused while a legal hold covers the draft or its case.
struct StudioEraseButton: View {
    static let removeHelp = "Remove from the list. The draft stays in the record (with its versions and exports); use Erase to remove its content."
    let storage: StudioStorage
    let id: UUID
    let onErased: () -> Void
    @Environment(AppState.self) private var appState
    @State private var asking = false
    @State private var reason = ""
    @State private var basis = ""
    @State private var refusal: String?
    @State private var working = false

    var body: some View {
        Button { asking = true } label: { Label("Erase…", systemImage: "xmark.bin").labelStyle(.iconOnly) }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .help("Erase this draft's content — every version and export snapshot — keeping only a record that it was erased, by whom and why.")
            .popover(isPresented: $asking) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Erase this draft").font(.headline)
                    Text("Its content, every earlier version and every export snapshot are cleared from the ledger. What stays: the dates, the fingerprints and the record of this erasure. Not possible while a legal hold covers the draft or its case. " + StudioErasureResult.outsideTheLedger)
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    TextField("Reason (required) — e.g. the person's request and its date", text: $reason).textFieldStyle(.roundedBorder)
                    TextField("Basis (optional) — e.g. the law or policy relied on", text: $basis).textFieldStyle(.roundedBorder)
                    if let refusal { Text(refusal).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                    HStack {
                        Spacer()
                        Button("Cancel") { asking = false }
                        Button("Erase", role: .destructive) {
                            working = true
                            Task {
                                defer { working = false }
                                if let why = await storage.erase(id, reason: reason, legalBasis: basis, app: appState) {
                                    refusal = why
                                } else {
                                    asking = false
                                    onErased()
                                }
                            }
                        }
                        .disabled(reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || working)
                    }
                }
                .padding(14).frame(width: 380)
            }
    }
}
