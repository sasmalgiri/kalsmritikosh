//
//  WorkplaceStudioView.swift
//  Kalsmritikosh
//
//  The Workplace / HR Investigation studio — persona studio exemplar #1. Walks
//  the REAL-LIFE stages in the real order (Mandate → Allegations → Evidence →
//  Credibility → Findings → Report) and produces the exact deliverable a
//  workplace investigator signs: the recognized report format with classified
//  findings on the balance of probabilities and procedural-fairness
//  confirmations. Persists on-device as JSON.
//

import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

public struct WorkplaceStudioView: View {
    @AppStorage("kalsmritikosh.wi.store") private var storeBlob = ""
    @State private var cases: [WorkplaceInvestigation] = []
    @State private var loaded = false
    @State private var activeID: UUID?
    @State private var stage: WorkplaceInvestigation.Stage = .mandate

    @State private var newAllegation = ""
    @State private var newEvidence = ""
    @State private var newPerson = ""
    @State private var newRecommendation = ""
    @State private var showExporter = false

    public init() {}

    public var body: some View {
        Group {
            if let binding = activeBinding { studio(binding) } else { listScreen }
        }
        .onAppear(perform: load)
        .fileExporter(isPresented: $showExporter,
                      document: RCAMarkdownDocument(text: activeReport),
                      contentType: .plainText,
                      defaultFilename: exportFilename) { _ in }
    }

