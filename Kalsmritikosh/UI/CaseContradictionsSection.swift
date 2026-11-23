//
//  CaseContradictionsSection.swift
//  Kalsmritikosh
//
//  P3 — the case file's contradictions: "Find contradictions" compares this case's own documents by the
//  rules on the Mac, then — when AI is set up — opens the one AI entry, "Look for conflicts with AI…" (owner
//  request 2026-11-16: one AI conflict path; every quote it gives checked against the documents). Each
//  contradiction shows its statements verbatim, each with "Open source" at its words — never averaged,
//  never resolved.
//
//  P0-C 3–4 / P1-A (owner's implementation plan 2026-11-04): the review happens HERE — a list of the
//  case's contradictions beside the selected one's detail; Confirm, Dismiss (with a reason) or Defer,
//  recorded through InvestigationContradictionGapService against the version of both documents. An
//  unchanged rerun keeps the decision; a revised document reopens it and says which. The history stays.
//  A confirmed item can be added to the chronology or the report without retyping (JobResultHandoff).
//  The selection, filter and search come back when the case is reopened (CaseWorkspaceState).
//

import SwiftUI
import os

/// The case's shared workspace preferences (one per open case file); every change is saved at once.
@MainActor @Observable
final class CaseWorkspaceHolder {
    let caseID: UUID
    @ObservationIgnored private let defaults: UserDefaults
    var state: CaseWorkspaceState {
        didSet { if state != oldValue { CaseWorkspaceStore.save(state, caseID: caseID, defaults: defaults) } }
    }
    init(caseID: UUID, defaults: UserDefaults) {
        self.caseID = caseID; self.defaults = defaults
        self.state = CaseWorkspaceStore.load(caseID: caseID, defaults: defaults)
    }
}

/// The contradiction review list and its decision draft (testable without a view).
@MainActor @Observable
final class CaseContradictionReviewModel {
    let caseID: UUID
    let workspace: CaseWorkspaceHolder
    private(set) var items: [CaseContradictionReviewItem] = []
    /// Document names (knowledge object → file name).
    var names: [UUID: String] = [:]
    var loaded = false
    var busy = false
    var lastRun: String?
    /// Whether the last "Find contradictions" could not run (then it is not recorded as a check made).
    var lastCheckFailed = false
    /// SEARCH-13 — where "Compare the next documents" continues from (nil: nothing left, or not known).
    var continuation: Int?
    /// The rules' run of the last "Find contradictions", handed to the AI look that follows it (the service reuses it only
    /// while the case's documents are unchanged) and then cleared.
    private var lastRulesRun: CaseContradictionRun?
    /// SEARCH-13: the structured receipt of the last run, logged beside its line.
    private(set) var lastReceipt: CaseContradictionReceipt?
    var error: String?
    var notice: String?
    /// The decision draft for the selected item.
    var draftReason: CaseReviewReason?
    var draftNote = ""
    /// Owner request 2026-11-16 — each conflict's detail (open kind, who found it, every side, the AI's explanation).
    var details: [UUID: CaseConflictDetail] = [:]
    /// The kind shown (nil: every kind), by its stored value.
    var kindFilter: String?
    /// What "Look for conflicts with AI…" would do now (read before it runs; nil until read).
    var aiPreview: AIConflictScanPreview?
    /// Why reading that preview failed (nil: it was read, or not yet tried). A failure is never shown as "AI is off".
    var aiPreviewFailure: String?
    /// What the last AI look did, and what it checked.
    var aiRunText: String?
    var aiCoverage: String?

    init(caseID: UUID, workspace: CaseWorkspaceHolder) { self.caseID = caseID; self.workspace = workspace }

    var selectedID: UUID? {
        get { workspace.state.selectedContradictionID }
        set {
            guard newValue != workspace.state.selectedContradictionID else { return }
            workspace.state.selectedContradictionID = newValue
            draftReason = nil; draftNote = ""
        }
    }
    var filter: CaseReviewFilter {
        get { workspace.state.contradictionFilter }
        set { workspace.state.contradictionFilter = newValue }
    }
    var search: String {
        get { workspace.state.contradictionSearch }
        set { workspace.state.contradictionSearch = newValue }
    }

