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
    case automation, assistant, money, people, patterns, history, briefings, exchange
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automation: return "Automation"
        case .assistant: return "AI assistant"
        case .money: return "Money"
        case .people: return "People and roles"
        case .patterns: return "Relationship patterns"
        case .history: return "History set"
        case .briefings: return "Briefings"
        case .exchange: return "Exchange files"
        }
    }
    var symbol: String {
        switch self {
        case .automation: return "gearshape.2"
        case .assistant: return "sparkles"
        case .money: return "banknote"
        case .people: return "person.2"
        case .patterns: return "point.3.connected.trianglepath.dotted"
        case .history: return "clock.arrow.circlepath"
        case .briefings: return "doc.richtext"
        case .exchange: return "arrow.left.arrow.right.square"
        }
    }
    /// What the tool is for, shown as text at the top of the section (HELP-04: critical instructions without hovering).
    var purpose: String {
        switch self {
        case .automation: return "What this case's rules may do by themselves, and the work they queued. The mode is never permission to send documents to an AI."
        case .assistant: return "The case's optional AI assistant: its mode and the proposals it returned. Every proposal waits for your decision; the case works fully by hand."
        case .money: return "Record an amount exactly as a document writes it, and see the case's figures. Currencies are never added together; an unclassified record is in no figure."
        case .people: return "Who may do what in this case. Working alone you hold every role; giving someone a role makes it a team case."
        case .patterns: return "How two items of the map connect, following only the link types you choose. Reading a pattern records nothing."
        case .history: return "Other cases this case may consult, each with a purpose and a scope. Nothing is copied from them."
        case .briefings: return "Named, ordered sets of items for a reader. Export one through the export checks from the brief."
        case .exchange: return "Move this case's questions, people, dated events, their sources and your links in and out as a documented file (ime-case-exchange JSON, version 1)."
        }
    }
    /// The Help topic that explains it in full.
    var helpTopic: String {
        switch self {
        case .automation: return "concept-case-actions-automation"
        case .assistant: return "concept-case-ai-assistant"
        case .money, .history: return "concept-case-money-history"
        case .people: return "concept-case-roles-access"
        case .patterns: return "task-case-search"
        case .briefings: return "task-case-map-brief"
        case .exchange: return "task-case-interop"
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
        case .people: CasePeopleRolesTool(caseID: model.caseID, actor: model.actor)
        case .patterns: CasePatternTool(caseID: model.caseID, actor: model.actor, projection: projection)
        case .history: CaseHistorySetTool(caseID: model.caseID, actor: model.actor)
        case .briefings: CaseBriefingsTool(caseID: model.caseID, actor: model.actor, service: service)
        case .exchange: CaseExchangeTool(caseID: model.caseID, actor: model.actor, title: projection?.title ?? "Case")
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
        }
        .task { await load() }
    }

    private func load() async {
        guard let auto = appState.caseAutomation else { state = .failed(reason: "the ledger isn't open yet.", next: "Wait for the case to finish opening, then choose Refresh."); return }
        do {
            let p = try await auto.policy(caseID: caseID)
            mode = p.policy.mode; version = p.version
            queue = try await auto.queue(caseID: caseID)
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

// MARK: - AI assistant (mode and proposals; this screen never runs the AI)

struct CaseAssistantTool: View {
    @Environment(AppState.self) private var appState
    let caseID: UUID
    let actor: String
    @State private var state: CaseToolState = .loading
    @State private var policy = CaseAIPolicy()
    @State private var proposals: [CaseAIProposal] = []
    @State private var reason = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Mode", selection: $policy.mode) { ForEach(CaseAIMode.allCases, id: \.self) { Text($0.label).tag($0) } }
                .pickerStyle(.radioGroup)
            Button("Set assistant mode") { Task { await setMode() } }.caseMapControlHelp("Set assistant mode")
            CaseToolStateView(state: state)
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

struct CaseMoneyTool: View {
    @Environment(AppState.self) private var appState
    let caseID: UUID
    let actor: String
    @State private var state: CaseToolState = .loading
    @State private var ledger: CaseMoneyLedger?
    @State private var kind: CaseMoneyKind = .unclassified
    @State private var amount = ""
    @State private var day = ""
    @State private var payer = ""
    @State private var payee = ""
    @State private var reference = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    Picker("Kind", selection: $kind) { ForEach(CaseMoneyKind.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
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
            }
            Button("Record money…") { Task { await record() } }
                .caseMapControlHelp("Record money…")
                .disabled(reason: amount.trimmingCharacters(in: .whitespaces).isEmpty ? "Type the amount as the document writes it." : nil)
            CaseToolStateView(state: state)
            if let l = ledger {
                let outcomes = l.outcomes()
                Text("Figures by currency").font(.headline)
                if outcomes.byCurrency.isEmpty {
                    CaseToolStateView(state: .empty(what: "No classified movement yet.", next: "Record a payment, receipt, transfer, refund, reversal or fee; other kinds are mentions of money and enter no figure."))
                }
                // S15 (ARCH-10) — the same canonical lines the map, the report and the AI's money tool show (net included).
                ForEach(l.figures(), id: \.self) { f in
                    Text("\(f.figure.label): \(f.text)")
                        .font(.callout.monospacedDigit()).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(outcomes.warnings, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
                Text("Records (\(l.records.filter(\.isActive).count))").font(.headline)
                ForEach(l.records.filter(\.isActive)) { r in
                    Text("\(r.kind.rawValue): \(r.display)" + ((r.date ?? r.dateText).map { " — \($0)" } ?? "")).font(.caption)
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        guard let file = appState.caseFiles?.file else { state = .failed(reason: "the ledger isn't open yet.", next: "Wait for the case to finish opening, then reopen Case tools."); return }
        do { ledger = try await file.moneyLedger(caseID: caseID); state = .ready }
        catch { KalsmritikoshLog.ui.error("Money tool: \(error.localizedDescription, privacy: .public)"); state = .from(error, doing: "reading money records") }
    }
    private func record() async {
        guard let file = appState.caseFiles?.file else { return }
        guard PurchaseCenter.shared.allowPaidAction("record money") else { return }
        var input = CaseMoneyRecordInput(kind: kind, amountText: amount)
        input.date = day.trimmingCharacters(in: .whitespaces).isEmpty ? nil : day.trimmingCharacters(in: .whitespaces)
        input.reference = reference; input.payerName = payer; input.payeeName = payee
        do { _ = try await file.recordMoney(caseID: caseID, input, actor: actor); amount = ""; await load() }
        catch { KalsmritikoshLog.ui.error("Money not recorded: \(error.localizedDescription, privacy: .public)"); state = .from(error, doing: "recording money") }
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

// MARK: - HELP-01: start a case from its question (no intake form, no wizard)

nonisolated enum FirstCaseEntry {
    /// The ways in, and how many screens each takes before case work starts.
    enum Start: String, CaseIterable, Sendable {
        case question, documents, existingCase, sample
        var title: String {
            switch self {
            case .question: return "Start from a question"
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

    /// The case title from the question when none is typed: its first line, at most 80 characters, without a trailing "?".
    static func title(question: String, typed: String) -> String {
        let t = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }
        let first = question.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines).first ?? ""
        let trimmed = String(first.prefix(80)).trimmingCharacters(in: CharacterSet(charactersIn: "? ").union(.whitespaces))
        return trimmed.isEmpty ? "New case" : trimmed
    }
}

struct QuickCaseSheet: View {
    @Environment(AppState.self) private var appState
    let done: (UUID?) -> Void
    @State private var question = ""
    @State private var title = ""
    @State private var templateID = ""
    @State private var team = false
    @State private var error: String?
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Start from a question").font(.title2.bold())
            Text("Type the question the case is to answer. That is all a case needs to begin; add documents, people and work when you are ready.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("The question (e.g. Who approved the second payment to Supplier ABC?)", text: $question, axis: .vertical).lineLimit(2...5)
                .textFieldStyle(.roundedBorder)
            TextField("Case title (optional — the question is used)", text: $title).textFieldStyle(.roundedBorder)
            Picker("Kind of investigation (optional)", selection: $templateID) {
                Text("None — start empty").tag("")
                ForEach(CaseTemplate.all) { Text($0.title).tag($0.id) }
            }
            Picker("Who works on it", selection: $team) {
                Text("Just me").tag(false)
                Text("A team (give roles in Case tools ▸ People and roles)").tag(true)
            }
            .pickerStyle(.radioGroup)
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("Cancel") { done(nil) }.keyboardShortcut(.cancelAction)
                Button("Create case") { Task { await create() } }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(reason: working ? "The case is being created." : question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Type the question first." : nil)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func create() async {
        guard let cases = appState.investigationCases, let svc = appState.caseFiles, let wsRepo = appState.workspaces else {
            error = "The ledger isn't ready yet."; return
        }
        working = true; defer { working = false }
        let actor = InvestigatorProfile.name, now = Date()
        let name = FirstCaseEntry.title(question: question, typed: title)
        do {
            let ws = Workspace(title: name)
            try await wsRepo.upsert(ws)
            let c = try await cases.createCase(workspaceID: ws.id, title: name, purpose: question.trimmingCharacters(in: .whitespacesAndNewlines), actor: actor, at: now)
            if let t = CaseTemplate.template(id: templateID) { try await svc.applyTemplate(t, caseID: c.id, workspaceID: ws.id, actor: actor, at: now) }
            if team { CaseMapWorkspaceMemoryHint.openTools(.people, caseID: c.id) }
            done(c.id)
        } catch {
            KalsmritikoshLog.ui.error("Quick case not created: \(error.localizedDescription, privacy: .public)")
            self.error = error.localizedDescription
        }
    }
}

/// Which tool to open when a case first opens on the map (set by the question start when a team was chosen).
@MainActor
enum CaseMapWorkspaceMemoryHint {
    private static var pending: [UUID: CaseMapTool] = [:]
    static func openTools(_ tool: CaseMapTool, caseID: UUID) { pending[caseID] = tool }
    static func take(caseID: UUID) -> CaseMapTool? { pending.removeValue(forKey: caseID) }
}
