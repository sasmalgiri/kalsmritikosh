//
//  PrivilegeLogStudioView.swift
//  Kalsmritikosh
//
//  The Lawyer's Privilege-Log studio (persona studio #2). Walks the real-life
//  steps — Matter → Withheld documents → QC review → Log — and produces the
//  exact FRCP 26(b)(5) hardcopy: the caption'd table with a legend and a
//  certification block. Persists on-device as JSON.
//

import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

public struct PrivilegeLogStudioView: View {
    /// Final brief §3.1 — drafts live in the encrypted ledger, bound to their case.
    @State private var storage = StudioStorage(studio: "privilegeLog", legacyKey: "kalsmritikosh.pl.store")
    @Environment(AppState.self) private var appState
    @State private var logs: [PrivilegeLog] = []
    @State private var loaded = false
    @State private var activeID: UUID?
    @State private var stage: PrivilegeLog.Stage = .matter
    @State private var showExporter = false
    /// Review R2: the one rendering of the report being exported — its bytes go to the file and the record.
    @State private var exportPackage: StudioExportPackage?
    @State private var gate = StudioProvenanceGate()
    @State private var fillMessage: String?

    public init() {}

    public var body: some View {
        Group {
            if let binding = activeBinding { studio(binding) } else { listScreen }
        }
        .onAppear(perform: load)
        .studioStorageBanner(storage)
        .studioProvenanceGate(gate)
        .fileExporter(isPresented: $showExporter,
                      document: RCAMarkdownDocument(text: exportPackage?.text ?? ""),
                      contentType: .plainText,
                      defaultFilename: exportFilename) { result in
            // Recorded only after the file was written (final brief §3.1 / §4 artifact pipeline).
            if case .success(let url) = result, let pkg = exportPackage {
                storage.exported(pkg, format: "markdown", writtenTo: url, app: appState)
            }
            exportPackage = nil
        }
    }

    // MARK: Persistence

    private func load() {
        guard !loaded else { return }
        loaded = true
        // Final brief §3.2: references resolve against the draft's own case at preview and export.
        gate.resolve = { [storage, appState] id, values, provenance, privileged in
            let context = await appState.studioEvidenceContext(caseID: storage.caseOf[id], workspaceID: nil, includePrivileged: privileged)
            return await StudioEvidenceResolver.unresolved(values: values, provenance: provenance, context: context)
        }
        Task { logs = await storage.load(PrivilegeLog.self, app: appState) }
    }
    private func persist() { storage.persist(logs, app: appState) }
    private var activeBinding: Binding<PrivilegeLog>? {
        guard let id = activeID, let idx = logs.firstIndex(where: { $0.id == id }) else { return nil }
        return Binding(get: { logs[idx] },
                       set: { logs[idx] = $0; logs[idx].updatedAt = Date(); persist() })
    }

    // MARK: List

