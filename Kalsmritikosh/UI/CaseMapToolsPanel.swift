//
//  CaseMapToolsPanel.swift
//  Kalsmritikosh
//
//  Smart-map S12 (HELP-04/05/07/08/10, ADAPT-05/06) — minimal, honest entry points for the case services built in S6–S11
//  that had no screen: automation policy and queue, the AI assistant's mode and proposals, money entry and figures, people
//  and roles, relationship patterns, the history set, briefings, and structured exchange files. One sheet from the map's
//  header ("Case tools", ⌃⌘T), a list of tools on the left (↑ ↓ to choose) and the chosen tool on the right. Every tool
//  says what it is for in text above its controls (never hover-only), shows one next action when it is empty or fails, and
//  calls the EXISTING services only — every change is checked by them (roles, closed case, erasure). Nothing here sends
//  anything anywhere; the AI assistant section never runs the AI (it shows and decides proposals).
//

import SwiftUI
import UniformTypeIdentifiers
import os

/// The tools, in the order the list shows them.
enum CaseMapTool: String, CaseIterable, Identifiable, Sendable {
    case automation, assistant, money, casePeople, team, teamFolder, people, patterns, history, closing, briefings, exchange
    // Unified path AI-28 / IN-20 (owner 2026-11-22) — not tested yet.
    case studyDeeper, enrichment
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automation: return "Automation"
        case .assistant: return "AI assistant"
        case .money: return "Money"
        case .casePeople: return "People in the case"
        case .team: return "Team and work"
        case .teamFolder: return "Team folder"
        case .people: return "People and roles"
        case .patterns: return "Relationship patterns"
        case .history: return "History set"
        case .closing: return "Closing and reopening"
        case .briefings: return "Briefings"
        case .exchange: return "Exchange files"
        case .studyDeeper: return "Study deeper"
        case .enrichment: return "Check against saved lists"
        }
    }
    var symbol: String {
        switch self {
        case .automation: return "gearshape.2"
        case .assistant: return "sparkles"
        case .money: return "banknote"
        case .casePeople: return "person.text.rectangle"
        case .team: return "person.3.sequence"
        case .teamFolder: return "folder.badge.person.crop"
        case .people: return "person.2"
        case .patterns: return "point.3.connected.trianglepath.dotted"
        case .history: return "clock.arrow.circlepath"
        case .closing: return "archivebox"
        case .briefings: return "doc.richtext"
        case .exchange: return "arrow.left.arrow.right.square"
        case .studyDeeper: return "brain"
        case .enrichment: return "checklist"
        }
    }
    /// What the tool is for, shown as text at the top of the section (HELP-04: critical instructions without hovering).
    var purpose: String {
        switch self {
        case .automation: return "What this case's rules may do by themselves, and the work they queued. The mode is never permission to send documents to an AI."
        case .assistant: return "The case's optional AI assistant: its mode and the proposals it returned. Every proposal waits for your decision; the case works fully by hand."
        case .money: return "Record an amount exactly as a document writes it, or import a bank statement file, and see the case's figures. Choose each amount's kind; currencies are never added together, and an entry with no kind is counted as \u{201C}not counted\u{201D} until you choose one."
        case .casePeople: return "Everyone the case concerns, with each role they hold here (a role never implies wrongdoing), a profile whose every line says where it comes from, places they were observed, and their statement."
        case .team: return "Who works on the case and what each person did: the team, work histories, declared capabilities and absences, conflict checks, and who could take a piece of work."
        case .teamFolder: return "Work with other people through a folder you can all reach — a file share, an external disk or a synced folder. Ask for a contribution, take in what comes back through the case's intake, and share assignments; there is no server and no account, and every item says whether it is only on this Mac or already in the folder."
        case .people: return "Who may do what in this case. Working alone you hold every role; giving someone a role makes it a team case."
        case .patterns: return "How two items of the map connect, following only the link types you choose. Reading a pattern records nothing."
        case .history: return "Other cases this case may consult, each with a purpose and a scope. Nothing is copied from them."
        case .closing: return "What each closure recorded (disposition, waived work, what stays unresolved), material that arrived after closure waiting for a decision, and finished work that newer evidence may reopen."
        case .briefings: return "Named, ordered sets of items for a reader. Export one through the export checks from the brief."
        case .exchange: return "Move this case's questions, people, dated events, their sources and your links in and out as a documented file (ime-case-exchange JSON, version 1)."
        case .studyDeeper: return "Ask the app to study the case's people more deeply now instead of waiting: it rebuilds what it has distilled about each one from the documents. With AI analysis off, the result is limited to what the app can read without it."
        case .enrichment: return "Check the case's people against the sanctions lists already saved on this Mac. Nothing is sent; a list never saved is said, and a name match is a lead to review, never a finding. Registry and court searches are in Online tools."
        }
    }
    /// The Help topic that explains it in full.
    var helpTopic: String {
        switch self {
        case .automation: return "concept-case-actions-automation"
        case .assistant: return "concept-case-ai-assistant"
        case .money, .history: return "concept-case-money-history"
        case .people, .casePeople, .team, .teamFolder: return "concept-case-roles-access"
        case .closing: return "concept-case-actions-automation"
        case .patterns: return "task-case-search"
        case .briefings: return "task-case-map-brief"
        case .exchange: return "task-case-interop"
        case .studyDeeper: return "concept-case-ai-assistant"
        case .enrichment: return "task-online-tools"
        }
    }
}

struct CaseMapToolsPanel: View {
    @Environment(AppState.self) private var appState
    let model: CaseFileModel
    let projection: CaseMapProjection?
    let service: CaseMapService?
    @State var tool: CaseMapTool
    let close: () -> Void
    /// Shows a record on the map (the workspace closes the panel and reveals it); nil: no map behind the panel.
    var open: ((CaseMapNodeID) -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Case tools", systemImage: "wrench.and.screwdriver").font(.headline)
                Spacer()
                Button("Help for this tool") { SurfaceOpener.openHelp(tool.helpTopic) }.buttonStyle(.link)
                Button("Close") { close() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            // A fixed-size sheet: the list keeps its width and the detail takes the rest (no split-view proposal involved).
            GeometryReader { geo in
                HStack(spacing: 0) {
                    List(CaseMapTool.allCases, selection: Binding(get: { Optional(tool) }, set: { if let t = $0 { tool = t } })) { t in
                        Label(t.title, systemImage: t.symbol).tag(t)
                            .accessibilityLabel("Tool: \(t.title)")
                    }
                    .frame(width: 210)
                    .accessibilityIdentifier("case.tools.list")
                    Divider()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(tool.title).font(.title3.weight(.semibold))
                            Text(tool.purpose).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            Divider()
                            section
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(width: max(0, geo.size.width - 211), height: geo.size.height)
                    .accessibilityIdentifier("case.tools.detail")
                }
            }
        }
        .frame(width: 860, height: 600)
    }

