//
//  WorkProductHandoffView.swift
//  Kalsmritikosh
//
//  #146 (Handoff / Review) — the production surface where a reviewer reviews a matter's work products and
//  exercises the HUMAN-ONLY decisions that hand a matter off: build the findings work product, approve or
//  withdraw findings, and close or reopen the matter. It consumes the SHARED case authorities through the
//  persona-neutral WorkProductHandoffService (read) + InvestigationFindingsService / InvestigationClosureService
//  (the recorded human decisions) — the same production path the acceptance suites drive.
//
//  Truth boundaries surfaced, never bypassed: approval is never inferred (findings stay "not approved" until a
//  human approves), closure is never inferred and is honest (unresolved items entered at closure are retained),
//  and reopening preserves the prior decision. Nothing here auto-approves or auto-closes.
//

import SwiftUI
import AppKit

// MARK: - Model (testable, @Observable)

@MainActor
@Observable
public final class WorkProductHandoffModel {
    private let handoff: WorkProductHandoffService
    private let findings: InvestigationFindingsService
    private let closure: InvestigationClosureService

    /// The matter currently under review.
    public private(set) var caseID: UUID?
    public private(set) var snapshot: CaseHandoffSnapshot?
    /// The most recently built (immutable) findings run — the thing approve / close reference.
    public private(set) var built: InvestigationFindings?

    /// Reviewer inputs.
    public var rationale: String = ""
    /// The standard of proof these findings are declared to meet. Required before
    /// approval — findings can't be approved without a declared evidentiary bar.
    public var proofStandard: EvidentiaryStandard?
    /// One accepted unresolved-limitation per line, recorded honestly at closure.
    public var unresolvedText: String = ""

    public private(set) var lastOutcome: String?
    public private(set) var lastError: String?
    public private(set) var busy = false

    public init(handoff: WorkProductHandoffService, findings: InvestigationFindingsService, closure: InvestigationClosureService) {
        self.handoff = handoff; self.findings = findings; self.closure = closure
    }

    /// Load (or reload) the handoff snapshot for a matter. Switching matters starts a CLEAN slate: reviewer
    /// inputs (rationale, unresolved items, export choices) and the last built findings never carry across
    /// matters — a rationale typed for one matter can never be reused to approve/close/export another.
    public func load(caseID: UUID) async {
        if self.caseID != caseID {
            built = nil
            rationale = ""
            proofStandard = nil
            unresolvedText = ""
            exportRedactionTerms = ""
            exportFormat = .pdf
            lastOutcome = nil
            lastError = nil
        }
        self.caseID = caseID
        await refresh()
    }

    private func refresh() async {
        guard let caseID else { return }
        do { snapshot = try await handoff.snapshot(caseID: caseID) }
        catch { lastError = "\(error)"; snapshot = nil }
    }

    /// Build the case's findings work product over the shared assembly engine (does not approve or close).
    public func buildFindings(actor: String, at date: Date) async {
        guard let snap = snapshot else { lastError = "Load a matter first."; return }
        let access = exportAccess(workspaceID: snap.workspaceID)
        await perform {
            let f = try await self.findings.buildFindings(caseID: snap.caseID, access: access, actor: actor, at: date)
            self.built = f
            return "Built findings: \(f.run.findingCount) finding(s), receipt sealed."
        }
    }

    /// Record the human approval of the built findings run as the matter's findings.
    public func approve(actor: String, at date: Date) async {
        guard let snap = snapshot, let f = built else { lastError = "Build findings first."; return }
        let why = trimmed(rationale)
        guard !why.isEmpty else { lastError = "Give a rationale for approval."; return }
        guard let std = proofStandard else {
            lastError = "Choose the standard of proof these findings meet before approving."; return
        }
        await perform {
            _ = try await self.findings.approveFindings(caseID: snap.caseID, findings: f, proofStandard: std,
                                                        rationale: why, actor: actor, at: date)
            await self.refresh()
            return "Findings approved under \(std.label)."
        }
    }

    /// Withdraw a prior approval (a new recorded decision; the prior approval is preserved).
    public func withdraw(actor: String, at date: Date) async {
        guard let snap = snapshot, let f = built else { lastError = "Build findings first."; return }
        let why = trimmed(rationale)
        guard !why.isEmpty else { lastError = "Give a rationale for withdrawal."; return }
        await perform {
            _ = try await self.findings.withdrawApproval(caseID: snap.caseID, findings: f, rationale: why, actor: actor, at: date)
            await self.refresh()
            return "Approval withdrawn."
        }
    }