    /// The listed items: the filter, then the search words (summary, both quotes, document names).
    var visible: [CaseContradictionReviewItem] {
        let words = search.lowercased().split(separator: " ").map(String.init)
        return items.filter { item in
            if let k = kindFilter, kind(of: item).storageValue != k { return false }
            switch filter {
            case .awaiting: if !item.status.awaitingReview { return false }
            case .decided: if item.status.awaitingReview { return false }
            case .all: break
            }
            guard !words.isEmpty else { return true }
            let c = item.contradiction
            let hay = ([JobResultHandoff.reviewText(c), c.claimA, c.claimB]
                       + [c.evidenceA, c.evidenceB].compactMap { $0.flatMap { names[$0] } }).joined(separator: " ").lowercased()
            return words.allSatisfy { hay.contains($0) }
        }
    }
    var selected: CaseContradictionReviewItem? { items.first { $0.id == selectedID } }

    /// The item's kind: its detail's open kind, else what the check or the scan recorded.
    func kind(of item: CaseContradictionReviewItem) -> ConflictKind {
        details[item.id]?.kind ?? ConflictKind.of(item.contradiction)
    }
    /// The kinds the case's items have, for the filter.
    var kindsPresent: [ConflictKind] {
        var seen = Set<String>(), out: [ConflictKind] = []
        for item in items {
            let k = kind(of: item)
            if seen.insert(k.storageValue).inserted { out.append(k) }
        }
        return out.sorted { $0.displayName < $1.displayName }
    }
    /// Who found the item, as the label shown (AI-49: "Found by AI · quote checked", or "Hint (rule-made, not checked)").
    func foundByLabel(_ item: CaseContradictionReviewItem) -> String {
        InvestigationContradictionGapService.foundBy(item.contradiction, detail: details[item.id])?.label ?? AIFindingLabels.hint
    }
    /// An AI finding not yet confirmed is a proposal, never a finding of fact.
    func isAIProposal(_ item: CaseContradictionReviewItem) -> Bool {
        InvestigationContradictionGapService.foundBy(item.contradiction, detail: details[item.id]) == .ai && item.status.current != .confirmed
    }
    var awaitingCount: Int { items.filter { $0.status.awaitingReview }.count }
    var reopenedCount: Int { items.filter { $0.status.isReopened }.count }

    /// Move the selection through the listed items (keyboard review).
    func move(_ step: Int) {
        let list = visible
        guard !list.isEmpty else { return }
        guard let i = list.firstIndex(where: { $0.id == selectedID }) else { selectedID = list.first?.id; return }
        selectedID = list[max(0, min(list.count - 1, i + step))].id
    }

    /// One review key (⌥⌘↓ ⌥⌘↑ ⌥⌘Y ⌥⌘N ⌥⌘L), from the Case Review menu. The menu carries the keys so
    /// they work while the note field is being typed in (UI walk 2026-11-06: a button's key inside the
    /// page did not fire with the note field focused). A decision goes through `decide`, so a missing
    /// reason is said, never skipped; the note typed so far is kept with it.
    func perform(_ key: CaseReviewKey, desk: InvestigationContradictionGapService, objects: KnowledgeObjectRepository?,
                 actor: String, at date: Date = Date()) async {
        switch key {
        case .next: move(1)
        case .previous: move(-1)
        case .confirm, .dismiss, .deferIt:
            guard let decision = key.decision, !busy else { return }
            await decide(decision, desk: desk, objects: objects, actor: actor, at: date)
        }
    }

    /// Why the decision cannot be recorded yet (nil: it can).
    func problem(for decision: CaseReviewDecision) -> String? {
        if selected == nil { return "Choose a contradiction in the list first." }
        if decision == .dismissed, draftReason == nil { return "Choose why you are dismissing it." }
        if draftReason == .other, draftNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Say why in the note." }
        return nil
    }

    func load(desk: InvestigationContradictionGapService, objects: KnowledgeObjectRepository?) async {
        do {
            items = try await desk.contradictionReviewItems(caseID: caseID)
            do { details = try await desk.conflictDetails(caseID: caseID) } catch {
                KalsmritikoshLog.ui.error("Case conflict details load failed: \(String(describing: error), privacy: .public)")
                details = [:]
            }
            var ids = Set(items.flatMap { [$0.contradiction.evidenceA, $0.contradiction.evidenceB].compactMap { $0 } })
            for d in details.values { ids.formUnion(d.sides.map(\.objectID)) }
            if !ids.isEmpty, let objects { names = try await objects.sourceFilenames(for: ids) }
            loaded = true
            // Keep the remembered selection if it still exists; otherwise the first listed item.
            if selected == nil { workspace.state.selectedContradictionID = visible.first?.id }
        } catch {
            KalsmritikoshLog.ui.error("Case contradictions load failed: \(String(describing: error), privacy: .public)")
            self.error = "The contradictions could not be read: \(error.localizedDescription)"
        }
    }