    @ViewBuilder private var section: some View {
        switch tool {
        case .automation: CaseAutomationTool(caseID: model.caseID, actor: model.actor)
        case .assistant: CaseAssistantTool(caseID: model.caseID, actor: model.actor)
        case .money: CaseMoneyTool(caseID: model.caseID, actor: model.actor)
        case .casePeople: CasePeopleInCaseTool(caseID: model.caseID, actor: model.actor)
        case .team: CaseTeamWorkTool(caseID: model.caseID, actor: model.actor, open: open)
        case .teamFolder: CaseTeamFolderTool(caseID: model.caseID, actor: model.actor)
        case .people: CasePeopleRolesTool(caseID: model.caseID, actor: model.actor)
        case .patterns: CasePatternTool(caseID: model.caseID, actor: model.actor, projection: projection)
        case .history: CaseHistorySetTool(caseID: model.caseID, actor: model.actor, service: service, open: open)
        case .closing: CaseMapClosingTool(caseID: model.caseID, actor: model.actor, service: service, open: open)
        case .briefings: CaseBriefingsTool(caseID: model.caseID, actor: model.actor, service: service)
        case .exchange: CaseExchangeTool(caseID: model.caseID, actor: model.actor, title: projection?.title ?? "Case")
        case .studyDeeper: CaseStudyDeeperTool(caseID: model.caseID)
        case .enrichment: CaseLocalEnrichmentTool(caseID: model.caseID)
        }
    }
}

// MARK: - Automation

struct CaseAutomationTool: View {
    @Environment(AppState.self) private var appState
    let caseID: UUID
    let actor: String
    @State private var state: CaseToolState = .loading
    @State private var mode: CaseAutomationMode = .manual
    @State private var version = 0
    @State private var queue: [CaseOutboxItem] = []
    @State private var notice: String?
    /// Unified path ARCH-12 (owner 2026-11-22) — not tested yet: who the case's work may go to.
    @State private var recipients: [CaseExternalRecipient] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Mode", selection: $mode) { ForEach(CaseAutomationMode.allCases, id: \.self) { Text($0.label).tag($0) } }
                .pickerStyle(.radioGroup)
            HStack {
                Button("Set automation mode") { Task { await setMode() } }.caseMapControlHelp("Set automation mode")
                Text("Policy version \(version)").font(.caption).foregroundStyle(.secondary)
            }
            CaseToolStateView(state: state)
            if let notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
            Text("Queued and held work").font(.headline)
            if queue.isEmpty, state == .ready {
                CaseToolStateView(state: .empty(what: "Nothing is queued.", next: "Automatic work appears here when a new document version arrives and the mode allows it."))
            }
            ForEach(queue) { item in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.purpose).font(.callout)
                        Text("\(item.state.label)" + (item.stateReason.map { " — \($0)" } ?? "")).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if [.queued, .held, .retrying, .failed].contains(item.state) {
                        Button("Cancel queued work") { Task { await cancel(item.id) } }.controlSize(.small).caseMapControlHelp("Cancel queued work")
                    }
                }
                .accessibilityElement(children: .combine)
            }
            if queue.contains(where: { $0.state == .held }) {
                Button("Resume held work") { Task { await resume() } }.caseMapControlHelp("Resume held work")
            }
            if !recipients.isEmpty {
                Text("Authorised recipients").font(.headline)
                ForEach(recipients) { r in
                    Text("\(r.recipient) · \(r.channel) · \(r.contentScope)" + (r.isActive ? "" : " (withdrawn)"))
                        .font(.caption).foregroundStyle(r.isActive ? .primary : .secondary)
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        guard let auto = appState.caseAutomation else { state = .failed(reason: "the ledger isn't open yet.", next: "Wait for the case to finish opening, then choose Refresh."); return }
        do {
            let p = try await auto.policy(caseID: caseID)
            mode = p.policy.mode; version = p.version
            queue = try await auto.queue(caseID: caseID)
            recipients = try await auto.externalRecipients(caseID: caseID)
            state = .ready
        } catch {
            KalsmritikoshLog.ui.error("Automation tool: \(error.localizedDescription, privacy: .public)")
            state = .from(error, doing: "reading the automation policy")
        }
    }
    private func setMode() async {
        guard let auto = appState.caseAutomation else { return }
        do { version = try await auto.setMode(caseID: caseID, mode, actor: actor); notice = "Mode recorded as policy version \(version)."; state = .ready }
        catch { KalsmritikoshLog.ui.error("Automation mode not set: \(error.localizedDescription, privacy: .public)"); state = .from(error, doing: "changing the case's policy") }
    }
    private func cancel(_ id: UUID) async {
        guard let auto = appState.caseAutomation else { return }
        do { try await auto.cancel(caseID: caseID, id: id, reason: "Cancelled from Case tools", actor: actor); await load() }
        catch { KalsmritikoshLog.ui.error("Automation cancel failed: \(error.localizedDescription, privacy: .public)"); state = .from(error, doing: "cancelling work") }
    }
    private func resume() async {
        guard let auto = appState.caseAutomation else { return }
        do { let n = try await auto.resumeHeld(caseID: caseID, actor: actor); notice = "\(n) item(s) resumed."; await load() }
        catch { KalsmritikoshLog.ui.error("Automation resume failed: \(error.localizedDescription, privacy: .public)"); state = .from(error, doing: "resuming work") }
    }
}

// MARK: - AI assistant (mode, an explicit run, and proposals)