    /// Close the matter by a recorded human decision. Accepted unresolved items are retained (honest closure).
    /// Optionally pins the built findings run + its receipt seal.
    public func close(actor: String, at date: Date) async {
        guard let snap = snapshot else { lastError = "Load a matter first."; return }
        let why = trimmed(rationale)
        guard !why.isEmpty else { lastError = "Give a rationale for closure."; return }
        let unresolved = unresolvedText.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        await perform {
            _ = try await self.closure.closeCase(
                caseID: snap.caseID, expectedRevision: snap.revision, rationale: why, unresolvedItems: unresolved,
                workProductRunID: self.built?.run.id, receiptSeal: self.built?.receipt.seal, actor: actor, at: date)
            await self.refresh()
            return unresolved.isEmpty ? "Matter closed." : "Matter closed with \(unresolved.count) recorded unresolved item(s)."
        }
    }

    /// Reopen a closed matter by a recorded human decision; the prior closure is preserved.
    public func reopen(actor: String, at date: Date) async {
        guard let snap = snapshot else { lastError = "Load a matter first."; return }
        let why = trimmed(rationale)
        guard !why.isEmpty else { lastError = "Give a rationale for reopening."; return }
        await perform {
            _ = try await self.closure.reopenCase(caseID: snap.caseID, expectedRevision: snap.revision, rationale: why, actor: actor, at: date)
            await self.refresh()
            return "Matter reopened."
        }
    }

    // MARK: - Export (#147)

    /// The chosen deliverable format and optional redaction terms for exporting the built findings.
    public var exportFormat: ExportDeliverableFormat = .pdf
    public var exportRedactionTerms: String = ""

    private let exporter = WorkProductExportService()

    /// Map the built findings work product into the neutral export document (reuses the ONE composer).
    private func exportableDocument() -> ExportableDocument? {
        guard let f = built else { return nil }
        return WorkProductComposer.exportable(f.assembled.workProduct, citationStyle: .footnote, manifest: f.manifest)
    }

    private var redactionPolicy: RedactionPolicy? {
        let terms = exportRedactionTerms
            .split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return terms.isEmpty ? nil : RedactionPolicy(customTerms: terms)
    }

    /// Render the built findings to bytes in the chosen format (fail-closed if redaction would leak).
    public func exportData() throws -> Data {
        guard let doc = exportableDocument() else { throw WorkProductExportError.writeFailed("Build findings first.") }
        return try exporter.data(for: doc, format: exportFormat, redaction: redactionPolicy)
    }

    /// Render the built findings and write them to a user-chosen file.
    public func export(to url: URL) {
        guard let doc = exportableDocument() else { lastError = "Build findings first."; return }
        do {
            _ = try exporter.write(doc, format: exportFormat, to: url, redaction: redactionPolicy)
            lastOutcome = "Exported \(exportFormat.displayName) → \(url.lastPathComponent)"; lastError = nil
        } catch { lastError = "Export failed: \(error)"; lastOutcome = nil }
    }

    // MARK: - Internals

    private func perform(_ work: @escaping () async throws -> String) async {
        busy = true; defer { busy = false }
        do { lastOutcome = try await work(); lastError = nil }
        catch { lastError = "\(error)"; lastOutcome = nil }
    }

    private func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func exportAccess(workspaceID: UUID) -> SensitiveAccessContext {
        SensitiveAccessContext(scope: SensitiveScope(
            workspaceID: workspaceID, maximumSensitivity: .restricted, permitsPrivilegedMaterial: false, purpose: .export))
    }
}

// MARK: - View

public struct WorkProductHandoffView: View {
    @Environment(AppState.self) private var appState
    @State private var model: WorkProductHandoffModel?
    @State private var selectedWorkspace: Workspace.ID?
    @State private var workspaceList: [Workspace] = []
    @State private var caseList: [InvestigationCase] = []
    @State private var selectedCase: UUID?

    public init() {}

    public var body: some View {
        Group {
            if let handoff = appState.workProductHandoff, appState.investigationFindings != nil, appState.investigationClosure != nil {
                content(handoff)
            } else {
                ContentUnavailableView("Handoff & Review is still starting…", systemImage: "checkmark.seal")
            }
        }
        .task { await loadWorkspaces() }
    }