    /// Record the decision on the selected item, then reload. Returns the record (nil: refused).
    @discardableResult
    func decide(_ decision: CaseReviewDecision, desk: InvestigationContradictionGapService, objects: KnowledgeObjectRepository?,
                actor: String, at date: Date = Date()) async -> CaseReviewDecisionRecord? {
        if let why = problem(for: decision) { error = why; return nil }
        guard let item = selected else { return nil }
        busy = true; defer { busy = false }
        do {
            let record = try await desk.reviewContradiction(caseID: caseID, contradictionID: item.id, decision: decision, reason: draftReason,
                                                            note: draftNote, actor: actor, at: date)
            error = nil
            notice = "\(decision.label): \(JobResultHandoff.reviewText(item.contradiction))"
            draftReason = nil; draftNote = ""
            let next = visible.first { $0.id != item.id && $0.status.awaitingReview }?.id
            await load(desk: desk, objects: objects)
            // Keyboard review: move on to the next item waiting for a decision.
            if filter == .awaiting, let next { workspace.state.selectedContradictionID = next }
            return record
        } catch {
            KalsmritikoshLog.ui.error("Contradiction decision failed: \(String(describing: error), privacy: .public)")
            self.error = "Not recorded: \(error.localizedDescription)"
            return nil
        }
    }

    enum Destination { case chronology, report }

    /// Carry the selected confirmed item into the chronology or the report (both passages, the decision).
    func carry(_ to: Destination, caseFiles: CaseFileService, actor: String) async {
        guard let item = selected else { return }
        do {
            switch to {
            case .chronology: try await JobResultHandoff.addReviewedToChronology(item, caseFiles: caseFiles, actor: actor)
            case .report: try await JobResultHandoff.addReviewedToReport(item, caseFiles: caseFiles, actor: actor)
            }
            error = nil
            notice = to == .chronology ? "Added to the chronology with every side\u{2019}s passage." : "Selected for the report with every side\u{2019}s passage."
        } catch {
            KalsmritikoshLog.ui.error("Contradiction carry failed: \(String(describing: error), privacy: .public)")
            self.error = error.localizedDescription
        }
    }

    func setLastRun(_ text: String) { lastRun = text }

    /// "Find contradictions" (owner request 2026-11-16, one AI conflict path): the rules on this Mac, always; then, when
    /// AI is set up for this case, the same "Look for conflicts with AI…" sheet (what would be sent, the estimate) — nothing
    /// is sent until "Run the look". AI off: rules only, and the screen says so. Returns whether to show that sheet.
    @discardableResult
    func findContradictions(desk: InvestigationContradictionGapService, objects: KnowledgeObjectRepository?, startingAt: Int = 0) async -> Bool {
        busy = true
        defer { busy = false }
        do {
            let run = try await desk.findContradictions(caseID: caseID, startingAt: startingAt)
            lastRun = Self.rulesRunText(run)
            lastRulesRun = run
            lastReceipt = CaseContradictionReceipt(run, at: Date())
            continuation = run.continuation
            lastCheckFailed = false
            error = nil
        } catch {
            KalsmritikoshLog.ui.error("Find contradictions failed: \(String(describing: error), privacy: .public)")
            lastRun = "The check could not run: \(error.localizedDescription)"
            lastRulesRun = nil
            lastReceipt = nil
            lastCheckFailed = true
            await load(desk: desk, objects: objects)
            return false
        }
        await load(desk: desk, objects: objects)
        await loadAIPreview(desk: desk)
        if let failure = aiPreviewFailure {
            let before: String = lastRun ?? ""
            lastRun = "\(before) The AI look could not be prepared — nothing was sent (\(failure))"
            return false
        }
        guard let preview = aiPreview, preview.aiAvailable else {
            let off = aiPreview?.offReason ?? "AI is off or not set up."
            let before: String = lastRun ?? ""
            lastRun = "\(before) AI is off — nothing was sent (\(off)). The rules compare only labelled values; a conflict written in sentences needs AI."
            return false
        }
        lastRun = (lastRun ?? "") + " To look for conflicts of any kind with AI, check what would be sent and the estimate, then choose “Run the look”."
        return true
    }