struct CaseAssistantTool: View {
    @Environment(AppState.self) private var appState
    let caseID: UUID
    let actor: String
    @State private var state: CaseToolState = .loading
    @State private var policy = CaseAIPolicy()
    @State private var proposals: [CaseAIProposal] = []
    @State private var reason = ""
    /// Case plan 2026-11-16 (QA-16 / AI-04): an explicit run — nothing runs on navigation; the run's own gates apply (mode,
    /// set-up, daily limit, the case's permission asked once, privileged and restricted documents never sent, cache).
    @State private var taskKind: CaseAITaskKind = .review
    @State private var running = false
    @State private var runReport: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Mode", selection: $policy.mode) { ForEach(CaseAIMode.allCases, id: \.self) { Text($0.label).tag($0) } }
                .pickerStyle(.radioGroup)
            Button("Set assistant mode") { Task { await setMode() } }.caseMapControlHelp("Set assistant mode")
            CaseToolStateView(state: state)
            HStack {
                Picker("Ask for", selection: $taskKind) {
                    Text("Claims relevant to the open questions").tag(CaseAITaskKind.review)
                    Text("Follow-up actions").tag(CaseAITaskKind.followUps)
                    Text("Links between records").tag(CaseAITaskKind.links)
                    Text("Placing records in branches").tag(CaseAITaskKind.organize)
                    Text("Summaries").tag(CaseAITaskKind.summary)
                }
                .frame(maxWidth: 340)
                Button("Run the assistant") { Task { await runAssistant() } }
                    .disabled(reason: policy.mode == .off ? "The assistant is off for this case." : (running ? "A run is in progress." : nil),
                              remedy: "Choose a mode other than Off and set it.")
                    .caseMapControlHelp("Run the assistant")
                if running { ProgressView().controlSize(.small) }
            }
            if let runReport { Text(runReport).font(.caption).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("case.ai.runReport") }
            Text("Proposals waiting for you").font(.headline)
            let open = proposals.filter { $0.state == .proposed || $0.state == .deferred }
            if open.isEmpty, state == .ready {
                CaseToolStateView(state: .empty(what: "No proposal is waiting.", next: "Ask the assistant from the case when it is on; everything else works by hand."))
            }
            if !open.isEmpty {
                TextField("Reason (needed to reject or defer)", text: $reason).textFieldStyle(.roundedBorder)
            }
            ForEach(open) { p in
                VStack(alignment: .leading, spacing: 4) {
                    Text(p.statement).font(.callout).fixedSize(horizontal: false, vertical: true)
                    Text(p.label).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Accept proposal") { Task { await decide(p.id, accept: true, deferring: false) } }.caseMapControlHelp("Accept proposal")
                        Button("Reject proposal") { Task { await decide(p.id, accept: false, deferring: false) } }.caseMapControlHelp("Reject proposal")
                            .disabled(reason: reason.trimmingCharacters(in: .whitespaces).isEmpty ? "A reason is needed." : nil, remedy: "Type the reason above.")
                        Button("Defer proposal") { Task { await decide(p.id, accept: false, deferring: true) } }.caseMapControlHelp("Defer proposal")
                            .disabled(reason: reason.trimmingCharacters(in: .whitespaces).isEmpty ? "A reason is needed." : nil, remedy: "Type the reason above.")
                    }
                    .controlSize(.small)
                }
                .padding(8)
                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .task { await load() }
    }

    private func load() async {
        guard let ai = appState.caseAIAssist else {
            state = .aiFailed(reason: "the assistant is not available on this Mac now.", next: "Work on the case by hand; the assistant is optional.")
            return
        }
        do { policy = try await ai.policy(caseID: caseID).policy; proposals = try await ai.proposals(caseID: caseID); state = .ready }
        catch { KalsmritikoshLog.ui.error("Assistant tool: \(error.localizedDescription, privacy: .public)"); state = .from(error, doing: "reading the assistant's proposals") }
    }
    private func setMode() async {
        guard let auto = appState.caseAutomation else { return }
        do { _ = try await auto.setAIPolicy(caseID: caseID, policy, actor: actor); await load() }
        catch { KalsmritikoshLog.ui.error("Assistant mode not set: \(error.localizedDescription, privacy: .public)"); state = .from(error, doing: "changing the case's policy") }
    }

    private func runAssistant() async {
        guard let ai = appState.caseAIAssist else { return }
        running = true; defer { running = false }
        do {
            let r = try await ai.run(caseID: caseID, task: CaseAIAssistTask(kind: taskKind), actor: actor)
            runReport = Self.reportLine(r)
            await load()
        } catch {
            KalsmritikoshLog.ui.error("Assistant run failed: \(error.localizedDescription, privacy: .public)")
            runReport = "The run could not start: \(error.localizedDescription)"
        }
    }

    /// What the run did, in plain words (what was sent and what came back as proposals).
    static func reportLine(_ r: CaseAIRunReport) -> String {
        var s: String
        switch r.outcome {
        case .done: s = "Done: \(r.proposals.count) proposal(s) to review below."
        case .cached: s = "Answered already for the same documents and policy; nothing was sent."
        case .notRun, .declined, .refused, .failed, .cancelled: s = r.reason ?? "Nothing was kept."
        }
        if let c = r.coverage { s += " Documents: \(c.sent) of \(c.caseDocuments) sent" + (c.excluded.isEmpty ? "." : "; not sent: " + c.excluded.joined(separator: ", ") + ".") }
        if !r.suppressed.isEmpty { s += " \(r.suppressed.count) suggestion(s) already decided were not offered again." }
        return s
    }

    private func decide(_ id: UUID, accept: Bool, deferring: Bool) async {
        guard let ai = appState.caseAIAssist else { return }
        do {
            if accept { _ = try await ai.accept(caseID: caseID, proposalID: id, actor: actor) }
            else { try await ai.decline(caseID: caseID, proposalID: id, deferring: deferring, reason: reason, actor: actor) }
            reason = ""
            await load()
        } catch { KalsmritikoshLog.ui.error("Proposal decision not recorded: \(error.localizedDescription, privacy: .public)"); state = .from(error, doing: "deciding proposals") }
    }
}

// MARK: - Money

