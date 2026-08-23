//
//  PrivilegeLogStudioView.swift
//  Kalsmritikosh
//
//  The Lawyer's Privilege-Log studio (persona studio #2). Walks the real-life
//  steps — Matter → Withheld documents → QC review → Log — and produces the
//  exact FRCP 26(b)(5) hardcopy: the caption'd table with a legend and a
//  certification block. Persists on-device as JSON.
//

import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

public struct PrivilegeLogStudioView: View {
    @AppStorage("kalsmritikosh.pl.store") private var storeBlob = ""
    @State private var logs: [PrivilegeLog] = []
    @State private var loaded = false
    @State private var activeID: UUID?
    @State private var stage: PrivilegeLog.Stage = .matter
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
           let d = try? JSONDecoder().decode([PrivilegeLog].self, from: data) { logs = d }
    }
    private func persist() {
        if let data = try? JSONEncoder().encode(logs), let s = String(data: data, encoding: .utf8) { storeBlob = s }
    }
    private var activeBinding: Binding<PrivilegeLog>? {
        guard let id = activeID, let idx = logs.firstIndex(where: { $0.id == id }) else { return nil }
        return Binding(get: { logs[idx] },
                       set: { logs[idx] = $0; logs[idx].updatedAt = Date(); persist() })
    }

    // MARK: List

    private var listScreen: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Privilege Log Studio", systemImage: "lock.doc")
                        .font(.largeTitle.weight(.bold))
                    Text("Build an FRCP 26(b)(5) privilege log the real-life way: describe each withheld document well enough that the claim can be tested — without revealing what's protected — assert the basis, QC it, and serve the exact table courts expect.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 10) {
                    Button { newLog() } label: { Label("New privilege log", systemImage: "plus.circle.fill") }
                        .buttonStyle(.borderedProminent)
                        .guidance(GuidanceTip("New privilege log",
                                              what: "Starts a log for one production: name the matter, add each withheld document, QC the descriptions, and export the served table."))
                    Button { loadSample() } label: { Label("Load a worked example", systemImage: "wand.and.stars") }
                }
                if logs.isEmpty {
                    ContentUnavailableView("No logs yet", systemImage: "lock.doc",
                                           description: Text("Create one, or load the worked example to see the finished table."))
                        .frame(maxWidth: .infinity, minHeight: 200)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 14)], spacing: 14) {
                        ForEach(logs.sorted { $0.updatedAt > $1.updatedAt }) { l in card(l) }
                    }
                }
            }
            .padding(24).frame(maxWidth: 940, alignment: .leading).frame(maxWidth: .infinity)
        }
        .navigationTitle("Privilege Log")
    }

    private func card(_ l: PrivilegeLog) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(l.title.trimmed.isEmpty ? "Untitled" : l.title).font(.headline).lineLimit(1)
            Text(l.caption.trimmed.isEmpty ? "No caption yet." : l.caption)
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            ProgressView(value: l.completionFraction).tint(.green)
            HStack {
                Text("\(l.entries.count) withheld document(s)").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button(role: .destructive) { logs.removeAll { $0.id == l.id }; persist() } label: { Image(systemName: "trash") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                Button("Open") { activeID = l.id; stage = firstIncomplete(l) }
                    .buttonStyle(.bordered).controlSize(.small)
            }
        }
        .padding(16).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }

    private func newLog() {
        var l = PrivilegeLog(title: "New privilege log", now: Date())
        l.preparedBy = NSFullUserName()
        StudioAudit.record(&l.history, "Created")
        logs.append(l); persist(); activeID = l.id; stage = .matter
    }
    private func loadSample() {
        let l = PrivilegeLog.sample(now: Date())
        logs.append(l); persist(); activeID = l.id; stage = .log
    }
    private func firstIncomplete(_ l: PrivilegeLog) -> PrivilegeLog.Stage {
        PrivilegeLog.Stage.allCases.first { !l.isComplete($0) } ?? .log
    }

    // MARK: Studio

    private func studio(_ p: Binding<PrivilegeLog>) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { activeID = nil } label: { Label("All logs", systemImage: "chevron.left").font(.caption) }
                    .buttonStyle(.plain).foregroundStyle(.tint)
                TextField("Log title", text: p.title).textFieldStyle(.plain).font(.headline).frame(maxWidth: 360)
                Spacer()
                Button { showExporter = true } label: { Label("Export", systemImage: "square.and.arrow.up") }.controlSize(.small)
                #if os(macOS)
                Button { printLog(p.wrappedValue) } label: { Label("Print", systemImage: "printer") }.controlSize(.small)
                #endif
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            Divider()
            stepper(p.wrappedValue)
            Divider()
            ScrollView {
                stageContent(p)
                    .padding(24).frame(maxWidth: 980, alignment: .leading).frame(maxWidth: .infinity, alignment: .top)
            }
        }
    }

    private func stepper(_ l: PrivilegeLog) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(PrivilegeLog.Stage.allCases.enumerated()), id: \.element) { idx, s in
                Button { stage = s } label: {
                    VStack(spacing: 4) {
                        ZStack {
                            Circle().fill(stage == s ? AnyShapeStyle(.tint) : (l.isComplete(s) ? AnyShapeStyle(.green.opacity(0.9)) : AnyShapeStyle(.quaternary)))
                                .frame(width: 30, height: 30)
                            Image(systemName: l.isComplete(s) && stage != s ? "checkmark" : s.systemImage)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(stage == s || l.isComplete(s) ? Color.white : Color.secondary)
                        }
                        Text(s.title).font(.caption2.weight(stage == s ? .bold : .regular))
                            .foregroundStyle(stage == s ? .primary : .secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                if idx < PrivilegeLog.Stage.allCases.count - 1 {
                    Rectangle().fill(.quaternary).frame(height: 2).frame(maxWidth: 40)
                }
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }

    @ViewBuilder
    private func stageContent(_ p: Binding<PrivilegeLog>) -> some View {
        switch stage {
        case .matter: matterStage(p)
        case .entries: entriesStage(p)
        case .review: reviewStage(p)
        case .log: logStage(p)
        }
    }

    private func matterStage(_ p: Binding<PrivilegeLog>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            header("Matter", "The case caption and the parties — this heads the served log.")
            field("Case caption — e.g. Doe v. Acme Corp., No. 1:26-cv-0421 (N.D. Ga.)", p.caption)
            HStack(spacing: 12) {
                field("Producing party", p.producingParty)
                field("Requesting party", p.requestingParty)
            }
            field("Prepared by (counsel)", p.preparedBy)
            next(.entries)
        }
    }

    private func entriesStage(_ p: Binding<PrivilegeLog>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            header("Withheld documents",
                   "One entry per withheld document. Describe each well enough to let the claim be tested — never revealing the protected content itself.")
            ForEach(p.entries) { $e in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        TextField("yyyy-mm-dd", text: $e.date).textFieldStyle(.roundedBorder).frame(width: 110)
                        TextField("Type (Email / Memo …)", text: $e.docType).textFieldStyle(.roundedBorder).frame(width: 160)
                        Picker("", selection: $e.privilege) {
                            ForEach(PrivilegeBasis.allCases, id: \.self) { Text($0.label).tag($0) }
                        }.labelsHidden().frame(maxWidth: 210)
                        Spacer()
                        Button { p.wrappedValue.entries.removeAll { $0.id == e.id } } label: { Image(systemName: "xmark.circle") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 8) {
                        TextField("Author", text: $e.author).textFieldStyle(.roundedBorder)
                        TextField("Recipient(s)", text: $e.recipients).textFieldStyle(.roundedBorder)
                        TextField("CC", text: $e.cc).textFieldStyle(.roundedBorder).frame(width: 140)
                    }
                    TextField("Description — enough to assess the claim, without the protected content", text: $e.descriptionText, axis: .vertical)
                        .textFieldStyle(.roundedBorder).lineLimit(1...3)
                    TextField("Bates range / control number", text: $e.bates).textFieldStyle(.roundedBorder).frame(maxWidth: 280)
                    if !e.isComplete {
                        Label("Needs date, type, author, and a description.", systemImage: "exclamationmark.circle")
                            .font(.caption2).foregroundStyle(.orange)
                    }
                }
                .padding(10).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            }
            Button { p.wrappedValue.entries.append(PLEntry()) } label: { Label("Add withheld document", systemImage: "plus") }
            next(.review)
        }
    }

    private func reviewStage(_ p: Binding<PrivilegeLog>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            header("QC review",
                   "The two checks counsel makes before serving a log — an inadequate description invites a motion to compel; an over-detailed one can waive the privilege.")
            Toggle("Every description lets the claim be assessed WITHOUT revealing protected content", isOn: p.descriptionsDoNotRevealContent)
            Toggle("Every entry asserts a specific privilege basis (AC / WP / both)", isOn: p.everyEntryHasBasis)
            let incomplete = p.wrappedValue.entries.filter { !$0.isComplete }.count
            if incomplete > 0 {
                Label("\(incomplete) entr\(incomplete == 1 ? "y" : "ies") still missing required fields — complete them before serving.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            next(.log)
        }
    }

    private func logStage(_ p: Binding<PrivilegeLog>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            header("The served log", "The exact FRCP 26(b)(5) table — caption, entries, legend, certification.")
            if !p.wrappedValue.isComplete(.log) {
                Label("The log isn't ready: complete the matter, the entries, and both QC confirmations.",
                      systemImage: "lock.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            ScrollView([.horizontal, .vertical]) {
                Text(PrivilegeLogRenderer.markdown(p.wrappedValue, generatedAt: Date()))
                    .font(.callout.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(16)
            }
            .frame(maxHeight: 380)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
            HStack(spacing: 10) {
                Button { copyLog(p.wrappedValue) } label: { Label("Copy", systemImage: "doc.on.doc") }
                Button { showExporter = true } label: { Label("Export Markdown", systemImage: "square.and.arrow.up") }
                #if os(macOS)
                Button { printLog(p.wrappedValue) } label: { Label("Print / Save as PDF", systemImage: "printer") }
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
    private func next(_ s: PrivilegeLog.Stage) -> some View {
        HStack { Spacer(); Button { stage = s } label: { Label("Next: \(s.title)", systemImage: "arrow.right") }.buttonStyle(.borderedProminent) }
    }

    private var activeReport: String {
        guard let b = activeBinding else { return "" }
        return PrivilegeLogRenderer.markdown(b.wrappedValue, generatedAt: Date())
    }
    private var exportFilename: String {
        "privilege-log-\((activeBinding?.wrappedValue.title ?? "log").replacingOccurrences(of: " ", with: "-").lowercased())"
    }
    private func copyLog(_ l: PrivilegeLog) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(PrivilegeLogRenderer.markdown(l, generatedAt: Date()), forType: .string)
        #endif
    }
    #if os(macOS)
    private func printLog(_ l: PrivilegeLog) {
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 468, height: 648))
        tv.string = PrivilegeLogRenderer.markdown(l, generatedAt: Date())
        tv.font = NSFont.monospacedSystemFont(ofSize: 9, weight: .regular)
        let op = NSPrintOperation(view: tv); op.jobTitle = "Privilege Log — \(l.title)"; op.run()
    }
    #endif
}

#if DEBUG
#Preview("Privilege Log Studio") {
    PrivilegeLogStudioView().frame(width: 1040, height: 760)
}
#endif