    /// What the rules did, in plain words.
    nonisolated static func rulesRunText(_ run: CaseContradictionRun) -> String {
        // AI-43 (owner 2026-11-23): the rules finder is switched off — the AI's look finds conflicts.
        if run.rulesSwitchedOff {
            return "The rules no longer decide what is a conflict: use \u{201C}Look for conflicts with AI\u{2026}\u{201D} — the AI finds conflicts and every quote is checked against its document."
        }
        // Case plan 2026-11-16 (SEARCH-13): a run that compared fewer documents than the case holds says so.
        var text: String
        if run.startingAt > 0, let total = run.documentsInCase {
            // SEARCH-14: earlier documents are compared with the page only where they share a subject with it.
            let carriedText = run.carried == 0 ? "no earlier document shares a name, record identifier or reference with this page, so no pair across pages was compared"
                : "\(run.carried) earlier document(s) sharing a name, record identifier or reference with this page were compared with it (\(run.crossPageFindings) found that way); other pairs across pages are not compared"
            text = "Compared documents \(run.startingAt + 1)–\(run.startingAt + run.documents) of this case's \(total) on this Mac (\(carriedText)): \(run.ruleFindings.count) found by the rules"
        } else if let total = run.documentsInCase, total > run.documents {
            text = "Compared \(run.documents) of this case's \(total) documents on this Mac (the other \(total - run.documents) were not compared in this run): \(run.ruleFindings.count) found by the rules"
        } else {
            text = "Compared \(run.documents) document(s) on this Mac: \(run.ruleFindings.count) found by the rules"
        }
        if let q = run.orderedBy { text += " — read in the order of the case question “\(q.prefix(80))” (documents matching its words first)" }
        if let compared = run.moneyMovementsCompared {
            text += " (\(run.moneyFindings) of them against the \(compared) money movement(s) in the case's money records)"
        } else {
            text += " (the case's money records could not be read, so they were not compared)"
        }
        return text + ". Decisions already made are kept unless a document changed."
    }

    /// Read what "Look for conflicts with AI…" would do now (nothing is sent).
    func loadAIPreview(desk: InvestigationContradictionGapService) async {
        do {
            aiPreview = try await desk.aiConflictPreview(caseID: caseID)
            aiPreviewFailure = nil
        } catch {
            KalsmritikoshLog.ui.error("AI conflict preview failed: \(String(describing: error), privacy: .public)")
            aiPreview = nil
            aiPreviewFailure = error.localizedDescription
        }
    }

    /// Run the look the person saw the estimate for, then reload.
    func runAILook(desk: InvestigationContradictionGapService, objects: KnowledgeObjectRepository?) async {
        guard let preview = aiPreview else { return }
        busy = true; defer { busy = false }
        let rulesRun = lastRulesRun
        lastRulesRun = nil
        do {
            let run = try await desk.lookForConflictsWithAI(caseID: caseID, preview: preview, rulesRun: rulesRun)
            aiRunText = run.message
            aiCoverage = run.coverage.isEmpty ? nil : run.coverage
            error = nil
        } catch {
            KalsmritikoshLog.ui.error("AI conflict look failed: \(String(describing: error), privacy: .public)")
            aiRunText = "The look could not run: \(error.localizedDescription)"
        }
        await load(desk: desk, objects: objects)
        await loadAIPreview(desk: desk)
    }
}

struct CaseContradictionsSection: View {
    @Environment(AppState.self) private var appState
    @Environment(CaseFileModel.self) private var caseModel
    let caseID: UUID
    let closed: Bool
    @State private var running = false
    @State private var openSource: CitationOpenTarget?
    @State private var openedPassage: OpenedSource?
    @State private var showingAILook = false

    private var model: CaseContradictionReviewModel { caseModel.review }