/// Money: record an amount by hand (its kind chosen, never assumed; its source document and place in it), import a bank
/// statement file (preview, then all or nothing, then a receipt), change a record's kind as a recorded revision, and see the
/// figures by currency with what they leave out.
struct CaseMoneyTool: View {
    @Environment(AppState.self) private var appState
    let caseID: UUID
    let actor: String
    @State private var state: CaseToolState = .loading
    @State private var ledger: CaseMoneyLedger?
    @State private var documents: [CaseMoneyDocument] = []
    /// Ease fixes A — no default kind: the person chooses one (an unclassified record counts in no figure).
    @State private var kind: CaseMoneyKind?
    @State private var amount = ""
    @State private var day = ""
    @State private var payer = ""
    @State private var payee = ""
    @State private var reference = ""
    @State private var sourceDocument: UUID?
    @State private var locator = ""
    @State private var quote = ""
    @State private var choosingFile = false
    @State private var pendingImport: CaseStatementImportDraft?
    @State private var reclassifying: CaseMoneyRecord?
    /// Case plan 2026-11-16 (MONEY-13): a look-alike pair the person is deciding (one payment or two), with the choice.
    @State private var deciding: CaseMoneyIdentityChoice?
    @State private var notice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Record one amount").font(.headline)
            entryForm
            Button("Record money…") { Task { await record() } }
                .caseMapControlHelp("Record money…")
                .disabled(reason: recordBlocked)
            Divider()
            HStack {
                Button("Import bank statement…") { choosingFile = true }
                    .caseMapControlHelp("Import bank statement…")
                Text("A CSV or tab-separated file whose header names a date column and debit/credit columns.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            CaseToolStateView(state: state)
            if let notice { Text(notice).font(.callout).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("case.money.notice") }
            if let l = ledger { figures(l) }
        }
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.commaSeparatedText, .tabSeparatedText, .plainText]) { result in
            if case .success(let url) = result { Task { await prepareImport(url) } }
        }
        .sheet(item: $pendingImport) { draft in
            CaseStatementImportSheet(caseID: caseID, actor: actor, draft: draft, accounts: ledger?.accounts.filter(\.isActive) ?? []) { receipt in
                pendingImport = nil
                if let receipt { notice = receipt.summary; Task { await load() } }
            }
        }
        .sheet(item: $deciding) { choice in
            CaseMoneyIdentitySheet(caseID: caseID, actor: actor, choice: choice) { message in
                deciding = nil
                if let message { notice = message; Task { await load() } }
            }
        }
        .sheet(item: $reclassifying) { r in
            CaseMoneyReclassifySheet(caseID: caseID, actor: actor, record: r) { message in
                reclassifying = nil
                if let message { notice = message; Task { await load() } }
            }
        }
        .task { await load() }
    }

    private var recordBlocked: String? {
        if kind == nil { return "Choose what the amount is (payment, receipt, refund …)." }
        if amount.trimmingCharacters(in: .whitespaces).isEmpty { return "Type the amount as the document writes it." }
        return nil
    }

    @ViewBuilder private var entryForm: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
            GridRow {
                Picker("Kind", selection: $kind) {
                    Text("Choose a kind").tag(CaseMoneyKind?.none)
                    ForEach(CaseMoneyKind.allCases, id: \.self) { k in Text(Self.kindTitle(k)).tag(Optional(k)) }
                }
                TextField("Amount as written (e.g. INR 2.5 lakh)", text: $amount).textFieldStyle(.roundedBorder)
            }
            GridRow {
                TextField("Day (yyyy-MM-dd), optional", text: $day).textFieldStyle(.roundedBorder)
                TextField("Reference, optional", text: $reference).textFieldStyle(.roundedBorder)
            }
            GridRow {
                TextField("Payer as written, optional", text: $payer).textFieldStyle(.roundedBorder)
                TextField("Payee as written, optional", text: $payee).textFieldStyle(.roundedBorder)
            }
            GridRow {
                Picker("Source document (optional)", selection: $sourceDocument) {
                    Text("None — my own entry").tag(UUID?.none)
                    ForEach(documents) { d in Text(d.name).tag(Optional(d.id)) }
                }
                .caseMapControlHelp("Source document (optional)")
                TextField("Page or place in it, optional (e.g. p. 3, row 12)", text: $locator).textFieldStyle(.roundedBorder)
            }
            GridRow {
                TextField("Words as the document writes them, optional", text: $quote).textFieldStyle(.roundedBorder)
                    .gridCellColumns(2)
            }
        }
    }

    /// A kind as the picker shows it; "not yet classified" says what it means.
    static func kindTitle(_ k: CaseMoneyKind) -> String {
        k == .unclassified ? "Not yet classified (counts in no figure)" : k.label
    }

    @ViewBuilder private func figures(_ l: CaseMoneyLedger) -> some View {
        let outcomes = l.outcomes()
        Text("Figures by currency").font(.headline)
        if outcomes.byCurrency.isEmpty {
            CaseToolStateView(state: .empty(what: "No classified movement yet.", next: "Record a payment, receipt, transfer, refund, reversal or fee; other kinds are mentions of money and enter no figure."))
        }
        // S15 (ARCH-10) — the same canonical lines the map, the report and the AI's money tool show (net included).
        // Case plan 2026-11-16 (MONEY-13): each figure opens to every entry it counts, with where each comes from.
        ForEach(l.figures(), id: \.self) { f in
            let entries = l.records(for: f)
            if entries.isEmpty {
                Text("\(f.figure.label): \(f.text)")
                    .font(.callout.monospacedDigit()).fixedSize(horizontal: false, vertical: true)
            } else {
                DisclosureGroup {
                    ForEach(entries) { r in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(CaseMoneyTool.recordLine(r)).font(.caption).fixedSize(horizontal: false, vertical: true)
                            Text(r.provenance).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                } label: {
                    Text("\(f.figure.label): \(f.text) — \(entries.count) entr\(entries.count == 1 ? "y" : "ies")")
                        .font(.callout.monospacedDigit()).fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityIdentifier("case.money.figure")
            }
        }
        undecidedPairs(l)
        // Ease fixes A — what the figures leave out, counted, with the action that fixes it.
        let notCounted = l.unclassified.count
        if notCounted > 0 {
            Label(CaseMoneyTool.notCountedText(notCounted), systemImage: "exclamationmark.circle")
                .font(.callout.weight(.semibold)).foregroundStyle(.orange)
                .accessibilityIdentifier("case.money.notCounted")
        }
        ForEach(outcomes.warnings, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
        let current = l.current
        Text("Records (\(current.count))").font(.headline)
        ForEach(current) { r in
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(CaseMoneyTool.recordLine(r)).font(.caption).fixedSize(horizontal: false, vertical: true)
                    Text(r.provenance).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Button("Change kind…") { reclassifying = r }.controlSize(.small).caseMapControlHelp("Change kind…")
            }
        }
        let replaced = l.amended.count
        if replaced > 0 { Text("\(replaced) record(s) replaced by a revision are kept and shown in the money report; they count in no figure.").font(.caption).foregroundStyle(.secondary) }
        Divider()
        // QA-16 (2026-11-17): rates, account relationships and gaps (MONEY-08/09/11).
        CaseMoneyMoreBlock(caseID: caseID, actor: actor, ledger: l, documents: documents) { message in notice = message; Task { await load() } }
    }

    /// Look-alike pairs counted once until a person decides; each decision needs a reason and is kept (append-only).
    @ViewBuilder private func undecidedPairs(_ l: CaseMoneyLedger) -> some View {
        let pairs = l.undecidedPairs()
        if !pairs.isEmpty {
            Text("Possibly the same payment (\(pairs.count))").font(.headline)
            Text("Each pair is counted once until you decide. Same amount is not the same payment: decide from the documents.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(Array(pairs.enumerated()), id: \.offset) { _, pair in
                VStack(alignment: .leading, spacing: 4) {
                    ForEach([pair.a, pair.b]) { r in
                        Text(CaseMoneyTool.recordLine(r) + " · " + r.provenance).font(.caption).fixedSize(horizontal: false, vertical: true)
                    }
                    HStack {
                        Button("Same payment…") { deciding = CaseMoneyIdentityChoice(a: pair.a, b: pair.b, decision: .sameTransaction) }
                            .controlSize(.small).caseMapControlHelp("Same payment…")
                        Button("Two payments…") { deciding = CaseMoneyIdentityChoice(a: pair.a, b: pair.b, decision: .distinct) }
                            .controlSize(.small).caseMapControlHelp("Two payments…")
                    }
                }
                .padding(6)
                .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                .accessibilityIdentifier("case.money.undecidedPair")
            }
        }
    }

    static func notCountedText(_ n: Int) -> String {
        "\(n) entr\(n == 1 ? "y" : "ies") not counted: choose a kind (“Change kind…”)."
    }

    static func recordLine(_ r: CaseMoneyRecord) -> String {
        var s = "\(kindTitle(r.kind)): \(r.display)"
        if let d = r.date ?? r.dateText { s += " — \(d)" }
        if let ref = r.reference { s += " — \(ref)" }
        return s
    }

    private func load() async {
        guard let file = appState.caseFiles?.file else { state = .failed(reason: "the ledger isn't open yet.", next: "Wait for the case to finish opening, then reopen Case tools."); return }
        do {
            ledger = try await file.moneyLedger(caseID: caseID)
            documents = try await file.moneyCaseDocuments(caseID: caseID)
            state = .ready
        } catch { KalsmritikoshLog.ui.error("Money tool: \(error.localizedDescription, privacy: .public)"); state = .from(error, doing: "reading money records") }
    }

    private func record() async {
        guard let file = appState.caseFiles?.file, let kind else { return }
        guard PurchaseCenter.shared.allowPaidAction("record money") else { return }
        var input = CaseMoneyRecordInput(kind: kind, amountText: amount)
        let d = day.trimmingCharacters(in: .whitespaces)
        input.date = d.isEmpty ? nil : d
        input.reference = reference; input.payerName = payer; input.payeeName = payee
        input.quote = quote
        if let doc = documents.first(where: { $0.id == sourceDocument }) {
            input.sourceVersionID = doc.id
            input.sourceName = CaseMoneyTool.sourceName(doc.name, locator: locator)
        }
        do {
            _ = try await file.recordMoney(caseID: caseID, input, actor: actor)
            amount = ""; quote = ""; locator = ""; self.kind = nil
            notice = "Recorded."
            await load()
        } catch { KalsmritikoshLog.ui.error("Money not recorded: \(error.localizedDescription, privacy: .public)"); state = .from(error, doing: "recording money") }
    }

    /// The source's name with the place in it ("Statement March.pdf, p. 3").
    static func sourceName(_ name: String, locator: String) -> String {
        let l = locator.trimmingCharacters(in: .whitespaces)
        return l.isEmpty ? name : "\(name), \(l)"
    }

    private func prepareImport(_ url: URL) async {
        guard let file = appState.caseFiles?.file else { return }
        guard PurchaseCenter.shared.allowPaidAction("import a statement", importing: true) else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
                notice = "Nothing was imported: the file is not text."; return
            }
            let digest = CaseStatementImportDraft.sha256(data)
            let match = try await file.moneyCaseDocument(caseID: caseID, sha256: digest)
            pendingImport = CaseStatementImportDraft(fileName: url.lastPathComponent, text: text, sha256: digest, document: match)
        } catch {
            KalsmritikoshLog.ui.error("Statement file not read: \(error.localizedDescription, privacy: .public)")
            state = .from(error, doing: "importing a statement")
        }
    }
}

