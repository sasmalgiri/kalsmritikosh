//
//  CaseSearchPanel.swift
//  Kalsmritikosh
//
//  Living case map M5 — "Search case evidence": a search of this case's documents only. Rule groups (all /
//  at least one / none) or the search text; the explanation of what will run; results with their witnesses,
//  counts and pages; what was searched (the receipt); save as a live search or a frozen result. From a hit:
//  Open source, Add to chronology…, Select for report — the existing case commands. Reads this Mac's ledger;
//  nothing is sent anywhere, and no AI is involved.
//

import SwiftUI
import os

struct CaseSearchPanel: View {
    @Environment(AppState.self) private var appState
    let caseID: UUID
    let actor: String
    var closed = false
    /// Navigation merge — shown inside the Search area (no Close button, no sheet size, no Return shortcut
    /// that would answer for the whole window) instead of as a sheet from the case file.
    var embedded = false
    /// A query handed over from the header search box: put in the text field and run once.
    @Binding var seed: String?
    let onDone: () -> Void
    /// S3 (MAP-01 / MAP-08) — show a hit's document on the case map (revealed and selected wherever it is folded).
    var showOnMap: ((UUID) -> Void)? = nil

    @State private var model: CaseSearchModel
    @State private var showRules = true
    @State private var showReceipt = false
    @State private var saving = false
    @State private var saveName = ""
    @State private var saveKind: CaseSavedSearch.Kind = .live
    @State private var openSource: CitationOpenTarget?
    @State private var openedPassage: OpenedSource?
    @State private var chronologyPassage: ChronologyPassage?