    var body: some View {
        @Bindable var model = model
        CaseSection(title: "Contradictions",
                    subtitle: "Statements in this case's documents that may not both be true — check each pair. Both sides are shown with their sources; nothing is averaged or decided for you.") {
            HStack {
                Button {
                    Task { await find() }
                } label: {
                    Label("Find contradictions", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                }
                .disabled(running || closed || appState.investigationContradictionGap == nil)
                .accessibilityIdentifier("case.contradictions.find")
                if let next = model.continuation {
                    Button("Compare the next documents") { Task { await find(startingAt: next) } }
                        .disabled(running || closed)
                        .caseMapControlHelp("Compare the next documents")
                        .accessibilityIdentifier("case.contradictions.next")
                }
                aiLookButton
                if running || model.busy { ProgressView().controlSize(.small) }
                Spacer()
                kindPicker
                Picker("Show", selection: $model.filter) {
                    ForEach(CaseReviewFilter.allCases) { Text($0.label).tag($0) }
                }
                .frame(maxWidth: 260)
                .accessibilityIdentifier("case.contradictions.filter")
                TextField("Search contradictions", text: $model.search)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 200)
                    .accessibilityIdentifier("case.contradictions.search")
            }
            Text("Compares this case's documents with each other — never with documents outside the case. Choose an item, then Confirm, Dismiss (with a reason) or Defer; the decision is kept until one of its documents changes. Keys: ⌥⌘↓ and ⌥⌘↑ move through the list; ⌥⌘Y confirms, ⌥⌘N dismisses, ⌥⌘L defers.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            // Ease fixes A — what the rules look for, and what they do not, stated plainly.
            Text(rulesCoverageText)
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("case.contradictions.coverage")
            aiStatusLines
            if let lastRun = model.lastRun { Text(lastRun).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            if let e = model.error { Text(e).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            else if let n = model.notice { Text(n).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            if model.items.isEmpty {
                Text(model.lastRun == nil ? "Not checked yet." : "No contradictions found by the checks run. That does not prove the documents agree.")
                    .font(.callout).foregroundStyle(.secondary)
            } else if model.visible.isEmpty {
                Text(model.filter == .awaiting ? "Nothing is waiting for a decision. Choose “All” to see the decided items." : "No contradiction matches.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                HStack(alignment: .top, spacing: 12) {
                    list
                        .frame(width: 300, alignment: .topLeading)
                    Divider()
                    if let item = model.selected {
                        detail(item).frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading).layoutPriority(1)
                    } else {
                        Text("Choose a contradiction in the list.").font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
        }
        // Keyboard review: the Case Review menu's keys act on this section while it is on screen, also
        // while the note field has focus (a menu key equivalent is not taken by the text field).
        .focusedSceneValue(\.caseReview, CaseReviewCommandTarget { key in Task { await perform(key) } })
        .task(id: caseID) { await reload() }
        .sheet(isPresented: $showingAILook) { aiLookSheet }
        .sheet(item: $openSource) { target in CitationSourceSheet(target: target) { openSource = nil } }
        .sheet(item: $openedPassage) { opened in CitedPassageSheet(opened: opened) { openedPassage = nil } }
    }

    // MARK: AI look (owner request 2026-11-16)

    private var aiLookDisabledReason: String? {
        if closed { return "The case is closed." }
        if running || model.busy { return "A check is running." }
        if let failure = model.aiPreviewFailure { return "Could not read whether AI is set up: " + failure }
        guard let p = model.aiPreview else { return "Reading whether AI is set up…" }
        return p.aiAvailable ? nil : (p.offReason ?? "AI is off.")
    }

    /// What the rules compare; with AI off it says so first ("AI is off; rules checked: …").
    private var rulesCoverageText: String {
        guard let p = model.aiPreview, p.aiOff else { return CaseContradictionFinder.ruleCoverage }
        return p.coverageLine
    }

    private var aiLookButton: some View {
        Button {
            Task {
                guard let desk = appState.investigationContradictionGap else { return }
                await model.loadAIPreview(desk: desk)
                showingAILook = model.aiPreview?.aiAvailable == true
            }
        } label: {
            Label("Look for conflicts with AI…", systemImage: "sparkle.magnifyingglass")
        }
        .disabled(reason: aiLookDisabledReason, remedy: "Set up AI in Settings ▸ Online (a plan or your own key), then allow it for this case. The rules work without it.")
        .accessibilityIdentifier("case.contradictions.ai")
        .caseMapControlHelp("Look for conflicts with AI…")
    }

    @ViewBuilder private var aiLookSheet: some View {
        if let preview = model.aiPreview {
            AIConflictLookSheet(preview: preview, onRun: {
                showingAILook = false
                Task { await runAILook() }
            }, onCancel: { showingAILook = false })
        }
    }

    private var kindPicker: some View {
        @Bindable var model = model
        return Picker("Kind", selection: $model.kindFilter) {
            Text("All kinds").tag(String?.none)
            ForEach(model.kindsPresent) { k in Text(k.displayName).tag(Optional(k.storageValue)) }
        }
        .frame(maxWidth: 240)
        .accessibilityIdentifier("case.contradictions.kind")
        .caseMapControlHelp("Kind")
    }

    @ViewBuilder private var aiStatusLines: some View {
        if let p = model.aiPreview, !p.aiAvailable, let why = p.offReason {
            Text(why).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("case.contradictions.ai.off")
        }
        if let text = model.aiRunText {
            Text(text).font(.caption).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("case.contradictions.ai.result")
        }
        if let coverage = model.aiCoverage {
            Text(coverage).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func runAILook() async {
        guard let desk = appState.investigationContradictionGap else { return }
        await model.runAILook(desk: desk, objects: appState.objects)
        do {
            try await appState.caseFiles?.file.logAction(caseID: caseID, action: "conflicts looked for with AI", detail: model.aiRunText, actor: InvestigatorProfile.name)
        } catch {
            KalsmritikoshLog.ui.error("AI conflict look log failed: \(error.localizedDescription, privacy: .public)")
        }
        await caseModel.refreshGlance(appState)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(model.visible.count) listed · \(model.awaitingCount) waiting for a decision" + (model.reopenedCount > 0 ? " · \(model.reopenedCount) reopened" : ""))
                .font(.caption2).foregroundStyle(.secondary)
            ForEach(model.visible) { item in
                let isSelected = item.id == model.selectedID
                Button { model.selectedID = item.id } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(model.kind(of: item).displayName)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.tint.opacity(0.15), in: .capsule)
                            statusBadge(item.status)
                            Spacer(minLength: 0)
                        }
                        Text(Self.summary(item.contradiction)).font(.callout).lineLimit(3).multilineTextAlignment(.leading)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(isSelected ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(isSelected ? Color.accentColor : .clear, lineWidth: 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(Self.summary(item.contradiction)). \(item.status.label(names: model.names))")
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                .accessibilityIdentifier("case.contradictions.row")
            }
        }
    }

    private func statusBadge(_ status: CaseItemReviewStatus) -> some View {
        let (text, color): (String, Color) = status.isReopened ? ("Reopened", .orange)
            : status.current.map { ($0.label, $0 == .confirmed ? Color.green : $0 == .dismissed ? Color.secondary : Color.orange) } ?? ("Not reviewed", .blue)
        return Text(text).font(.caption2.weight(.medium)).foregroundStyle(color)
    }

    @ViewBuilder private func detail(_ item: CaseContradictionReviewItem) -> some View {
        @Bindable var model = model
        let c = item.contradiction
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(model.kind(of: item).displayName)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.tint.opacity(0.15), in: .capsule)
                Text(model.foundByLabel(item)).font(.caption2).foregroundStyle(.secondary)
                    .accessibilityIdentifier("case.contradictions.foundBy")
                Spacer()
            }
            if model.isAIProposal(item) {
                Label("Proposal from AI — not a finding until you confirm it.", systemImage: "sparkles")
                    .font(.caption).foregroundStyle(.orange)
                    .accessibilityIdentifier("case.contradictions.proposal")
            }
            Text(Self.summary(c)).font(.callout.weight(.medium)).textSelection(.enabled)
            HStack(alignment: .top, spacing: 10) {
                side("A", quote: c.claimA, object: c.evidenceA, item: item, which: .a)
                side("B", quote: c.claimB, object: c.evidenceB, item: item, which: .b)
            }
            if let d = model.details[item.id] {
                ConflictDetailExtras(detail: d, extraSides: item.extraSides, names: model.names) { object, quote, version in
                    open(object, quote: quote, position: CaseSourcePosition(objectID: object, origin: .contradiction(id: item.id, side: .b), revision: version))
                }
            }
            Label(item.status.label(names: model.names), systemImage: item.status.isReopened ? "arrow.triangle.2.circlepath" : "checkmark.seal")
                .font(.caption).foregroundStyle(item.status.isReopened ? .orange : .secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("case.contradictions.status")
            Divider()
            Picker("Reason", selection: $model.draftReason) {
                Text("No reason chosen").tag(CaseReviewReason?.none)
                ForEach(CaseReviewReason.allCases) { Text($0.label).tag(Optional($0)) }
            }
            .frame(maxWidth: 380)
            .accessibilityHint("Needed to dismiss: why the two statements do not conflict, or why you cannot decide yet.")
            // UI walk 2026-11-06: typing a long note widened the page past the window. The field has a
            // fixed largest width and grows downwards (wraps) instead.
            TextField("Note (optional; needed for “Other”)", text: $model.draftNote, axis: .vertical)
                .lineLimit(1...4)
                .frame(maxWidth: 480, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("case.contradictions.note")
            HStack(spacing: 8) {
                decisionButton(.confirmed, "Confirm", hint: "Records that these two statements conflict in this case. Key: ⌥⌘Y.")
                decisionButton(.dismissed, "Dismiss", hint: "Sets it aside for this case with the reason chosen. Neither document is changed. Key: ⌥⌘N.")
                decisionButton(.deferred, "Defer", hint: "Keeps it waiting for a decision, with your note. Key: ⌥⌘L.")
                needMoreEvidenceButton
                Spacer()
            }
            Text("Dismissing needs a reason. A dismissal changes neither document; it is kept until one of them changes, then the item reopens.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if item.status.current == .confirmed, let caseFiles = appState.caseFiles {
                HStack(spacing: 8) {
                    Button("Add to chronology") { Task { await model.carry(.chronology, caseFiles: caseFiles, actor: caseModel.actor); await caseModel.load(appState) } }
                        .accessibilityHint("Adds this contradiction with both passages to the case chronology; nothing to retype.")
                    Button("Include in report") { Task { await model.carry(.report, caseFiles: caseFiles, actor: caseModel.actor); await caseModel.load(appState) } }
                        .accessibilityHint("Selects this contradiction, with both passages, for the case report.")
                    Spacer()
                }
                .disabled(closed)
            }
            if !item.status.history.isEmpty {
                DisclosureGroup("Decision history (\(item.status.history.count))") {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(item.status.history.reversed()) { d in
                            Text(d.summary).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption)
                .accessibilityIdentifier("case.contradictions.history")
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    private func decisionButton(_ decision: CaseReviewDecision, _ title: String, hint: String) -> some View {
        Button(title) {
            guard let desk = appState.investigationContradictionGap else { return }
            Task {
                await model.decide(decision, desk: desk, objects: appState.objects, actor: caseModel.actor)
                await caseModel.refreshGlance(appState)
            }
        }
        .disabled(reason: closed ? "The case is closed." : model.busy ? "A decision is being recorded." : model.problem(for: decision),
                  remedy: closed ? "Reopen the case to record decisions." : nil)
        .accessibilityHint(hint)
        .accessibilityIdentifier("case.contradictions.\(decision.rawValue)")
    }

    /// Examined, and it cannot be settled on what is in the case yet: recorded as unresolved, with the note.
    private var needMoreEvidenceButton: some View {
        Button("Need more evidence") {
            guard let desk = appState.investigationContradictionGap else { return }
            if model.draftNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { model.draftNote = "Needs more evidence." }
            Task {
                await model.decide(.unresolved, desk: desk, objects: appState.objects, actor: caseModel.actor)
                await caseModel.refreshGlance(appState)
            }
        }
        .disabled(reason: closed ? "The case is closed." : model.busy ? "A decision is being recorded." : (model.selected == nil ? "Choose a contradiction in the list first." : nil),
                  remedy: closed ? "Reopen the case to record decisions." : nil)
        .accessibilityIdentifier("case.contradictions.unresolved")
        .caseMapControlHelp("Need more evidence")
    }

    private func side(_ title: String, quote: String, object: UUID?, item: CaseContradictionReviewItem,
                      which: CaseSourcePosition.Side) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption2.weight(.bold)).foregroundStyle(.secondary)
            Text("\u{201C}\(quote)\u{201D}").font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if let object {
                Button {
                    open(object, quote: quote, position: CaseSourcePosition(objectID: object, origin: .contradiction(id: item.id, side: which),
                                                                           revision: item.currentVersions[object] ?? nil))
                } label: {
                    Label(model.names[object].map { "Open source — \($0)" } ?? "Open source", systemImage: "doc.text.magnifyingglass").font(.caption)
                }
                .buttonStyle(.link)
                .accessibilityIdentifier("case.contradictions.open")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The description without the check's provenance marker (shown separately).
    nonisolated static func summary(_ c: Contradiction) -> String { JobResultHandoff.reviewText(c) }

    nonisolated static func provenanceText(_ c: Contradiction) -> String {
        switch CaseContradictionFinder.provenance(of: c) {
        case .rules?: return AIFindingLabels.hint
        case .aiRead?: return AIFindingLabels.ai
        case nil: return AIFindingLabels.hint
        }
    }

    private func perform(_ key: CaseReviewKey) async {
        guard let desk = appState.investigationContradictionGap else { return }
        if key.decision != nil, closed { model.error = "The case is closed. Reopen the case to record decisions."; return }
        await model.perform(key, desk: desk, objects: appState.objects, actor: caseModel.actor)
        if key.decision != nil { await caseModel.refreshGlance(appState) }
    }

    private func reload() async {
        guard let desk = appState.investigationContradictionGap else { return }
        await model.load(desk: desk, objects: appState.objects)
        await model.loadAIPreview(desk: desk)
    }

    private func find(startingAt: Int = 0) async {
        guard let desk = appState.investigationContradictionGap else { return }
        running = true
        defer { running = false }
        let showAI = await model.findContradictions(desk: desk, objects: appState.objects, startingAt: startingAt)
        // A check that could not run is recorded as such, never as "contradictions checked" (which tells the overview the
        // case's documents were compared).
        let action = model.lastCheckFailed ? "contradiction check failed" : "contradictions checked"
        do {
            try await appState.caseFiles?.file.logAction(caseID: caseID, action: action, detail: model.lastRun, actor: InvestigatorProfile.name)
            // SEARCH-13: the run's structured receipt beside its line (what was compared, in which order, which versions).
            if let receipt = model.lastReceipt {
                try await appState.caseFiles?.file.logAction(caseID: caseID, action: CaseContradictionReceipt.action, detail: receipt.json, actor: InvestigatorProfile.name)
            }
        }
        catch { KalsmritikoshLog.ui.error("Contradiction check log failed: \(error.localizedDescription, privacy: .public)") }
        await caseModel.refreshGlance(appState)
        if showAI { showingAILook = true }
    }

    private func open(_ objectID: UUID, quote: String, position: CaseSourcePosition) {
        // LB3 — only identifiers are remembered; the passage is read again from the ledger on return.
        caseModel.workspace.state.lastSource = position
        // SRC-01/SRC-08 — the version the side was read from (position.revision), or its passage labelled.
        Task { @MainActor in
            switch await CitedSourceOpening.resolve(appState, objectID: objectID, sourceVersionID: position.revision, quote: quote) {
            case .viewer(let target): openSource = target
            case .passage(let opened): openedPassage = opened
            }
        }
    }
}

// MARK: - Keyboard review from the menu bar

/// The contradiction review keys — one table for the Case Review menu, its titles and the help text.
enum CaseReviewKey: String, CaseIterable, Identifiable {
    case next, previous, confirm, dismiss, deferIt
    var id: String { rawValue }
    var title: String {
        switch self {
        case .next: return "Next Contradiction"
        case .previous: return "Previous Contradiction"
        case .confirm: return "Confirm Contradiction"
        case .dismiss: return "Dismiss Contradiction"
        case .deferIt: return "Defer Contradiction"
        }
    }
    var key: KeyEquivalent {
        switch self {
        case .next: return .downArrow
        case .previous: return .upArrow
        case .confirm: return "y"
        case .dismiss: return "n"
        case .deferIt: return "l"
        }
    }
    /// Always ⌥⌘.
    static let modifiers: EventModifiers = [.command, .option]
    var decision: CaseReviewDecision? {
        switch self {
        case .next, .previous: return nil
        case .confirm: return .confirmed
        case .dismiss: return .dismissed
        case .deferIt: return .deferred
        }
    }
}

/// What the open case's contradiction section offers the menu (nil when no such section is on screen).
struct CaseReviewCommandTarget {
    let perform: @MainActor (CaseReviewKey) -> Void
}

struct CaseReviewFocusKey: FocusedValueKey {
    typealias Value = CaseReviewCommandTarget
}

extension FocusedValues {
    var caseReview: CaseReviewCommandTarget? {
        get { self[CaseReviewFocusKey.self] }
        set { self[CaseReviewFocusKey.self] = newValue }
    }
}

/// The Case Review menu: the review keys as menu key equivalents, so they work whichever control in the
/// window has focus — the note field included. Disabled when no case contradiction list is on screen.
struct CaseReviewCommands: Commands {
    @FocusedValue(\.caseReview) private var review

    var body: some Commands {
        CommandMenu("Case Review") {
            ForEach(CaseReviewKey.allCases) { key in
                Button(key.title) { review?.perform(key) }
                    .keyboardShortcut(key.key, modifiers: CaseReviewKey.modifiers)
                    .disabled(review == nil)
            }
        }
    }
}