// MARK: - People and roles

struct CasePeopleRolesTool: View {
    @Environment(AppState.self) private var appState
    let caseID: UUID
    let actor: String
    @State private var state: CaseToolState = .loading
    @State private var grants: [CaseAccessGrant] = []
    @State private var name = ""
    @State private var role: CaseAccessRole = .reviewer
    @State private var reason = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if grants.filter(\.isActive).isEmpty, state == .ready {
                CaseToolStateView(state: .empty(what: "Working alone: you hold every role.", next: "Give a role to a person only when someone else works on this case."))
            }
            ForEach(grants.filter(\.isActive)) { g in
                HStack {
                    Text(g.line).font(.callout).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Remove role…") { Task { await revoke(g.id) } }.controlSize(.small).caseMapControlHelp("Remove role…")
                        .disabled(reason: reason.trimmingCharacters(in: .whitespaces).isEmpty ? "A reason is needed." : nil, remedy: "Type the reason below.")
                }
            }
            Divider()
            HStack {
                TextField("Person's name", text: $name).textFieldStyle(.roundedBorder)
                Picker("Role", selection: $role) { ForEach(CaseAccessRole.allCases, id: \.self) { Text($0.label).tag($0) } }.frame(maxWidth: 200)
            }
            TextField("Reason (recorded in the access history)", text: $reason).textFieldStyle(.roundedBorder)
            Button("Give a role…") { Task { await grant() } }.caseMapControlHelp("Give a role…")
                .disabled(reason: name.trimmingCharacters(in: .whitespaces).isEmpty || reason.trimmingCharacters(in: .whitespaces).isEmpty ? "A name and a reason are needed." : nil)
            CaseToolStateView(state: state)
            Text("Names are recorded on this Mac; they are not signed-in accounts.").font(.caption).foregroundStyle(.secondary)
        }
        .task { await load() }
    }

    private func load() async {
        guard let file = appState.caseFiles?.file else { state = .failed(reason: "the ledger isn't open yet.", next: "Wait for the case to finish opening, then reopen Case tools."); return }
        do { grants = try await file.accessGrants(caseID: caseID); state = .ready }
        catch { KalsmritikoshLog.ui.error("Roles tool: \(error.localizedDescription, privacy: .public)"); state = .from(error, doing: "reading the case's roles") }
    }
    private func grant() async {
        guard let file = appState.caseFiles?.file else { return }
        do { _ = try await file.grantAccess(caseID: caseID, to: name, role: role, reason: reason, actor: actor); name = ""; reason = ""; await load() }
        catch { KalsmritikoshLog.ui.error("Role not given: \(error.localizedDescription, privacy: .public)"); state = .from(error, doing: "giving roles") }
    }
    private func revoke(_ id: UUID) async {
        guard let file = appState.caseFiles?.file else { return }
        do { try await file.revokeAccess(caseID: caseID, grantID: id, reason: reason, actor: actor); reason = ""; await load() }
        catch { KalsmritikoshLog.ui.error("Role not removed: \(error.localizedDescription, privacy: .public)"); state = .from(error, doing: "removing roles") }
    }
}

