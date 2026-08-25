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

/// Approval+assessment atomicity by recorded compensation: when the assessment
/// cannot be persisted, the approval is withdrawn and this error surfaces.
public nonisolated enum ConformanceGateError: Error, CustomStringConvertible {
    case assessmentNotRecorded(String)
    public var description: String {
        switch self {
        case .assessmentNotRecorded(let reason):
            return "Approval withdrawn: \(reason)"
        }
    }
}

// MARK: - Model (testable, @Observable)

@MainActor
@Observable
public final class WorkProductHandoffModel {
    private let handoff: WorkProductHandoffService
    private let findings: InvestigationFindingsService
    private let closure: InvestigationClosureService
    /// INV-12 desk — used only to SURFACE undecided contradictions/gaps at report time (read-only here).
    private let contradictionGap: InvestigationContradictionGapService?
    /// Level-1 persistence (v107). nil = preview-only (tests without a DB).
    private let assessments: ConformanceAssessmentRepository?
    /// The v104 HMAC audit chain — sealed and bound into the conformance seal
    /// at approval so the certificate attests over a specific ledger state.
    private let auditChain: AuditChainService?
    /// The protocol registry (v108) — new runs freeze the ACTIVE imported
    /// constitution when one exists; the built-in doctrine is the fallback.
    private let protocols: ProtocolRegistryRepository?

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

    /// Undecided (open) in-scope contradictions/gaps at report time — surfaced so findings are never approved
    /// while tensions remain quietly unresolved. Populated on load from the INV-12 desk.
    public private(set) var openContradictionCount = 0
    public private(set) var openGapCount = 0
    /// The approver's explicit acknowledgment they've seen the open items — required to approve when any exist.
    public var acknowledgedOpenItems = false
    /// Level-1 conformance: PER-RULE, actor-bound attestations (audit item 1 —
    /// no blanket toggle). A rule the app cannot check deterministically stays
    /// `notEvaluated` until the reviewer attests it individually with a
    /// rationale; conformance is indeterminate until every rule is resolved.
    public var ruleAttestations: [String: RuleAttestation] = [:]
    /// The constitution FROZEN when this matter's findings were first built in
    /// this session — the assessment never chases the live compiler value mid-run.
    public private(set) var frozenSutra: Sutra?
    /// Which registered protocol GOVERNS this matter's new runs (audit item 6 —
    /// custom protocols wired into run creation). nil = the built-in doctrine.
    /// Persisted per case; locked once the run's constitution is frozen.
    public private(set) var selectedProtocolID: String?
    /// The ACTIVE registered protocols selectable for new runs.
    public private(set) var activeProtocols: [RegisteredProtocol] = []

    private nonisolated static func protocolChoiceKey(_ caseID: UUID) -> String {
        "kalsmritikosh.case.protocol.\(caseID.uuidString)"
    }

    /// Choose the governing protocol for this matter's NEXT run. Refused once
    /// the current run's constitution is frozen — a protocol never changes
    /// mid-run; a new choice governs the next build.
    public func selectProtocol(sutraID: String?) {
        guard frozenSutra == nil else {
            lastError = "This run's constitution is already frozen — the choice applies from the next build."
            return
        }
        selectedProtocolID = sutraID
        guard let caseID else { return }
        if let sutraID { UserDefaults.standard.set(sutraID, forKey: Self.protocolChoiceKey(caseID)) }
        else { UserDefaults.standard.removeObject(forKey: Self.protocolChoiceKey(caseID)) }
    }
    /// The most recently RECORDED assessment for this matter (v107 row). An old
    /// run reopens against this — its own stored snapshot, not today's Sutra.
    public private(set) var storedAssessment: StoredConformanceAssessment?

    /// Authorized deviations recorded by the reviewer this session: rule ID →
    /// justification. Visible on the certificate, never hidden.
    public var approvedDeviations: [String: DeviationAuthorization] = [:]

    /// Surface an export failure raised by the view layer (save panels live there).
    public func noteExportFailure(_ message: String) { lastError = message }

