//
//  ForensicStudioView.swift
//  Kalsmritikosh
//
//  The Forensic Accountant studio (persona studio #4). Real-life stages —
//  Engagement → Materials → Method → Tracing schedule → Findings & opinion —
//  producing the FRCP 26(a)(2)(B) expert report with the Daubert disciplines
//  enforced: method named from the recognized catalog (indirect methods must be
//  justified), every schedule row tied to a source document, findings kept
//  distinct from the opinion, certainty declared.
//

import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

public struct ForensicStudioView: View {
    @AppStorage("kalsmritikosh.fa.store") private var storeBlob = ""
    @State private var engagements: [ForensicEngagement] = []
    @State private var loaded = false
    @State private var activeID: UUID?
    @State private var stage: ForensicEngagement.Stage = .engagement
    @State private var newFinding = ""
    @State private var newLimitation = ""
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
           let d = try? JSONDecoder().decode([ForensicEngagement].self, from: data) { engagements = d }
    }
    private func persist() {
        if let data = try? JSONEncoder().encode(engagements), let s = String(data: data, encoding: .utf8) { storeBlob = s }
    }
    private var activeBinding: Binding<ForensicEngagement>? {
        guard let id = activeID, let idx = engagements.firstIndex(where: { $0.id == id }) else { return nil }
        return Binding(get: { engagements[idx] },
                       set: { engagements[idx] = $0; engagements[idx].updatedAt = Date(); persist() })
    }

    // MARK: List

    private var listScreen: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Forensic Accounting Studio", systemImage: "dollarsign.arrow.circlepath")
                        .font(.largeTitle.weight(.bold))
                    Text("Follow the money the way a testifying expert must: name the tracing method, list the materials relied upon, build a schedule where every amount drills to its source document, and produce the FRCP 26(a)(2)(B) expert report — findings distinct from opinion, to a reasonable degree of professional certainty.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text(JurisdictionNotice.studio(instrument: "US FRCP 26(a)(2)(B) and Daubert"))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 10) {
                    Button { newEngagement() } label: { Label("New engagement", systemImage: "plus.circle.fill") }
                        .buttonStyle(.borderedProminent)
                        .guidance(GuidanceTip("New engagement",
                                              what: "Starts a forensic engagement: scope, materials relied upon, a named tracing method, the sourced schedule, and the expert report."))
                    Button { loadSample() } label: { Label("Load a worked example", systemImage: "wand.and.stars") }
                }
                if engagements.isEmpty {
                    ContentUnavailableView("No engagements yet", systemImage: "dollarsign.arrow.circlepath",
                                           description: Text("Create one, or load the worked example to see the finished report."))
                        .frame(maxWidth: .infinity, minHeight: 200)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 14)], spacing: 14) {
                        ForEach(engagements.sorted { $0.updatedAt > $1.updatedAt }) { e in card(e) }
                    }
                }
            }
            .padding(24).frame(maxWidth: 940, alignment: .leading).frame(maxWidth: .infinity)
        }
        .navigationTitle("Forensic Accounting")
    }

    private func card(_ e: ForensicEngagement) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(e.title.trimmed.isEmpty ? "Untitled" : e.title).font(.headline).lineLimit(1)
            Text(e.scope.trimmed.isEmpty ? "No scope yet." : e.scope)
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            ProgressView(value: e.completionFraction).tint(.green)
            HStack {
                Text("\(e.schedule.count) transaction(s) · \(e.method?.name ?? "no method")")
                    .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                Spacer()
                Button(role: .destructive) { engagements.removeAll { $0.id == e.id }; persist() } label: { Image(systemName: "trash") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                Button("Open") { activeID = e.id; stage = firstIncomplete(e) }
                    .buttonStyle(.bordered).controlSize(.small)
            }
        }
        .padding(16).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }

    private func newEngagement() {
        var e = ForensicEngagement(title: "New engagement", now: Date())
        e.expert = NSFullUserName()
        StudioAudit.record(&e.history, "Created")
        engagements.append(e); persist(); activeID = e.id; stage = .engagement
    }
    private func loadSample() {
        let e = ForensicEngagement.sample(now: Date())
        engagements.append(e); persist(); activeID = e.id; stage = .opinion
    }
    private func firstIncomplete(_ e: ForensicEngagement) -> ForensicEngagement.Stage {
        ForensicEngagement.Stage.allCases.first { !e.isComplete($0) } ?? .opinion
    }

    // MARK: Studio

    private func studio(_ f: Binding<ForensicEngagement>) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { activeID = nil } label: { Label("All engagements", systemImage: "chevron.left").font(.caption) }
                    .buttonStyle(.plain).foregroundStyle(.tint)
                TextField("Engagement title", text: f.title).textFieldStyle(.plain).font(.headline).frame(maxWidth: 360)
                Spacer()
                Button { showExporter = true } label: { Label("Export", systemImage: "square.and.arrow.up") }.controlSize(.small)
                #if os(macOS)
                Button { printReport(f.wrappedValue) } label: { Label("Print", systemImage: "printer") }.controlSize(.small)
                #endif
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            Divider()
            stepper(f.wrappedValue)
            Divider()
            ScrollView {
                stageContent(f)
                    .padding(24).frame(maxWidth: 1000, alignment: .leading).frame(maxWidth: .infinity, alignment: .top)
            }
        }
    }

    private func stepper(_ e: ForensicEngagement) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(ForensicEngagement.Stage.allCases.enumerated()), id: \.element) { idx, s in
                Button { stage = s } label: {
                    VStack(spacing: 4) {
                        ZStack {
                            Circle().fill(stage == s ? AnyShapeStyle(.tint) : (e.isComplete(s) ? AnyShapeStyle(.green.opacity(0.9)) : AnyShapeStyle(.quaternary)))
                                .frame(width: 30, height: 30)
                            Image(systemName: e.isComplete(s) && stage != s ? "checkmark" : s.systemImage)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(stage == s || e.isComplete(s) ? Color.white : Color.secondary)
                        }
                        Text(s.title).font(.caption2.weight(stage == s ? .bold : .regular))
                            .foregroundStyle(stage == s ? .primary : .secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                if idx < ForensicEngagement.Stage.allCases.count - 1 {
                    Rectangle().fill(.quaternary).frame(height: 2).frame(maxWidth: 40)
                }
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }

    @ViewBuilder
    private func stageContent(_ f: Binding<ForensicEngagement>) -> some View {
        switch stage {
        case .engagement: engagementStage(f)
        case .materials: materialsStage(f)
        case .method: methodStage(f)
        case .schedule: scheduleStage(f)
        case .opinion: opinionStage(f)
        }
    }

    private func engagementStage(_ f: Binding<ForensicEngagement>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            header("Engagement & qualifications", "What you were asked to determine, for whom — and the qualifications the report must state.")
            TextEditor(text: f.scope).font(.body).frame(minHeight: 70)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
            HStack(spacing: 12) {
                field("Expert", f.expert)
                field("Prepared for", f.preparedFor)
            }
            Text("Qualifications (26(a)(2)(B))").font(.callout.weight(.semibold))
            TextField("Credentials, experience, prior testimony…", text: f.qualifications, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(2...3)
            next(.materials)
        }
    }

    private func materialsStage(_ f: Binding<ForensicEngagement>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            header("Materials relied upon", "Every record the analysis rests on — the list opposing counsel will test first.")
            ForEach(f.materials) { $m in
                HStack(spacing: 8) {
                    TextField("What it is", text: $m.descriptionText).textFieldStyle(.roundedBorder)
                    TextField("source / producing party", text: $m.source).textFieldStyle(.roundedBorder).frame(width: 260)
                    Button { f.wrappedValue.materials.removeAll { $0.id == m.id } } label: { Image(systemName: "xmark.circle") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            Button { f.wrappedValue.materials.append(FAMaterial()) } label: { Label("Add material", systemImage: "plus") }
            next(.method)
        }
    }

    private func methodStage(_ f: Binding<ForensicEngagement>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            header("Methodology — named, from the recognized methods",
                   FundsTracingMethods.disciplineNote)
            Picker("Tracing method", selection: f.methodID) {
                Text("Choose…").tag("")
                ForEach(FundsTracingMethods.methods) { m in
                    Text("\(m.family) — \(m.name)").tag(m.id)
                }
            }
            .frame(maxWidth: 520)
            if let m = f.wrappedValue.method {
                Text(m.detail).font(.caption).foregroundStyle(.secondary)
                if m.family == "Indirect" {
                    Text("Why direct tracing isn't possible (required for an indirect method)").font(.callout.weight(.semibold))
                    TextField("Justification…", text: f.methodJustification, axis: .vertical)
                        .textFieldStyle(.roundedBorder).lineLimit(1...3)
                }
            }
            next(.schedule)
        }
    }

    private func scheduleStage(_ f: Binding<ForensicEngagement>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            header("Tracing schedule", "One row per movement of money. The rule: every amount drills to its source document — a row without a source is incomplete.")
            ForEach(f.schedule) { $t in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        TextField("yyyy-mm-dd", text: $t.date).textFieldStyle(.roundedBorder).frame(width: 110)
                        TextField("Description", text: $t.descriptionText).textFieldStyle(.roundedBorder)
                        TextField("Amount", text: $t.amount).textFieldStyle(.roundedBorder).frame(width: 110)
                        Button { f.wrappedValue.schedule.removeAll { $0.id == t.id } } label: { Image(systemName: "xmark.circle") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 8) {
                        TextField("Payer", text: $t.payer).textFieldStyle(.roundedBorder)
                        TextField("Payee", text: $t.payee).textFieldStyle(.roundedBorder)
                        TextField("Account", text: $t.account).textFieldStyle(.roundedBorder).frame(width: 120)
                    }
                    TextField("Source document (required)", text: $t.sourceDoc).textFieldStyle(.roundedBorder)
                    if !t.isComplete {
                        Label("Needs date, description, amount, and a source document.", systemImage: "exclamationmark.circle")
                            .font(.caption2).foregroundStyle(.orange)
                    }
                }
                .padding(10).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            }
            Button { f.wrappedValue.schedule.append(FATransaction()) } label: { Label("Add transaction", systemImage: "plus") }
            Text("Schedule total: $\(String(format: "%.2f", f.wrappedValue.scheduleTotal))")
                .font(.callout.weight(.semibold))
            next(.opinion)
        }
    }

    private func opinionStage(_ f: Binding<ForensicEngagement>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            header("Findings & opinion — kept distinct",
                   "Findings are factual observations from the schedule; the opinion is your professional judgement drawn from them, held to a reasonable degree of professional certainty.")
            Text("Findings of fact").font(.callout.weight(.semibold))
            ForEach(Array(f.wrappedValue.findings.enumerated()), id: \.offset) { idx, _ in
                HStack(spacing: 8) {
                    Text("\(idx + 1).").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                    TextField("", text: Binding(get: { f.wrappedValue.findings[idx] },
                                                set: { var a = f.wrappedValue.findings; a[idx] = $0; f.wrappedValue.findings = a }))
                        .textFieldStyle(.plain)
                    Button { var a = f.wrappedValue.findings; a.remove(at: idx); f.wrappedValue.findings = a } label: { Image(systemName: "xmark.circle") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 8) {
                TextField("Add a finding", text: $newFinding).textFieldStyle(.roundedBorder)
                    .onSubmit { addFinding(f) }
                Button { addFinding(f) } label: { Image(systemName: "plus") }.disabled(newFinding.trimmed.isEmpty)
            }
            Text("Opinion").font(.callout.weight(.semibold))
            TextEditor(text: f.opinion).font(.body).frame(minHeight: 80)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
            Toggle("This opinion is held to a reasonable degree of professional certainty", isOn: f.certaintyDeclared)
            Text("Limitations").font(.callout.weight(.semibold))
            ForEach(Array(f.wrappedValue.limitations.enumerated()), id: \.offset) { idx, _ in
                HStack(spacing: 8) {
                    Image(systemName: "circle.fill").font(.system(size: 5)).foregroundStyle(.secondary)
                    TextField("", text: Binding(get: { f.wrappedValue.limitations[idx] },
                                                set: { var a = f.wrappedValue.limitations; a[idx] = $0; f.wrappedValue.limitations = a }))
                        .textFieldStyle(.plain)
                    Button { var a = f.wrappedValue.limitations; a.remove(at: idx); f.wrappedValue.limitations = a } label: { Image(systemName: "xmark.circle") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 8) {
                TextField("Add a limitation (missing records, offered no opinion on…)", text: $newLimitation).textFieldStyle(.roundedBorder)
                    .onSubmit { addLimitation(f) }
                Button { addLimitation(f) } label: { Image(systemName: "plus") }.disabled(newLimitation.trimmed.isEmpty)
            }
            Text("Report preview").font(.callout.weight(.semibold))
            ScrollView([.horizontal, .vertical]) {
                Text(FAReportRenderer.markdown(f.wrappedValue, generatedAt: Date()))
                    .font(.callout.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(16)
            }
            .frame(maxHeight: 360)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
            HStack(spacing: 10) {
                Button { copyReport(f.wrappedValue) } label: { Label("Copy", systemImage: "doc.on.doc") }
                Button { showExporter = true } label: { Label("Export Markdown", systemImage: "square.and.arrow.up") }
                #if os(macOS)
                Button { printReport(f.wrappedValue) } label: { Label("Print / Save as PDF", systemImage: "printer") }
                #endif
            }
        }
    }

    // MARK: Small pieces

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
    private func next(_ s: ForensicEngagement.Stage) -> some View {
        HStack { Spacer(); Button { stage = s } label: { Label("Next: \(s.title)", systemImage: "arrow.right") }.buttonStyle(.borderedProminent) }
    }
    private func addFinding(_ f: Binding<ForensicEngagement>) {
        let t = newFinding.trimmed; guard !t.isEmpty else { return }
        f.wrappedValue.findings.append(t); newFinding = ""
    }
    private func addLimitation(_ f: Binding<ForensicEngagement>) {
        let t = newLimitation.trimmed; guard !t.isEmpty else { return }
        f.wrappedValue.limitations.append(t); newLimitation = ""
    }

    /// Every deliverable that LEAVES the studio (copy/print/export) carries a
    /// signed seal — content hash, honest stage completion, signer key.
    private func sealed(_ e: ForensicEngagement) -> String {
        let stages = ForensicEngagement.Stage.allCases
        return StudioDeliverableSeal.sealedReport(
            studio: "Forensic Accountant", title: e.title,
            report: FAReportRenderer.markdown(e, generatedAt: Date()),
            stagesComplete: stages.filter { e.isComplete($0) }.count,
            stagesTotal: stages.count, at: Date())
    }
    private var activeReport: String {
        guard let b = activeBinding else { return "" }
        return sealed(b.wrappedValue)
    }
    private var exportFilename: String {
        "expert-report-\((activeBinding?.wrappedValue.title ?? "engagement").replacingOccurrences(of: " ", with: "-").lowercased())"
    }
    private func copyReport(_ e: ForensicEngagement) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sealed(e), forType: .string)
        #endif
    }
    #if os(macOS)
    private func printReport(_ e: ForensicEngagement) {
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 468, height: 648))
        tv.string = sealed(e)
        tv.font = NSFont.monospacedSystemFont(ofSize: 9, weight: .regular)
        let op = NSPrintOperation(view: tv); op.jobTitle = "Expert Report — \(e.title)"; op.run()
    }
    #endif
}

#if DEBUG
#Preview("Forensic Studio") {
    ForensicStudioView().frame(width: 1040, height: 780)
}
#endif
