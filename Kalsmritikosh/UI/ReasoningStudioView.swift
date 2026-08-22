//
//  ReasoningStudioView.swift
//  Kalsmritikosh
//
//  The Reasoning Studio — a guided, start-to-finish root-cause investigation:
//  Frame the problem → Brainstorm causes → 5 Whys → Fishbone (Ishikawa) diagram
//  → Conclude → Report with a prepared-by / submit-to approval block and export
//  (Markdown, Copy, Print → Save as PDF). Deterministic throughout; an optional
//  Full-power AI only *suggests* causes and next "whys" that you curate.
//
//  Analyses persist on-device as JSON (no schema migration, nothing uploaded).
//

import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

struct RCAMarkdownDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        text = String(data: configuration.file.regularFileContents ?? Data(), encoding: .utf8) ?? ""
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

public struct ReasoningStudioView: View {
    @Environment(AppState.self) private var appState

    @AppStorage("kalsmritikosh.rca.store") private var storeBlob = ""
    @State private var analyses: [RootCauseAnalysis] = []
    @State private var loaded = false
    @State private var activeID: UUID?
    @State private var stage: RootCauseAnalysis.Stage = .frame

    // transient input buffers
    @State private var ideaText = ""
    @State private var newFactor = ""
    @State private var newRecommendation = ""
    @State private var aiBusy = false
    @State private var aiNote: String?
    @State private var showExporter = false

    public init() {}

    private var aiAvailable: Bool { FeatureFlags.shared.fullPowerMode && appState.capabilities != nil }

    public var body: some View {
        Group {
            if let binding = activeBinding {
                studio(binding)
            } else {
                listScreen
            }
        }
        .onAppear(perform: load)
        .fileExporter(isPresented: $showExporter,
                      document: RCAMarkdownDocument(text: activeReport),
                      contentType: .plainText,
                      defaultFilename: exportFilename) { _ in }
    }