    /// The recorded facts the assessor consults — derived in the model from
    /// service-backed state, not assembled by the view. Multi-phase: findings
    /// always; chain-of-custody when the case holds custody entries; closure
    /// when a close/reopen decision was recorded.
    public func conformanceFacts(assumingApproval: Bool = false) -> ConformanceFacts {
        // Intake is reached the moment a matter exists; its reserved decision
        // ("Authorize the scope") is recorded when the scope was confirmed.
        var reached: Set<PersonaJobKind> = [.caseIntake, .findings]
        if !(snapshot?.custody.isEmpty ?? true) { reached.insert(.evidenceCustody) }
        if snapshot?.latestClosure != nil { reached.insert(.closure) }
        var decisions: Set<PersonaJobKind> = []
        if let status = snapshot?.status, status != .open { decisions.insert(.caseIntake) }
        if assumingApproval || (snapshot?.isApproved ?? false) { decisions.insert(.findings) }
        if snapshot?.latestClosure != nil { decisions.insert(.closure) }
        // Evidence kinds actually bound to this run (custody manifest).
        var evidence: Set<String> = []
        if let custody = snapshot?.custody, !custody.isEmpty {
            evidence.insert("custody.record")
            if custody.allSatisfy({ $0.contentHash != nil }) { evidence.insert("custody.hash") }
        }
        return ConformanceFacts(
            completedPhaseKinds: reached,
            standardOfProofDeclared: proofStandard != nil,
            openItemsAcknowledged: !hasOpenItems || acknowledgedOpenItems,
            humanDecisionsMade: decisions,
            approvedDeviations: approvedDeviations,
            presentEvidenceKinds: evidence,
            attestations: ruleAttestations)
    }

    /// The custody manifest embedded into assessments (its hash is signed).
    private func currentEvidenceManifest() -> [EvidenceManifestEntry]? {
        guard let custody = snapshot?.custody, !custody.isEmpty else { return nil }
        return custody
            .map { EvidenceManifestEntry(sourceVersionID: $0.sourceVersionID.uuidString,
                                         contentHash: $0.contentHash) }
            .sorted { $0.sourceVersionID < $1.sourceVersionID }
    }

    /// The REAL run this assessment binds to (audit item 2): the built findings
    /// run's ID + a hash over its immutable identifying state.
    private struct RunStateBinding: Codable {
        let runID: UUID
        let receiptSeal: String
        let caseRevision: Int
    }
    public func runBinding() -> (runID: UUID?, runStateSHA256: String?) {
        guard let run = built?.run else { return (nil, nil) }
        let binding = RunStateBinding(runID: run.id,
                                      receiptSeal: built?.receipt.seal ?? "",
                                      caseRevision: snapshot?.revision ?? 0)
        return (run.id, try? ConformanceCanonical.sha256(of: binding))
    }

    /// Live (unrecorded) assessment against the frozen constitution.
    public func currentAssessment(at now: Date = Date(),
                                  assumingApproval: Bool = false) -> ConformanceAssessment {
        let binding = runBinding()
        var assessment = SutraConformance.assess(
            facts: conformanceFacts(assumingApproval: assumingApproval),
            against: frozenSutra ?? SutraCompiler.shared(), at: now,
            runID: binding.runID,
            runStateSHA256: binding.runStateSHA256)
        assessment.evidenceManifest = currentEvidenceManifest()
        return assessment
    }

    /// Record + seal this run's assessment (called on approval). The seal links
    /// the case, revision, findings-receipt seal, schema version, the evidence
    /// manifest, and the freshly sealed audit-chain head; recording appends a
    /// new revision — prior assessments are never rewritten. Returns a WARNING
    /// string on any failure so the approval outcome carries it (audit item 2:
    /// the success path must never erase a recording/sealing failure).
    private func recordAssessment(caseID: UUID, at date: Date) async -> (recorded: Bool, warning: String?) {
        guard let repo = assessments else { return (true, nil) }
        let assessment = currentAssessment(at: date)
        let nextRevision = ((try? await repo.latest(caseID: caseID))?.runRevision ?? 0) + 1
        var linkage = ConformanceSealLinkage(caseID: caseID,
                                             runRevision: nextRevision,
                                             assessedRunRevision: nextRevision,
                                             receiptSeal: built?.receipt.seal,
                                             databaseSchemaVersion: SchemaMigrations.latestVersion)
        // Bind the tamper-evident ledger: seal outstanding audit events first,
        // then record the head this certificate attests over. A remaining
        // unsealed count refuses the seal rather than attesting over a ledger
        // that can still silently change.
        if let chain = auditChain {
            _ = try? await chain.seal(now: date)
            if let v = try? await chain.verify() { linkage.unsealedAuditEvents = v.unsealedCount }
            if let h = try? await chain.head() {
                linkage.auditChainHead = h.hash
                linkage.auditEventCount = h.sealedSeq
            }
        }
        var warning: String? = nil
        var sealed: SealedConformance? = nil
        do { sealed = try ConformanceSeal.seal(assessment: assessment, linkage: linkage) }
        catch { warning = "assessment recorded UNSEALED — sealing refused: \(error)" }
        do { storedAssessment = try await repo.record(caseID: caseID, assessment: assessment, seal: sealed, at: date) }
        catch { return (false, "\(error)") }   // caller compensates: approval is withdrawn
        return (true, warning)
    }
    public var hasOpenItems: Bool { openContradictionCount + openGapCount > 0 }
    /// One accepted unresolved-limitation per line, recorded honestly at closure.
    public var unresolvedText: String = ""