    @ViewBuilder
    private func content(_ handoff: WorkProductHandoffService) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Handoff & Review").font(.title2.weight(.semibold))
                Text("Review a matter's findings and evidence, then record the human decisions that hand it off — approve findings, close, or reopen. Nothing is approved or closed automatically.")
                    .font(.callout).foregroundStyle(.secondary)
                matterPicker
                Divider()
                if let model, let snap = model.snapshot {
                    matterSummary(snap)
                    findingsSection(model, snap)
                    if model.built != nil { exportSection(model, snap) }
                    closureSection(model, snap)
                    custodySection(snap)
                    if let outcome = model.lastOutcome {
                        Label(outcome, systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
                    }
                    if let err = model.lastError {
                        Label(err, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
                    }
                } else {
                    Text("Pick a workspace and a matter to review.").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .padding(20)
        }
    }

    private var matterPicker: some View {
        HStack(spacing: 10) {
            Picker("Workspace", selection: $selectedWorkspace) {
                Text("Choose…").tag(Optional<Workspace.ID>.none)
                ForEach(workspaceList, id: \.id) { ws in Text(ws.title).tag(Optional(ws.id)) }
            }
            .frame(maxWidth: 220)
            .onChange(of: selectedWorkspace) { _, _ in Task { await loadCases() } }
            Picker("Matter", selection: $selectedCase) {
                Text("Choose…").tag(Optional<UUID>.none)
                ForEach(caseList, id: \.id) { c in Text(c.title).tag(Optional(c.id)) }
            }
            .frame(maxWidth: 260)
            .onChange(of: selectedCase) { _, id in if let id { Task { await openMatter(id) } } }
        }
    }

    private func matterSummary(_ snap: CaseHandoffSnapshot) -> some View {
        HStack(spacing: 12) {
            Label(snap.title, systemImage: "folder.fill").font(.headline)
            statusChip(snap.isClosed ? "Closed" : "Open", closed: snap.isClosed)
            statusChip(snap.isApproved ? "Findings approved" : "Findings not approved", closed: !snap.isApproved)
        }
    }

    private func statusChip(_ text: String, closed: Bool) -> some View {
        Text(text).font(.caption.weight(.medium)).padding(.horizontal, 8).padding(.vertical, 3)
            .background((closed ? Color.orange : Color.green).opacity(0.15), in: Capsule())
            .foregroundStyle(closed ? Color.orange : Color.green)
    }

    @ViewBuilder
    private func findingsSection(_ model: WorkProductHandoffModel, _ snap: CaseHandoffSnapshot) -> some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 8) {
            Text("Findings").font(.headline)
            // Standard of proof — findings can't be approved without a declared bar.
            HStack(spacing: 8) {
                Text("Standard of proof").font(.caption).foregroundStyle(.secondary)
                Picker("Standard of proof", selection: $model.proofStandard) {
                    Text("Choose…").tag(Optional<EvidentiaryStandard>.none)
                    ForEach(EvidentiaryStandard.allCases, id: \.self) { s in Text(s.label).tag(Optional(s)) }
                }
                .labelsHidden().frame(maxWidth: 300)
                .guidance(GuidanceTip("Standard of proof",
                                      what: "The evidentiary bar these findings are declared to meet (e.g. balance of probabilities, clear and convincing, beyond reasonable doubt). It is stamped into the approval record so the report states the threshold it was tested against.",
                                      enabledWhen: nil))
            }
            if let s = model.proofStandard {
                Text(s.detail).font(.caption2).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Button { Task { await model.buildFindings(actor: "me", at: Date()) } } label: {
                    Label("Build findings", systemImage: "doc.badge.gearshape")
                }.buttonStyle(.bordered).disabled(model.busy)
                Button { Task { await model.approve(actor: "me", at: Date()) } } label: {
                    Label("Approve", systemImage: "checkmark.seal.fill")
                }.buttonStyle(.borderedProminent).disabled(model.busy || model.built == nil)
                    .guidance(GuidanceTip("Approve findings",
                                          what: "Records your human approval of the built findings under the chosen standard of proof. Approval authorizes the report — it does not verify the world or close the matter.",
                                          enabledWhen: "Build findings, choose a standard of proof, and enter a rationale (below) first."),
                              enabled: !(model.busy || model.built == nil))
                Button { Task { await model.withdraw(actor: "me", at: Date()) } } label: {
                    Label("Withdraw", systemImage: "xmark.seal")
                }.buttonStyle(.bordered).disabled(model.busy || model.built == nil || !snap.isApproved)
            }
            if !snap.approvalHistory.isEmpty {
                ForEach(snap.approvalHistory) { a in
                    Text("• \(a.decision.rawValue) — \(a.rationale) (\(a.actor))").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func exportSection(_ model: WorkProductHandoffModel, _ snap: CaseHandoffSnapshot) -> some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 8) {
            Text("Export").font(.headline)
            Text("Export the built findings as a file. Optional redaction removes the terms below and refuses the export if any would leak.")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Picker("Format", selection: $model.exportFormat) {
                    ForEach(ExportDeliverableFormat.allCases, id: \.self) { f in Text(f.displayName).tag(f) }
                }.frame(maxWidth: 220)
                TextField("Redact terms (comma-separated, optional)", text: $model.exportRedactionTerms)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 280)
                Button {
                    presentSavePanel(model: model, title: snap.title)
                } label: { Label("Export…", systemImage: "square.and.arrow.up") }
                .buttonStyle(.borderedProminent).disabled(model.busy)
            }
        }
    }

    /// Present a save panel and, on confirmation, write the export to the chosen location.
    private func presentSavePanel(model: WorkProductHandoffModel, title: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(title).\(model.exportFormat.fileExtension)"
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { model.export(to: url) }
    }

    @ViewBuilder
    private func closureSection(_ model: WorkProductHandoffModel, _ snap: CaseHandoffSnapshot) -> some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 8) {
            Text("Closure").font(.headline)
            TextField("Rationale (required for approve / close / reopen)", text: $model.rationale).textFieldStyle(.roundedBorder)
            if !snap.isClosed {
                TextField("Accepted unresolved items (one per line)", text: $model.unresolvedText, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(2...4)
            }
            HStack(spacing: 10) {
                if snap.isClosed {
                    Button { Task { await model.reopen(actor: "me", at: Date()) } } label: {
                        Label("Reopen matter", systemImage: "lock.open")
                    }.buttonStyle(.bordered).disabled(model.busy)
                } else {
                    Button { Task { await model.close(actor: "me", at: Date()) } } label: {
                        Label("Close matter", systemImage: "lock")
                    }.buttonStyle(.borderedProminent).disabled(model.busy)
                }
            }
            ForEach(snap.closureHistory) { c in
                VStack(alignment: .leading, spacing: 2) {
                    Text("• \(c.decision.rawValue) — \(c.rationale) (\(c.actor))").font(.caption).foregroundStyle(.secondary)
                    if !c.unresolvedItems.isEmpty {
                        Text("   unresolved: \(c.unresolvedItems.joined(separator: "; "))").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func custodySection(_ snap: CaseHandoffSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Evidence & custody (\(snap.custody.count))").font(.headline)
            ForEach(snap.custody, id: \.sourceVersionID) { entry in
                HStack(spacing: 8) {
                    Image(systemName: entry.contentHash == nil ? "questionmark.circle" : "checkmark.shield")
                        .foregroundStyle(entry.contentHash == nil ? .orange : .green)
                        .accessibilityLabel(entry.contentHash == nil ? "Evidence not yet verified" : "Evidence verified with content hash")
                    Text(entry.sourceVersionID.uuidString).font(.caption.monospaced()).lineLimit(1)
                    Spacer(minLength: 0)
                    Text("\(entry.custodyEvents.count) custody event(s)").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Data loading

    private func loadWorkspaces() async {
        guard let ws = appState.workspaces else { return }
        workspaceList = (try? await ws.all(includeArchived: false)) ?? []
    }

    private func loadCases() async {
        guard let cases = appState.investigationCases, let wsID = selectedWorkspace else { caseList = []; return }
        caseList = (try? await cases.listCases(workspaceID: wsID)) ?? []
        selectedCase = nil
    }

    private func openMatter(_ id: UUID) async {
        guard let handoff = appState.workProductHandoff,
              let findings = appState.investigationFindings,
              let closure = appState.investigationClosure else { return }
        let m = model ?? WorkProductHandoffModel(handoff: handoff, findings: findings, closure: closure)
        await m.load(caseID: id)
        model = m
    }
}