    private var listScreen: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Privilege Log Studio", systemImage: "lock.doc")
                        .font(.largeTitle.weight(.bold))
                    Text("Build an FRCP 26(b)(5) privilege log the real-life way: describe each withheld document well enough that the claim can be tested — without revealing what's protected — assert the basis, QC it, and serve the exact table courts expect.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text(JurisdictionNotice.studio(instrument: "US FRCP 26(b)(5)(A)"))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 10) {
                    Button { newLog() } label: { Label("New privilege log", systemImage: "plus.circle.fill") }
                        .buttonStyle(.borderedProminent)
                        .guidance(GuidanceTip("New privilege log",
                                              what: "Starts a log for one production: name the matter, add each withheld document, QC the descriptions, and export the served table."))
                    Button { loadSample() } label: { Label("Load a worked example", systemImage: "wand.and.stars") }
                }
                if logs.isEmpty {
                    ContentUnavailableView("No logs yet", systemImage: "lock.doc",
                                           description: Text("Create one, or load the worked example to see the finished table."))
                        .frame(maxWidth: .infinity, minHeight: 200)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 14)], spacing: 14) {
                        ForEach(logs.sorted { $0.updatedAt > $1.updatedAt }) { l in card(l) }
                    }
                }
            }
            .padding(24).frame(maxWidth: 940, alignment: .leading).frame(maxWidth: .infinity)
        }
        .navigationTitle("Privilege Log")
    }

    private func card(_ l: PrivilegeLog) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(l.title.trimmed.isEmpty ? "Untitled" : l.title).font(.headline).lineLimit(1)
            Text(l.caption.trimmed.isEmpty ? "No caption yet." : l.caption)
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            ProgressView(value: l.completionFraction).tint(.green)
            HStack {
                Text("\(l.entries.count) withheld document(s)").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button(role: .destructive) { logs.removeAll { $0.id == l.id }; persist() } label: { Label("Remove", systemImage: "trash").labelStyle(.iconOnly) }
                    .help(StudioEraseButton.removeHelp)
                StudioEraseButton(storage: storage, id: l.id) { logs.removeAll { $0.id == l.id }; persist() }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                Button("Open") { activeID = l.id; stage = firstIncomplete(l) }
                    .buttonStyle(.bordered).controlSize(.small)
            }
        }
        .padding(16).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }

    private func newLog() {
        var l = PrivilegeLog(title: "New privilege log", now: Date())
        l.preparedBy = NSFullUserName()
        StudioAudit.record(&l.history, "Created")
        logs.append(l); persist(); activeID = l.id; stage = .matter
    }
    private func loadSample() {
        let l = PrivilegeLog.sample(now: Date())
        logs.append(l); persist(); activeID = l.id; stage = .log
    }
    private func firstIncomplete(_ l: PrivilegeLog) -> PrivilegeLog.Stage {
        PrivilegeLog.Stage.allCases.first { !l.isComplete($0) } ?? .log
    }

    // MARK: Studio

    private func studio(_ p: Binding<PrivilegeLog>) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { activeID = nil } label: { Label("All logs", systemImage: "chevron.left").font(.caption) }
                    .buttonStyle(.plain).foregroundStyle(.tint)
                TextField("Log title", text: p.title).textFieldStyle(.plain).font(.headline).frame(maxWidth: 360)
                Spacer()
                StudioFillFromCaseMenu(model: p, message: $fillMessage, bind: { await storage.bind(p.wrappedValue.id, to: $0, app: appState) })
                Button { approveNow(p.wrappedValue) } label: {
                    Label(storage.approvedIDs.contains(p.wrappedValue.id) ? "Approved" : "Approve", systemImage: storage.approvedIDs.contains(p.wrappedValue.id) ? "checkmark.seal.fill" : "checkmark.seal")
                }.controlSize(.small)
                .help("Approve exactly this version. Reports carry a DRAFT banner until a current approval covers them; any change returns the draft to draft.")
                .task(id: p.wrappedValue.id) { await storage.refreshApproval(p.wrappedValue.id, app: appState) }
                Button { gate.run(p) { exportNow($0) } } label: { Label("Export", systemImage: "square.and.arrow.up") }.controlSize(.small)
                #if os(macOS)
                Button { gate.run(p) { printNow($0) } } label: { Label("Print", systemImage: "printer") }.controlSize(.small)
                #endif
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            if let fillMessage {
                Text(fillMessage).font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 20).padding(.bottom, 6).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            stepper(p.wrappedValue)
            Divider()
            ScrollView {
                stageContent(p)
                    .padding(24).frame(maxWidth: 980, alignment: .leading).frame(maxWidth: .infinity, alignment: .top)
            }
        }
    }

    private func stepper(_ l: PrivilegeLog) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(PrivilegeLog.Stage.allCases.enumerated()), id: \.element) { idx, s in
                Button { stage = s } label: {
                    VStack(spacing: 4) {
                        ZStack {
                            Circle().fill(stage == s ? AnyShapeStyle(.tint) : (l.isComplete(s) ? AnyShapeStyle(.green.opacity(0.9)) : AnyShapeStyle(.quaternary)))
                                .frame(width: 30, height: 30)
                            Image(systemName: l.isComplete(s) && stage != s ? "checkmark" : s.systemImage)
                                .scaledFont(13, weight: .semibold, relativeTo: .body)
                                .foregroundStyle(stage == s || l.isComplete(s) ? Color.white : Color.secondary)
                        }
                        Text(s.title).font(.caption2.weight(stage == s ? .bold : .regular))
                            .foregroundStyle(stage == s ? .primary : .secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                if idx < PrivilegeLog.Stage.allCases.count - 1 {
                    Rectangle().fill(.quaternary).frame(height: 2).frame(maxWidth: 40)
                }
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }

    @ViewBuilder
    private func stageContent(_ p: Binding<PrivilegeLog>) -> some View {
        switch stage {
        case .matter: matterStage(p)
        case .entries: entriesStage(p)
        case .review: reviewStage(p)
        case .log: logStage(p)
        }
    }

    private func matterStage(_ p: Binding<PrivilegeLog>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            header("Matter", "The case caption and the parties — this heads the served log.")
            field("Case caption — e.g. Doe v. Acme Corp., No. 1:26-cv-0421 (N.D. Ga.)", p.caption)
            HStack(spacing: 12) {
                field("Producing party", p.producingParty)
                field("Requesting party", p.requestingParty)
            }
            field("Prepared by (counsel)", p.preparedBy)
            next(.entries)
        }
    }

    private func entriesStage(_ p: Binding<PrivilegeLog>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            header("Withheld documents",
                   "One entry per withheld document. Describe each well enough to let the claim be tested — never revealing the protected content itself.")
            ForEach(p.entries) { $e in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        TextField("yyyy-mm-dd", text: $e.date).textFieldStyle(.roundedBorder).frame(width: 110)
                        TextField("Type (Email / Memo …)", text: $e.docType).textFieldStyle(.roundedBorder).frame(width: 160)
                        Picker("", selection: $e.privilege) {
                            ForEach(PrivilegeBasis.allCases, id: \.self) { Text($0.label).tag($0) }
                        }.labelsHidden().frame(maxWidth: 210)
                        Spacer()
                        Button { p.wrappedValue.entries.removeAll { $0.id == e.id } } label: { Label("Remove", systemImage: "xmark.circle").labelStyle(.iconOnly) }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 8) {
                        TextField("Author", text: $e.author).textFieldStyle(.roundedBorder)
                        TextField("Recipient(s)", text: $e.recipients).textFieldStyle(.roundedBorder)
                        TextField("CC", text: $e.cc).textFieldStyle(.roundedBorder).frame(width: 140)
                    }
                    TextField("Description — enough to assess the claim, without the protected content", text: $e.descriptionText, axis: .vertical)
                        .textFieldStyle(.roundedBorder).lineLimit(1...3)
                    TextField("Bates range / control number", text: $e.bates).textFieldStyle(.roundedBorder).frame(maxWidth: 280)
                    if !e.isComplete {
                        Label("Needs date, type, author, and a description.", systemImage: "exclamationmark.circle")
                            .font(.caption2).foregroundStyle(.orange)
                    }
                }
                .padding(10).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            }
            Button { p.wrappedValue.entries.append(PLEntry()) } label: { Label("Add withheld document", systemImage: "plus") }
            next(.review)
        }
    }

    private func reviewStage(_ p: Binding<PrivilegeLog>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            header("QC review",
                   "The two checks counsel makes before serving a log — an inadequate description invites a motion to compel; an over-detailed one can waive the privilege.")
            Toggle("Every description lets the claim be assessed WITHOUT revealing protected content", isOn: p.descriptionsDoNotRevealContent)
            Toggle("Every entry asserts a specific privilege basis (AC / WP / both)", isOn: p.everyEntryHasBasis)
            let incomplete = p.wrappedValue.entries.filter { !$0.isComplete }.count
            if incomplete > 0 {
                Label("\(incomplete) entr\(incomplete == 1 ? "y" : "ies") still missing required fields — complete them before serving.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            next(.log)
        }
    }

    private func logStage(_ p: Binding<PrivilegeLog>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            header("The served log", "The exact FRCP 26(b)(5) table — caption, entries, legend, certification.")
            if !p.wrappedValue.isComplete(.log) {
                Label("The log isn't ready: complete the matter, the entries, and both QC confirmations.",
                      systemImage: "lock.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            ScrollView([.horizontal, .vertical]) {
                Text(PrivilegeLogRenderer.markdown(p.wrappedValue, generatedAt: Date()))
                    .font(.callout.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(16)
            }
            .frame(maxHeight: 380)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
            HStack(spacing: 10) {
                Button { gate.run(p) { copyNow($0) } } label: { Label("Copy", systemImage: "doc.on.doc") }
                Button { gate.run(p) { exportNow($0) } } label: { Label("Export Markdown", systemImage: "square.and.arrow.up") }
                #if os(macOS)
                Button { gate.run(p) { printNow($0) } } label: { Label("Print / Save as PDF", systemImage: "printer") }
                #endif
            }
        }
    }

    // MARK: Small pieces

    private func header(_ title: String, _ blurb: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.title2.weight(.bold))
            Text(blurb).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func field(_ label: String, _ text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(label, text: text).textFieldStyle(.roundedBorder)
        }
    }
    private func next(_ s: PrivilegeLog.Stage) -> some View {
        HStack { Spacer(); Button { stage = s } label: { Label("Next: \(s.title)", systemImage: "arrow.right") }.buttonStyle(.borderedProminent) }
    }

    /// Every deliverable that LEAVES the studio (copy/print/export) carries a
    /// signed seal — content hash, honest stage completion, signer key.
    private func sealed(_ l: PrivilegeLog, approved: Bool = false) -> String {
        let stages = PrivilegeLog.Stage.allCases
        return StudioDeliverableSeal.sealedReport(
            studio: "Privilege Log", title: l.title,
            report: (approved ? "" : StudioStorage.draftBanner) + PrivilegeLogRenderer.markdown(l, generatedAt: Date()),
            stagesComplete: stages.filter { l.isComplete($0) }.count,
            stagesTotal: stages.count, at: Date())
    }

    // MARK: Export package (review R2) — rendered and sealed once; the same bytes are written and recorded

    private func exportNow(_ v: PrivilegeLog) {
        Task {
            guard let pkg = await storage.package(v, app: appState, authorise: .init(provenance: v.provenance, values: v.gateValues, privileged: PrivilegeLog.needsPrivilegedSources), render: { sealed(v, approved: $0) }) else { return }
            exportPackage = pkg
            showExporter = true
        }
    }
    private func copyNow(_ v: PrivilegeLog) {
        Task {
            guard let pkg = await storage.package(v, app: appState, authorise: .init(provenance: v.provenance, values: v.gateValues, privileged: PrivilegeLog.needsPrivilegedSources), render: { sealed(v, approved: $0) }) else { return }
            #if os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(pkg.text, forType: .string)
            #endif
            storage.exported(pkg, format: "clipboard", writtenTo: nil, app: appState)
        }
    }
    private func printNow(_ v: PrivilegeLog) {
        Task {
            guard let pkg = await storage.package(v, app: appState, authorise: .init(provenance: v.provenance, values: v.gateValues, privileged: PrivilegeLog.needsPrivilegedSources), render: { sealed(v, approved: $0) }) else { return }
            #if os(macOS)
            // Recorded only when the print job completed — a cancelled dialog, or a build that cannot print, records nothing.
            if AppPrinting.run(text: pkg.text, jobTitle: "Privilege Log — \(v.title)") == .printed { storage.exported(pkg, format: "print", writtenTo: nil, app: appState) }
            #endif
        }
    }
    /// Approve exactly this version (every stage complete, every source resolved, nothing waived).
    private func approveNow(_ v: PrivilegeLog) {
        Task {
            let why = await storage.approve(v, provenance: v.provenance, values: v.gateValues, privileged: PrivilegeLog.needsPrivilegedSources, mandatory: PrivilegeLog.mandatoryEvidence, app: appState)
            storage.notice = why ?? "Approved — this exact version. Any change returns it to draft."
        }
    }
    private var activeReport: String {
        guard let b = activeBinding else { return "" }
        return sealed(b.wrappedValue)
    }
    private var exportFilename: String {
        "privilege-log-\((activeBinding?.wrappedValue.title ?? "log").replacingOccurrences(of: " ", with: "-").lowercased())"
    }
}

#if DEBUG
#Preview("Privilege Log Studio") {
    PrivilegeLogStudioView().frame(width: 1040, height: 760)

}
#endif