    public private(set) var lastOutcome: String?
    public private(set) var lastError: String?
    public private(set) var busy = false

    public init(handoff: WorkProductHandoffService, findings: InvestigationFindingsService,
                closure: InvestigationClosureService,
                contradictionGap: InvestigationContradictionGapService? = nil,
                assessments: ConformanceAssessmentRepository? = nil,
                auditChain: AuditChainService? = nil,
                protocols: ProtocolRegistryRepository? = nil) {
        self.handoff = handoff; self.findings = findings; self.closure = closure
        self.contradictionGap = contradictionGap
        self.assessments = assessments
        self.auditChain = auditChain
        self.protocols = protocols
    }

    /// Load (or reload) the handoff snapshot for a matter. Switching matters starts a CLEAN slate: reviewer
    /// inputs (rationale, unresolved items, export choices) and the last built findings never carry across
    /// matters — a rationale typed for one matter can never be reused to approve/close/export another.
    public func load(caseID: UUID) async {
        if self.caseID != caseID {
            built = nil
            rationale = ""
            proofStandard = nil
            openContradictionCount = 0
            openGapCount = 0
            acknowledgedOpenItems = false
            unresolvedText = ""
            exportRedactionTerms = ""
            exportFormat = .pdf
            lastOutcome = nil
            lastError = nil
            ruleAttestations = [:]
            frozenSutra = nil
            storedAssessment = nil
            approvedDeviations = [:]
        }
        self.caseID = caseID
        selectedProtocolID = UserDefaults.standard.string(forKey: Self.protocolChoiceKey(caseID))
        await refresh()
    }

    private func refresh() async {
        guard let caseID else { return }
        do { snapshot = try await handoff.snapshot(caseID: caseID) }
        catch { lastError = "\(error)"; snapshot = nil }
        // Surface undecided in-scope contradictions/gaps (review == nil = no case disposition yet).
        if let desk = contradictionGap {
            let cs = (try? await desk.contradictions(caseID: caseID)) ?? []
            let gs = (try? await desk.gaps(caseID: caseID)) ?? []
            openContradictionCount = cs.filter { $0.review == nil }.count
            openGapCount = gs.filter { $0.review == nil }.count
        }
        // Reopen path: the matter's recorded assessment, frozen snapshot and all.
        if let repo = assessments {
            storedAssessment = try? await repo.latest(caseID: caseID)
        }
        // The active registered protocols selectable for new runs.
        if let protocols {
            activeProtocols = ((try? await protocols.list()) ?? []).filter { $0.status == .active }
        }
    }

