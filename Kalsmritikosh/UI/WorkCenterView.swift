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
//  Parity pass (2026-08-17): auto-save as you type + auto-complete when a
//  step's required fields are filled (with an engagement guard so seeded
//  values never auto-fire), "How this job works" guide, per-step guidance
//  and notes, who/when attestations, stakeholder Summary + Copy Report +
//  Print, register search + date filter + expandable detail, auto-advance.
//  Because this shell is single-window, the active run and opened-tool marks
//  persist so an "Open tool" round trip resumes exactly where you left off.
//

import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

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
    @State private var showSummary = false

    // Variants (SAP master data: start a run pre-filled from a saved one).
    @State private var variantsByDef: [String: [WCDocument]] = [:]
    @State private var showSaveVariant = false
    @State private var variantName = ""
    /// The run's "Client / matter" name — renames the run so it's findable.
    @State private var clientName = ""
    // Attach-evidence + derivation-notice state.
    @State private var showFileImporter = false
    @State private var derivedKeys: Set<String> = []

    // Auto-save defaults ON; auto-complete defaults OFF (owner decision
    // 2026-08-18, matching how the owner runs the source system) — steps are
    // finalized with an explicit Confirm unless the user opts in via the
    // automation menu.
    @AppStorage("kalsmritikosh.wc.autoSave") private var autoSave = true
    @AppStorage("kalsmritikosh.wc.autoComplete") private var autoComplete = false
    /// Steps whose fields the user actually touched this session — the
    /// engagement guard so auto-complete never fires on untouched values.
    @State private var touchedSeqs: Set<Int> = []
    @State private var autoTask: Task<Void, Never>?
    @State private var savedFlash = false

    // First-run guidance — once per workflow, once per step's Open.
    @AppStorage("kalsmritikosh.wc.introSeen") private var introSeenBlob = ""
    @AppStorage("kalsmritikosh.wc.stepOpenSeen") private var stepOpenSeenBlob = ""
    @State private var showIntro = false
    @State private var openPromptOp: WCOperation?

    /// Single-window shell: remember the open run + opened tools across the
    /// "Open tool" round trip (the view is destroyed while the user works in
    /// the launched surface).
    @AppStorage("kalsmritikosh.wc.activeRun") private var persistedRunID = ""
    @AppStorage("kalsmritikosh.wc.openedSteps") private var openedStepsBlob = ""

    // Documents register — search + date filter + expandable detail.
    @State private var docSearch = ""
    @State private var docDateFilterOn = false
    @State private var docFrom = Date().addingTimeInterval(-30 * 86_400)
    @State private var docTo = Date()
    @State private var expandedDocID: UUID?

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
        .task { await restoreAndReload() }
        .sheet(isPresented: $showSummary) { summarySheet }
        .alert("Save as Variant", isPresented: $showSaveVariant) {
            TextField("Variant name", text: $variantName)
            Button("Cancel", role: .cancel) {}
            Button("Save") { saveVariant() }
        } message: {
            Text("Reuse this run's field entries next time by starting from this variant.")
        }
        .fileImporter(isPresented: $showFileImporter,
                      allowedContentTypes: [.item],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { attachFiles(urls) }
        }
        .alert("Opening a tool for this step",
               isPresented: Binding(get: { openPromptOp != nil },
                                    set: { if !$0 { openPromptOp = nil } }),
               presenting: openPromptOp) { op in
            Button("Open now") { performOpen(op) }
            Button("Cancel", role: .cancel) { openPromptOp = nil }
        } message: { op in
            Text("\(op.hint)\n\nThe app switches to that screen. Do the work there, then come back to Work Center — this run reopens exactly where you left off\(autoComplete ? ", and the step marks itself done once its required fields are filled" : "").")
        }
    }

    // MARK: - Boot / restore

    private func restoreAndReload() async {
        await reloadLists()
        // Resume the run that was open when the user jumped out to a tool.
        if activeRun == nil, let id = UUID(uuidString: persistedRunID),
           let repo = appState.workCenter, let run = try? await repo.run(id),
           run.status != .confirmed {
            open(run)
        }
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

                documentsRegister
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
                .help("Resume this run where you left off")
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
            Text(def.operations.map(\.title).joined(separator: " → "))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            HStack {
                Text("\(def.operations.count) steps · posts \(postedTypes(def))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Start") { start(def) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Start a new run of this workflow — it gets its own WF number")
            }
            ForEach(variantsByDef[def.defID] ?? []) { variant in
                Button {
                    start(def, variant: variant)
                } label: {
                    Label("Start from: \(variant.title)", systemImage: "square.stack.3d.up")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .help("Start a run pre-filled from this saved variant (\(variant.docNumber))")
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

    // MARK: - Documents register (search + date filter + detail)

    private var visibleDocuments: [WCDocument] {
        allDocuments.filter { doc in
            WCDocumentFilter.matches(doc, query: docSearch)
                && (!docDateFilterOn
                    || WCDocumentFilter.inRange(doc, from: docFrom, to: docTo, calendar: .current))
        }
    }

    @ViewBuilder
    private var documentsRegister: some View {
        if !allDocuments.isEmpty {
            sectionLabel("Documents — every number issued")
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search by number, title, or any entered value — e.g. WF-2026 or a matter name",
                          text: $docSearch)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))

            HStack(spacing: 10) {
                Toggle(isOn: $docDateFilterOn) {
                    Label("Date range", systemImage: "calendar").font(.caption)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help("Show only documents created between two dates")
                if docDateFilterOn {
                    DatePicker("", selection: $docFrom, displayedComponents: .date)
                        .labelsHidden().controlSize(.small)
                    Text("→").foregroundStyle(.secondary)
                    DatePicker("", selection: $docTo, displayedComponents: .date)
                        .labelsHidden().controlSize(.small)
                }
                Spacer()
                Text("\(visibleDocuments.count) shown")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            VStack(spacing: 6) {
                if visibleDocuments.isEmpty {
                    Text("No document matches the current search / date range.")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(visibleDocuments.prefix(60)) { doc in
                    VStack(alignment: .leading, spacing: 0) {
                        documentRow(doc)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    expandedDocID = expandedDocID == doc.id ? nil : doc.id
                                }
                            }
                            .help("Click to see everything recorded on this document")
                        if expandedDocID == doc.id { documentDetail(doc) }
                    }
                }
            }
        }
    }

    private func documentRow(_ doc: WCDocument) -> some View {
        HStack(spacing: 10) {
            Image(systemName: WCDocType.icon(doc.docType))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(doc.docNumber)
                .font(.caption.monospaced().weight(.semibold))
                .textSelection(.enabled)
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

    /// Everything recorded on a document, label: value, in recipe order.
    private func documentDetail(_ doc: WCDocument) -> some View {
        let def = doc.defID.flatMap(WCCatalog.definition)
        return VStack(alignment: .leading, spacing: 4) {
            detailLine("Type", WCDocType.displayName(doc.docType))
            detailLine("By", doc.actor)
            ForEach((def?.operations ?? []).filter { doc.fieldValues[$0.seq] != nil }, id: \.seq) { op in
                let vals = doc.fieldValues[op.seq] ?? [:]
                if doc.docType == "WF" {
                    Text("\(op.seq). \(op.title)")
                        .font(.caption.weight(.semibold))
                        .padding(.top, 2)
                }
                ForEach(op.fields.filter { !(vals[$0.key] ?? "").isEmpty }) { field in
                    detailLine(field.label, vals[field.key] ?? "")
                }
                ForEach(WCStepRef.decodeList(vals[WCReservedKey.refs])) { ref in
                    detailLine("Evidence", ref.detail.isEmpty ? ref.title : "\(ref.title) — \(ref.detail)")
                }
                if let note = vals[WCReservedKey.note], !note.isEmpty {
                    detailLine("Note", note)
                }
                if let att = WCReservedKey.attestation(in: vals) {
                    detailLine("Confirmed", "\(att.at.formatted(date: .abbreviated, time: .shortened))\(att.by.isEmpty ? "" : " by \(att.by)")")
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
        .padding(.leading, 28)
    }

    private func detailLine(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("\(label):").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).font(.caption2).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Run screen

    @ViewBuilder
    private func runScreen(_ run: WCDocument) -> some View {
        if let def = run.defID.flatMap(WCCatalog.definition) {
            HSplitView {
                stepRail(run, def)
                    .frame(minWidth: 250, idealWidth: 290, maxWidth: 350)
                VStack(alignment: .leading, spacing: 0) {
                    if showIntro { introCard(def) }
                    stepDetail(run, def)
                }
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            ContentUnavailableView("Unknown workflow",
                                   systemImage: "questionmark.circle",
                                   description: Text("This run references a workflow definition that no longer exists."))
        }
    }

    // MARK: Step states (one colour per state, like the source system)

    private enum StepState { case done, current, locked, upcoming }

    private func stepState(_ op: WCOperation, run: WCDocument) -> StepState {
        if run.confirmedSeqs.contains(op.seq) { return .done }
        if !lockedReasons(op, run: run).isEmpty { return .locked }
        if op.seq == currentOp(run)?.seq { return .current }
        return .upcoming
    }

    private func stateColor(_ st: StepState) -> Color {
        switch st {
        case .done:     return .green
        case .current:  return .accentColor
        case .locked:   return .orange
        case .upcoming: return .secondary
        }
    }

    /// The step the user should be on now: first not-done, unlocked step.
    private func currentOp(_ run: WCDocument) -> WCOperation? {
        guard let def = run.defID.flatMap(WCCatalog.definition) else { return nil }
        return def.operations.first {
            !run.confirmedSeqs.contains($0.seq) && lockedReasons($0, run: run).isEmpty
        }
    }

    private func lockedReasons(_ op: WCOperation, run: WCDocument) -> [String] {
        WCGatePolicy.lockedReasons(op, state: gateState(run))
    }

    private func stepRail(_ run: WCDocument, _ def: WCWorkflowDefinition) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Button {
                        closeRun()
                    } label: {
                        Label("All workflows", systemImage: "chevron.left")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    Spacer()
                    automationMenu
                    Button { showIntro = true } label: {
                        Image(systemName: "questionmark.circle")
                    }
                    .buttonStyle(.plain)
                    .help("How this job works — show the step-by-step guide again")
                }

                Text(run.title).font(.headline)
                HStack(spacing: 8) {
                    Text(run.docNumber).font(.caption.monospaced().weight(.semibold))
                        .textSelection(.enabled)
                    statusChip(run.status)
                }
                HStack(spacing: 4) {
                    Text("Client / matter").font(.caption2).foregroundStyle(.secondary)
                    TextField("name this job so you can find it later", text: $clientName)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                        .onSubmit { renameRun(run) }
                }
                ProgressView(value: Double(run.confirmedSeqs.count),
                             total: Double(def.operations.count))
                    .tint(.green)
                    .controlSize(.small)
                    .animation(.easeInOut(duration: 0.35), value: run.confirmedSeqs.count)
                Text(progressLine(run, def))
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                HStack(spacing: 6) {
                    Button { showSummary = true } label: {
                        Label("Summary", systemImage: "doc.richtext").font(.caption)
                    }
                    .controlSize(.small)
                    .help("A clean, plain-language summary you can hand to a non-technical reader — counsel, a manager. Copy or print it.")
                    Button { copyToClipboard(reportText(run, def)) } label: {
                        Label("Copy Report", systemImage: "doc.on.doc").font(.caption)
                    }
                    .controlSize(.small)
                    .help("Copy the full technical report — every step, value, attestation and document number")
                    Button {
                        variantName = ""
                        showSaveVariant = true
                    } label: {
                        Label("Variant", systemImage: "square.and.arrow.down.on.square").font(.caption)
                    }
                    .controlSize(.small)
                    .help("Save this run's entries as a reusable variant — next time, start pre-filled in one click")
                    #if os(macOS)
                    Button { printText(reportText(run, def), jobTitle: run.docNumber, monospace: true) } label: {
                        Image(systemName: "printer").font(.caption)
                    }
                    .controlSize(.small)
                    .help("Print the technical report")
                    #endif
                }
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

    /// Quick per-run automation switches.
    private var automationMenu: some View {
        Menu {
            Toggle(isOn: $autoSave) { Label("Auto-save as I go", systemImage: "square.and.arrow.down") }
            Toggle(isOn: $autoComplete) { Label("Auto-complete steps when filled", systemImage: "checkmark.circle") }
            Divider()
            Text("Off = save and confirm each step yourself.")
        } label: {
            Image(systemName: "slider.horizontal.3")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Automation — turn auto-save and auto-complete on or off")
    }

    private func progressLine(_ run: WCDocument, _ def: WCWorkflowDefinition) -> String {
        let done = run.confirmedSeqs.count
        if done == def.operations.count { return "All \(done) steps confirmed — workflow complete." }
        guard let now = currentOp(run) else { return "\(done) of \(def.operations.count) steps done" }
        let idx = (def.operations.firstIndex { $0.seq == now.seq } ?? 0) + 1
        let next = def.operations.first { $0.seq > now.seq }
        return "Step \(idx) of \(def.operations.count) · Now: \(now.title)\(next.map { " → Next: \($0.title)" } ?? " → Finish")"
    }

    private func railRow(_ op: WCOperation, run: WCDocument) -> some View {
        let st = stepState(op, run: run)
        let color = stateColor(st)
        let selected = op.seq == selectedSeq
        let vals = run.fieldValues[op.seq] ?? [:]
        let icon: String = switch st {
        case .done:     "checkmark.circle.fill"
        case .current:  "arrow.right.circle.fill"
        case .locked:   "lock.fill"
        case .upcoming: "\(op.seq).circle"
        }
        return Button {
            select(op.seq, in: run)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(st == .upcoming ? color.opacity(0.25) : color)
                    .frame(width: 3)
                Image(systemName: icon)
                    .foregroundStyle(color)
                VStack(alignment: .leading, spacing: 1) {
                    Text(op.title)
                        .font(.callout.weight(selected || st == .current ? .semibold : .regular))
                        .foregroundStyle(.primary)
                    if let att = WCReservedKey.attestation(in: vals) {
                        Text("\(att.at.formatted(date: .abbreviated, time: .shortened))\(att.by.isEmpty ? "" : " · \(att.by)")\(postedDocs.first { $0.stepSeq == op.seq }.map { " · \($0.docNumber)" } ?? "")")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else if st == .locked, let reason = lockedReasons(op, run: run).first {
                        Label(reason, systemImage: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                    } else if let type = op.postsDocType {
                        Text("Posts \(WCDocType.displayName(type))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 8).padding(.vertical, 7)
            .background(selected ? AnyShapeStyle(.tint.opacity(0.12)) : AnyShapeStyle(.clear),
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(chipHelp(op, state: st, run: run))
    }

    private func chipHelp(_ op: WCOperation, state: StepState, run: WCDocument) -> String {
        switch state {
        case .done:     return "Done — click to review this step"
        case .current:  return "You are here — \(op.hint)"
        case .locked:   return "Locked — \(lockedReasons(op, run: run).first ?? "finish the earlier step first")"
        case .upcoming: return "Coming up — \(op.hint)"
        }
    }

    // MARK: First-run guide

    private func introSeen(_ def: WCWorkflowDefinition) -> Bool {
        introSeenBlob.split(separator: ",").map(String.init).contains(def.defID)
    }
    private func markIntroSeen(_ def: WCWorkflowDefinition) {
        if !introSeen(def) {
            introSeenBlob += (introSeenBlob.isEmpty ? "" : ",") + def.defID
        }
        showIntro = false
    }

    private func introCard(_ def: WCWorkflowDefinition) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("How this job works", systemImage: "lightbulb.fill")
                    .font(.callout.weight(.semibold))
                Spacer()
                Button { markIntroSeen(def) } label: { Image(systemName: "xmark").imageScale(.small) }
                    .buttonStyle(.plain)
                    .help("Hide — reopen any time with the ? button")
            }
            Text(def.purpose)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            guideLine("1", "Work top to bottom on the left rail. Each step explains itself; fill its fields on the right.")
            guideLine("2", "For a step that needs a tool, press Open — do the work there, then come back to Work Center; this run reopens where you left off.")
            guideLine("3", autoComplete
                      ? "Each step marks itself done once its required fields are filled — no separate confirm."
                      : "Press Confirm on each step to finalize it (auto-complete is off).")
            guideLine("4", autoSave
                      ? "Everything auto-saves — close any time and resume from the Work Center list."
                      : "Auto-save is off — press Save on a step to store your entries.")
            Text("The \(def.operations.count) steps:  " + def.operations.map { "\($0.seq). \($0.title)" }.joined(separator: "  →  "))
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Got it") { markIntroSeen(def) }
                .buttonStyle(.borderedProminent).controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.tint.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .padding([.horizontal, .top], 16)
    }

    private func guideLine(_ n: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(n)
                .font(.caption2.weight(.bold)).foregroundStyle(.tint)
                .frame(width: 15, height: 15)
                .background(.tint.opacity(0.15), in: Circle())
            Text(text).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Step detail

    private func stepDetail(_ run: WCDocument, _ def: WCWorkflowDefinition) -> some View {
        let op = def.operations.first { $0.seq == selectedSeq } ?? def.operations[0]
        let locked = lockedReasons(op, run: run)
        let confirmed = run.confirmedSeqs.contains(op.seq)
        let vals = run.fieldValues[op.seq] ?? [:]
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // Header
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Step \(op.seq) of \(def.operations.count)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        if savedFlash {
                            Label("Saved", systemImage: "checkmark.circle")
                                .font(.caption2).foregroundStyle(.green)
                                .transition(.opacity)
                        }
                    }
                    Text(op.title).font(.title2.weight(.bold))
                }

                // What to do here — the per-step guidance box.
                VStack(alignment: .leading, spacing: 4) {
                    Label("What to do here", systemImage: "info.circle.fill")
                        .font(.caption.weight(.semibold)).foregroundStyle(.tint)
                    Text(stepGuidance(op))
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(.tint.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))

                if let posted = justPosted {
                    banner(icon: "checkmark.seal.fill", tint: .green,
                           text: "Posted \(WCDocType.displayName(posted.docType)) \(posted.docNumber) — find it later in Documents by this number or any value you entered.")
                } else if confirmed, let att = WCReservedKey.attestation(in: vals) {
                    banner(icon: "checkmark.circle.fill", tint: .green,
                           text: "Confirmed \(att.at.formatted(date: .abbreviated, time: .shortened))\(att.by.isEmpty ? "" : " by \(att.by)")."
                                 + (postedDocs.first { $0.stepSeq == op.seq }
                                        .map { " Document \($0.docNumber)." } ?? ""))
                } else if !locked.isEmpty {
                    banner(icon: "lock.fill", tint: .orange,
                           text: locked.joined(separator: " ")
                                 + " You can read and fill this now; it finalizes once the earlier step is done.")
                }

                if let message = errorMessage {
                    banner(icon: "exclamationmark.triangle.fill", tint: .red, text: message)
                }

                // The real surface where this step's work happens.
                if let surface = op.launchesSurface.flatMap(Destination.init(rawValue:)) {
                    Button {
                        requestOpen(op, surface: surface)
                    } label: {
                        Label("Open \(surface.title) — do this step's work there",
                              systemImage: surface.icon)
                    }
                    .buttonStyle(.bordered)
                    .help("Open the tool to do this step now — this run reopens when you come back")
                }

                // Fields
                if !op.fields.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        if !derivedKeys.isEmpty && !confirmed {
                            Label("Some fields were filled in from your earlier runs — check and adjust.",
                                  systemImage: "wand.and.stars")
                                .font(.caption).foregroundStyle(.tint)
                        }
                        ForEach(op.fields) { field in
                            fieldInput(field, run: run, op: op, disabled: confirmed)
                        }
                        evidenceSection(run: run, op: op, disabled: confirmed)
                        // Optional per-step note (attached to the record).
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Note (optional)").font(.callout.weight(.medium))
                            TextField("Anything else worth recording",
                                      text: draftBinding(WCReservedKey.note, run: run, op: op),
                                      axis: .vertical)
                                .textFieldStyle(.roundedBorder)
                                .lineLimit(1...3)
                                .disabled(confirmed)
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
                    .help("Go back a step — nothing is lost")

                    Button {
                        select(min(def.operations.count, op.seq + 1), in: run)
                    } label: { Label("Next", systemImage: "chevron.right") }
                    .disabled(op.seq >= def.operations.count)
                    .help("Jump to the next step")

                    Spacer()

                    if !confirmed {
                        if !autoSave {
                            Button("Save") { save(run, seq: op.seq) }
                                .disabled(!draftDirty)
                                .help("Store your entries for this step")
                        }
                        Button {
                            confirm(run, op: op)
                        } label: {
                            Label(op.postsDocType.map { "Confirm & post \(WCDocType.displayName($0))" }
                                    ?? "Confirm step",
                                  systemImage: "checkmark.seal")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!locked.isEmpty)
                        .help("Finalize this step and record who did it and when")
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

    /// Plain-language "what to do here" — adapts to the automation settings.
    private func stepGuidance(_ op: WCOperation) -> String {
        var s = op.hint
        if op.launchesSurface != nil {
            s += " Press \u{201C}Open\u{201D} to do this in the app, then come back and fill the fields below."
        } else {
            s += " Fill the fields below."
        }
        if autoSave { s += " Entries save as you type" } else { s += " Press Save to store entries" }
        if autoComplete { s += "; the step marks itself done once its required fields are filled." }
        else { s += "; press Confirm to finalize it." }
        if let doc = op.postsDocType {
            s += " Finalizing posts a \(WCDocType.displayName(doc)) you can quote or export later."
        }
        return s
    }

    // MARK: - Field inputs

    @ViewBuilder
    private func fieldInput(_ field: WCField, run: WCDocument, op: WCOperation, disabled: Bool) -> some View {
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
                TextField(field.placeholder, text: draftBinding(field.key, run: run, op: op))
                    .textFieldStyle(.roundedBorder)
                    .disabled(disabled)
            case .longText:
                TextEditor(text: draftBinding(field.key, run: run, op: op))
                    .font(.callout)
                    .frame(minHeight: 76)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                    .disabled(disabled)
            case .choice:
                Picker(field.label, selection: draftBinding(field.key, run: run, op: op)) {
                    Text("—").tag("")
                    ForEach(field.options, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .disabled(disabled)
            case .bool:
                Picker(field.label, selection: draftBinding(field.key, run: run, op: op)) {
                    Text("—").tag("")
                    Text("Yes").tag("Yes")
                    Text("No").tag("No")
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: 220)
                .disabled(disabled)
            case .date:
                DatePicker("", selection: dateBinding(field.key, run: run, op: op),
                           displayedComponents: .date)
                    .datePickerStyle(.compact)
                    .labelsHidden()
                    .disabled(disabled)
            case .dateRange:
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("From").font(.caption2).foregroundStyle(.secondary)
                        DatePicker("", selection: rangeBinding(field.key, part: 0, run: run, op: op),
                                   displayedComponents: .date)
                            .datePickerStyle(.compact).labelsHidden()
                            .disabled(disabled)
                    }
                    Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("To").font(.caption2).foregroundStyle(.secondary)
                        DatePicker("", selection: rangeBinding(field.key, part: 1, run: run, op: op),
                                   displayedComponents: .date)
                            .datePickerStyle(.compact).labelsHidden()
                            .disabled(disabled)
                    }
                }
            }
            Text(field.help)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func draftBinding(_ key: String, run: WCDocument, op: WCOperation) -> Binding<String> {
        Binding(
            get: { draft[key] ?? "" },
            set: { newValue in
                draft[key] = newValue
                draftDirty = true
                onFieldEdited(run, op: op)
            }
        )
    }

    // MARK: Date fields (stored as "yyyy-MM-dd" / "yyyy-MM-dd → yyyy-MM-dd")

    private var dayFormatter: DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }

    private func dateBinding(_ key: String, run: WCDocument, op: WCOperation) -> Binding<Date> {
        Binding(
            get: { dayFormatter.date(from: draft[key] ?? "") ?? Date() },
            set: { draftBinding(key, run: run, op: op).wrappedValue = dayFormatter.string(from: $0) }
        )
    }

    private func rangeParts(_ key: String) -> (String, String) {
        let parts = (draft[key] ?? "").components(separatedBy: " → ")
        return (parts.first ?? "", parts.count > 1 ? parts[1] : "")
    }

    private func rangeBinding(_ key: String, part: Int, run: WCDocument, op: WCOperation) -> Binding<Date> {
        Binding(
            get: {
                let raw = part == 0 ? rangeParts(key).0 : rangeParts(key).1
                return dayFormatter.date(from: raw) ?? Date()
            },
            set: { newDate in
                var (from, to) = rangeParts(key)
                if part == 0 { from = dayFormatter.string(from: newDate) }
                else { to = dayFormatter.string(from: newDate) }
                draftBinding(key, run: run, op: op).wrappedValue = "\(from) → \(to)"
            }
        )
    }

    // MARK: Attach evidence (external files, stored as reserved __refs JSON)

    private func stepRefs() -> [WCStepRef] {
        WCStepRef.decodeList(draft[WCReservedKey.refs])
    }

    @ViewBuilder
    private func evidenceSection(run: WCDocument, op: WCOperation, disabled: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Evidence attached").font(.callout.weight(.medium))
                Spacer()
                if !disabled {
                    Button {
                        showFileImporter = true
                    } label: { Label("Attach files", systemImage: "paperclip") }
                    .controlSize(.small)
                    .help("Attach the files this step rests on — they ride with the record and are searchable")
                }
            }
            if stepRefs().isEmpty {
                Text("Nothing attached — optional, but attached files make the record self-explanatory later.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            ForEach(stepRefs()) { ref in
                HStack(spacing: 6) {
                    Image(systemName: "doc").foregroundStyle(.secondary)
                    Text(ref.title).font(.caption)
                    if !ref.detail.isEmpty {
                        Text(ref.detail).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                    }
                    Spacer()
                    if !disabled {
                        Button {
                            setRefs(stepRefs().filter { $0.id != ref.id }, run: run, op: op)
                        } label: { Image(systemName: "xmark.circle") }
                        .buttonStyle(.plain)
                        .help("Remove this attachment from the step")
                    }
                }
            }
        }
    }

    private func attachFiles(_ urls: [URL]) {
        guard let run = activeRun, let def = run.defID.flatMap(WCCatalog.definition),
              let op = def.operations.first(where: { $0.seq == selectedSeq }) else { return }
        let new = urls.map {
            WCStepRef(id: UUID().uuidString, title: $0.lastPathComponent,
                      detail: $0.deletingLastPathComponent().path)
        }
        setRefs(stepRefs() + new, run: run, op: op)
    }

    private func setRefs(_ refs: [WCStepRef], run: WCDocument, op: WCOperation) {
        draft[WCReservedKey.refs] = WCStepRef.encodeList(refs)
        draftDirty = true
        onFieldEdited(run, op: op)
    }

    // MARK: Prefill (derivation + date seeds — never marks the step touched)

    private func prefill(_ op: WCOperation, run: WCDocument) {
        derivedKeys = []
        guard !run.confirmedSeqs.contains(op.seq) else { return }
        let derived = WCFieldDerivation.derive(
            for: op, examiner: actorName,
            priorRuns: runs.filter { $0.id != run.id })
        for (key, value) in derived where (draft[key] ?? "").isEmpty {
            draft[key] = value
            derivedKeys.insert(key)
            draftDirty = true
        }
        // Seed date fields so the calendar opens on a real date.
        let today = dayFormatter.string(from: Date())
        for field in op.fields where (draft[field.key] ?? "").isEmpty {
            switch field.kind {
            case .date:
                draft[field.key] = today
                draftDirty = true
            case .dateRange:
                let start = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
                draft[field.key] = "\(dayFormatter.string(from: start)) → \(today)"
                draftDirty = true
            default: break
            }
        }
    }

    // MARK: Variants + rename

    private func saveVariant() {
        guard let repo = appState.workCenter, let run = activeRun,
              let defID = run.defID else { return }
        let name = variantName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        var values = run.fieldValues
        var merged = values[selectedSeq] ?? [:]
        for (k, v) in draft { merged[k] = v }
        values[selectedSeq] = merged
        Task {
            do {
                _ = try await repo.createVariant(defID: defID, name: name,
                                                 values: values, actor: actorName, at: Date())
                await reloadLists()
            } catch {
                errorMessage = "Could not save the variant: \(error)"
            }
        }
    }

    private func renameRun(_ run: WCDocument) {
        guard let repo = appState.workCenter else { return }
        let name = clientName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != run.title else { return }
        Task {
            try? await repo.rename(runID: run.id, title: name, at: Date())
            await reloadRun(run.id)
            await reloadLists()
        }
    }

    // MARK: Auto-save / auto-complete

    /// A field changed: persist after a short dwell (if auto-save), then —
    /// after a longer dwell — auto-confirm the step if it's eligible.
    private func onFieldEdited(_ run: WCDocument, op: WCOperation) {
        errorMessage = nil
        touchedSeqs.insert(op.seq)
        guard autoSave else { return }
        autoTask?.cancel()
        let values = draft
        autoTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, selectedSeq == op.seq else { return }
            await persistDraft(run, seq: op.seq, values: values, flash: true)
            guard autoComplete else { return }
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled, selectedSeq == op.seq,
                  let currentRun = try? await appState.workCenter?.run(run.id) else { return }
            let eligible = WCAutoComplete.eligible(
                op,
                confirmed: currentRun.confirmedSeqs,
                lockedReasons: lockedReasons(op, run: currentRun),
                values: draft,
                touched: touchedSeqs.contains(op.seq),
                openedTool: openedSteps().contains("\(run.id.uuidString)#\(op.seq)"))
            if eligible { confirm(currentRun, op: op) }
        }
    }

    @MainActor
    private func persistDraft(_ run: WCDocument, seq: Int, values: [String: String], flash: Bool) async {
        guard let repo = appState.workCenter else { return }
        do {
            try await repo.saveFields(runID: run.id, seq: seq, values: values, at: Date())
            draftDirty = false
            if let updated = try? await repo.run(run.id) { activeRun = updated }
            if flash {
                withAnimation { savedFlash = true }
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    withAnimation { savedFlash = false }
                }
            }
        } catch {
            errorMessage = "Could not save: \(error)"
        }
    }

    // MARK: Open-tool guidance + persistence

    private func openedSteps() -> Set<String> {
        Set(openedStepsBlob.split(separator: ",").map(String.init))
    }
    private func stepOpenSeen(_ op: WCOperation, def: WCWorkflowDefinition) -> Bool {
        stepOpenSeenBlob.split(separator: ",").map(String.init).contains("\(def.defID)#\(op.seq)")
    }

    /// First time for this step, explain what happens; after that, open straight away.
    private func requestOpen(_ op: WCOperation, surface: Destination) {
        guard let run = activeRun, let def = run.defID.flatMap(WCCatalog.definition) else { return }
        if stepOpenSeen(op, def: def) { performOpen(op) } else { openPromptOp = op }
        _ = surface
    }

    private func performOpen(_ op: WCOperation) {
        guard let run = activeRun, let def = run.defID.flatMap(WCCatalog.definition),
              let surface = op.launchesSurface.flatMap(Destination.init(rawValue:)) else { return }
        let seenKey = "\(def.defID)#\(op.seq)"
        if !stepOpenSeen(op, def: def) {
            stepOpenSeenBlob += (stepOpenSeenBlob.isEmpty ? "" : ",") + seenKey
        }
        let openedKey = "\(run.id.uuidString)#\(op.seq)"
        if !openedSteps().contains(openedKey) {
            openedStepsBlob += (openedStepsBlob.isEmpty ? "" : ",") + openedKey
        }
        openPromptOp = nil
        // Persist the draft so nothing is lost across the round trip.
        if draftDirty { save(run, seq: selectedSeq) }
        onNavigate(surface)
    }

    // MARK: - Reports

    private func reportText(_ run: WCDocument, _ def: WCWorkflowDefinition) -> String {
        WCInstanceReport(run: run, definition: def, documents: postedDocs).rendered()
    }

    private func summaryText(_ run: WCDocument, _ def: WCWorkflowDefinition) -> String {
        WCStakeholderSummary(run: run, definition: def, documents: postedDocs,
                             preparedAt: Date()).rendered()
    }

    @ViewBuilder
    private var summarySheet: some View {
        if let run = activeRun, let def = run.defID.flatMap(WCCatalog.definition) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Label("Summary for a non-technical reader", systemImage: "doc.richtext")
                        .font(.headline)
                    Spacer()
                    Button { copyToClipboard(summaryText(run, def)) } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    #if os(macOS)
                    Button { printText(summaryText(run, def), jobTitle: run.docNumber, monospace: false) } label: {
                        Label("Print", systemImage: "printer")
                    }
                    #endif
                    Button("Done") { showSummary = false }
                        .buttonStyle(.borderedProminent)
                }
                .padding(16)
                Divider()
                ScrollView {
                    Text(summaryText(run, def))
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
            }
            .frame(minWidth: 560, minHeight: 480)
        }
    }

    private func copyToClipboard(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }

    #if os(macOS)
    private func printText(_ text: String, jobTitle: String, monospace: Bool) {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 468, height: 648))
        textView.string = text
        textView.font = monospace
            ? NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
            : NSFont.systemFont(ofSize: 11)
        let operation = NSPrintOperation(view: textView)
        operation.jobTitle = jobTitle
        operation.run()
    }
    #endif

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
        var byDef: [String: [WCDocument]] = [:]
        for def in WCCatalog.all {
            byDef[def.defID] = (try? await repo.variants(defID: def.defID)) ?? []
        }
        variantsByDef = byDef
    }

    private func start(_ def: WCWorkflowDefinition, variant: WCDocument? = nil) {
        guard let repo = appState.workCenter else { return }
        errorMessage = nil
        Task {
            do {
                var run = try await repo.createRun(
                    defID: def.defID,
                    title: variant?.title ?? def.name,
                    actor: actorName,
                    at: Date())
                // Pre-fill every step from the variant's saved entries.
                if let variant {
                    for (seq, values) in variant.fieldValues {
                        try await repo.saveFields(runID: run.id, seq: seq,
                                                  values: values, at: Date())
                    }
                    if let refreshed = try await repo.run(run.id) { run = refreshed }
                }
                open(run)
                showIntro = !introSeen(def)
            } catch {
                errorMessage = "Could not start the workflow: \(error)"
            }
        }
    }

    private func open(_ run: WCDocument) {
        activeRun = run
        persistedRunID = run.id.uuidString
        clientName = run.title
        justPosted = nil
        errorMessage = nil
        if let def = run.defID.flatMap(WCCatalog.definition) {
            selectedSeq = currentOp(run)?.seq ?? def.operations.last?.seq ?? 1
            showIntro = !introSeen(def)
        } else {
            selectedSeq = 1
        }
        draft = run.fieldValues[selectedSeq] ?? [:]
        draftDirty = false
        if let def = run.defID.flatMap(WCCatalog.definition),
           let op = def.operations.first(where: { $0.seq == selectedSeq }) {
            prefill(op, run: run)
        }
        Task { await reloadRun(run.id) }
    }

    private func closeRun() {
        autoTask?.cancel()
        if let run = activeRun, draftDirty { save(run, seq: selectedSeq) }
        activeRun = nil
        persistedRunID = ""
        Task { await reloadLists() }
    }

    private func select(_ seq: Int, in run: WCDocument) {
        // Persist unsaved edits before moving — Previous/Next never lose work.
        autoTask?.cancel()
        if draftDirty { save(run, seq: selectedSeq) }
        selectedSeq = seq
        let current = activeRun ?? run
        draft = current.fieldValues[seq] ?? [:]
        draftDirty = false
        justPosted = nil
        errorMessage = nil
        if let def = current.defID.flatMap(WCCatalog.definition),
           let op = def.operations.first(where: { $0.seq == seq }) {
            prefill(op, run: current)
        }
    }

    private func save(_ run: WCDocument, seq: Int) {
        let values = draft
        Task { await persistDraft(run, seq: seq, values: values, flash: false) }
    }

    private func confirm(_ run: WCDocument, op: WCOperation) {
        guard let repo = appState.workCenter else { return }
        errorMessage = nil
        autoTask?.cancel()
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
                if updated.status == .confirmed { persistedRunID = "" }
                // Auto-advance to the next open step (the posted banner stays
                // visible until the next interaction).
                if let next = currentOp(updated), next.seq != op.seq {
                    selectedSeq = next.seq
                    draft = updated.fieldValues[next.seq] ?? [:]
                    draftDirty = false
                } else {
                    draft = updated.fieldValues[op.seq] ?? [:]
                }
            } catch let wcError as WorkCenterError {
                errorMessage = friendly(wcError)
            } catch {
                errorMessage = "Could not confirm: \(error)"
            }
        }
    }

    private func reloadRun(_ id: UUID) async {
        guard let repo = appState.workCenter else { return }
        if let run = try? await repo.run(id) {
            activeRun = run
            // Refresh the visible draft with what's on file (e.g. after an
            // Open-tool round trip re-created this view).
            if !draftDirty { draft = run.fieldValues[selectedSeq] ?? [:] }
        }
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
