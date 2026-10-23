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
    @State private var showExporter = false

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
        .fileExporter(isPresented: $showExporter,
                      document: RCAMarkdownDocument(text: activeReport),
                      contentType: .plainText,
                      defaultFilename: exportFilename) { _ in }
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
                if let notice {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "info.circle").foregroundStyle(.secondary)
                        Text(notice).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button { self.notice = nil } label: { Label("Dismiss", systemImage: "xmark").labelStyle(.iconOnly) }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                    .padding(10).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                }
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

    private func studio(_ a: Binding<ACHAnalysis>) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { activeID = nil } label: { Label("All analyses", systemImage: "chevron.left").font(.caption) }
                    .buttonStyle(.plain).foregroundStyle(.tint)
                TextField("Title", text: a.title).textFieldStyle(.plain).font(.headline).frame(maxWidth: 320)
                Spacer()
                Button { showExporter = true } label: { Label("Export", systemImage: "square.and.arrow.up") }.controlSize(.small)
                #if os(macOS)
                Button { printReport(a.wrappedValue) } label: { Label("Print", systemImage: "printer") }.controlSize(.small)
                #endif
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
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
                Text("Add at least two hypotheses and one piece of evidence to build the matrix.")
                    .font(.callout).foregroundStyle(.secondary)
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
                                    TextField("source (optional)", text: $e.source).textFieldStyle(.plain).font(.caption2).foregroundStyle(.secondary)
                                }.frame(width: 240, alignment: .leading)
                                ForEach(hyps) { h in cell(a, evidenceID: e.id, hyp: h) }
                                Image(systemName: a.wrappedValue.isDiagnostic(e) ? "checkmark.circle.fill" : "minus")
                                    .foregroundStyle(a.wrappedValue.isDiagnostic(e) ? Color.green : Color.secondary)
                                    .frame(width: 40)
                                    .help(a.wrappedValue.isDiagnostic(e) ? "Diagnostic — it distinguishes the hypotheses" : "Not diagnostic — rated the same across hypotheses")
                                Button { a.wrappedValue.evidence.removeAll { $0.id == e.id } } label: { Label("Remove", systemImage: "xmark.circle").labelStyle(.iconOnly) }
                                    .buttonStyle(.plain).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                        }
                        Divider()
                        // inconsistency score row
                        HStack(spacing: 6) {
                            Text("Inconsistency").font(.caption2.weight(.bold)).frame(width: 240, alignment: .leading)
                            ForEach(hyps) { h in
                                Text("\(a.wrappedValue.inconsistencyScore(h))")
                                    .font(.caption.weight(.bold)).frame(width: 60)
                                    .foregroundStyle(a.wrappedValue.leastInconsistent?.id == h.id ? Color.green : Color.primary)
                            }
                            Spacer().frame(width: 40)
                        }
                    }
                }
                .frame(maxHeight: 420)
                HStack(spacing: 8) {
                    TextField("Add evidence", text: $newEvidence).textFieldStyle(.roundedBorder)
                        .onSubmit { addEvidence(a) }
                    Button { addEvidence(a) } label: { Label("Add evidence", systemImage: "plus") }
                        .disabled(newEvidence.trimmed.isEmpty)
                }
                Text("Rate each cell for how consistent the evidence is with that hypothesis: CC very consistent · C consistent · N neutral · I inconsistent · II very inconsistent. Only I / II count against a hypothesis.")
                    .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func cell(_ a: Binding<ACHAnalysis>, evidenceID: UUID, hyp: ACHHypothesis) -> some View {
        let key = ACHAnalysis.key(evidenceID, hyp.id)
        let current = a.wrappedValue.ratings[key] ?? .neutral
        return Menu {
            ForEach(ACHConsistency.allCases, id: \.self) { c in
                Button("\(c.symbol) — \(c.label)") { a.wrappedValue.ratings[key] = c }
            }
        } label: {
            Text(current.symbol)
                .font(.caption.weight(.semibold))
                .frame(width: 60, height: 28)
                .background(cellColor(current), in: RoundedRectangle(cornerRadius: 6))
        }
        .menuStyle(.borderlessButton).fixedSize()
    }

    private func cellColor(_ c: ACHConsistency) -> Color {
        switch c {
        case .veryInconsistent: return .red.opacity(0.28)
        case .inconsistent: return .red.opacity(0.14)
        case .veryConsistent: return .green.opacity(0.22)
        case .consistent: return .green.opacity(0.12)
        case .neutral: return .gray.opacity(0.12)
        }
    }

    private func rankingSection(_ a: ACHAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Ranking — fewest inconsistencies first").font(.callout.weight(.semibold))
            if !a.isReady { Text("Build the matrix to see the ranking.").font(.caption).foregroundStyle(.tertiary) }
            else {
                ForEach(Array(a.ranking.enumerated()), id: \.element.hypothesis.id) { i, entry in
                    let n = (a.hypotheses.firstIndex { $0.id == entry.hypothesis.id } ?? 0) + 1
                    HStack(spacing: 8) {
                        Text("\(i + 1).").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                        Text("H\(n)").font(.caption.weight(.bold)).foregroundStyle(i == 0 ? Color.green : .secondary)
                        Text(entry.hypothesis.text).font(.caption).lineLimit(1)
                        Spacer()
                        Text("\(entry.score) pt\(entry.score == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                    }
                }
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
            if let h = a.wrappedValue.leastInconsistent {
                Text("ACH points to: \(h.text). You decide — record your judgment below.")
                    .font(.caption).foregroundStyle(.secondary)
            }
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
                Button { copyReport(a.wrappedValue) } label: { Label("Copy report", systemImage: "doc.on.doc") }
                Button { showExporter = true } label: { Label("Export Markdown", systemImage: "square.and.arrow.up") }
            }
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

    private var activeReport: String {
        guard let b = activeBinding else { return "" }
        return ACHReportRenderer.markdown(b.wrappedValue, generatedAt: Date())
    }
    private var exportFilename: String {
        let t = activeBinding?.wrappedValue.title ?? "ach"
        return "ach-\(t.replacingOccurrences(of: " ", with: "-").lowercased())"
    }
    private func copyReport(_ a: ACHAnalysis) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ACHReportRenderer.markdown(a, generatedAt: Date()), forType: .string)
        #endif
    }
    #if os(macOS)
    private func printReport(_ a: ACHAnalysis) {
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 468, height: 648))
        tv.string = ACHReportRenderer.markdown(a, generatedAt: Date())
        tv.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        let op = NSPrintOperation(view: tv); op.jobTitle = "ACH — \(a.title)"; op.run()
    }
    #endif
}

#if DEBUG
#Preview("ACH matrix") {
    ACHMatrixView().environment(AppState()).frame(width: 1040, height: 780)
}
#endif