    // MARK: - Persistence

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let data = storeBlob.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([RootCauseAnalysis].self, from: data) {
            analyses = decoded
        }
    }
    private func persist() {
        if let data = try? JSONEncoder().encode(analyses),
           let s = String(data: data, encoding: .utf8) { storeBlob = s }
    }

    private var activeBinding: Binding<RootCauseAnalysis>? {
        guard let id = activeID, let idx = analyses.firstIndex(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { analyses[idx] },
            set: { analyses[idx] = $0; analyses[idx].updatedAt = Date(); persist() }
        )
    }

    // MARK: - List screen

    private var listScreen: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Reasoning Studio", systemImage: "brain.head.profile")
                        .font(.largeTitle.weight(.bold))
                    Text("Run a structured investigation from start to finish — brainstorm, 5 Whys, a fishbone cause-and-effect diagram, then a written conclusion and an approval-ready report you can submit. Everything stays on this Mac.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 10) {
                    Button { newAnalysis() } label: {
                        Label("New investigation", systemImage: "plus.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .guidance(GuidanceTip("New investigation",
                                          what: "Starts a fresh root-cause analysis. You'll frame the problem, then work through brainstorm, 5 Whys, and a fishbone diagram to a conclusion and a submittable report."))
                    Button { loadSample() } label: {
                        Label("Load a worked example", systemImage: "wand.and.stars")
                    }
                    .guidance(GuidanceTip("Load a worked example",
                                          what: "Adds a fully worked sample investigation (an SIU claim-inconsistency case) so you can click straight through every stage and see the finished report."))
                }

                if analyses.isEmpty {
                    ContentUnavailableView("No investigations yet",
                                           systemImage: "brain.head.profile",
                                           description: Text("Create one to start reasoning through a case with brainstorming, 5 Whys and a fishbone diagram."))
                        .frame(maxWidth: .infinity, minHeight: 220)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 14)], spacing: 14) {
                        ForEach(analyses.sorted { $0.updatedAt > $1.updatedAt }) { rca in
                            analysisCard(rca)
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 940, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Reasoning Studio")
    }

    private func analysisCard(_ rca: RootCauseAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(rca.title.trimmed.isEmpty ? "Untitled" : rca.title)
                    .font(.headline).lineLimit(1)
                Spacer()
                statusChip(rca.approval.status)
            }
            Text(rca.problemStatement.trimmed.isEmpty ? "No problem statement yet." : rca.problemStatement)
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            ProgressView(value: rca.completionFraction).tint(.green)
            HStack {
                Text("Updated \(rca.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button(role: .destructive) { delete(rca) } label: { Image(systemName: "trash") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Delete this investigation")
                Button("Open") { activeID = rca.id; stage = firstIncompleteStage(rca) }
                    .buttonStyle(.bordered).controlSize(.small)
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }

    private func newAnalysis() {
        var rca = RootCauseAnalysis(title: "New investigation", now: Date())
        rca.approval.preparedBy = NSFullUserName()
        analyses.append(rca); persist()
        activeID = rca.id; stage = .frame
    }
    private func loadSample() {
        let rca = RootCauseAnalysis.sample(now: Date())
        analyses.append(rca); persist()
        activeID = rca.id; stage = .fishbone   // open where the visual payoff is
    }
    private func delete(_ rca: RootCauseAnalysis) {
        analyses.removeAll { $0.id == rca.id }; persist()
        if activeID == rca.id { activeID = nil }
    }
    private func firstIncompleteStage(_ rca: RootCauseAnalysis) -> RootCauseAnalysis.Stage {
        RootCauseAnalysis.Stage.allCases.first { !rca.isComplete($0) } ?? .report
    }

    // MARK: - Studio (an open analysis)

    private func studio(_ rca: Binding<RootCauseAnalysis>) -> some View {
        VStack(spacing: 0) {
            studioHeader(rca)
            Divider()
            stepperBar(rca.wrappedValue)
            Divider()
            ScrollView {
                stageContent(rca)
                    .padding(24)
                    .frame(maxWidth: 900, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .top)
            }
        }
    }

    private func studioHeader(_ rca: Binding<RootCauseAnalysis>) -> some View {
        HStack(spacing: 12) {
            Button { activeID = nil } label: { Label("All investigations", systemImage: "chevron.left").font(.caption) }
                .buttonStyle(.plain).foregroundStyle(.tint)
            TextField("Case / matter name", text: rca.title)
                .textFieldStyle(.plain).font(.headline).frame(maxWidth: 360)
            statusChip(rca.wrappedValue.approval.status)
            Spacer()
            Button { showExporter = true } label: { Label("Export", systemImage: "square.and.arrow.up") }
                .controlSize(.small)
            #if os(macOS)
            Button { printReport(rca.wrappedValue) } label: { Label("Print", systemImage: "printer") }
                .controlSize(.small)
                .help("Print — or choose “Save as PDF” in the print dialog")
            #endif
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }

    private func stepperBar(_ rca: RootCauseAnalysis) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(RootCauseAnalysis.Stage.allCases.enumerated()), id: \.element) { idx, s in
                Button { stage = s } label: {
                    VStack(spacing: 4) {
                        ZStack {
                            Circle()
                                .fill(stage == s ? AnyShapeStyle(.tint) : (rca.isComplete(s) ? AnyShapeStyle(.green.opacity(0.9)) : AnyShapeStyle(.quaternary)))
                                .frame(width: 30, height: 30)
                            Image(systemName: rca.isComplete(s) && stage != s ? "checkmark" : s.systemImage)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(stage == s || rca.isComplete(s) ? Color.white : Color.secondary)
                        }
                        Text(s.title).font(.caption2.weight(stage == s ? .bold : .regular))
                            .foregroundStyle(stage == s ? .primary : .secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                if idx < RootCauseAnalysis.Stage.allCases.count - 1 {
                    Rectangle().fill(.quaternary).frame(height: 2).frame(maxWidth: 40)
                }
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }

    @ViewBuilder
    private func stageContent(_ rca: Binding<RootCauseAnalysis>) -> some View {
        switch stage {
        case .frame:      frameStage(rca)
        case .brainstorm: brainstormStage(rca)
        case .fiveWhys:   fiveWhysStage(rca)
        case .fishbone:   fishboneStage(rca)
        case .conclude:   concludeStage(rca)
        case .report:     reportStage(rca)
        }
    }

    // MARK: Stage 1 — Frame

    private func frameStage(_ rca: Binding<RootCauseAnalysis>) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            stageHeader("Frame the problem",
                        "State the effect you're investigating in one clear sentence — the incident, the discrepancy, the outcome. Everything downstream hangs off this.")
            Text("Problem statement").font(.callout.weight(.semibold))
            TextEditor(text: rca.problemStatement)
                .font(.body).frame(minHeight: 120)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
            Text("Tip: describe what happened, where, and how you know — not why yet. Example: “The claimant's stated injury date is inconsistent across three documents.”")
                .font(.caption).foregroundStyle(.secondary)
            nextButton(to: .brainstorm)
        }
    }

    // MARK: Stage 2 — Brainstorm

    private func brainstormStage(_ rca: Binding<RootCauseAnalysis>) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            stageHeader("Brainstorm possible causes",
                        "Get every plausible cause out of your head first — no filtering. You'll organise and test them next. Park anything you want to keep but set aside.")
            HStack(spacing: 8) {
                TextField("Add a possible cause and press Return", text: $ideaText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addIdea(rca) }
                Button { addIdea(rca) } label: { Label("Add", systemImage: "plus") }
                    .disabled(ideaText.trimmed.isEmpty)
                    .guidance(GuidanceTip("Add a cause",
                                          what: "Captures one brainstorm idea. Add freely — you organise and test them in the next steps.",
                                          enabledWhen: "Type a possible cause first."),
                              enabled: !ideaText.trimmed.isEmpty)
                if aiAvailable {
                    Button { Task { await aiSuggestCauses(rca) } } label: {
                        if aiBusy { ProgressView().controlSize(.small) }
                        else { Label("Suggest (AI)", systemImage: "sparkles") }
                    }
                    .disabled(aiBusy || rca.wrappedValue.problemStatement.trimmed.count < 4)
                    .help("On-device AI proposes candidate causes to consider — you keep or discard each. Nothing is uploaded.")
                }
            }
            if let aiNote { Text(aiNote).font(.caption).foregroundStyle(.secondary) }

            if rca.wrappedValue.brainstorm.isEmpty {
                Text("No ideas yet. Aim for quantity — 8–12 is a good start.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(rca.brainstorm) { $idea in
                ideaRow($idea, rca: rca)
            }
            nextButton(to: .fiveWhys)
        }
    }

    private func ideaRow(_ idea: Binding<RCAIdea>, rca: Binding<RootCauseAnalysis>) -> some View {
        HStack(spacing: 8) {
            Image(systemName: idea.wrappedValue.parked ? "moon.zzz" : "lightbulb")
                .foregroundStyle(idea.wrappedValue.parked ? Color.secondary : Color.yellow)
            TextField("Cause", text: idea.text).textFieldStyle(.plain)
                .strikethrough(idea.wrappedValue.parked)
            Menu {
                Button("None") { idea.wrappedValue.category = nil }
                ForEach(rca.wrappedValue.fishbone.map(\.name), id: \.self) { name in
                    Button(name) { idea.wrappedValue.category = name; sortIdeaIntoFishbone(idea.wrappedValue, rca: rca) }
                }
            } label: {
                Text(idea.wrappedValue.category ?? "Sort…").font(.caption)
            }
            .menuStyle(.borderlessButton).fixedSize()
            Button { idea.wrappedValue.parked.toggle() } label: {
                Image(systemName: idea.wrappedValue.parked ? "arrow.uturn.up" : "moon.zzz")
            }.buttonStyle(.plain).foregroundStyle(.secondary)
                .help(idea.wrappedValue.parked ? "Un-park" : "Park — keep but set aside")
            Button { rca.wrappedValue.brainstorm.removeAll { $0.id == idea.wrappedValue.id } } label: {
                Image(systemName: "xmark.circle.fill")
            }.buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(8)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Stage 3 — 5 Whys

    private func fiveWhysStage(_ rca: Binding<RootCauseAnalysis>) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            stageHeader("Ask “why?” five times",
                        "Start from the problem and keep asking why the previous answer happened. Each answer becomes the next question. Three to five levels usually reaches a root cause you can act on.")
            if rca.wrappedValue.fiveWhys.isEmpty {
                Button { seedFirstWhy(rca) } label: { Label("Start the chain", systemImage: "arrow.down.right.circle") }
                    .buttonStyle(.borderedProminent)
            }
            ForEach(rca.fiveWhys) { $step in
                let i = rca.wrappedValue.fiveWhys.firstIndex { $0.id == step.id } ?? 0
                whyRow(index: i, step: $step, rca: rca)
            }
            if !rca.wrappedValue.fiveWhys.isEmpty {
                HStack {
                    Button { addWhy(rca) } label: { Label("Add another “why”", systemImage: "plus") }
                        .controlSize(.small)
                    if aiAvailable {
                        Button { Task { await aiSuggestWhy(rca) } } label: {
                            if aiBusy { ProgressView().controlSize(.small) }
                            else { Label("Suggest next (AI)", systemImage: "sparkles") }
                        }
                        .controlSize(.small)
                        .disabled(aiBusy)
                        .help("On-device AI proposes the next answer to test — you edit or discard it.")
                    }
                }
            }
            nextButton(to: .fishbone)
        }
    }

    private func whyRow(index i: Int, step: Binding<RCAWhyStep>, rca: Binding<RootCauseAnalysis>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Why #\(i + 1)").font(.caption.weight(.bold)).foregroundStyle(.tint)
                Spacer()
                Button { rca.wrappedValue.fiveWhys.removeAll { $0.id == step.wrappedValue.id } } label: {
                    Image(systemName: "xmark.circle")
                }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
            TextField("Question", text: step.question).textFieldStyle(.roundedBorder).font(.callout.weight(.medium))
            TextField("Because… (this becomes the next question)", text: step.answer, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(1...3)
            TextField("Evidence (optional) — a document number or source", text: step.evidence)
                .textFieldStyle(.roundedBorder).font(.caption)
        }
        .padding(10)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .leading) {
            Rectangle().fill(.tint.opacity(0.5)).frame(width: 3)
        }
    }

    // MARK: Stage 4 — Fishbone

    private func fishboneStage(_ rca: Binding<RootCauseAnalysis>) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            stageHeader("Organise causes on a fishbone",
                        "Sort the plausible causes into the six arms of an Ishikawa diagram. Star the ones you judge probable. The diagram is your cause-and-effect picture of the case.")
            FishboneDiagram(effect: rca.wrappedValue.problemStatement,
                            categories: rca.wrappedValue.fishbone)
                .frame(height: 340)
                .frame(maxWidth: .infinity)
                .background(.quaternary.opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
            ForEach(rca.fishbone) { $cat in
                fishboneCategoryEditor($cat)
            }
            nextButton(to: .conclude)
        }
    }

    private func fishboneCategoryEditor(_ cat: Binding<RCAFishboneCategory>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(cat.wrappedValue.name, systemImage: "fish").font(.callout.weight(.semibold))
                Spacer()
                Button { cat.wrappedValue.causes.append(RCAFishboneCause(text: "")) } label: {
                    Image(systemName: "plus")
                }.buttonStyle(.plain).foregroundStyle(.tint)
            }
            if cat.wrappedValue.causes.isEmpty {
                Text("No causes here yet.").font(.caption).foregroundStyle(.tertiary)
            }
            ForEach(cat.causes) { $cause in
                HStack(spacing: 8) {
                    Button { cause.likely.toggle() } label: {
                        Image(systemName: cause.likely ? "star.fill" : "star")
                            .foregroundStyle(cause.likely ? Color.yellow : Color.secondary)
                    }.buttonStyle(.plain).help("Mark as a probable cause")
                    TextField("Cause", text: $cause.text).textFieldStyle(.plain)
                    Button { cat.wrappedValue.causes.removeAll { $0.id == cause.id } } label: {
                        Image(systemName: "xmark.circle")
                    }.buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Stage 5 — Conclude

    private func concludeStage(_ rca: Binding<RootCauseAnalysis>) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            stageHeader("Reach a conclusion",
                        "State the root cause your analysis supports, the factors that contributed, and what you recommend. Pull from the starred fishbone causes and the end of your 5 Whys.")

            if !starredCauses(rca.wrappedValue).isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Probable causes you starred").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(starredCauses(rca.wrappedValue), id: \.self) { c in
                        Label(c, systemImage: "star.fill").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(.yellow.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }

            Text("Root cause").font(.callout.weight(.semibold))
            TextEditor(text: rca.conclusion.rootCause)
                .font(.body).frame(minHeight: 70)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))

            listEditor(title: "Contributing factors",
                       items: rca.conclusion.contributingFactors,
                       newText: $newFactor, placeholder: "Add a contributing factor")
            listEditor(title: "Recommendations",
                       items: rca.conclusion.recommendations,
                       newText: $newRecommendation, placeholder: "Add a recommendation", numbered: true)

            Text("Summary (for the reader)").font(.callout.weight(.semibold))
            TextEditor(text: rca.conclusion.summary)
                .font(.body).frame(minHeight: 90)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))

            nextButton(to: .report)
        }
    }

    private func listEditor(title: String, items: Binding<[String]>, newText: Binding<String>,
                            placeholder: String, numbered: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.callout.weight(.semibold))
            ForEach(Array(items.wrappedValue.enumerated()), id: \.offset) { idx, _ in
                HStack(spacing: 8) {
                    Image(systemName: numbered ? "\(min(idx + 1, 50)).circle" : "circle.fill")
                        .font(.caption2).foregroundStyle(.secondary)
                    TextField("", text: Binding(get: { items.wrappedValue[idx] },
                                                set: { var a = items.wrappedValue; a[idx] = $0; items.wrappedValue = a }))
                        .textFieldStyle(.plain)
                    Button { var a = items.wrappedValue; a.remove(at: idx); items.wrappedValue = a } label: {
                        Image(systemName: "xmark.circle")
                    }.buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 8) {
                TextField(placeholder, text: newText).textFieldStyle(.roundedBorder)
                    .onSubmit { addToList(items, newText) }
                Button { addToList(items, newText) } label: { Image(systemName: "plus") }
                    .disabled(newText.wrappedValue.trimmed.isEmpty)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Stage 6 — Report + approval

    private func reportStage(_ rca: Binding<RootCauseAnalysis>) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            stageHeader("Report & approval",
                        "Fill the sign-off block, then submit for approval. Once approved, export or print (Save as PDF) and hand it to the recipient. The preview below is the exact document.")

            // Approval controls
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    field("Prepared by", rca.approval.preparedBy)
                    field("Submit to (recipient / authority)", rca.approval.submittedTo)
                }
                approvalActions(rca)
                if rca.wrappedValue.approval.status == .approved || rca.wrappedValue.approval.status == .returned {
                    HStack(spacing: 12) {
                        field("Decision by", rca.approval.approver)
                        field("Decision note", rca.approval.decisionNote)
                    }
                }
            }
            .padding(14)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))

            // Live document preview
            Text("Document preview").font(.callout.weight(.semibold))
            ScrollView {
                Text(RCAReportRenderer.markdown(rca.wrappedValue, generatedAt: Date()))
                    .font(.callout.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            .frame(maxHeight: 380)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))

            HStack(spacing: 10) {
                Button { copyReport(rca.wrappedValue) } label: { Label("Copy", systemImage: "doc.on.doc") }
                Button { showExporter = true } label: { Label("Export Markdown", systemImage: "square.and.arrow.up") }
                #if os(macOS)
                Button { printReport(rca.wrappedValue) } label: { Label("Print / Save as PDF", systemImage: "printer") }
                #endif
            }
        }
    }

    private func approvalActions(_ rca: Binding<RootCauseAnalysis>) -> some View {
        HStack(spacing: 10) {
            statusChip(rca.wrappedValue.approval.status)
            Spacer()
            switch rca.wrappedValue.approval.status {
            case .draft, .returned:
                Button {
                    rca.wrappedValue.approval.status = .pendingApproval
                    rca.wrappedValue.approval.submittedAt = Date()
                } label: { Label("Submit for approval", systemImage: "paperplane") }
                .buttonStyle(.borderedProminent)
                .disabled(!rca.wrappedValue.isComplete(.conclude) || rca.wrappedValue.approval.submittedTo.trimmed.isEmpty)
                .guidance(GuidanceTip("Submit for approval",
                                      what: "Marks the report as pending the recipient's decision and stamps the time. You can still print or export it.",
                                      enabledWhen: "State a root cause (Conclude) and fill “Submit to” first."),
                          enabled: rca.wrappedValue.isComplete(.conclude) && !rca.wrappedValue.approval.submittedTo.trimmed.isEmpty)
            case .pendingApproval:
                Button {
                    rca.wrappedValue.approval.status = .returned
                    rca.wrappedValue.approval.decidedAt = Date()
                } label: { Label("Return", systemImage: "arrow.uturn.left") }
                Button {
                    if rca.wrappedValue.approval.approver.trimmed.isEmpty { rca.wrappedValue.approval.approver = NSFullUserName() }
                    rca.wrappedValue.approval.status = .approved
                    rca.wrappedValue.approval.decidedAt = Date()
                } label: { Label("Approve & sign", systemImage: "checkmark.seal.fill") }
                .buttonStyle(.borderedProminent)
            case .approved:
                Label("Approved — ready to submit", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                Button { rca.wrappedValue.approval.status = .draft } label: { Text("Reopen").font(.caption) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Small pieces

    private func stageHeader(_ title: String, _ blurb: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.title2.weight(.bold))
            Text(blurb).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func field(_ label: String, _ text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(label, text: text).textFieldStyle(.roundedBorder)
        }
    }

    private func nextButton(to next: RootCauseAnalysis.Stage) -> some View {
        HStack {
            Spacer()
            Button { stage = next } label: { Label("Next: \(next.title)", systemImage: "arrow.right") }
                .buttonStyle(.borderedProminent)
        }
        .padding(.top, 4)
    }

    private func statusChip(_ status: RCAApprovalStatus) -> some View {
        let tint: Color = switch status {
        case .draft: .secondary
        case .pendingApproval: .orange
        case .approved: .green
        case .returned: .red
        }
        return Text(status.label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(tint.opacity(0.16), in: Capsule())
            .foregroundStyle(tint)
    }

    // MARK: - Mutations

    private func addIdea(_ rca: Binding<RootCauseAnalysis>) {
        let t = ideaText.trimmed; guard !t.isEmpty else { return }
        rca.wrappedValue.brainstorm.append(RCAIdea(text: t)); ideaText = ""
    }
    private func sortIdeaIntoFishbone(_ idea: RCAIdea, rca: Binding<RootCauseAnalysis>) {
        guard let cat = idea.category,
              let idx = rca.wrappedValue.fishbone.firstIndex(where: { $0.name == cat }) else { return }
        if !rca.wrappedValue.fishbone[idx].causes.contains(where: { $0.text == idea.text }) {
            rca.wrappedValue.fishbone[idx].causes.append(RCAFishboneCause(text: idea.text))
        }
    }
    private func seedFirstWhy(_ rca: Binding<RootCauseAnalysis>) {
        let p = rca.wrappedValue.problemStatement.trimmed
        rca.wrappedValue.fiveWhys = [RCAWhyStep(question: p.isEmpty ? "Why did this happen?" : "Why did this happen: \(p)?")]
    }
    private func addWhy(_ rca: Binding<RootCauseAnalysis>) {
        let last = rca.wrappedValue.fiveWhys.last?.answer.trimmed ?? ""
        let q = last.isEmpty ? "Why?" : "Why did that happen — \(last)?"
        rca.wrappedValue.fiveWhys.append(RCAWhyStep(question: q))
    }
    private func addToList(_ items: Binding<[String]>, _ newText: Binding<String>) {
        let t = newText.wrappedValue.trimmed; guard !t.isEmpty else { return }
        items.wrappedValue.append(t); newText.wrappedValue = ""
    }
    private func starredCauses(_ rca: RootCauseAnalysis) -> [String] {
        rca.fishbone.flatMap { $0.causes }.filter { $0.likely && !$0.text.trimmed.isEmpty }.map(\.text)
    }

    // MARK: - AI assist

    private func aiSuggestCauses(_ rca: Binding<RootCauseAnalysis>) async {
        guard let caps = appState.capabilities else { return }
        aiBusy = true; aiNote = nil
        let existing = rca.wrappedValue.brainstorm.map(\.text)
        let suggestions = await RootCauseAIAssist.suggestCauses(
            problem: rca.wrappedValue.problemStatement, existing: existing, capabilities: caps)
        aiBusy = false
        if suggestions.isEmpty { aiNote = "No suggestions right now — add causes manually, or try again."; return }
        for s in suggestions { rca.wrappedValue.brainstorm.append(RCAIdea(text: s)) }
        aiNote = "Added \(suggestions.count) AI suggestion\(suggestions.count == 1 ? "" : "s") — review, edit or remove each."
    }

    private func aiSuggestWhy(_ rca: Binding<RootCauseAnalysis>) async {
        guard let caps = appState.capabilities else { return }
        aiBusy = true
        let answers = rca.wrappedValue.fiveWhys.map(\.answer).filter { !$0.trimmed.isEmpty }
        let why = await RootCauseAIAssist.suggestNextWhy(
            problem: rca.wrappedValue.problemStatement, answersSoFar: answers, capabilities: caps)
        aiBusy = false
        guard let why else { return }
        let last = answers.last ?? ""
        rca.wrappedValue.fiveWhys.append(RCAWhyStep(question: last.isEmpty ? "Why?" : "Why did that happen — \(last)?", answer: why))
    }

    // MARK: - Report output

    private var activeReport: String {
        guard let b = activeBinding else { return "" }
        return RCAReportRenderer.markdown(b.wrappedValue, generatedAt: Date())
    }
    private var exportFilename: String {
        let t = activeBinding?.wrappedValue.title ?? "investigation"
        return "root-cause-\(t.replacingOccurrences(of: " ", with: "-").lowercased())"
    }
    private func copyReport(_ rca: RootCauseAnalysis) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(RCAReportRenderer.markdown(rca, generatedAt: Date()), forType: .string)
        #endif
    }
    #if os(macOS)
    private func printReport(_ rca: RootCauseAnalysis) {
        let text = RCAReportRenderer.markdown(rca, generatedAt: Date())
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 468, height: 648))
        tv.string = text
        tv.font = NSFont.systemFont(ofSize: 11)
        let op = NSPrintOperation(view: tv)
        op.jobTitle = "Root-Cause Analysis — \(rca.title)"
        op.run()
    }
    #endif
}

// MARK: - Fishbone diagram (Ishikawa) — drawn, not a placeholder

struct FishboneDiagram: View {
    let effect: String
    let categories: [RCAFishboneCategory]

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let spineY = h / 2
            let headX = w - 150
            ZStack {
                // Spine + arrowhead into the effect head
                Path { p in
                    p.move(to: CGPoint(x: 20, y: spineY))
                    p.addLine(to: CGPoint(x: headX, y: spineY))
                }
                .stroke(Color.secondary, lineWidth: 2)

                // Bones
                ForEach(Array(categories.enumerated()), id: \.element.id) { idx, cat in
                    boneView(idx: idx, cat: cat, w: headX, spineY: spineY, h: h)
                }

                // Effect head
                Text(effect.trimmed.isEmpty ? "The effect / problem" : effect)
                    .font(.caption.weight(.bold))
                    .multilineTextAlignment(.center)
                    .padding(8)
                    .frame(width: 140)
                    .background(.tint.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.tint))
                    .position(x: headX + 74, y: spineY)
            }
        }
    }

    private func boneView(idx: Int, cat: RCAFishboneCategory, w: CGFloat, spineY: CGFloat, h: CGFloat) -> some View {
        let count = max(categories.count, 1)
        let usable = w - 60
        let step = usable / CGFloat((count + 1) / 2 + 1)
        let column = idx / 2
        let anchorX = 40 + step * CGFloat(column + 1)
        let up = idx % 2 == 0
        let tipY = up ? spineY - (h / 2 - 24) : spineY + (h / 2 - 24)
        let tipX = anchorX - 46
        let likely = cat.causes.filter { $0.likely && !$0.text.trimmed.isEmpty }.count
        return ZStack {
            Path { p in
                p.move(to: CGPoint(x: anchorX, y: spineY))
                p.addLine(to: CGPoint(x: tipX, y: tipY))
            }
            .stroke(Color.secondary.opacity(0.7), lineWidth: 1.5)

            VStack(spacing: 1) {
                Text(cat.name).font(.caption2.weight(.bold))
                if !cat.causes.isEmpty {
                    Text("\(cat.causes.count) cause\(cat.causes.count == 1 ? "" : "s")\(likely > 0 ? " · \(likely)★" : "")")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(cat.causes.isEmpty ? AnyShapeStyle(.quaternary.opacity(0.4)) : AnyShapeStyle(.tint.opacity(0.14)),
                        in: RoundedRectangle(cornerRadius: 6))
            .position(x: tipX, y: up ? tipY - 8 : tipY + 8)
        }
    }
}

#if DEBUG
#Preview("Fishbone diagram") {
    FishboneDiagram(
        effect: "Claimant's injury date is inconsistent across documents",
        categories: [
            RCAFishboneCategory(name: "People", causes: [RCAFishboneCause(text: "Adjuster transcription error", likely: true)]),
            RCAFishboneCategory(name: "Process", causes: [RCAFishboneCause(text: "No intake verification step", likely: true),
                                                           RCAFishboneCause(text: "Manual re-keying")]),
            RCAFishboneCategory(name: "Policy & Management", causes: []),
            RCAFishboneCategory(name: "Equipment & Tools", causes: [RCAFishboneCause(text: "Legacy claim form")]),
            RCAFishboneCategory(name: "Information & Evidence", causes: [RCAFishboneCause(text: "Conflicting medical records", likely: true)]),
            RCAFishboneCategory(name: "Environment", causes: [])
        ])
    .frame(width: 900, height: 360)
    .padding()
}

#Preview("Reasoning Studio") {
    ReasoningStudioView()
        .environment(AppState())
        .frame(width: 1040, height: 760)
}
#endif