// MARK: - Relationship patterns

struct CasePatternTool: View {
    @Environment(AppState.self) private var appState
    let caseID: UUID
    let actor: String
    let projection: CaseMapProjection?
    @State private var from: CaseMapNodeID?
    @State private var to: CaseMapNodeID?
    @State private var lines: [String] = []
    @State private var name = ""
    @State private var state: CaseToolState = .ready
    @State private var lastQuery: CaseMapPathQuery?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let p = projection, p.nodes.count > 1 {
                Picker("From", selection: $from) {
                    Text("Choose an item").tag(CaseMapNodeID?.none)
                    ForEach(p.nodes) { n in Text("\(n.kind.label): \(String(n.title.prefix(60)))").tag(Optional(n.id)) }
                }
                Picker("To", selection: $to) {
                    Text("Any item").tag(CaseMapNodeID?.none)
                    ForEach(p.nodes) { n in Text("\(n.kind.label): \(String(n.title.prefix(60)))").tag(Optional(n.id)) }
                }
                Button("Find paths") { find(p) }.caseMapControlHelp("Find paths")
                    .disabled(reason: from == nil ? "Choose where the path starts." : nil)
                ForEach(lines, id: \.self) { Text($0).font(.caption).fixedSize(horizontal: false, vertical: true) }
                if lastQuery != nil {
                    HStack {
                        TextField("Pattern name", text: $name).textFieldStyle(.roundedBorder)
                        Button("Save pattern") { Task { await save() } }.caseMapControlHelp("Save pattern")
                            .disabled(reason: name.trimmingCharacters(in: .whitespaces).isEmpty ? "Give the pattern a name." : nil)
                    }
                }
            } else {
                CaseToolStateView(state: .empty(what: "The map has fewer than two items.", next: "Record a question and bring documents into the case; patterns connect what is on the map."))
            }
            CaseToolStateView(state: state)
        }
    }

    private func find(_ p: CaseMapProjection) {
        guard let from else { return }
        let q = CaseMapPathQuery(from: from, to: to)
        switch CaseMapPathSearch.run(q, in: p) {
        case .success(let r): lines = r.lines; lastQuery = q; state = .ready
        case .failure(let e):
            lastQuery = nil
            switch e {
            case .rejected(let why): state = .blocked(reason: why.joined(separator: " "), next: "Change the start, end or limits and choose Find paths again.")
            case .notInMap(let what): state = .empty(what: "\(what) is not on the map now.", next: "Choose Refresh on the map, then pick the items again.")
            }
        }
    }
    private func save() async {
        guard let db = appState.database, let q = lastQuery else { return }
        do { _ = try await CaseSearchRepository(database: db).savePattern(caseID: caseID, name: name, kind: .live, query: q, result: nil, fence: nil, actor: actor); name = ""; state = .ready }
        catch { KalsmritikoshLog.ui.error("Pattern not saved: \(error.localizedDescription, privacy: .public)"); state = .from(error, doing: "saving patterns") }
    }
}

// MARK: - History set

struct CaseHistorySetTool: View {
    @Environment(AppState.self) private var appState
    let caseID: UUID
    let actor: String
    var service: CaseMapService? = nil
    var open: ((CaseMapNodeID) -> Void)? = nil
    @State private var state: CaseToolState = .loading
    @State private var sources: [CaseHistorySource] = []
    @State private var cases: [CaseloadRow] = []
    @State private var other: UUID?
    @State private var purpose = ""
    @State private var scope: CaseHistoryScope = .identifiersOnly

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if sources.filter(\.isActive).isEmpty, state == .ready {
                CaseToolStateView(state: .empty(what: "No other case is in this case's history set.", next: "Add one below with the purpose you need it for."))
            }
            ForEach(sources.filter(\.isActive)) { s in
                Text("\(s.kind.label): \(historySourceName(s)) — \(s.purpose) (\(s.scope.label))").font(.callout)
                // QA-16 (2026-11-17): compare, reference, known-at and review for a case in the set.
                if s.kind == .case, s.originCaseID != nil, cases.contains(where: { $0.caseID == s.originCaseID }) {
                    CaseHistoryReviewBlock(caseID: caseID, actor: actor, source: s, originTitle: historySourceName(s), service: service)
                }
            }
            Divider()
            Picker("Case", selection: $other) {
                Text("Choose a case").tag(UUID?.none)
                ForEach(cases.filter { $0.caseID != caseID }) { c in Text(c.title).tag(Optional(c.caseID)) }
            }
            Picker("Scope", selection: $scope) { ForEach(CaseHistoryScope.allCases, id: \.self) { Text($0.label).tag($0) } }
            TextField("Purpose (why this case may be consulted)", text: $purpose).textFieldStyle(.roundedBorder)
            Button("Add to history set…") { Task { await add() } }.caseMapControlHelp("Add to history set…")
                .disabled(reason: other == nil || purpose.trimmingCharacters(in: .whitespaces).isEmpty ? "Choose a case and state the purpose." : nil)
            CaseToolStateView(state: state)
            Divider()
            // HISTORY-01: identifiers chosen to be looked for in other cases, each with its matching basis.
            CaseOverlapIdentifiersBlock(caseID: caseID, actor: actor, service: service)
        }
        .task { await load() }
    }

    /// The other case's title, or "an erased case" when it no longer exists (SEC-07).
    private func historySourceName(_ s: CaseHistorySource) -> String {
        if let title = cases.first(where: { $0.caseID == s.originCaseID })?.title { return title }
        if s.kind == .case { return "an erased case" }
        return s.externalName ?? s.collectionRef ?? "—"
    }

    private func load() async {
        guard let svc = appState.caseFiles else {
            state = .failed(reason: "the ledger isn't open yet.", next: "Wait for the case to finish opening, then reopen Case tools."); return
        }
        do {
            sources = try await svc.file.historySources(caseID: caseID)
            cases = try await svc.caseload(includeArchived: true)
            state = .ready
        } catch { KalsmritikoshLog.ui.error("History set tool: \(error.localizedDescription, privacy: .public)"); state = .from(error, doing: "reading the history set") }
    }
    private func add() async {
        guard let file = appState.caseFiles?.file, let other else { return }
        do { _ = try await file.addHistorySource(caseID: caseID, kind: .case, originCaseID: other, purpose: purpose, scope: scope, actor: actor); purpose = ""; await load() }
        catch { KalsmritikoshLog.ui.error("History source not added: \(error.localizedDescription, privacy: .public)"); state = .from(error, doing: "changing the history set") }
    }
}