    // MARK: Persistence

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let data = storeBlob.data(using: .utf8),
           let d = try? JSONDecoder().decode([WorkplaceInvestigation].self, from: data) { cases = d }
    }
    private func persist() {
        if let data = try? JSONEncoder().encode(cases), let s = String(data: data, encoding: .utf8) { storeBlob = s }
    }
    private var activeBinding: Binding<WorkplaceInvestigation>? {
        guard let id = activeID, let idx = cases.firstIndex(where: { $0.id == id }) else { return nil }
        return Binding(get: { cases[idx] },
                       set: { cases[idx] = $0; cases[idx].updatedAt = Date(); persist() })
    }

    // MARK: List

    private var listScreen: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("HR Investigation Studio", systemImage: "person.2.badge.gearshape")
                        .font(.largeTitle.weight(.bold))
                    Text("Run a workplace investigation the way it's really done — mandate, allegations framed as questions, evidence, credibility, classified findings on the balance of probabilities — and produce the exact report an investigator signs.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 10) {
                    Button { newCase() } label: { Label("New investigation", systemImage: "plus.circle.fill") }
                        .buttonStyle(.borderedProminent)
                        .guidance(GuidanceTip("New investigation",
                                              what: "Starts a workplace investigation through the real-life stages: mandate, allegations, evidence, credibility, findings, report."))
                    Button { loadSample() } label: { Label("Load a worked example", systemImage: "wand.and.stars") }
                }
                if cases.isEmpty {
                    ContentUnavailableView("No investigations yet", systemImage: "person.2.badge.gearshape",
                                           description: Text("Create one, or load the worked example to see the finished report."))
                        .frame(maxWidth: .infinity, minHeight: 200)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 14)], spacing: 14) {
                        ForEach(cases.sorted { $0.updatedAt > $1.updatedAt }) { c in card(c) }
                    }
                }
            }
            .padding(24).frame(maxWidth: 940, alignment: .leading).frame(maxWidth: .infinity)
        }
        .navigationTitle("HR Investigation")
    }

    private func card(_ c: WorkplaceInvestigation) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(c.title.trimmed.isEmpty ? "Untitled" : c.title).font(.headline).lineLimit(1)
            Text(c.mandate.trimmed.isEmpty ? "No mandate yet." : c.mandate)
                .font(.caption).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            ProgressView(value: c.completionFraction).tint(.green)
            HStack {
                Text("\(c.allegations.count) allegation(s) · \(c.evidence.count) evidence")
                    .font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button(role: .destructive) { cases.removeAll { $0.id == c.id }; persist() } label: { Image(systemName: "trash") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                Button("Open") { activeID = c.id; stage = firstIncomplete(c) }
                    .buttonStyle(.bordered).controlSize(.small)
            }
        }
        .padding(16).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }

    private func newCase() {
        var c = WorkplaceInvestigation(title: "New investigation", now: Date())
        c.investigator = NSFullUserName()
        cases.append(c); persist(); activeID = c.id; stage = .mandate
    }
    private func loadSample() {
        let c = WorkplaceInvestigation.sample(now: Date())
        cases.append(c); persist(); activeID = c.id; stage = .report
    }
    private func firstIncomplete(_ c: WorkplaceInvestigation) -> WorkplaceInvestigation.Stage {
        WorkplaceInvestigation.Stage.allCases.first { !c.isComplete($0) } ?? .report
    }

    // MARK: Studio shell

    private func studio(_ w: Binding<WorkplaceInvestigation>) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { activeID = nil } label: { Label("All investigations", systemImage: "chevron.left").font(.caption) }
                    .buttonStyle(.plain).foregroundStyle(.tint)
                TextField("Case title", text: w.title).textFieldStyle(.plain).font(.headline).frame(maxWidth: 360)
                Spacer()
                Button { showExporter = true } label: { Label("Export", systemImage: "square.and.arrow.up") }.controlSize(.small)
                #if os(macOS)
                Button { printReport(w.wrappedValue) } label: { Label("Print", systemImage: "printer") }.controlSize(.small)
                #endif
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            Divider()
            stepper(w.wrappedValue)
            Divider()
            ScrollView {
                stageContent(w)
                    .padding(24).frame(maxWidth: 900, alignment: .leading).frame(maxWidth: .infinity, alignment: .top)
            }
        }
    }

    private func stepper(_ c: WorkplaceInvestigation) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(WorkplaceInvestigation.Stage.allCases.enumerated()), id: \.element) { idx, s in
                Button { stage = s } label: {
                    VStack(spacing: 4) {
                        ZStack {
                            Circle().fill(stage == s ? AnyShapeStyle(.tint) : (c.isComplete(s) ? AnyShapeStyle(.green.opacity(0.9)) : AnyShapeStyle(.quaternary)))
                                .frame(width: 30, height: 30)
                            Image(systemName: c.isComplete(s) && stage != s ? "checkmark" : s.systemImage)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(stage == s || c.isComplete(s) ? Color.white : Color.secondary)
                        }
                        Text(s.title).font(.caption2.weight(stage == s ? .bold : .regular))
                            .foregroundStyle(stage == s ? .primary : .secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                if idx < WorkplaceInvestigation.Stage.allCases.count - 1 {
                    Rectangle().fill(.quaternary).frame(height: 2).frame(maxWidth: 40)
                }
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }

    @ViewBuilder
    private func stageContent(_ w: Binding<WorkplaceInvestigation>) -> some View {
        switch stage {
        case .mandate: mandateStage(w)
        case .allegations: allegationsStage(w)
        case .evidence: evidenceStage(w)
        case .credibility: credibilityStage(w)
        case .findings: findingsStage(w)
        case .report: reportStage(w)
        }
    }

    // MARK: Stages (the real-life order)

    private func mandateStage(_ w: Binding<WorkplaceInvestigation>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            header("Mandate / terms of reference",
                   "Who commissioned the investigation, and exactly what you are to determine. Findings must stay inside this mandate.")
            TextEditor(text: w.mandate).font(.body).frame(minHeight: 90)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
            HStack(spacing: 12) {
                field("Investigator", w.investigator)
                field("Submit to", w.submittedTo)
            }
            Toggle("The mandate authorises recommendations", isOn: w.recommendationsAuthorised)
                .help("Real-life rule: recommend outcomes ONLY if your terms of reference authorise it — otherwise the report omits them.")
            next(.allegations)
        }
    }

    private func allegationsStage(_ w: Binding<WorkplaceInvestigation>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            header("Allegations — framed as questions",
                   "State each allegation as a specific, answerable question (\u{201C}Did X …?\u{201D}) and name the policy it engages. Describe behaviour, not labels.")
            ForEach(w.allegations) { $a in
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Did …?", text: $a.question).textFieldStyle(.roundedBorder).font(.callout.weight(.medium))
                    TextField("Policy / rule engaged", text: $a.policy).textFieldStyle(.roundedBorder).font(.caption)
                    HStack {
                        Spacer()
                        Button { w.wrappedValue.allegations.removeAll { $0.id == a.id } } label: { Image(systemName: "xmark.circle") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
                .padding(10).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            }
            HStack(spacing: 8) {
                TextField("Add an allegation as a question", text: $newAllegation).textFieldStyle(.roundedBorder)
                    .onSubmit { addAllegation(w) }
                Button { addAllegation(w) } label: { Image(systemName: "plus") }
                    .disabled(newAllegation.trimmed.isEmpty)
            }
            next(.evidence)
        }
    }

    private func evidenceStage(_ w: Binding<WorkplaceInvestigation>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            header("Evidence & interviews",
                   "Record every document and interview considered, and describe your methodology — interview the respondent LAST, with the allegations put in full.")
            ForEach(w.evidence) { $e in
                HStack(spacing: 8) {
                    TextField("What it is", text: $e.descriptionText).textFieldStyle(.plain)
                    TextField("source", text: $e.source).textFieldStyle(.plain).font(.caption).frame(width: 170)
                    TextField("yyyy-mm-dd", text: $e.date).textFieldStyle(.plain).font(.caption).frame(width: 90)
                    Button { w.wrappedValue.evidence.removeAll { $0.id == e.id } } label: { Image(systemName: "xmark.circle") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
                .padding(8).background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
            }
            HStack(spacing: 8) {
                TextField("Add evidence or an interview", text: $newEvidence).textFieldStyle(.roundedBorder)
                    .onSubmit { addEvidence(w) }
                Button { addEvidence(w) } label: { Image(systemName: "plus") }.disabled(newEvidence.trimmed.isEmpty)
            }
            Text("Methodology").font(.callout.weight(.semibold))
            TextEditor(text: w.methodologyNote).font(.body).frame(minHeight: 70)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
            next(.credibility)
        }
    }

    private func credibilityStage(_ w: Binding<WorkplaceInvestigation>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            header("Credibility assessment",
                   "Where accounts conflict, assess each person's credibility on the recognized factors: plausibility, corroboration, consistency, motive to fabricate.")
            ForEach(w.credibility) { $c in
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Person", text: $c.person).textFieldStyle(.roundedBorder).font(.callout.weight(.medium))
                    TextField("Reasoned assessment", text: $c.assessment, axis: .vertical)
                        .textFieldStyle(.roundedBorder).lineLimit(1...3)
                }
                .padding(8).background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
            }
            HStack(spacing: 8) {
                TextField("Add a person to assess", text: $newPerson).textFieldStyle(.roundedBorder)
                    .onSubmit { addCredibility(w) }
                Button { addCredibility(w) } label: { Image(systemName: "plus") }.disabled(newPerson.trimmed.isEmpty)
            }
            next(.findings)
        }
    }

    private func findingsStage(_ w: Binding<WorkplaceInvestigation>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            header("Findings — balance of probabilities",
                   "Classify each allegation and give the reasoning as \u{201C}because X, supported by Y\u{201D}. \(FindingClassifications.disciplineNote)")
            ForEach(w.allegations) { $a in
                VStack(alignment: .leading, spacing: 6) {
                    Text(a.question).font(.callout.weight(.semibold))
                    TextField("Respondent's response", text: $a.respondentResponse, axis: .vertical)
                        .textFieldStyle(.roundedBorder).lineLimit(1...2).font(.caption)
                    Picker("Finding", selection: $a.finding) {
                        Text("Not yet classified").tag(Optional<FindingClassification>.none)
                        ForEach(FindingClassification.allCases, id: \.self) { Text($0.label).tag(Optional($0)) }
                    }
                    .frame(maxWidth: 320)
                    if let f = a.finding { Text(f.detail).font(.caption2).foregroundStyle(.secondary) }
                    TextField("Because X, supported by Y…", text: $a.reasoning, axis: .vertical)
                        .textFieldStyle(.roundedBorder).lineLimit(2...4)
                }
                .padding(10).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            }
            next(.report)
        }
    }

    private func reportStage(_ w: Binding<WorkplaceInvestigation>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            header("Report & fairness",
                   "Confirm procedural fairness, add recommendations only if your mandate authorises them, and export the signed report.")
            Toggle("The respondent was given notice of the allegations", isOn: w.noticeGiven)
            Toggle("The respondent had a fair opportunity to respond before findings", isOn: w.opportunityToRespond)
            if !(w.wrappedValue.noticeGiven && w.wrappedValue.opportunityToRespond) {
                Label("A finding can be right on the evidence yet fail if the process was unfair — confirm both fairness steps.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            if w.wrappedValue.recommendationsAuthorised {
                Text("Recommendations (authorised by the mandate)").font(.callout.weight(.semibold))
                ForEach(w.recommendations) { $r in
                    HStack(spacing: 8) {
                        TextField("Recommendation", text: $r.text).textFieldStyle(.plain)
                        Button { w.wrappedValue.recommendations.removeAll { $0.id == r.id } } label: { Image(systemName: "xmark.circle") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 8) {
                    TextField("Add a recommendation", text: $newRecommendation).textFieldStyle(.roundedBorder)
                        .onSubmit { addRecommendation(w) }
                    Button { addRecommendation(w) } label: { Image(systemName: "plus") }.disabled(newRecommendation.trimmed.isEmpty)
                }
            } else {
                Text("The mandate does not authorise recommendations — the report will state that they are omitted.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Report preview").font(.callout.weight(.semibold))
            ScrollView {
                Text(WIReportRenderer.markdown(w.wrappedValue, generatedAt: Date()))
                    .font(.callout.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(16)
            }
            .frame(maxHeight: 360)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
            HStack(spacing: 10) {
                Button { copyReport(w.wrappedValue) } label: { Label("Copy", systemImage: "doc.on.doc") }
                Button { showExporter = true } label: { Label("Export Markdown", systemImage: "square.and.arrow.up") }
                #if os(macOS)
                Button { printReport(w.wrappedValue) } label: { Label("Print / Save as PDF", systemImage: "printer") }
                #endif
            }
        }
    }

    // MARK: Small pieces + mutations

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
    private func next(_ s: WorkplaceInvestigation.Stage) -> some View {
        HStack { Spacer(); Button { stage = s } label: { Label("Next: \(s.title)", systemImage: "arrow.right") }.buttonStyle(.borderedProminent) }
    }
    private func addAllegation(_ w: Binding<WorkplaceInvestigation>) {
        let t = newAllegation.trimmed; guard !t.isEmpty else { return }
        w.wrappedValue.allegations.append(WIAllegation(question: t)); newAllegation = ""
    }
    private func addEvidence(_ w: Binding<WorkplaceInvestigation>) {
        let t = newEvidence.trimmed; guard !t.isEmpty else { return }
        w.wrappedValue.evidence.append(WIEvidence(descriptionText: t)); newEvidence = ""
    }
    private func addCredibility(_ w: Binding<WorkplaceInvestigation>) {
        let t = newPerson.trimmed; guard !t.isEmpty else { return }
        w.wrappedValue.credibility.append(WICredibility(person: t)); newPerson = ""
    }
    private func addRecommendation(_ w: Binding<WorkplaceInvestigation>) {
        let t = newRecommendation.trimmed; guard !t.isEmpty else { return }
        w.wrappedValue.recommendations.append(WIRecommendation(text: t)); newRecommendation = ""
    }

    private var activeReport: String {
        guard let b = activeBinding else { return "" }
        return WIReportRenderer.markdown(b.wrappedValue, generatedAt: Date())
    }
    private var exportFilename: String {
        "hr-investigation-\((activeBinding?.wrappedValue.title ?? "report").replacingOccurrences(of: " ", with: "-").lowercased())"
    }
    private func copyReport(_ w: WorkplaceInvestigation) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(WIReportRenderer.markdown(w, generatedAt: Date()), forType: .string)
        #endif
    }
    #if os(macOS)
    private func printReport(_ w: WorkplaceInvestigation) {
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 468, height: 648))
        tv.string = WIReportRenderer.markdown(w, generatedAt: Date())
        tv.font = NSFont.systemFont(ofSize: 11)
        let op = NSPrintOperation(view: tv); op.jobTitle = "Workplace Investigation — \(w.title)"; op.run()
    }
    #endif
}

#if DEBUG
#Preview("HR Investigation Studio") {
    WorkplaceStudioView().frame(width: 1040, height: 760)
}
#endif