    /// Build the case's findings work product over the shared assembly engine (does not approve or close).
    public func buildFindings(actor: String, at date: Date) async {
        guard let snap = snapshot else { lastError = "Load a matter first."; return }
        let access = exportAccess(workspaceID: snap.workspaceID)
        // Run-start freeze: the constitution this run will be assessed against is
        // fixed the moment findings are first built — never a live value. The
        // matter's SELECTED protocol wins (custom or built-in id); otherwise the
        // ACTIVE imported version of the built-in doctrine; built-in as fallback.
        if frozenSutra == nil {
            var resolved: Sutra? = nil
            if let protocols {
                let governingID = selectedProtocolID ?? SutraCompiler.shared().id
                resolved = try? await protocols.activeSutra(id: governingID)
                if resolved == nil && selectedProtocolID != nil {
                    lastError = "The selected protocol '\(governingID)' has no active version — the built-in doctrine governs this run."
                }
            }
            frozenSutra = resolved ?? SutraCompiler.shared()
        }
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
        if hasOpenItems && !acknowledgedOpenItems {
            lastError = "\(openContradictionCount) open contradiction(s) and \(openGapCount) open gap(s) are still undecided in scope. Review them, then tick the acknowledgment before approving."
            return
        }
        let awareness = hasOpenItems
            ? " Open items at approval: \(openContradictionCount) contradiction(s), \(openGapCount) gap(s) — acknowledged by approver."
            : " No open contradictions or gaps at approval."
        // CONFORMANCE GATE (audit item 1): in strict mode with persistence wired,
        // approval is REFUSED unless the run — assessed as if this approval were
        // recorded — is conformant (deviations allowed, each on the certificate).
        // Indeterminate (unattested rules) or failed (unreached required phase,
        // asserted prohibition, non-waivable deviation) blocks the approval
        // itself; conformance is a precondition, not an afterthought.
        if assessments != nil && !FeatureFlags.classicConformanceValue() {
            let projected = currentAssessment(at: date, assumingApproval: true)
            switch projected.status {
            case .conformant, .conformantWithDeviations:
                break
            case .indeterminate:
                lastError = "Approval blocked — \(projected.unevaluated.count) rule(s) await attestation or an authorized deviation. Resolve each in the conformance panel, then approve."
                return
            case .notConformant:
                let failed = projected.evaluations.filter { $0.outcome == .failed }
                lastError = "Approval blocked — the run is not conformant: \(failed.map(\.rule.text).prefix(2).joined(separator: "; "))\(failed.count > 2 ? " (+\(failed.count - 2) more)" : "")."
                return
            }
        }
        await perform {
            _ = try await self.findings.approveFindings(caseID: snap.caseID, findings: f, proofStandard: std,
                                                        rationale: why + awareness, actor: actor, at: date)
            await self.refresh()
            // Strict conformance: record + seal the per-rule assessment of this
            // approved run against the frozen constitution.
            if !FeatureFlags.classicConformanceValue() {
                let result = await self.recordAssessment(caseID: snap.caseID, at: date)
                if !result.recorded {
                    // COMPENSATION (approval+assessment atomicity): an approval
                    // must never stand without its recorded assessment. The
                    // approval is WITHDRAWN as a recorded decision — both the
                    // approval and its reversal stay in the genealogy — and the
                    // failure surfaces as the error, never as success.
                    let reason = "Automatic withdrawal — conformance assessment could not be recorded: \(result.warning ?? "unknown error")"
                    _ = try await self.findings.withdrawApproval(caseID: snap.caseID, findings: f,
                                                                 rationale: reason, actor: actor, at: date)
                    await self.refresh()
                    throw ConformanceGateError.assessmentNotRecorded(reason)
                }
                // A sealing failure with the row recorded rides the outcome.
                if let warning = result.warning {
                    return "Findings approved under \(std.label) — ⚠️ \(warning)"
                }
            }
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
    /// CONFORMANCE STYLE switch — classic summary label vs strict per-rule assessment.
    @AppStorage(FeatureFlags.classicConformanceKey) private var classicConformance = false
    /// Deviation recording (strict mode): the rule being deviated + its typed authorization.
    @State private var deviationRule: SutraRule?
    @State private var deviationAuthorizer = ""
    @State private var deviationRole = ""
    @State private var deviationJustification = ""
    /// Per-rule attestation capture (strict mode): actor, role, rationale.
    @State private var attestRule: SutraRule?
    @State private var attestActor = ""
    @State private var attestRole = ""
    @State private var attestRationale = ""
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
            // Open items at report time — findings can't be approved while these are undecided
            // unless the approver explicitly acknowledges them.
            if model.hasOpenItems {
                VStack(alignment: .leading, spacing: 6) {
                    Label("\(model.openContradictionCount) open contradiction(s) and \(model.openGapCount) open gap(s) are still undecided in this case's scope.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Resolve them on the Contradiction & Gap desk, or acknowledge that you're approving with them open.")
                        .font(.caption2).foregroundStyle(.secondary)
                    Toggle("I've reviewed the open items and am approving with them recorded as open",
                           isOn: $model.acknowledgedOpenItems)
                        .font(.caption)
                }
                .padding(10)
                .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            }
            if !snap.approvalHistory.isEmpty {
                ForEach(snap.approvalHistory) { a in
                    Text("• \(a.decision.rawValue) — \(a.rationale) (\(a.actor))").font(.caption).foregroundStyle(.secondary)
                }
            }
            conformanceReadout(model, snap)
        }
    }

