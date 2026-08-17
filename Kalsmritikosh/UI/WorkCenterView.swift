//
//  WorkCenterView.swift
//  Kalsmritikosh
//
//  WORK-CENTER — the SAP-style guided workflow runner UI (owner request
//  2026-08-17, ported from maxmailin's Work Center). Catalog of recipes →
//  start a run (posts a numbered WF- document) → step rail with Now/Next →
//  typed fields with per-field help → gates with plain-language locked
//  reasons → "Open tool" jumps to the real surface where the work happens →
//  Confirm posts the step's own numbered document. Runs are resumable; the
//  Documents register lists every number ever issued.
//

import SwiftUI

public struct WorkCenterView: View {
    @Environment(AppState.self) private var appState
    /// Opens the real surface a step launches (RootView owns navigation).
    let onNavigate: (Destination) -> Void

    @State private var runs: [WCDocument] = []
    @State private var allDocuments: [WCDocument] = []
    @State private var activeRun: WCDocument?
    @State private var postedDocs: [WCDocument] = []
    @State private var selectedSeq: Int = 1
    /// Unsaved field edits for the selected step.
    @State private var draft: [String: String] = [:]
    @State private var draftDirty = false
    @State private var errorMessage: String?
    @State private var justPosted: WCDocument?

    public init(onNavigate: @escaping (Destination) -> Void) {
        self.onNavigate = onNavigate
    }

    public var body: some View {
        Group {
            if let run = activeRun {
                runScreen(run)
            } else {
                catalogScreen
            }
        }
        .task { await reloadLists() }
    }

    // MARK: - Catalog (no active run)

    private var catalogScreen: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Work Center")
                        .font(.largeTitle.weight(.bold))
                    Text("Guided workflows with the rigor built in: each step is gated on the one before it, captures what a defensible record needs, and posts a numbered document you can quote later.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if !openRuns.isEmpty {
                    sectionLabel("Resume where you left off")
                    VStack(spacing: 8) {
                        ForEach(openRuns) { run in resumeRow(run) }
                    }
                }

