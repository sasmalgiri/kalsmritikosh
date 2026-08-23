//
//  SIUStudioView.swift
//  Kalsmritikosh
//
//  The SIU studio (persona studio #3). Walks the real-life stages — Claim →
//  Red flags (from the recognized indicator taxonomy) → Investigation →
//  Discrepancies → Disposition — and produces the exact SIU investigation /
//  referral report a unit files, with the regulatory disciplines enforced:
//  indicators are never proof, external referral requires the good-faith
//  confirmation, and returning to claims still shows the work.
//

import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

public struct SIUStudioView: View {
    @AppStorage("kalsmritikosh.siu.store") private var storeBlob = ""
    @State private var referrals: [SIUReferral] = []
    @State private var loaded = false
    @State private var activeID: UUID?
    @State private var stage: SIUReferral.Stage = .claim
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
           let d = try? JSONDecoder().decode([SIUReferral].self, from: data) { referrals = d }
    }
    private func persist() {
        if let data = try? JSONEncoder().encode(referrals), let s = String(data: data, encoding: .utf8) { storeBlob = s }
    }
    private var activeBinding: Binding<SIUReferral>? {
        guard let id = activeID, let idx = referrals.firstIndex(where: { $0.id == id }) else { return nil }
        return Binding(get: { referrals[idx] },
                       set: { referrals[idx] = $0; referrals[idx].updatedAt = Date(); persist() })
    }

    // MARK: List

    private var listScreen: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("SIU Studio", systemImage: "shield.lefthalf.filled")
                        .font(.largeTitle.weight(.bold))
                    Text("Work a referred claim the way an SIU really does: record red flags against objective criteria (indicators, never proof), build the loss chronology, document the investigation, preserve discrepancies, and file the exact report — whether it returns to claims or refers out.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 10) {
                    Button { newReferral() } label: { Label("New claim file", systemImage: "plus.circle.fill") }
                        .buttonStyle(.borderedProminent)
                        .guidance(GuidanceTip("New claim file",
                                              what: "Starts an SIU file: claim identification, red flags against written criteria, chronology, investigation steps, discrepancies, and the disposition report."))
                    Button { loadSample() } label: { Label("Load a worked example", systemImage: "wand.and.stars") }
                }
                if referrals.isEmpty {
                    ContentUnavailableView("No claim files yet", systemImage: "shield.lefthalf.filled",
                                           description: Text("Create one, or load the worked example to see the finished report."))
                        .frame(maxWidth: .infinity, minHeight: 200)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 14)], spacing: 14) {
                        ForEach(referrals.sorted { $0.updatedAt > $1.updatedAt }) { r in card(r) }
                    }
                }
            }
            .padding(24).frame(maxWidth: 940, alignment: .leading).frame(maxWidth: .infinity)
        }
        .navigationTitle("SIU")
    }

    private func card(_ r: SIUReferral) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(r.title.trimmed.isEmpty ? "Untitled" : r.title).font(.headline).lineLimit(1)
            Text("\(r.claimNumber.isEmpty ? "No claim no." : r.claimNumber) · \(r.redFlags.count) red flag(s) · \(r.disposition?.label ?? "no disposition")")
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            ProgressView(value: r.completionFraction).tint(.green)
            HStack {
                Text("Updated \(r.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button(role: .destructive) { referrals.removeAll { $0.id == r.id }; persist() } label: { Image(systemName: "trash") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                Button("Open") { activeID = r.id; stage = firstIncomplete(r) }
                    .buttonStyle(.bordered).controlSize(.small)
            }
        }
        .padding(16).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }

    private func newReferral() {
        var r = SIUReferral(title: "New claim file", now: Date())
        r.investigator = NSFullUserName()
        StudioAudit.record(&r.history, "Created")
        referrals.append(r); persist(); activeID = r.id; stage = .claim
    }
    private func loadSample() {
        let r = SIUReferral.sample(now: Date())
        referrals.append(r); persist(); activeID = r.id; stage = .disposition
    }
    private func firstIncomplete(_ r: SIUReferral) -> SIUReferral.Stage {
        SIUReferral.Stage.allCases.first { !r.isComplete($0) } ?? .disposition
    }

    // MARK: Studio

    private func studio(_ r: Binding<SIUReferral>) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { activeID = nil } label: { Label("All claim files", systemImage: "chevron.left").font(.caption) }
                    .buttonStyle(.plain).foregroundStyle(.tint)
                TextField("File title", text: r.title).textFieldStyle(.plain).font(.headline).frame(maxWidth: 360)
                Spacer()
                Button { showExporter = true } label: { Label("Export", systemImage: "square.and.arrow.up") }.controlSize(.small)
                #if os(macOS)
                Button { printReport(r.wrappedValue) } label: { Label("Print", systemImage: "printer") }.controlSize(.small)
                #endif
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            Divider()
            stepper(r.wrappedValue)
            Divider()
            ScrollView {
                stageContent(r)
                    .padding(24).frame(maxWidth: 980, alignment: .leading).frame(maxWidth: .infinity, alignment: .top)
            }
        }
    }

    private func stepper(_ r: SIUReferral) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(SIUReferral.Stage.allCases.enumerated()), id: \.element) { idx, s in
                Button { stage = s } label: {
                    VStack(spacing: 4) {
                        ZStack {
                            Circle().fill(stage == s ? AnyShapeStyle(.tint) : (r.isComplete(s) ? AnyShapeStyle(.green.opacity(0.9)) : AnyShapeStyle(.quaternary)))
                                .frame(width: 30, height: 30)
                            Image(systemName: r.isComplete(s) && stage != s ? "checkmark" : s.systemImage)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(stage == s || r.isComplete(s) ? Color.white : Color.secondary)
                        }
                        Text(s.title).font(.caption2.weight(stage == s ? .bold : .regular))
                            .foregroundStyle(stage == s ? .primary : .secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                if idx < SIUReferral.Stage.allCases.count - 1 {
                    Rectangle().fill(.quaternary).frame(height: 2).frame(maxWidth: 40)
                }
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }

    @ViewBuilder
    private func stageContent(_ r: Binding<SIUReferral>) -> some View {
        switch stage {
        case .claim: claimStage(r)
        case .redFlags: redFlagsStage(r)
        case .investigation: investigationStage(r)
        case .discrepancies: discrepanciesStage(r)
        case .disposition: dispositionStage(r)
        }
    }

    private func claimStage(_ r: Binding<SIUReferral>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            header("Claim identification", "The block that heads every SIU report.")
            HStack(spacing: 12) {
                field("Claim number", r.claimNumber)
                field("Insured / claimant", r.insured)
                field("Policy number", r.policyNumber)
            }
            HStack(spacing: 12) {
                field("Loss date", r.lossDate)
                field("Loss type", r.lossType)
                field("Claimed amount", r.claimedAmount)
            }
            field("Investigator", r.investigator)
            next(.redFlags)
        }
    }

    private func redFlagsStage(_ r: Binding<SIUReferral>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            header("Red flags — against objective criteria",
                   "Pick each indicator from the recognized taxonomy and record the case-specific observation. \(SIUFraudIndicators.disciplineNote)")
            ForEach(r.redFlags) { $f in
                VStack(alignment: .leading, spacing: 6) {
                    Picker("Indicator", selection: $f.indicatorID) {
                        Text("Custom…").tag("")
                        ForEach(SIUFraudIndicators.categories) { c in
                            Text("\(c.group) — \(c.title)").tag(c.id)
                        }
                    }
                    .frame(maxWidth: 480)
                    TextField("What was observed in THIS claim", text: $f.note, axis: .vertical)
                        .textFieldStyle(.roundedBorder).lineLimit(1...2)
                    HStack { Spacer()
                        Button { r.wrappedValue.redFlags.removeAll { $0.id == f.id } } label: { Image(systemName: "xmark.circle") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
                .padding(10).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            }
            Button { r.wrappedValue.redFlags.append(SIURedFlag()) } label: { Label("Add red flag", systemImage: "plus") }
            Text("Which written criteria do these flags meet?").font(.callout.weight(.semibold))
            TextField("e.g. Meets referral criteria §2(b): two or more recognized indicators…", text: r.criteriaNote, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(1...2)
            next(.investigation)
        }
    }

    private func investigationStage(_ r: Binding<SIUReferral>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            header("Chronology & investigation",
                   "The loss chronology (every line sourced) and each investigative step with its result — the examiner wants to see the work.")
            Text("Loss chronology").font(.callout.weight(.semibold))
            ForEach(r.chronology) { $c in
                HStack(spacing: 8) {
                    TextField("yyyy-mm-dd", text: $c.date).textFieldStyle(.roundedBorder).frame(width: 110)
                    TextField("Event", text: $c.event).textFieldStyle(.roundedBorder)
                    TextField("Source", text: $c.source).textFieldStyle(.roundedBorder).frame(width: 180)
                    Button { r.wrappedValue.chronology.removeAll { $0.id == c.id } } label: { Image(systemName: "xmark.circle") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            Button { r.wrappedValue.chronology.append(SIUChronologyEvent()) } label: { Label("Add event", systemImage: "plus") }
                .controlSize(.small)
            Text("Investigation steps").font(.callout.weight(.semibold))
            ForEach(r.steps) { $t in
                HStack(spacing: 8) {
                    TextField("yyyy-mm-dd", text: $t.date).textFieldStyle(.roundedBorder).frame(width: 110)
                    TextField("Action (statement / EUO / records / ISO…)", text: $t.action).textFieldStyle(.roundedBorder)
                    TextField("Result", text: $t.result).textFieldStyle(.roundedBorder).frame(width: 220)
                    Button { r.wrappedValue.steps.removeAll { $0.id == t.id } } label: { Image(systemName: "xmark.circle") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            Button { r.wrappedValue.steps.append(SIUStep()) } label: { Label("Add step", systemImage: "plus") }
                .controlSize(.small)
            next(.discrepancies)
        }
    }

    private func discrepanciesStage(_ r: Binding<SIUReferral>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            header("Discrepancies & findings of fact",
                   "Preserve BOTH accounts of every conflict — never average them — and state the findings the developed facts support.")
            ForEach(r.discrepancies) { $d in
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Account A", text: $d.accountA).textFieldStyle(.roundedBorder)
                    TextField("Account B (the conflicting account)", text: $d.accountB).textFieldStyle(.roundedBorder)
                    TextField("Why it matters (materiality)", text: $d.materiality).textFieldStyle(.roundedBorder)
                    HStack { Spacer()
                        Button { r.wrappedValue.discrepancies.removeAll { $0.id == d.id } } label: { Image(systemName: "xmark.circle") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
                .padding(10).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            }
            Button { r.wrappedValue.discrepancies.append(SIUDiscrepancy()) } label: { Label("Add discrepancy", systemImage: "plus") }
            Text("Findings of fact").font(.callout.weight(.semibold))
            TextEditor(text: r.findingsOfFact).font(.body).frame(minHeight: 90)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
            next(.disposition)
        }
    }

    private func dispositionStage(_ r: Binding<SIUReferral>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            header("Disposition & report",
                   "Return to claims when suspicion isn't substantiated — that's a good outcome when the file shows the work. External referral demands reasonable suspicion, reported in good faith.")
            Picker("Disposition", selection: r.disposition) {
                Text("Not yet decided").tag(Optional<SIUDisposition>.none)
                ForEach(SIUDisposition.allCases, id: \.self) { Text($0.label).tag(Optional($0)) }
            }
            .frame(maxWidth: 460)
            TextField("Rationale", text: r.dispositionRationale, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(2...4)
            Toggle("I acknowledge the red flags are indicators — not, on their own, proof of fraud", isOn: r.indicatorsNotProofAcknowledged)
            if r.wrappedValue.disposition?.isExternalReferral == true {
                Toggle("This external referral is made in good faith under the applicable reporting statute", isOn: r.goodFaithConfirmed)
                    .tint(.orange)
            }
            if !r.wrappedValue.isComplete(.disposition) {
                Label("The report unlocks when a disposition, its rationale, and the acknowledgment(s) are recorded.",
                      systemImage: "lock.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            Text("Report preview").font(.callout.weight(.semibold))
            ScrollView([.horizontal, .vertical]) {
                Text(SIUReportRenderer.markdown(r.wrappedValue, generatedAt: Date()))
                    .font(.callout.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(16)
            }
            .frame(maxHeight: 360)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
            HStack(spacing: 10) {
                Button { copyReport(r.wrappedValue) } label: { Label("Copy", systemImage: "doc.on.doc") }
                Button { showExporter = true } label: { Label("Export Markdown", systemImage: "square.and.arrow.up") }
                #if os(macOS)
                Button { printReport(r.wrappedValue) } label: { Label("Print / Save as PDF", systemImage: "printer") }
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
    private func next(_ s: SIUReferral.Stage) -> some View {
        HStack { Spacer(); Button { stage = s } label: { Label("Next: \(s.title)", systemImage: "arrow.right") }.buttonStyle(.borderedProminent) }
    }

    private var activeReport: String {
        guard let b = activeBinding else { return "" }
        return SIUReportRenderer.markdown(b.wrappedValue, generatedAt: Date())
    }
    private var exportFilename: String {
        "siu-report-\((activeBinding?.wrappedValue.claimNumber ?? "claim").replacingOccurrences(of: " ", with: "-").lowercased())"
    }
    private func copyReport(_ r: SIUReferral) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(SIUReportRenderer.markdown(r, generatedAt: Date()), forType: .string)
        #endif
    }
    #if os(macOS)
    private func printReport(_ r: SIUReferral) {
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 468, height: 648))
        tv.string = SIUReportRenderer.markdown(r, generatedAt: Date())
        tv.font = NSFont.monospacedSystemFont(ofSize: 9, weight: .regular)
        let op = NSPrintOperation(view: tv); op.jobTitle = "SIU Report — \(r.title)"; op.run()
    }
    #endif
}

#if DEBUG
#Preview("SIU Studio") {
    SIUStudioView().frame(width: 1040, height: 760)
}
#endif