    init(caseID: UUID, actor: String, closed: Bool = false, embedded: Bool = false, seed: Binding<String?> = .constant(nil),
         showOnMap: ((UUID) -> Void)? = nil, onDone: @escaping () -> Void) {
        self.caseID = caseID; self.actor = actor; self.closed = closed; self.embedded = embedded; self.onDone = onDone; self.showOnMap = showOnMap
        _seed = seed
        _model = State(initialValue: CaseSearchModel(caseID: caseID))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Search case evidence", systemImage: "doc.text.magnifyingglass").font(.headline)
                InfoPopoverButton(topic: "task-case-search")
                Spacer()
                if model.running {
                    ProgressView().controlSize(.small)
                    if let p = model.progress { Text(p.line).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                    Button("Cancel") { model.cancel() }
                }
                if !embedded { Button("Close") { onDone() }.keyboardShortcut(.cancelAction) }
            }
            .padding(14)
            Text("Searches only this case's documents and its own records (questions, notes, report points, tasks, people, money), word for word, on this Mac. It finds the words you ask for; it does not decide what they mean.")
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 14)
            Divider().padding(.top, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    builder
                    expert
                    results
                    savedList
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: embedded ? nil : 820, idealWidth: embedded ? nil : 960, minHeight: embedded ? nil : 600, idealHeight: embedded ? nil : 760)
        .task {
            if model.service == nil, let db = appState.database {
                model.service = CaseSearchService(sources: CaseSearchSources.live(database: db, map: CaseMapServiceFactory.map(appState)))
            }
            await model.loadSaved()
            await model.checkPolicies()
            takeSeed()
        }
        .onChange(of: seed) { _, _ in takeSeed() }
        .sheet(isPresented: $saving) { saveSheet }
        .sheet(item: $openSource) { target in CitationSourceSheet(target: target) { openSource = nil } }
        .sheet(item: $openedPassage) { opened in
            VStack(spacing: 0) {
                EvidenceViewer(citation: opened.citation)
                HStack { Spacer(); Button("Close") { openedPassage = nil }.keyboardShortcut(.cancelAction) }.padding(10)
            }
        }
        .sheet(item: $chronologyPassage) { p in AddPassageToChronologySheet(passage: p) { chronologyPassage = nil } }
        .sheet(item: $model.viewingReceipt) { s in frozenSheet(s) }
    }

    /// Run a handed-over query once: it goes in the text field, and runs when it reads as a valid search
    /// (otherwise its explanation says what to fix, and nothing runs).
    private func takeSeed() {
        guard let q = seed, model.service != nil else { return }
        seed = nil
        model.text = q
        if model.parse.isValid { model.search() }
    }

    // MARK: Rules

    private var builder: some View {
        DisclosureGroup(isExpanded: $showRules) {
            VStack(alignment: .leading, spacing: 8) {
                CaseSearchGroupEditor(group: $model.rules, depth: 0, onRemove: nil)
                HStack {
                    Button("Use these rules") { model.useRules() }
                        .help("Writes the rules into the search text below and shows what they mean. Nothing runs yet.")
                    Button("Show the text as rules") { model.showAsRules() }
                        .help("Shows the search text below as rule groups.")
                    if let e = model.builderError { Text(e).font(.caption).foregroundStyle(.red) }
                }
                .controlSize(.small)
            }
            .padding(.top, 6)
        } label: {
            Text("Rules").font(.subheadline.weight(.semibold))
        }
    }

    // MARK: Expert text, options, explanation

    private var expert: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Search text, for example: (invoice OR receipt) AND \"paid twice\" -draft", text: $model.text)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { if model.parse.isValid { model.search() } }
                    .accessibilityLabel("Search text")
                Button("Search") { model.search() }
                    .keyboardShortcut(embedded ? nil : .defaultAction)
                    .disabled(reason: model.parse.isValid ? (model.running ? "A search is running." : nil) : "Fix the search first — it is not run as it stands.")
            }
            HStack(spacing: 14) {
                Toggle("Match case", isOn: $model.options.matchCase).toggleStyle(.checkbox)
                Toggle("Match accents", isOn: $model.options.matchAccents).toggleStyle(.checkbox)
                Text("Word endings, approximate and meaning-based matching: off (not available in case search).")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .controlSize(.small)
            let p = model.parse
            if model.text.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("Type a search or use the rules. Operators are written in capitals: AND, OR, NOT, NEAR/5. Fields: person:, type:, file:, tag:, exact:, amounts such as amount:INR>=50000 or currency:USD, and dates such as stated-on:2024-03, modified-before:2024-01-31, event-after:2023.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if let q = p.query {
                VStack(alignment: .leading, spacing: 2) {
                    Text("What will be searched").font(.caption.weight(.semibold))
                    ForEach(Array(q.explanation.enumerated()), id: \.offset) { _, line in Text(line).font(.caption).textSelection(.enabled) }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                .accessibilityElement(children: .combine)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Label("This search is not run as it stands:", systemImage: "exclamationmark.triangle").font(.caption.weight(.semibold)).foregroundStyle(.orange)
                    ForEach(p.errors, id: \.self) { Text("• " + $0).font(.caption).fixedSize(horizontal: false, vertical: true) }
                    if let r = p.repair {
                        Text("A repaired search is offered: \(r.text)").font(.caption.monospaced()).textSelection(.enabled)
                        Text("Changes: " + r.changes.joined(separator: "; ") + "." + (r.broadens ? " It searches more broadly than what you typed." : ""))
                            .font(.caption2).foregroundStyle(r.broadens ? .orange : .secondary).fixedSize(horizontal: false, vertical: true)
                        Button("Use the repaired query") { model.useRepair(r) }.controlSize(.small)
                            .help("Puts the repaired search in the text field. It runs only when you choose Search.")
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }
            if let e = model.error { Label(e, systemImage: "xmark.octagon").font(.caption).foregroundStyle(.red) }
            else if let n = model.notice { Label(n, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary) }
        }
    }

    // MARK: Results

    @ViewBuilder private var results: some View {
        switch model.outcome {
        case .rejected(let why, _)?:
            Label("Not run: " + why.joined(separator: " "), systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
        case .failed(let why)?:
            Label(why, systemImage: "xmark.octagon").font(.callout).foregroundStyle(.red)
        case .ran(let run)?:
            VStack(alignment: .leading, spacing: 8) {
                Divider()
                if let c = model.changes {
                    HStack {
                        Label(c.summary, systemImage: "sparkles").font(.callout)
                        Spacer()
                        Button("Mark as seen") { Task { await model.acknowledge() } }.controlSize(.small)
                            .help("New matches are counted from now on. It records nothing about the documents.")
                    }
                    // M9 — vital information is not only on hover.
                    Text("“Mark as seen” counts new matches from now on; it records nothing about the documents and reviews nothing.")
                        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                // S4 (SEARCH-04) — the active scope: the mother case, prior cases, date meaning and every constraint that ran.
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(run.activeScope.enumerated()), id: \.offset) { _, l in Text(l).font(.caption2).fixedSize(horizontal: false, vertical: true) }
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("case.search.scope")
                Text(run.countsLine).font(.callout.monospacedDigit()).accessibilityIdentifier("case.search.counts")
                if let z = run.zeroMatchStatement { Text(z).font(.callout).fixedSize(horizontal: false, vertical: true) }
                if let s = run.stoppedEarly {
                    HStack {
                        Label(s, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                        if let c = run.continuation {
                            Button("Continue (\(c.remaining) not searched yet)") { model.resume() }.controlSize(.small)
                                .help("Searches the documents this run did not reach. Refused if the case's documents changed since it stopped.")
                        }
                    }
                }
                ForEach(model.alerts) { a in
                    VStack(alignment: .leading, spacing: 2) {
                        Label("“\(a.saved.name)” ran again because the case's material changed: \(a.changes.summary)", systemImage: "bell").font(.caption)
                        ForEach(a.provenance, id: \.self) { Text("• " + $0).font(.caption2).foregroundStyle(.secondary) }
                    }
                }
                recordResults(run)
                receipt(run)
                if let page = model.page, !page.hits.isEmpty {
                    HStack {
                        Text(page.rangeLine).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Previous page") { model.pageIndex = max(0, model.pageIndex - 1) }
                            .disabled(reason: model.pageIndex == 0 ? "This is the first page." : nil)
                        Button("Next page") { model.pageIndex = min(run.pageCount - 1, model.pageIndex + 1) }
                            .disabled(reason: model.pageIndex >= run.pageCount - 1 ? "This is the last page." : nil)
                        Button("Save search…") { saveName = ""; saving = true }
                    }
                    .controlSize(.small)
                    ForEach(page.hits) { hit in hitRow(hit) }
                } else {
                    HStack { Spacer(); Button("Save search…") { saveName = ""; saving = true }.controlSize(.small) }
                }
            }
        case nil:
            EmptyView()
        }
    }

    private func receipt(_ run: CaseSearchRun) -> some View {
        DisclosureGroup(isExpanded: $showReceipt) {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(run.receipt.lines.dropFirst().enumerated()), id: \.offset) { _, l in
                    Text(l).font(.caption).fixedSize(horizontal: false, vertical: true)
                }
                Text("Matching: " + run.options.summary + ". Index \(run.indexRevision), run \(run.executedAt.formatted(date: .abbreviated, time: .standard)).")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.top, 4)
        } label: {
            Label("What was searched — " + run.receipt.headline, systemImage: run.receipt.complete ? "checkmark.seal" : "exclamationmark.circle")
                .font(.caption)
        }
        .accessibilityIdentifier("case.search.receipt")
    }

    private func hitRow(_ hit: CaseSearchHit) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(hit.name).font(.callout.weight(.semibold))
                Text("\(hit.occurrences) occurrence\(hit.occurrences == 1 ? "" : "s") · \(hit.passages) passage\(hit.passages == 1 ? "" : "s")")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                Button("Open source") { open(hit, hit.witnesses.first) }.buttonStyle(.link).font(.caption)
                if let showOnMap {
                    Button("Show on map") { showOnMap(hit.objectID) }.buttonStyle(.link).font(.caption)
                        .help("Shows this document on the case map and selects it, opening whatever group, branch or frame holds it.")
                }
            }
            // S4 (SEARCH-03 / SEARCH-05 / SEARCH-07) — what kind of match, where the document sits, and repeated copies.
            Text(hit.bases.map(\.label).joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary)
            if !hit.nesting.isEmpty { Text(hit.nesting.joined(separator: " › ")).font(.caption2).foregroundStyle(.secondary) }
            if !hit.copies.isEmpty { Text("The same text as \(hit.copies.count) other matching document\(hit.copies.count == 1 ? "" : "s") (a repeated copy, counted once in “distinct texts”).").font(.caption2).foregroundStyle(.secondary) }
            if let p = hit.partly { Label(p, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange) }
            if hit.textNotSearched { Label("Matched on its recorded fields; its text could not be searched.", systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange) }
            ForEach(hit.satisfied, id: \.self) { Label($0, systemImage: "checkmark").font(.caption) }
            ForEach(hit.absentAsRequired, id: \.self) { Label($0, systemImage: "minus.circle").font(.caption) }
            ForEach(hit.witnesses, id: \.self) { w in
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.highlighted(w)).font(.caption).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        Text(Self.locator(w) + " · " + hit.locator(w).line).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                        Button("Open source") { open(hit, w) }.buttonStyle(.link).font(.caption2)
                        Button("Add to chronology…") {
                            chronologyPassage = ChronologyPassage(objectID: hit.objectID, quote: w.matchedText, sourceVersionID: hit.versionIDs.first)
                        }
                        .buttonStyle(.link).font(.caption2)
                        .disabled(reason: closed ? "The case is closed." : nil)
                        Button("Select for report") { Task { await selectForReport(hit, w) } }
                            .buttonStyle(.link).font(.caption2)
                            .disabled(reason: closed ? "The case is closed." : nil)
                    }
                }
                .padding(6)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
            }
            if hit.occurrences > hit.witnesses.count {
                Text("\(hit.occurrences - hit.witnesses.count) more occurrence(s) in this document; open the source to see them.").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25)))
    }

    /// S4 (SEARCH-01) — the case's own records that matched, with what was searched and what was not.
    @ViewBuilder private func recordResults(_ run: CaseSearchRun) -> some View {
        if let r = run.records {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(r.hits) { h in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(h.classLabel).font(.caption2).foregroundStyle(.secondary)
                                Text(h.title).font(.caption.weight(.semibold))
                                Spacer()
                            }
                            ForEach(h.satisfied, id: \.self) { Label($0, systemImage: "checkmark").font(.caption2) }
                            ForEach(h.witnesses, id: \.self) { w in Text(Self.highlighted(w)).font(.caption2).textSelection(.enabled) }
                        }
                        .padding(4)
                    }
                    ForEach(Array(r.lines.enumerated()), id: \.offset) { _, l in Text(l).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                }
            } label: {
                Text("Case records: \(r.hits.count) matching of \(r.searched) searched").font(.caption)
            }
            .accessibilityIdentifier("case.search.records")
        } else if let why = run.recordsNotSearched {
            Label(why, systemImage: "info.circle").font(.caption2).foregroundStyle(.secondary)
        }
    }

    static func highlighted(_ w: CaseSearchWitness) -> AttributedString {
        var out = AttributedString()
        let ns = w.snippet as NSString
        var at = 0
        for h in w.highlights.sorted(by: { $0.lowerBound < $1.lowerBound }) where h.lowerBound >= at && h.upperBound <= ns.length {
            out += AttributedString(ns.substring(with: NSRange(location: at, length: h.lowerBound - at)))
            var m = AttributedString(ns.substring(with: NSRange(location: h.lowerBound, length: h.count)))
            m.inlinePresentationIntent = .stronglyEmphasized
            m.backgroundColor = .yellow.opacity(0.35)
            out += m
            at = h.upperBound
        }
        out += AttributedString(ns.substring(from: at))
        return out
    }

    static func locator(_ w: CaseSearchWitness) -> String {
        var parts: [String] = []
        if let p = w.page { parts.append("page \(p)") }
        if let o = w.passageOrdinal { parts.append("passage \(o + 1)") } else { parts.append("position unavailable") }
        if w.crossesPassageBoundary { parts.append("runs across two passages") }
        return parts.joined(separator: " · ")
    }

    // MARK: Hand-offs (the existing case commands)

    private func open(_ hit: CaseSearchHit, _ w: CaseSearchWitness?) {
        let quote = w?.matchedText
        // SRC-01/SRC-08 — the version the hit was read from, or the passage labelled with why it cannot open.
        Task { @MainActor in
            switch await CitedSourceOpening.resolve(appState, objectID: hit.objectID, sourceVersionID: hit.versionIDs.count == 1 ? hit.versionIDs.first : nil, quote: quote ?? w?.snippet) {
            case .viewer(let target): openSource = target
            case .passage(let opened): openedPassage = opened
            }
        }
    }

    private func selectForReport(_ hit: CaseSearchHit, _ w: CaseSearchWitness) async {
        guard let caseFiles = appState.caseFiles else { model.error = "The case file isn't ready yet."; return }
        do {
            let r = try await PassageReportSelection.add(caseID: caseID, objectID: hit.objectID, sourceVersionID: hit.versionIDs.first,
                                                         quote: w.matchedText, text: "\(hit.name): \u{201C}\(w.matchedText)\u{201D}",
                                                         caseFiles: caseFiles, actor: actor)
            model.notice = "Selected for the report, with its citation" + (r.support.isDocumentary ? " (verified in the document)." : " (not verified — check the passage).")
            model.error = nil
        } catch {
            KalsmritikoshLog.ui.error("Case search select for report failed: \(error.localizedDescription, privacy: .public)")
            model.error = error.localizedDescription
        }
    }

    // MARK: Saved searches

    @ViewBuilder private var savedList: some View {
        if !model.saved.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Divider()
                Text("Saved searches of this case").font(.subheadline.weight(.semibold))
                Text("A live search runs again on the case's documents as they are then; “Check for new matches” lists what is new and adds no document to the case. A frozen result stays as it was.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ForEach(model.saved) { s in
                    HStack {
                        Image(systemName: s.kind == .live ? "arrow.triangle.2.circlepath" : "lock.doc").accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(s.name).font(.callout)
                            Text((s.kind == .live ? "Live search" : "Frozen result") + " · \(s.result.documents) document(s) · run \(s.executedAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if s.kind == .live {
                            Toggle("Re-run when the case changes", isOn: Binding(get: { s.rerunPolicy == .onMaterialChange },
                                                                                set: { on in Task { await model.setPolicy(s, on ? .onMaterialChange : .manual) } }))
                                .toggleStyle(.checkbox)
                                .help("When the case's documents change, this search runs again when you open Search and tells you once about new matches. It never adds a document to the case and never marks anything as seen.")
                            Button("Check for new matches") { Task { await model.checkForNewMatches(s) } }
                                .help("Runs the search again over the case's documents as they are now and lists what is new since you last looked. It adds no document to the case.")
                            Button("Open in the text field") { model.open(s) }
                        } else {
                            Button("Show the frozen result") { model.viewingReceipt = s }
                        }
                        Button("Remove") { Task { await model.remove(s) } }
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    private var saveSheet: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Save this search").font(.headline)
            TextField("Name (e.g. Second payment approvals)", text: $saveName)
            Picker("Keep as", selection: $saveKind) {
                Text("Live search — runs again on the case's current documents").tag(CaseSavedSearch.Kind.live)
                Text("Frozen result — keeps this result as it is").tag(CaseSavedSearch.Kind.receipt)
            }
            .pickerStyle(.radioGroup)
            Text("Kept in this case's encrypted ledger with the search, its options, the documents searched and when it ran. It is removed with the case.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { saving = false }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    let name = saveName, kind = saveKind
                    Task { await model.save(name: name, kind: kind, actor: actor) }
                    saving = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(reason: saveName.trimmingCharacters(in: .whitespaces).isEmpty ? "Give the search a name." : nil)
            }
        }
        .padding(16)
        .frame(width: 480)
    }

    private func frozenSheet(_ s: CaseSavedSearch) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(s.name) — frozen result").font(.headline)
            Text("As run \(s.executedAt.formatted(date: .abbreviated, time: .standard)) over the case's documents then. The case may have changed since; this record does not.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(s.queryText).font(.caption.monospaced()).textSelection(.enabled)
            Text("\(s.result.documents) matching document(s) · \(s.result.occurrences) occurrence(s) · \(s.result.passages) passage(s)" + (s.result.complete ? "" : " · incomplete"))
                .font(.caption)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(s.result.matchedObjectIDs, id: \.self) { id in Text("• " + (s.result.names[id.uuidString] ?? id.uuidString)).font(.caption) }
                    Divider()
                    ForEach(Array(s.result.receiptLines.enumerated()), id: \.offset) { _, l in Text(l).font(.caption2).foregroundStyle(.secondary) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack { Spacer(); Button("Close") { model.viewingReceipt = nil }.keyboardShortcut(.cancelAction) }
        }
        .padding(16)
        .frame(width: 560, height: 460)
    }
}