                sectionLabel("Start a workflow")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 330), spacing: 14)], spacing: 14) {
                    ForEach(WCCatalog.all) { def in recipeCard(def) }
                }

                if !allDocuments.isEmpty {
                    sectionLabel("Documents — every number issued")
                    VStack(spacing: 6) {
                        ForEach(allDocuments.prefix(40)) { doc in documentRow(doc) }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private var openRuns: [WCDocument] {
        runs.filter { $0.status != .confirmed }
    }

    private func resumeRow(_ run: WCDocument) -> some View {
        HStack(spacing: 12) {
            Image(systemName: WCDocType.icon("WF"))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(run.title).font(.callout.weight(.semibold))
                HStack(spacing: 8) {
                    Text(run.docNumber).font(.caption.monospaced())
                    statusChip(run.status)
                    if let def = run.defID.flatMap(WCCatalog.definition) {
                        Text("\(run.confirmedSeqs.count) of \(def.operations.count) steps done")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            Button("Resume") { open(run) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private func recipeCard(_ def: WCWorkflowDefinition) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(def.name).font(.headline)
                Spacer()
                Text(def.persona)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.tint.opacity(0.15), in: Capsule())
            }
            Text(def.purpose)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("\(def.operations.count) steps · posts \(postedTypes(def))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Start") { start(def) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }

    private func postedTypes(_ def: WCWorkflowDefinition) -> String {
        let types = def.operations.compactMap(\.postsDocType)
        return types.isEmpty ? "—" : types.map(WCDocType.displayName).joined(separator: ", ")
    }

    private func documentRow(_ doc: WCDocument) -> some View {
        HStack(spacing: 10) {
            Image(systemName: WCDocType.icon(doc.docType))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(doc.docNumber)
                .font(.caption.monospaced().weight(.semibold))
                .frame(width: 110, alignment: .leading)
            Text(doc.title)
                .font(.caption)
                .lineLimit(1)
            Spacer()
            statusChip(doc.status)
            Text(doc.createdAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Run screen

    @ViewBuilder
    private func runScreen(_ run: WCDocument) -> some View {
        if let def = run.defID.flatMap(WCCatalog.definition) {
            HSplitView {
                stepRail(run, def)
                    .frame(minWidth: 250, idealWidth: 280, maxWidth: 340)
                stepDetail(run, def)
                    .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            ContentUnavailableView("Unknown workflow",
                                   systemImage: "questionmark.circle",
                                   description: Text("This run references a workflow definition that no longer exists."))
        }
    }

    private func stepRail(_ run: WCDocument, _ def: WCWorkflowDefinition) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    activeRun = nil
                    Task { await reloadLists() }
                } label: {
                    Label("All workflows", systemImage: "chevron.left")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)

                Text(run.title).font(.headline)
                HStack(spacing: 8) {
                    Text(run.docNumber).font(.caption.monospaced().weight(.semibold))
                    statusChip(run.status)
                }
                ProgressView(value: Double(run.confirmedSeqs.count),
                             total: Double(def.operations.count))
                    .controlSize(.small)
                Text(progressLine(run, def))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(14)

            Divider()

            ScrollView {
                VStack(spacing: 4) {
                    ForEach(def.operations) { op in railRow(op, run: run) }
                }
                .padding(8)
            }
        }
        .background(.background.secondary)
    }

    private func progressLine(_ run: WCDocument, _ def: WCWorkflowDefinition) -> String {
        let done = run.confirmedSeqs.count
        if done == def.operations.count { return "All \(done) steps confirmed — workflow complete." }
        let now = nextOpenSeq(run, def)
        let nowTitle = def.operations.first { $0.seq == now }?.title ?? "—"
        return "Step \(done) of \(def.operations.count) done · Now → \(nowTitle)"
    }

    private func nextOpenSeq(_ run: WCDocument, _ def: WCWorkflowDefinition) -> Int {
        def.operations.first { !run.confirmedSeqs.contains($0.seq) }?.seq
            ?? def.operations.last?.seq ?? 1
    }

    private func railRow(_ op: WCOperation, run: WCDocument) -> some View {
        let confirmed = run.confirmedSeqs.contains(op.seq)
        let selected = op.seq == selectedSeq
        return Button {
            select(op.seq, in: run)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: confirmed ? "checkmark.circle.fill" : "\(op.seq).circle")
                    .foregroundStyle(confirmed ? Color.green : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(op.title)
                        .font(.callout.weight(selected ? .semibold : .regular))
                        .foregroundStyle(.primary)
                    if let type = op.postsDocType {
                        Text("Posts \(WCDocType.displayName(type))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(selected ? AnyShapeStyle(.tint.opacity(0.12)) : AnyShapeStyle(.clear),
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func stepDetail(_ run: WCDocument, _ def: WCWorkflowDefinition) -> some View {
        let op = def.operations.first { $0.seq == selectedSeq } ?? def.operations[0]
        let locked = WCGatePolicy.lockedReasons(op, state: gateState(run))
        let confirmed = run.confirmedSeqs.contains(op.seq)
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // Header
                VStack(alignment: .leading, spacing: 4) {
                    Text("Step \(op.seq) of \(def.operations.count)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(op.title).font(.title2.weight(.bold))
                    Text(op.hint).font(.callout).foregroundStyle(.secondary)
                }

                if let posted = justPosted, posted.stepSeq == op.seq {
                    banner(icon: "checkmark.seal.fill", tint: .green,
                           text: "Posted \(WCDocType.displayName(posted.docType)) \(posted.docNumber).")
                } else if confirmed {
                    banner(icon: "checkmark.circle.fill", tint: .green,
                           text: "Confirmed. " + (postedDocs.first { $0.stepSeq == op.seq }
                                .map { "Document \($0.docNumber)." } ?? "Recorded on the run."))
                } else if !locked.isEmpty {
                    banner(icon: "lock.fill", tint: .orange,
                           text: locked.joined(separator: " "))
                }

                if let message = errorMessage {
                    banner(icon: "exclamationmark.triangle.fill", tint: .red, text: message)
                }

                // The real surface where this step's work happens.
                if let surface = op.launchesSurface.flatMap(Destination.init(rawValue:)) {
                    Button {
                        onNavigate(surface)
                    } label: {
                        Label("Open \(surface.title) — do this step's work there",
                              systemImage: surface.icon)
                    }
                    .buttonStyle(.bordered)
                }

                // Fields
                if !op.fields.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(op.fields) { field in
                            fieldInput(field, disabled: confirmed)
                        }
                    }
                    .padding(16)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
                }

                // Actions
                HStack(spacing: 10) {
                    Button {
                        select(max(1, op.seq - 1), in: run)
                    } label: { Label("Previous", systemImage: "chevron.left") }
                    .disabled(op.seq <= 1)

                    Button {
                        select(min(def.operations.count, op.seq + 1), in: run)
                    } label: { Label("Next", systemImage: "chevron.right") }
                    .disabled(op.seq >= def.operations.count)

                    Spacer()

                    if !confirmed {
                        Button("Save") { save(run, seq: op.seq) }
                            .disabled(!draftDirty)
                        Button {
                            confirm(run, op: op)
                        } label: {
                            Label(op.postsDocType.map { "Confirm & post \(WCDocType.displayName($0))" }
                                    ?? "Confirm step",
                                  systemImage: "checkmark.seal")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!locked.isEmpty)
                    }
                }

                // Executed steps ledger
                if !postedDocs.isEmpty {
                    Divider()
                    sectionLabel("Documents posted by this run")
                    VStack(spacing: 6) {
                        ForEach(postedDocs) { doc in documentRow(doc) }
                    }
                }

                if run.status == .confirmed {
                    banner(icon: "flag.checkered", tint: .green,
                           text: "Workflow complete — every step confirmed. All documents remain quotable from the Documents register.")
                }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Field inputs

    @ViewBuilder
    private func fieldInput(_ field: WCField, disabled: Bool) -> some View {
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
                TextField(field.placeholder, text: draftBinding(field.key))
                    .textFieldStyle(.roundedBorder)
                    .disabled(disabled)
            case .longText:
                TextEditor(text: draftBinding(field.key))
                    .font(.callout)
                    .frame(minHeight: 76)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                    .disabled(disabled)
            case .choice:
                Picker(field.label, selection: draftBinding(field.key)) {
                    Text("—").tag("")
                    ForEach(field.options, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .disabled(disabled)
            case .bool:
                Picker(field.label, selection: draftBinding(field.key)) {
                    Text("—").tag("")
                    Text("Yes").tag("Yes")
                    Text("No").tag("No")
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: 220)
                .disabled(disabled)
            }
            Text(field.help)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func draftBinding(_ key: String) -> Binding<String> {
        Binding(
            get: { draft[key] ?? "" },
            set: { draft[key] = $0; draftDirty = true }
        )
    }

    // MARK: - Small pieces

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private func statusChip(_ status: WCRunStatus) -> some View {
        let (label, tint): (String, Color) = switch status {
        case .open:      ("Open", .blue)
        case .released:  ("Released", .orange)
        case .confirmed: ("Confirmed", .green)
        }
        return Text(label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint)
    }

    private func banner(icon: String, tint: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(text).font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private func gateState(_ run: WCDocument) -> WCGatePolicy.RunState {
        // Overlay the unsaved draft so gate/lock feedback is live as the user types.
        var values = run.fieldValues
        var merged = values[selectedSeq] ?? [:]
        for (k, v) in draft { merged[k] = v }
        values[selectedSeq] = merged
        return WCGatePolicy.RunState(confirmed: run.confirmedSeqs, fieldValues: values)
    }

    private var actorName: String {
        let name = NSFullUserName()
        return name.isEmpty ? "Owner" : name
    }

    // MARK: - Actions

    private func reloadLists() async {
        guard let repo = appState.workCenter else { return }
        runs = (try? await repo.runs()) ?? []
        allDocuments = (try? await repo.allDocuments()) ?? []
    }

    private func start(_ def: WCWorkflowDefinition) {
        guard let repo = appState.workCenter else { return }
        errorMessage = nil
        Task {
            do {
                let run = try await repo.createRun(
                    defID: def.defID,
                    title: def.name,
                    actor: actorName,
                    at: Date())
                open(run)
            } catch {
                errorMessage = "Could not start the workflow: \(error)"
            }
        }
    }

    private func open(_ run: WCDocument) {
        activeRun = run
        justPosted = nil
        errorMessage = nil
        if let def = run.defID.flatMap(WCCatalog.definition) {
            selectedSeq = nextOpenSeq(run, def)
        } else {
            selectedSeq = 1
        }
        draft = run.fieldValues[selectedSeq] ?? [:]
        draftDirty = false
        Task { await reloadRun(run.id) }
    }

    private func select(_ seq: Int, in run: WCDocument) {
        // Persist unsaved edits before moving — Previous/Next never lose work.
        if draftDirty { save(run, seq: selectedSeq) }
        selectedSeq = seq
        draft = run.fieldValues[seq] ?? [:]
        draftDirty = false
        justPosted = nil
        errorMessage = nil
    }

    private func save(_ run: WCDocument, seq: Int) {
        guard let repo = appState.workCenter else { return }
        let values = draft
        Task {
            do {
                try await repo.saveFields(runID: run.id, seq: seq, values: values, at: Date())
                draftDirty = false
                await reloadRun(run.id)
            } catch {
                errorMessage = "Could not save: \(error)"
            }
        }
    }

    private func confirm(_ run: WCDocument, op: WCOperation) {
        guard let repo = appState.workCenter else { return }
        errorMessage = nil
        let values = draft
        Task {
            do {
                try await repo.saveFields(runID: run.id, seq: op.seq, values: values, at: Date())
                let (posted, updated) = try await repo.confirmStep(
                    runID: run.id, seq: op.seq, actor: actorName, at: Date())
                justPosted = posted
                activeRun = updated
                postedDocs = (try? await repo.documents(inRun: run.id)) ?? []
                draftDirty = false
            } catch let wcError as WorkCenterError {
                errorMessage = friendly(wcError)
            } catch {
                errorMessage = "Could not confirm: \(error)"
            }
        }
    }

    private func reloadRun(_ id: UUID) async {
        guard let repo = appState.workCenter else { return }
        if let run = try? await repo.run(id) { activeRun = run }
        postedDocs = (try? await repo.documents(inRun: id)) ?? []
    }

    private func friendly(_ error: WorkCenterError) -> String {
        switch error {
        case .missingRequiredFields(let labels):
            return "Fill the required field\(labels.count == 1 ? "" : "s") first: \(labels.joined(separator: ", "))."
        case .gatesLocked(let reasons):
            return reasons.joined(separator: " ")
        case .stepAlreadyConfirmed:
            return "This step is already confirmed."
        case .runNotFound:
            return "This run no longer exists."
        case .unknownDefinition, .unknownStep, .invalidStatusAdvance:
            return "This workflow can't be advanced: \(error)"
        }
    }
}