    /// Conformance readout — two styles behind the Settings switch. Classic is
    /// the previous recorded-gates summary, verbatim; strict is the Level-1
    /// per-rule assessment (fail-closed, attestation, frozen snapshot, seal).
    /// The flip is instant and lossless: neither style deletes the other's records.
    @ViewBuilder
    private func conformanceReadout(_ model: WorkProductHandoffModel, _ snap: CaseHandoffSnapshot) -> some View {
        if classicConformance {
            classicConformanceReadout(model, snap)
        } else {
            strictConformanceReadout(model, snap)
        }
    }

    /// The previous app's conformance summary, exactly as it shipped — but
    /// labelled for what it is: a legacy checklist over the recorded gates,
    /// NOT a per-rule conformance determination (audit 2026-08-25 item 7).
    private func classicConformanceReadout(_ model: WorkProductHandoffModel, _ snap: CaseHandoffSnapshot) -> some View {
        let record = RunRecord(
            completedPhaseKinds: [.findings],
            standardOfProofDeclared: model.proofStandard != nil,
            openItemsAcknowledged: !model.hasOpenItems || model.acknowledgedOpenItems,
            humanDecisionsMade: snap.isApproved ? [.findings] : [])
        let report = SutraConformance.verify(run: record, against: SutraCompiler.shared())
        return VStack(alignment: .leading, spacing: 3) {
            Label(report.summaryLine, systemImage: report.isConformant ? "checkmark.seal.fill" : "seal")
                .font(.caption)
                .foregroundStyle(report.isConformant ? Color.green : Color.orange)
                .help("Sūtra conformance — whether this run met its constitution (standard of proof declared, open items surfaced, approval recorded).")
            Text("Legacy checklist over the recorded gates — not a per-rule conformance determination. Turn off “Classic conformance readout” in Settings for the assessed, sealed certificate.")
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Level-1 strict assessment: one outcome per rule of the frozen constitution.
    /// A RECORDED assessment (this matter was approved) shows the stored row —
    /// its own snapshot, its own seal — never today's live Sutra.
    private func strictConformanceReadout(_ model: WorkProductHandoffModel, _ snap: CaseHandoffSnapshot) -> some View {
        @Bindable var model = model
        let stored = model.storedAssessment
        let assessment = stored?.assessment ?? model.currentAssessment()
        let (icon, color): (String, Color) = switch assessment.status {
        case .conformant:               ("checkmark.seal.fill", .green)
        case .conformantWithDeviations: ("checkmark.seal", .teal)
        case .notConformant:            ("xmark.seal.fill", .red)
        case .indeterminate:            ("seal", .orange)
        }
        return VStack(alignment: .leading, spacing: 6) {
            // Which constitution governs this matter's NEW runs — locked once frozen.
            if model.frozenSutra == nil && !model.activeProtocols.isEmpty {
                Picker("Governing protocol", selection: Binding(
                    get: { model.selectedProtocolID ?? "" },
                    set: { model.selectProtocol(sutraID: $0.isEmpty ? nil : $0) })) {
                    Text("Built-in doctrine").tag("")
                    ForEach(model.activeProtocols) { p in
                        Text("\(p.sutraID) v\(p.version) · \(p.publisher)").tag(p.sutraID)
                    }
                }
                .font(.caption).frame(maxWidth: 420)
                .help("The constitution the next findings build will freeze and be assessed against. A protocol never changes mid-run.")
            } else if let frozen = model.frozenSutra {
                Text("Constitution frozen for this run: \(frozen.citation)")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Label(assessment.displaySummaryLine, systemImage: icon)
                .font(.caption).foregroundStyle(color)
                .help("Sūtra conformance — every rule of the frozen constitution is evaluated individually; unevaluated mandatory rules block conformance instead of passing silently.")
            if let stored {
                Text("Recorded assessment · revision \(stored.runRevision) · \(stored.assessment.sutraCitation) · constitution sha256 \(stored.assessment.sutraSHA256.prefix(12))…")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if stored == nil && !assessment.unevaluated.isEmpty {
                Text("\(assessment.unevaluated.count) rule(s) await your individual attestation — each is recorded under your name with a rationale and sealed with the assessment. There is no attest-all shortcut.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                DisclosureGroup("Unevaluated rules (\(assessment.unevaluated.count))") {
                    ForEach(assessment.unevaluated) { e in
                        HStack(alignment: .firstTextBaseline) {
                            Text("\(e.rule.id) — \(e.rule.text)").font(.caption2).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 8)
                            Button("Attest…") {
                                attestRule = e.rule
                                attestRationale = ""
                            }
                            .font(.caption2).buttonStyle(.borderless)
                            Button("Record deviation…") {
                                deviationRule = e.rule
                                deviationJustification = ""
                            }
                            .font(.caption2).buttonStyle(.borderless)
                        }
                    }
                }
                .font(.caption)
                .alert("Attest rule", isPresented: Binding(
                    get: { attestRule != nil },
                    set: { if !$0 { attestRule = nil } })) {
                    TextField("Your name (required)", text: $attestActor)
                    TextField("Role (optional)", text: $attestRole)
                    TextField("Rationale — how you verified this rule was met", text: $attestRationale)
                    Button("Attest") {
                        let actor = attestActor.trimmingCharacters(in: .whitespaces)
                        let why = attestRationale.trimmingCharacters(in: .whitespacesAndNewlines)
                        if let rule = attestRule, !actor.isEmpty, !why.isEmpty {
                            model.ruleAttestations[rule.id] = RuleAttestation(
                                actor: actor,
                                role: attestRole.isEmpty ? nil : attestRole,
                                rationale: why, at: Date())
                        }
                        attestRule = nil
                    }
                    Button("Cancel", role: .cancel) { attestRule = nil }
                } message: {
                    Text("Your name, role, rationale and timestamp are recorded on this rule's evaluation and sealed with the assessment when you approve.")
                }
                .alert("Record authorized deviation", isPresented: Binding(
                    get: { deviationRule != nil },
                    set: { if !$0 { deviationRule = nil } })) {
                    TextField("Authorized by (required)", text: $deviationAuthorizer)
                    TextField("Role (optional)", text: $deviationRole)
                    TextField("Justification — why this departure is authorized", text: $deviationJustification)
                    Button("Record deviation") {
                        let who = deviationAuthorizer.trimmingCharacters(in: .whitespaces)
                        let why = deviationJustification.trimmingCharacters(in: .whitespacesAndNewlines)
                        if let rule = deviationRule, !who.isEmpty, !why.isEmpty {
                            model.approvedDeviations[rule.id] = DeviationAuthorization(
                                authorizedBy: who,
                                role: deviationRole.isEmpty ? nil : deviationRole,
                                justification: why, at: Date())
                        }
                        deviationRule = nil
                    }
                    Button("Cancel", role: .cancel) { deviationRule = nil }
                } message: {
                    Text("A deviation resolves the rule as an authorized departure and downgrades the sealed status to 'conformant with deviations'. Prohibitions are non-waivable — a deviation on one fails the run. Every departure stays on the certificate with who authorized it and why.")
                }
            }
            if assessment.status != .indeterminate {
                HStack(spacing: 10) {
                    Button {
                        var text = assessment.certificate
                        if let sealed = stored?.seal ?? (try? ConformanceSeal.seal(assessment: assessment)) {
                            text += "\n" + ConformanceSeal.markdown(for: sealed)
                        }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    } label: { Label("Copy sealed conformance certificate", systemImage: "signature") }
                    .buttonStyle(.bordered).controlSize(.small)
                    .help("Per-rule certificate with the constitution's SHA-256 and an ECDSA P-256 signature — verifiable outside this app.")
                    if let stored, stored.seal != nil {
                        Button {
                            exportBundle(stored, title: snap.title)
                        } label: { Label("Export verification bundle…", systemImage: "shippingbox") }
                        .buttonStyle(.bordered).controlSize(.small)
                        .help("A folder anyone can verify without Kalsmritikosh — integrity, authenticity and conformance replay (spec: BUNDLE_FORMAT.md; CLI: kalverify).")
                    }
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

    /// Export a sealed assessment as a verification-bundle folder (1.0.x-C).
    private func exportBundle(_ stored: StoredConformanceAssessment, title: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(title) — conformance bundle"
        panel.canCreateDirectories = true
        panel.prompt = "Export Bundle"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try ConformanceBundle.write(stored: stored, to: url) }
        catch { model?.noteExportFailure("Verification bundle export failed: \(error)") }
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
        let m = model ?? WorkProductHandoffModel(handoff: handoff, findings: findings, closure: closure,
                                                 contradictionGap: appState.investigationContradictionGap,
                                                 assessments: appState.conformanceAssessments,
                                                 auditChain: appState.auditChain,
                                                 protocols: appState.protocolRegistry)
        await m.load(caseID: id)
        model = m
    }
}