// MARK: - Briefings

struct CaseBriefingsTool: View {
    @Environment(AppState.self) private var appState
    let caseID: UUID
    let actor: String
    let service: CaseMapService?
    @State private var state: CaseToolState = .loading
    @State private var briefings: [CaseBriefing] = []
    @State private var title = ""
    @State private var notice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if briefings.isEmpty, state == .ready {
                CaseToolStateView(state: .empty(what: "No briefing yet.", next: "Create one below, then add items to it from the Brief (“Add step”)."))
            }
            ForEach(briefings) { b in
                HStack {
                    VStack(alignment: .leading) {
                        Text(b.title).font(.callout)
                        Text(b.frozenAt == nil ? "Follows the case as it is now" : "Frozen").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Export this briefing…") { export(b) }.controlSize(.small).caseMapControlHelp("Export this briefing…")
                }
            }
            HStack {
                TextField("Title (e.g. For the director)", text: $title).textFieldStyle(.roundedBorder)
                Button("Create briefing") { Task { await create() } }.caseMapControlHelp("Create briefing")
                    .disabled(reason: title.trimmingCharacters(in: .whitespaces).isEmpty ? "Give the briefing a title." : nil)
            }
            CaseToolStateView(state: state)
            if let notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
        }
        .task { await load() }
    }

    private func load() async {
        guard let file = appState.caseFiles?.file else { state = .failed(reason: "the ledger isn't open yet.", next: "Wait for the case to finish opening, then reopen Case tools."); return }
        do { briefings = try await file.briefLedger(caseID: caseID).briefings.filter { $0.withdrawnAt == nil }; state = .ready }
        catch { KalsmritikoshLog.ui.error("Briefings tool: \(error.localizedDescription, privacy: .public)"); state = .from(error, doing: "reading briefings") }
    }
    private func create() async {
        guard let file = appState.caseFiles?.file else { return }
        do { _ = try await file.createBriefing(caseID: caseID, title: title, purpose: nil, actor: actor); title = ""; await load() }
        catch { KalsmritikoshLog.ui.error("Briefing not created: \(error.localizedDescription, privacy: .public)"); state = .from(error, doing: "creating briefings") }
    }
    private func export(_ b: CaseBriefing) {
        guard let outputs = appState.caseOutputs, let service else { notice = "The ledger isn't ready yet; nothing was exported."; return }
        let caseID = caseID, actor = actor
        Task { notice = await CaseMapExportRoutes.exportBriefing(outputs: outputs, caseID: caseID, briefingID: b.id, title: b.title, actor: actor, service: service) }
    }
}

// MARK: - Exchange files (ADAPT-06)

struct CaseExchangeTool: View {
    @Environment(AppState.self) private var appState
    let caseID: UUID
    let actor: String
    let title: String
    @State private var state: CaseToolState = .loading
    @State private var receipts: [CaseExchangeReceipt] = []
    @State private var notice: String?
    @State private var importing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Supported: questions, people (with a role), dated events with their source references, and the links you drew between them. Not supported: documents themselves, money, tasks, reports and decisions — an import lists every field it did not take.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Export structured exchange (JSON)…") { export() }.caseMapControlHelp("Export structured exchange (JSON)…")
                Button("Import structured exchange (JSON)…") { importing = true }.caseMapControlHelp("Import structured exchange (JSON)…")
            }
            CaseToolStateView(state: state)
            if let notice { Text(notice).font(.callout).fixedSize(horizontal: false, vertical: true) }
            Text("Import receipts").font(.headline)
            if receipts.isEmpty, state == .ready {
                CaseToolStateView(state: .empty(what: "Nothing imported yet.", next: "Import a file exported from this app or written to the documented format."))
            }
            ForEach(receipts, id: \.id) { r in
                VStack(alignment: .leading, spacing: 2) {
                    Text("From \(r.sourceSystem): " + r.summary).font(.callout).fixedSize(horizontal: false, vertical: true)
                    ForEach(r.skipped + r.unsupportedFields.map { "Unsupported field: \($0)" } + r.limitations, id: \.self) {
                        Text($0).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            if case .success(let url) = result { Task { await importFile(url) } }
        }
        .task { await load() }
    }

    private func load() async {
        guard let file = appState.caseFiles?.file else { state = .failed(reason: "the ledger isn't open yet.", next: "Wait for the case to finish opening, then reopen Case tools."); return }
        do { receipts = try await file.exchangeImports(caseID: caseID); state = .ready }
        catch { KalsmritikoshLog.ui.error("Exchange tool: \(error.localizedDescription, privacy: .public)"); state = .from(error, doing: "reading import receipts") }
    }
    private func export() {
        guard let outputs = appState.caseOutputs, let file = appState.caseFiles?.file else { notice = "The ledger isn't ready yet; nothing was exported."; return }
        let caseID = caseID, actor = actor, title = title
        Task { notice = await CaseMapExportRoutes.exportExchange(outputs: outputs, file: file, caseID: caseID, title: title, actor: actor) }
    }
    private func importFile(_ url: URL) async {
        guard let file = appState.caseFiles?.file else { return }
        guard PurchaseCenter.shared.allowPaidAction("import into the case") else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let r = try await file.importExchange(caseID: caseID, data: data, actor: actor)
            notice = r.summary
            await load()
        } catch {
            KalsmritikoshLog.ui.error("Exchange import refused: \(error.localizedDescription, privacy: .public)")
            state = .from(error, doing: "importing into the case")
        }
    }
}

// MARK: - ADAPT-05: supplied summaries on an unread document (inspector)

struct CaseSuppliedSummaryBlock: View {
    @Environment(AppState.self) private var appState
    let caseID: UUID
    let actor: String
    let node: CaseMapNode
    @State private var summaries: [CaseSuppliedSummary] = []
    @State private var adding = false
    @State private var text = ""
    @State private var suppliedBy = ""
    @State private var basis = ""
    @State private var error: String?

