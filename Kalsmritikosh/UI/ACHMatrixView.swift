//
//  ACHMatrixView.swift
//  Kalsmritikosh
//
//  Analysis of Competing Hypotheses — the matrix studio for the `analysis` job.
//  Hypotheses are columns, evidence are rows; rate each cell CC/C/N/I/II. The
//  panel ranks hypotheses by fewest inconsistencies (ACH), flags which evidence
//  is diagnostic, and captures assumptions, indicators, and a written conclusion
//  with a confidence — never a computed verdict.
//
//  A-6 — the matrix lives in the ledger (schema v152, ACHRepository): hypotheses, evidence rows and
//  cells, scoped by an optional case, with who/when. An older on-device (AppStorage) store is imported
//  once on first load and then no longer read; the old key is left untouched. Removing an analysis,
//  hypothesis or evidence row retracts it — it stays in the record.
//

import SwiftUI
import UniformTypeIdentifiers
import os
#if os(macOS)
import AppKit
#endif

public struct ACHMatrixView: View {
    @Environment(AppState.self) private var appState

    /// The old on-device store — read ONCE for the import into the ledger, never written.
    @AppStorage(ACHRepository.legacyAppStorageKey) private var legacyStoreBlob = ""
    @State private var analyses: [ACHAnalysis] = []
    @State private var scopes: [UUID: UUID] = [:]          // analysis id → case id (when scoped to a case)
    @State private var loaded = false
    @State private var activeID: UUID?
    @State private var ledgerMissing = false
    @State private var notice: String?
    @State private var pendingSave: Task<Void, Never>?
    @State private var pendingSaveFor: UUID?

    @State private var newHypothesis = ""
    @State private var newEvidence = ""
    @State private var newAssumption = ""
    @State private var newIndicator = ""
    /// The sources in the active analysis's case scope (exact versions with labels), for citations.
    @State private var citationChoices: [(id: UUID, label: String)] = []
    @State private var citationChoicesFor: UUID?
    /// Open cases the person can file an analysis under (when this view has no fixed case).
    @State private var caseChoices: [StudioCaseChoice] = []

    /// When set, the list shows only this case's analyses and new ones are filed under it.
    private let caseID: UUID?

    public init(caseID: UUID? = nil) { self.caseID = caseID }

    public var body: some View {
        Group {
            if ledgerMissing {
                ContentUnavailableView("The ledger isn't open yet", systemImage: "tablecells",
                                       description: Text("Competing-hypotheses analyses are kept in the ledger. Open or create a library, then come back."))
            } else if let binding = activeBinding { studio(binding) } else { listScreen }
        }
        .task(id: appState.achMatrices != nil) { await load() }
        .onDisappear { flushSave() }
    }

    // MARK: Persistence (the ledger)

    private var actor: String { InvestigatorProfile.name }

    private func load() async {
        guard !loaded else { return }
        guard let repo = appState.achMatrices else { ledgerMissing = true; return }
        ledgerMissing = false
        await importLegacyIfNeeded(repo)
        do {
            let stored = try await repo.analyses(caseID: caseID)
            analyses = stored.map(\.analysis)
            scopes = Dictionary(uniqueKeysWithValues: stored.compactMap { s in s.caseID.map { (s.id, $0) } })
            if caseID == nil { caseChoices = await appState.studioCaseChoices() }
            loaded = true
        } catch {
            KalsmritikoshLog.ui.error("ACH load failed: \(error.localizedDescription, privacy: .public)")
            notice = "Couldn't read the analyses from the ledger: \(error.localizedDescription)"
        }
    }