/// One rule group, with its rules and nested groups.
struct CaseSearchGroupEditor: View {
    @Binding var group: CaseSearchRuleGroup
    let depth: Int
    let onRemove: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker("Match", selection: $group.mode) {
                    ForEach(CaseSearchRuleGroup.Mode.allCases) { Text($0.label).tag($0) }
                }
                .frame(width: 240)
                Spacer()
                Button("Add rule") { group.rules.append(CaseSearchRule()) }
                if depth < 3 { Button("Add group") { group.groups.append(CaseSearchRuleGroup()) } }
                if let onRemove { Button("Remove group", role: .destructive) { onRemove() } }
            }
            .controlSize(.small)
            ForEach($group.rules) { $rule in
                HStack {
                    Picker("Field", selection: $rule.field) {
                        ForEach(CaseSearchRule.Field.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().frame(width: 190)
                    if rule.field == .date {
                        Picker("Which date", selection: $rule.dateKind) {
                            ForEach(CaseSearchDateKind.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        .labelsHidden().frame(width: 190)
                        Picker("Compare", selection: $rule.dateRelation) {
                            ForEach(CaseSearchDateRelation.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        .labelsHidden().frame(width: 90)
                    }
                    TextField(rule.field == .date ? "2024-03-31, 2024-03 or 2024" : "Value", text: $rule.value)
                        .textFieldStyle(.roundedBorder)
                    if rule.field == .near {
                        Stepper("within \(rule.distance) words of", value: $rule.distance, in: 1...100).fixedSize()
                        TextField("Other words", text: $rule.other).textFieldStyle(.roundedBorder)
                    }
                    Button { group.rules.removeAll { $0.id == rule.id } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove rule")
                }
                .controlSize(.small)
            }
            ForEach($group.groups) { $sub in
                CaseSearchGroupEditor(group: $sub, depth: depth + 1, onRemove: { group.groups.removeAll { $0.id == sub.id } })
                    .padding(.leading, 16)
            }
        }
        .padding(8)
        .background(Color.primary.opacity(depth % 2 == 0 ? 0.03 : 0.06), in: RoundedRectangle(cornerRadius: 6))
    }
}