    private var versions: Set<UUID> { Set(node.sources.compactMap(\.sourceVersionID)) }
    private var objects: Set<UUID> { Set(node.sources.compactMap(\.objectID)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(summaries.filter { $0.isActive }) { s in
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.label).font(.caption.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                    Text(s.summary).font(.caption).fixedSize(horizontal: false, vertical: true)
                }
                .padding(6)
                .background(Color.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                .accessibilityElement(children: .combine)
            }
            if node.status.kind == .failed || node.status.kind == .unassessed {
                Button("Attach a supplied summary…") { adding = true }.caseMapControlHelp("Attach a supplied summary…")
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .task(id: node.id) { await load() }
        .sheet(isPresented: $adding) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Attach a supplied summary").font(.headline)
                Text("For material the app could not read. It is shown as supplied by the person named — never as the document's words — and the original stays as it is.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                TextField("The summary, as supplied", text: $text, axis: .vertical).lineLimit(3...8)
                TextField("Who supplied it", text: $suppliedBy)
                TextField("Basis (e.g. the custodian's covering letter), optional", text: $basis)
                HStack {
                    Spacer()
                    Button("Cancel") { adding = false }.keyboardShortcut(.cancelAction)
                    Button("Attach") { Task { await add() } }.keyboardShortcut(.defaultAction)
                        .disabled(reason: text.trimmingCharacters(in: .whitespaces).isEmpty || suppliedBy.trimmingCharacters(in: .whitespaces).isEmpty ? "The summary and who supplied it are needed." : nil)
                }
            }
            .padding(16).frame(width: 460)
        }
    }

    private func load() async {
        guard let file = appState.caseFiles?.file else { return }
        do {
            summaries = try await file.suppliedSummaries(caseID: caseID).filter { s in
                (s.sourceVersionID.map(versions.contains) ?? false) || (s.objectID.map(objects.contains) ?? false)
            }
        } catch { KalsmritikoshLog.ui.error("Supplied summaries not read: \(error.localizedDescription, privacy: .public)") }
    }
    private func add() async {
        guard let file = appState.caseFiles?.file else { return }
        do {
            _ = try await file.addSuppliedSummary(caseID: caseID, sourceVersionID: node.sources.first?.sourceVersionID, objectID: node.sources.first?.objectID,
                                                  sourceName: node.title, summary: text, suppliedBy: suppliedBy, basis: basis, actor: actor)
            adding = false; text = ""; error = nil
            await load()
        } catch {
            KalsmritikoshLog.ui.error("Supplied summary not attached: \(error.localizedDescription, privacy: .public)")
            self.error = error.localizedDescription
        }
    }
}

// MARK: - HELP-01: start a case from its question (Ease fixes B: the one "New case…" sheet, NewCaseSheet in CasesView)

nonisolated enum FirstCaseEntry {
    /// The ways in, and how many screens each takes before case work starts.
    enum Start: String, CaseIterable, Sendable {
        case question, documents, existingCase, sample
        var title: String {
            switch self {
            case .question: return "New case…"
            case .documents: return "Start with my documents"
            case .existingCase: return "Resume a case"
            case .sample: return "Try a sample case"
            }
        }
        /// Screens between the choice and the case's own work (the question start is one short sheet).
        var screensToCaseWork: Int {
            switch self {
            case .question: return 1
            case .documents: return 5
            case .existingCase: return 1
            case .sample: return 1
            }
        }
    }
    static let pendingKey = "kalsmritikosh.cases.startFromQuestion"
    /// Ease fixes B — "New case…" from the File menu (or the first screen): Cases opens with the one new-case sheet.
    static let newCaseRequested = Notification.Name("kalsmritikosh.cases.newCaseRequested")

    @MainActor static func requestNewCase() {
        AppDefaults.store.set(true, forKey: pendingKey)
        SurfaceOpener.open(.cases)
        NotificationCenter.default.post(name: newCaseRequested, object: nil)
    }

    /// The case title from the question when none is typed: its first line, at most 80 characters, without a trailing "?".
    static func title(question: String, typed: String) -> String {
        let t = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }
        let first = question.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines).first ?? ""
        let trimmed = String(first.prefix(80)).trimmingCharacters(in: CharacterSet(charactersIn: "? ").union(.whitespaces))
        return trimmed.isEmpty ? "New case" : trimmed
    }
}

/// Which tool to open when a case first opens on the map (set by the question start when a team was chosen).
@MainActor
enum CaseMapWorkspaceMemoryHint {
    private static var pending: [UUID: CaseMapTool] = [:]
    static func openTools(_ tool: CaseMapTool, caseID: UUID) { pending[caseID] = tool }
    static func take(caseID: UUID) -> CaseMapTool? { pending.removeValue(forKey: caseID) }
}


/// A look-alike pair and the decision the person is about to record (case plan 2026-11-16, MONEY-13).
struct CaseMoneyIdentityChoice: Identifiable {
    let a: CaseMoneyRecord
    let b: CaseMoneyRecord
    let decision: CaseMoneyIdentityDecision.Decision
    var id: String { a.id.uuidString + b.id.uuidString + decision.rawValue }
}

/// Record that two look-alike records are one payment or two, with a reason (MONEY-04's append-only decision).
struct CaseMoneyIdentitySheet: View {
    @Environment(AppState.self) private var appState
    let caseID: UUID
    let actor: String
    let choice: CaseMoneyIdentityChoice
    let done: (String?) -> Void
    @State private var reason = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(choice.decision == .sameTransaction ? "Record as one payment" : "Record as two payments").font(.headline)
            Text(CaseMoneyTool.recordLine(choice.a)).font(.caption)
            Text(CaseMoneyTool.recordLine(choice.b)).font(.caption)
            TextField("Why (what in the documents shows it)", text: $reason, axis: .vertical)
                .lineLimit(2...4)
                .accessibilityIdentifier("case.money.identityReason")
            if let error { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { done(nil) }.keyboardShortcut(.cancelAction)
                Button("Record") { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 420)
    }

    private func save() async {
        guard let file = appState.caseFiles?.file else { error = "The ledger isn't open."; return }
        do {
            try await file.decideMoneyIdentity(caseID: caseID, recordA: choice.a.id, recordB: choice.b.id, decision: choice.decision,
                                               reason: reason, actor: actor)
            done(choice.decision == .sameTransaction ? "Recorded as one payment; the figures count it once." : "Recorded as two payments; the figures count both.")
        } catch {
            KalsmritikoshLog.ui.error("Money identity decision failed: \(error.localizedDescription, privacy: .public)")
            self.error = error.localizedDescription
        }
    }
}