    /// One-time import of the old AppStorage blob. The blob is never modified or removed; a blob that
    /// can't be decoded is left as it is, reported, and the import is not marked done.
    private func importLegacyIfNeeded(_ repo: ACHRepository) async {
        do {
            guard try await !repo.hasImportedLegacy() else { return }
            let blob = legacyStoreBlob
            var decoded: [ACHAnalysis] = []
            if !blob.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                guard let data = blob.data(using: .utf8) else { return }
                do { decoded = try JSONDecoder().decode([ACHAnalysis].self, from: data) } catch {
                    KalsmritikoshLog.ui.error("ACH legacy store unreadable: \(error.localizedDescription, privacy: .public)")
                    notice = "An older on-device ACH store couldn't be read, so it was not imported. It is left untouched."
                    return
                }
            }
            let n = try await repo.importLegacy(decoded, actor: actor)
            if n > 0 { notice = "Moved \(n) analysis\(n == 1 ? "" : "es") from this Mac's old store into the ledger." }
        } catch {
            KalsmritikoshLog.ui.error("ACH legacy import failed: \(error.localizedDescription, privacy: .public)")
            notice = "Couldn't move the older on-device analyses into the ledger: \(error.localizedDescription)"
        }
    }

    /// Debounced save of one analysis: the latest edit wins; the repository refuses an older write.
    private func scheduleSave(_ a: ACHAnalysis) {
        if pendingSaveFor != a.id { flushSave() } else { pendingSave?.cancel() }
        let scope = scopes[a.id] ?? caseID
        pendingSaveFor = a.id
        pendingSave = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }   // cancelled: a newer edit follows
            await save(a, caseID: scope)
        }
    }

    /// Write the pending edit now (leaving the screen, or switching to another analysis).
    private func flushSave() {
        guard let pending = pendingSave, let id = pendingSaveFor else { return }
        pending.cancel(); pendingSave = nil; pendingSaveFor = nil
        guard let a = analyses.first(where: { $0.id == id }) else { return }
        let scope = scopes[a.id] ?? caseID
        Task { @MainActor in await save(a, caseID: scope) }
    }

    private func save(_ a: ACHAnalysis, caseID scope: UUID?) async {
        guard let repo = appState.achMatrices else { ledgerMissing = true; return }
        do {
            try await repo.save(a, caseID: scope, actor: actor)
        } catch {
            KalsmritikoshLog.ui.error("ACH save failed: \(error.localizedDescription, privacy: .public)")
            notice = "Couldn't save to the ledger: \(error.localizedDescription)"
        }
    }

    private var activeBinding: Binding<ACHAnalysis>? {
        guard let id = activeID, let idx = analyses.firstIndex(where: { $0.id == id }) else { return nil }
        return Binding(get: { analyses[idx] },
                       set: { analyses[idx] = $0; analyses[idx].updatedAt = Date(); scheduleSave(analyses[idx]) })
    }

    // MARK: List

    private var listScreen: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Competing Hypotheses (ACH)", systemImage: "tablecells")
                        .font(.largeTitle.weight(.bold))
                    Text("Test rival explanations the disciplined way: list every hypothesis, rate each piece of evidence for consistency, and let the matrix show which hypothesis has the fewest inconsistencies. You disprove, not confirm — the matrix aids judgment, it doesn't decide.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 10) {
                    Button { newAnalysis() } label: { Label("New analysis", systemImage: "plus.circle.fill") }
                        .buttonStyle(.borderedProminent)
                        .guidance(GuidanceTip("New analysis",
                                              what: "Starts a fresh Analysis of Competing Hypotheses: frame the question, list rival hypotheses, add evidence, and rate the matrix."))
                    Button { loadSample() } label: { Label("Load a worked example", systemImage: "wand.and.stars") }
                }
                noticeView
                if analyses.isEmpty {
                    ContentUnavailableView("No analyses yet", systemImage: "tablecells",
                                           description: Text("Create one to weigh competing explanations against your evidence."))
                        .frame(maxWidth: .infinity, minHeight: 220)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 14)], spacing: 14) {
                        ForEach(analyses.sorted { $0.updatedAt > $1.updatedAt }) { a in card(a) }
                    }
                }
            }
            .padding(24).frame(maxWidth: 940, alignment: .leading).frame(maxWidth: .infinity)
        }
        .navigationTitle("Competing Hypotheses")
    }

    private func card(_ a: ACHAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(a.title.trimmed.isEmpty ? "Untitled" : a.title).font(.headline).lineLimit(1)
            Text(a.question.trimmed.isEmpty ? "No question yet." : a.question)
                .font(.caption).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            ProgressView(value: a.completionFraction).tint(.green)
            HStack {
                Text("\(a.hypotheses.count) hypotheses · \(a.evidence.count) evidence")
                    .font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                if scopes[a.id] != nil, caseID == nil {
                    Label("Case", systemImage: "folder").font(.caption2).foregroundStyle(.secondary)
                        .help("Filed under a case")
                }
                Button(role: .destructive) { delete(a) } label: { Label("Remove", systemImage: "trash").labelStyle(.iconOnly) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Remove from the list (kept in the ledger's record)")
                Button("Open") { activeID = a.id }.buttonStyle(.bordered).controlSize(.small)
            }
        }
        .padding(16).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }

    private func newAnalysis() {
        var a = ACHAnalysis(title: "New analysis", now: Date())
        StudioAudit.record(&a.history, "Created")
        add(a)
    }
    private func loadSample() {
        add(ACHAnalysis.sample(now: Date()))
    }
    private func add(_ a: ACHAnalysis) {
        analyses.append(a)
        if let caseID { scopes[a.id] = caseID }
        activeID = a.id
        let scope = caseID
        Task { @MainActor in await save(a, caseID: scope) }
    }
    /// Retract — the analysis leaves the list but every row stays in the ledger.
    private func delete(_ a: ACHAnalysis) {
        if pendingSaveFor == a.id { pendingSave?.cancel(); pendingSave = nil; pendingSaveFor = nil }
        analyses.removeAll { $0.id == a.id }
        if activeID == a.id { activeID = nil }
        guard let repo = appState.achMatrices else { ledgerMissing = true; return }
        let who = actor
        Task { @MainActor in
            do { try await repo.retract(analysisID: a.id, actor: who) } catch {
                KalsmritikoshLog.ui.error("ACH retract failed: \(error.localizedDescription, privacy: .public)")
                notice = "Couldn't remove the analysis: \(error.localizedDescription)"
            }
        }
    }

    // MARK: Studio

    /// The exact source versions in the analysis's case scope, labelled — what an evidence row may
    /// cite. An analysis with no case offers no citations (its rows stay investigator's notes).
    private func loadCitationChoices(for a: ACHAnalysis) async {
        guard let scope = scopes[a.id] ?? caseID else { citationChoices = []; citationChoicesFor = a.id; return }
        guard citationChoicesFor != a.id else { return }
        citationChoicesFor = a.id
        guard let custody = appState.investigationCustody, let files = appState.caseFiles else { citationChoices = []; return }
        do {
            let entries = try await custody.manifest(caseID: scope)
            let ids = entries.map(\.sourceVersionID)
            let labels = try await files.file.sourceLabels(ids)
            citationChoices = ids.map { ($0, labels[$0] ?? "Source \($0.uuidString.prefix(8))") }
        } catch {
            KalsmritikoshLog.ui.error("ACH citation choices failed: \(error.localizedDescription, privacy: .public)")
            citationChoices = []
        }
    }

    /// The last outcome (a save problem, a release receipt, a refusal) — shown where the action was taken.
    @ViewBuilder private var noticeView: some View {
        if let notice {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle").foregroundStyle(.secondary)
                Text(notice).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("ach.notice")
                Spacer()
                Button { self.notice = nil } label: { Label("Dismiss", systemImage: "xmark").labelStyle(.iconOnly) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            .padding(10).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    /// UI journey run d (D-2): an analysis opened from the sidebar has no case, so it could cite
    /// nothing and its outputs were recorded nowhere. The person files it under one of the open
    /// cases here; citations then come from that case's sources and releases go to its log.
    private func casePicker(_ a: Binding<ACHAnalysis>) -> some View {
        let current = scopes[a.wrappedValue.id]
        return Menu {
            ForEach(caseChoices) { choice in
                Button(choice.title + (choice.id == current ? " ✓" : "")) { file(a.wrappedValue, under: choice) }
            }
            if caseChoices.isEmpty { Text("No open case — start one from Home or Cases") }
        } label: {
            Label(current.flatMap { id in caseChoices.first { $0.id == id }?.title } ?? "File under a case…", systemImage: "folder")
                .font(.caption).lineLimit(1)
        }
        .menuStyle(.borderlessButton).fixedSize()
        .help(current == nil ? "This analysis belongs to no case yet: cite nothing, record nothing. Choose the case it is part of."
              : "The case this analysis is filed under — its sources can be cited and its log records every copy, print and export.")
        .accessibilityIdentifier("ach.case")
    }

    private func file(_ a: ACHAnalysis, under choice: StudioCaseChoice) {
        guard let repo = appState.achMatrices else { ledgerMissing = true; return }
        let who = actor
        Task { @MainActor in
            do {
                try await repo.fileUnder(analysisID: a.id, caseID: choice.id, workspaceID: choice.workspaceID, actor: who)
                scopes[a.id] = choice.id
                citationChoicesFor = nil
                await loadCitationChoices(for: a)
                notice = "Filed under “\(choice.title)”. Evidence rows can now cite that case's sources; copies, prints and exports are recorded in its log."
            } catch {
                KalsmritikoshLog.ui.error("ACH case assignment failed: \(error.localizedDescription, privacy: .public)")
                notice = "Couldn't file the analysis under that case: \(error.localizedDescription)"
            }
        }
    }

    private func studio(_ a: Binding<ACHAnalysis>) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { activeID = nil } label: { Label("All analyses", systemImage: "chevron.left").font(.caption) }
                    .buttonStyle(.plain).foregroundStyle(.tint)
                TextField("Title", text: a.title).textFieldStyle(.plain).font(.headline).frame(maxWidth: 320)
                if caseID == nil { casePicker(a) }
                Spacer()
                Button { release(a.wrappedValue, route: .file) } label: { Label("Export", systemImage: "square.and.arrow.up") }.controlSize(.small)
                #if os(macOS)
                Button { release(a.wrappedValue, route: .print) } label: { Label("Print", systemImage: "printer") }.controlSize(.small)
                #endif
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    noticeView
                    questionSection(a)
                    hypothesesSection(a)
                    matrixSection(a)
                    rankingSection(a.wrappedValue)
                    listEditor("Critical assumptions", a.assumptions, $newAssumption, "Add an assumption you're relying on")
                    listEditor("Indicators to watch", a.indicators, $newIndicator, "Add an indicator that would change your read")
                    conclusionSection(a)
                }
                .padding(24).frame(maxWidth: 1000, alignment: .leading).frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .task(id: a.wrappedValue.id) { await loadCitationChoices(for: a.wrappedValue) }
    }

    private func questionSection(_ a: Binding<ACHAnalysis>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Question").font(.callout.weight(.semibold))
            TextField("What are you trying to explain or decide?", text: a.question, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(1...3)
        }
    }

    private func hypothesesSection(_ a: Binding<ACHAnalysis>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Hypotheses").font(.callout.weight(.semibold))
            Text("List rival explanations — ideally mutually exclusive. Aim for a complete set before rating.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(a.hypotheses) { $h in
                HStack(spacing: 8) {
                    let n = (a.wrappedValue.hypotheses.firstIndex { $0.id == h.id } ?? 0) + 1
                    Text("H\(n)").font(.caption.weight(.bold)).foregroundStyle(.tint).frame(width: 30)
                    TextField("Hypothesis", text: $h.text).textFieldStyle(.roundedBorder)
                    Button { a.wrappedValue.hypotheses.removeAll { $0.id == h.id } } label: { Label("Remove", systemImage: "xmark.circle").labelStyle(.iconOnly) }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 8) {
                TextField("Add a hypothesis", text: $newHypothesis).textFieldStyle(.roundedBorder)
                    .onSubmit { addHypothesis(a) }
                Button { addHypothesis(a) } label: { Label("Add", systemImage: "plus").labelStyle(.iconOnly) }
                    .disabled(newHypothesis.trimmed.isEmpty)
            }
        }
    }

    // The matrix — the centerpiece.
    private func matrixSection(_ a: Binding<ACHAnalysis>) -> some View {
        let hyps = a.wrappedValue.hypotheses
        return VStack(alignment: .leading, spacing: 8) {
            Text("Consistency matrix").font(.callout.weight(.semibold))
            if !a.wrappedValue.isReady {
                // UI journey 2026-10-30b, D-1: the evidence input used to live only inside the built
                // matrix, which needs evidence to exist — a new analysis could never add its first row.
                Text(a.wrappedValue.hypotheses.count < 2
                     ? "Add at least two hypotheses, then the evidence to rate against them."
                     : "Add the first piece of evidence to build the matrix.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    TextField("Add evidence", text: $newEvidence).textFieldStyle(.roundedBorder)
                        .onSubmit { addEvidence(a) }
                        .accessibilityIdentifier("ach.addEvidence")
                    Button { addEvidence(a) } label: { Label("Add evidence", systemImage: "plus") }
                        .disabled(newEvidence.trimmed.isEmpty)
                }
            } else {
                ScrollView(.horizontal, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 4) {
                        // header
                        HStack(spacing: 6) {
                            Text("Evidence").font(.caption2.weight(.bold)).frame(width: 240, alignment: .leading)
                            ForEach(Array(hyps.enumerated()), id: \.element.id) { i, _ in
                                Text("H\(i + 1)").font(.caption2.weight(.bold)).frame(width: 60)
                            }
                            Text("Diag").font(.caption2.weight(.bold)).frame(width: 40)
                        }
                        .padding(.vertical, 4).background(.quaternary.opacity(0.4))
                        // rows
                        ForEach(a.evidence) { $e in
                            HStack(spacing: 6) {
                                VStack(alignment: .leading, spacing: 2) {
                                    TextField("Evidence", text: $e.text).textFieldStyle(.plain).font(.caption)
                                    citationRow($e)
                                }.frame(width: 240, alignment: .leading)
                                ForEach(hyps) { h in cell(a, evidenceID: e.id, hyp: h) }
                                diagnosticMark(a.wrappedValue, e)
                                Button { a.wrappedValue.evidence.removeAll { $0.id == e.id } } label: { Label("Remove", systemImage: "xmark.circle").labelStyle(.iconOnly) }
                                    .buttonStyle(.plain).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                        }
                        Divider()
                        // inconsistency score row — every hypothesis with the fewest points is marked, so
                        // a tie shows as several marks, and an unrated matrix shows none.
                        let candidates = Set(a.wrappedValue.preference.candidates.map(\.id))
                        HStack(spacing: 6) {
                            Text("Inconsistency").font(.caption2.weight(.bold)).frame(width: 240, alignment: .leading)
                            ForEach(hyps) { h in
                                VStack(spacing: 0) {
                                    Text("\(a.wrappedValue.inconsistencyScore(h))")
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(candidates.contains(h.id) ? Color.green : Color.primary)
                                    Text("\(a.wrappedValue.assessedCount(h))/\(a.wrappedValue.evidence.count) rated")
                                        .font(.caption2).foregroundStyle(.tertiary)
                                }
                                .frame(width: 60)
                                .accessibilityLabel("\(a.wrappedValue.label(of: h)): \(a.wrappedValue.inconsistencyScore(h)) inconsistency points, \(a.wrappedValue.assessedCount(h)) of \(a.wrappedValue.evidence.count) cells rated")
                            }
                            Spacer().frame(width: 40)
                        }
                    }
                }
                .frame(maxHeight: 420)
                coverageLine(a.wrappedValue)
                HStack(spacing: 8) {
                    TextField("Add evidence", text: $newEvidence).textFieldStyle(.roundedBorder)
                        .onSubmit { addEvidence(a) }
                    Button { addEvidence(a) } label: { Label("Add evidence", systemImage: "plus") }
                        .disabled(newEvidence.trimmed.isEmpty)
                }
                Text("Rate each cell for how consistent the evidence is with that hypothesis: CC very consistent · C consistent · N neutral · I inconsistent · II very inconsistent · — unassessed (not yet rated; it says nothing). Only I / II count against a hypothesis.")
                    .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// "n of m cells rated" with the unassessed count — the matrix's coverage, always visible.
    private func coverageLine(_ a: ACHAnalysis) -> some View {
        HStack(spacing: 8) {
            Image(systemName: a.isFullyAssessed ? "checkmark.circle" : "circle.dotted")
                .foregroundStyle(a.isFullyAssessed ? Color.green : Color.orange)
            Text(a.cellCount == 0 ? "No cells to rate yet."
                 : "\(a.assessedCellCount) of \(a.cellCount) cells rated" + (a.unassessedCellCount == 0 ? "." : " · \(a.unassessedCellCount) unassessed (shown as —)."))
                .font(.caption)
            Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("ach.coverage")
    }

    private func diagnosticMark(_ a: ACHAnalysis, _ e: ACHEvidence) -> some View {
        let diagnostic = a.isDiagnostic(e)
        let full = a.isFullyAssessed(e)
        return Image(systemName: diagnostic ? "checkmark.circle.fill" : (full ? "minus" : "questionmark.circle"))
            .foregroundStyle(diagnostic ? Color.green : (full ? Color.secondary : Color.orange))
            .frame(width: 40)
            .help(diagnostic ? "Diagnostic — it distinguishes the hypotheses"
                  : (full ? "Not diagnostic — rated the same across hypotheses" : "Not fully assessed — rate every cell of this row first"))
            .accessibilityLabel(diagnostic ? "Diagnostic" : (full ? "Not diagnostic" : "Not fully assessed"))
    }

    /// Below the evidence text: its citation (an exact source version in the case's scope, with an
    /// optional quote) or, without one, the note that this is the investigator's own entry.
    @ViewBuilder
    private func citationRow(_ e: Binding<ACHEvidence>) -> some View {
        HStack(spacing: 4) {
            if e.wrappedValue.hasCitation, let c = e.wrappedValue.citation {
                Image(systemName: e.wrappedValue.isCited ? "link" : "link.badge.minus").font(.caption2)
                    .foregroundStyle(e.wrappedValue.isCited ? Color.accentColor : Color.orange)
                Text(citationLabel(c)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    .help("Cited: \(citationLabel(c))")
                // §2 — the citation's verification: the quoted words must be in this source, in this case.
                Text(e.wrappedValue.isCited ? "verified" : (e.wrappedValue.citationDetail ?? "not verified — quote the passage"))
                    .font(.caption2).lineLimit(1)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background((e.wrappedValue.isCited ? Color.green : Color.orange).opacity(0.18), in: Capsule())
                    .help(e.wrappedValue.isCited ? "The quoted words were found in this source as it is in the case now."
                          : "Not a citation yet: quote the passage so it can be checked against the source. Until then this row is your own note.")
                    .accessibilityIdentifier("ach.citation.state")
                TextField("quote the passage", text: Binding(get: { c.quote ?? "" },
                                                             set: { var ref = c; ref.quote = $0.trimmed.isEmpty ? nil : $0; e.wrappedValue.citation = ref; verifyCitation(e) }))
                    .textFieldStyle(.plain).font(.caption2)
                    .onSubmit { verifyCitation(e) }
                Button { e.wrappedValue.citation = nil; e.wrappedValue.citationState = nil; e.wrappedValue.citationDetail = nil } label: { Label("Remove citation", systemImage: "xmark.circle").labelStyle(.iconOnly) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Remove the citation — the row becomes an investigator's note")
            } else {
                Text("Investigator's note").font(.caption2).foregroundStyle(.orange)
                    .help("Uncited — this row is your own entry, not a source. Cite a source version and quote the passage to change that.")
                TextField("where from (optional)", text: e.source).textFieldStyle(.plain).font(.caption2).foregroundStyle(.secondary)
                if !citationChoices.isEmpty {
                    Menu {
                        ForEach(citationChoices, id: \.id) { choice in
                            Button(choice.label) {
                                e.wrappedValue.citation = StudioEvidenceRef(sourceVersionID: choice.id)
                                e.wrappedValue.citationState = nil; e.wrappedValue.citationDetail = "not verified — quote the passage"
                            }
                        }
                    } label: { Label("Cite", systemImage: "link.badge.plus").labelStyle(.iconOnly) }
                        .menuStyle(.borderlessButton).fixedSize().help("Cite an exact source version in this case's scope, then quote the passage")
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// §2 — check the row's citation through the case's one evidence verifier and record the state.
    private func verifyCitation(_ e: Binding<ACHEvidence>) {
        guard let c = e.wrappedValue.citation, let version = c.sourceVersionID,
              let scope = (activeID.flatMap { scopes[$0] }) ?? caseID, let files = appState.caseFiles else {
            e.wrappedValue.citationState = nil
            e.wrappedValue.citationDetail = appState.caseFiles == nil ? "the case file is not available" : "the analysis is not filed under a case"
            return
        }
        let id = e.wrappedValue.id
        Task { @MainActor in
            let result = await files.verify(reference: version.uuidString, passage: c, caseID: scope)
            guard var binding = activeBinding, let i = binding.wrappedValue.evidence.firstIndex(where: { $0.id == id }) else { return }
            binding.wrappedValue.evidence[i].citationState = result.support.stored == "verified" ? "verified" : "unverified"
            binding.wrappedValue.evidence[i].citationDetail = result.support.detail
            if let p = result.passage { binding.wrappedValue.evidence[i].citation = p }
        }
    }

    private func citationLabel(_ c: StudioEvidenceRef) -> String {
        if let v = c.sourceVersionID, let l = citationChoices.first(where: { $0.id == v })?.label { return l }
        if let v = c.sourceVersionID { return "Version \(v.uuidString.prefix(8))" }
        return "Cited"
    }

    private func cell(_ a: Binding<ACHAnalysis>, evidenceID: UUID, hyp: ACHHypothesis) -> some View {
        let key = ACHAnalysis.key(evidenceID, hyp.id)
        let current = a.wrappedValue.ratings[key]
        return Menu {
            ForEach(ACHConsistency.allCases, id: \.self) { c in
                Button("\(c.symbol) — \(c.label)") { a.wrappedValue.ratings[key] = c }
            }
            Divider()
            Button("\(ACHConsistency.unassessedSymbol) — \(ACHConsistency.unassessedLabel) (clear the rating)") { a.wrappedValue.ratings[key] = nil }
                .disabled(current == nil)
        } label: {
            Text(current?.symbol ?? ACHConsistency.unassessedSymbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(current == nil ? Color.secondary : Color.primary)
                .frame(width: 60, height: 28)
                .background(cellColor(current), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: current == nil ? [3, 3] : []))
                    .foregroundStyle(current == nil ? Color.secondary.opacity(0.6) : Color.clear))
        }
        .menuStyle(.borderlessButton).fixedSize()
        .help(current.map(\.label) ?? "Unassessed — not yet rated")
        .accessibilityLabel("\(a.wrappedValue.label(of: hyp)) cell: \(current?.label ?? ACHConsistency.unassessedLabel)")
    }

    private func cellColor(_ c: ACHConsistency?) -> Color {
        switch c {
        case .veryInconsistent: return .red.opacity(0.28)
        case .inconsistent: return .red.opacity(0.14)
        case .veryConsistent: return .green.opacity(0.22)
        case .consistent: return .green.opacity(0.12)
        case .neutral: return .gray.opacity(0.12)
        case nil: return .clear
        }
    }

    private func rankingSection(_ a: ACHAnalysis) -> some View {
        let candidates = Set(a.preference.candidates.map(\.id))
        return VStack(alignment: .leading, spacing: 6) {
            Text("Ranking — fewest inconsistencies first").font(.callout.weight(.semibold))
            if !a.isReady { Text("Build the matrix to see the ranking.").font(.caption).foregroundStyle(.tertiary) }
            else {
                ForEach(Array(a.ranking.enumerated()), id: \.element.hypothesis.id) { i, entry in
                    HStack(spacing: 8) {
                        Text("\(i + 1).").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                        Text(a.label(of: entry.hypothesis)).font(.caption.weight(.bold))
                            .foregroundStyle(candidates.contains(entry.hypothesis.id) ? Color.green : .secondary)
                        Text(entry.hypothesis.text).font(.caption).lineLimit(1)
                        if candidates.count > 1, candidates.contains(entry.hypothesis.id) {
                            Text("tied").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                                .background(.orange.opacity(0.18), in: Capsule())
                        }
                        Spacer()
                        Text("\(entry.score) pt\(entry.score == 1 ? "" : "s") · \(a.assessedCount(entry.hypothesis))/\(a.evidence.count) rated")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(a.preferenceStatement)
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("ach.preference")
                Text("Lowest score = survives the evidence best. It is not proof — if several stay close, treat them as live.")
                    .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
    }

    private func conclusionSection(_ a: Binding<ACHAnalysis>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Conclusion").font(.callout.weight(.semibold))
            Text(conclusionHint(a.wrappedValue))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker("Leading hypothesis", selection: a.conclusion.leadingHypothesisID) {
                Text("—").tag(Optional<UUID>.none)
                ForEach(a.wrappedValue.hypotheses) { h in Text(h.text).tag(Optional(h.id)) }
            }
            .frame(maxWidth: 420)
            HStack(spacing: 8) {
                Text("Confidence").font(.caption).foregroundStyle(.secondary)
                Picker("Confidence", selection: a.conclusion.confidence) {
                    ForEach(ACHConfidence.allCases, id: \.self) { Text($0.label).tag($0) }
                }.pickerStyle(.segmented).frame(maxWidth: 260).labelsHidden()
            }
            TextEditor(text: a.conclusion.summary)
                .font(.body).frame(minHeight: 80)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
            HStack(spacing: 10) {
                Button { release(a.wrappedValue, route: .clipboard) } label: { Label("Copy report", systemImage: "doc.on.doc") }
                Button { release(a.wrappedValue, route: .file) } label: { Label("Export Markdown", systemImage: "square.and.arrow.up") }
            }
        }
    }

    /// What the matrix says before the person decides — never "ACH points to X" unless one
    /// hypothesis alone has the fewest points on assessed, discriminating evidence.
    private func conclusionHint(_ a: ACHAnalysis) -> String {
        switch a.preference {
        case .noAssessment: return "The matrix is not rated yet, so it establishes no preference. You may still record your judgment below — it is yours, not the matrix's."
        case .noDiscriminatingEvidence: return "No assessed evidence distinguishes the hypotheses; no preference is established. Your judgment below is recorded as yours."
        case .tied(let hs, _): return "\(hs.map { a.label(of: $0) }.joined(separator: " and ")) tie on the ratings; the matrix establishes no preference between them. You decide — record your judgment below."
        case .leading(let h, _, _, _): return "The ratings leave \(a.label(of: h)) (\(h.text)) with the fewest inconsistencies. You decide — record your judgment below."
        }
    }

    private func listEditor(_ title: String, _ items: Binding<[String]>, _ newText: Binding<String>, _ placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.callout.weight(.semibold))
            ForEach(Array(items.wrappedValue.enumerated()), id: \.offset) { idx, _ in
                HStack(spacing: 8) {
                    Image(systemName: "circle.fill").scaledFont(5, relativeTo: .caption).foregroundStyle(.secondary)
                    TextField("", text: Binding(get: { items.wrappedValue[idx] },
                                                set: { var x = items.wrappedValue; x[idx] = $0; items.wrappedValue = x }))
                        .textFieldStyle(.plain)
                    Button { var x = items.wrappedValue; x.remove(at: idx); items.wrappedValue = x } label: { Label("Remove", systemImage: "xmark.circle").labelStyle(.iconOnly) }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 8) {
                TextField(placeholder, text: newText).textFieldStyle(.roundedBorder).onSubmit { addTo(items, newText) }
                Button { addTo(items, newText) } label: { Label("Add", systemImage: "plus").labelStyle(.iconOnly) }.disabled(newText.wrappedValue.trimmed.isEmpty)
            }
        }
        .padding(10).background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Mutations

    private func addHypothesis(_ a: Binding<ACHAnalysis>) {
        let t = newHypothesis.trimmed; guard !t.isEmpty else { return }
        a.wrappedValue.hypotheses.append(ACHHypothesis(text: t)); newHypothesis = ""
    }
    private func addEvidence(_ a: Binding<ACHAnalysis>) {
        let t = newEvidence.trimmed; guard !t.isEmpty else { return }
        a.wrappedValue.evidence.append(ACHEvidence(text: t)); newEvidence = ""
    }
    private func addTo(_ items: Binding<[String]>, _ newText: Binding<String>) {
        let t = newText.wrappedValue.trimmed; guard !t.isEmpty else { return }
        items.wrappedValue.append(t); newText.wrappedValue = ""
    }

    // MARK: Output

    private func exportFilename(_ a: ACHAnalysis) -> String {
        "ach-\(a.title.replacingOccurrences(of: " ", with: "-").replacingOccurrences(of: "/", with: "-").lowercased()).md"
    }

    /// App Store completion §4 — copy, print and export all go through `CaseOutputService`: the
    /// report is rendered once, its citations re-checked against the analysis's case as it is now,
    /// protected identities scrubbed, and the SAME bytes are copied, printed or written; the release
    /// is recorded in the case (a cancelled panel or print dialog records nothing).
    private func release(_ a: ACHAnalysis, route: CaseOutputRoute) {
        #if os(macOS)
        flushSave()
        guard let outputs = appState.caseOutputs else { notice = "The ledger isn't open yet; nothing was released."; return }
        var destination: URL?
        if route == .file {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = exportFilename(a)
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let url = panel.url else { return }
            destination = url
        }
        let scope = scopes[a.id] ?? caseID
        let text = ACHReportRenderer.markdown(a, generatedAt: Date())
        let citations = a.evidence.compactMap(\.citation)
        let title = a.title, who = actor
        Task { @MainActor in
            do {
                let pkg = try await outputs.prepareText(caseID: scope, kind: .achReport, route: route, actor: who, citations: citations, text: text)
                switch route {
                case .file:
                    guard let destination else { return }
                    notice = await outputs.write(pkg, to: destination).summary
                case .clipboard:
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(pkg.text, forType: .string)
                    notice = "Copied. " + (await outputs.released(pkg).summary)
                case .print:
                    switch AppPrinting.run(text: pkg.text, jobTitle: "ACH — \(title)", fontSize: 10) {
                    case .printed: notice = "Printed. " + (await outputs.released(pkg).summary)
                    case .cancelled: notice = "Print cancelled; nothing was recorded."
                    case .notAvailable: notice = AppPrinting.unavailableMessage
                    }
                case .share:
                    break
                }
            } catch {
                notice = error.localizedDescription
            }
        }
        #endif
    }
}

#if DEBUG
#Preview("ACH matrix") {
    ACHMatrixView().environment(AppState()).frame(width: 1040, height: 780)
}
#endif
