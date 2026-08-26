//
//  JournalistStudioView.swift
//  Kalsmritikosh
//
//  The Journalist studio (persona studio #5). Real-life stages — Story → Claims
//  → Right of reply → Memo — producing the pre-publication fact-check memo with
//  the newsroom disciplines enforced: every claim carries a status + sources;
//  any claim short of verified requires a right-of-reply entry and must run as
//  ALLEGED in copy; a corrections path must exist.
//

import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

public struct JournalistStudioView: View {
    @AppStorage("kalsmritikosh.jn.store") private var storeBlob = ""
    @State private var memos: [FactCheckMemo] = []
    @State private var loaded = false
    @State private var activeID: UUID?
    @State private var stage: FactCheckMemo.Stage = .story
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
           let d = try? JSONDecoder().decode([FactCheckMemo].self, from: data) { memos = d }
    }
    private func persist() {
        if let data = try? JSONEncoder().encode(memos), let s = String(data: data, encoding: .utf8) { storeBlob = s }
    }
    private var activeBinding: Binding<FactCheckMemo>? {
        guard let id = activeID, let idx = memos.firstIndex(where: { $0.id == id }) else { return nil }
        return Binding(get: { memos[idx] },
                       set: { memos[idx] = $0; memos[idx].updatedAt = Date(); persist() })
    }

    // MARK: List

    private var listScreen: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Fact-Check Studio", systemImage: "newspaper")
                        .font(.largeTitle.weight(.bold))
                    Text("Prepare a contested story the newsroom way: check every claim to its sources, log the right of reply with deadlines, flag what must run as alleged, and hand the editor the exact pre-publication memo.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 10) {
                    Button { newMemo() } label: { Label("New fact-check", systemImage: "plus.circle.fill") }
                        .buttonStyle(.borderedProminent)
                        .guidance(GuidanceTip("New fact-check",
                                              what: "Starts a pre-publication check: the story premise, claim-by-claim verification, the right-of-reply log, and the memo."))
                    Button { loadSample() } label: { Label("Load a worked example", systemImage: "wand.and.stars") }
                }
                if memos.isEmpty {
                    ContentUnavailableView("No fact-checks yet", systemImage: "newspaper",
                                           description: Text("Create one, or load the worked example to see the finished memo."))
                        .frame(maxWidth: .infinity, minHeight: 200)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 14)], spacing: 14) {
                        ForEach(memos.sorted { $0.updatedAt > $1.updatedAt }) { m in card(m) }
                    }
                }
            }
            .padding(24).frame(maxWidth: 940, alignment: .leading).frame(maxWidth: .infinity)
        }
        .navigationTitle("Fact-Check")
    }

    private func card(_ m: FactCheckMemo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(m.title.trimmed.isEmpty ? "Untitled" : m.title).font(.headline).lineLimit(1)
            Text(m.premise.trimmed.isEmpty ? "No premise yet." : m.premise)
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            ProgressView(value: m.completionFraction).tint(.green)
            HStack {
                let flagged = m.claims.filter { $0.status?.mustBeLabelledAlleged == true }.count
                Text("\(m.claims.count) claim(s) · \(flagged) to run as alleged")
                    .font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button(role: .destructive) { memos.removeAll { $0.id == m.id }; persist() } label: { Image(systemName: "trash") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                Button("Open") { activeID = m.id; stage = firstIncomplete(m) }
                    .buttonStyle(.bordered).controlSize(.small)
            }
        }
        .padding(16).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }

    private func newMemo() {
        var m = FactCheckMemo(title: "New fact-check", now: Date())
        m.reporter = NSFullUserName()
        StudioAudit.record(&m.history, "Created")
        memos.append(m); persist(); activeID = m.id; stage = .story
    }
    private func loadSample() {
        let m = FactCheckMemo.sample(now: Date())
        memos.append(m); persist(); activeID = m.id; stage = .memo
    }
    private func firstIncomplete(_ m: FactCheckMemo) -> FactCheckMemo.Stage {
        FactCheckMemo.Stage.allCases.first { !m.isComplete($0) } ?? .memo
    }

    // MARK: Studio

    private func studio(_ m: Binding<FactCheckMemo>) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { activeID = nil } label: { Label("All fact-checks", systemImage: "chevron.left").font(.caption) }
                    .buttonStyle(.plain).foregroundStyle(.tint)
                TextField("Memo title", text: m.title).textFieldStyle(.plain).font(.headline).frame(maxWidth: 360)
                Spacer()
                Button { showExporter = true } label: { Label("Export", systemImage: "square.and.arrow.up") }.controlSize(.small)
                #if os(macOS)
                Button { printMemo(m.wrappedValue) } label: { Label("Print", systemImage: "printer") }.controlSize(.small)
                #endif
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            Divider()
            stepper(m.wrappedValue)
            Divider()
            ScrollView {
                stageContent(m)
                    .padding(24).frame(maxWidth: 980, alignment: .leading).frame(maxWidth: .infinity, alignment: .top)
            }
        }
    }

    private func stepper(_ m: FactCheckMemo) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(FactCheckMemo.Stage.allCases.enumerated()), id: \.element) { idx, s in
                Button { stage = s } label: {
                    VStack(spacing: 4) {
                        ZStack {
                            Circle().fill(stage == s ? AnyShapeStyle(.tint) : (m.isComplete(s) ? AnyShapeStyle(.green.opacity(0.9)) : AnyShapeStyle(.quaternary)))
                                .frame(width: 30, height: 30)
                            Image(systemName: m.isComplete(s) && stage != s ? "checkmark" : s.systemImage)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(stage == s || m.isComplete(s) ? Color.white : Color.secondary)
                        }
                        Text(s.title).font(.caption2.weight(stage == s ? .bold : .regular))
                            .foregroundStyle(stage == s ? .primary : .secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                if idx < FactCheckMemo.Stage.allCases.count - 1 {
                    Rectangle().fill(.quaternary).frame(height: 2).frame(maxWidth: 40)
                }
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }

    @ViewBuilder
    private func stageContent(_ m: Binding<FactCheckMemo>) -> some View {
        switch stage {
        case .story: storyStage(m)
        case .claims: claimsStage(m)
        case .reply: replyStage(m)
        case .memo: memoStage(m)
        }
    }

    private func storyStage(_ m: Binding<FactCheckMemo>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            header("Story premise", "What the story alleges, in one paragraph — the memo checks THIS.")
            TextEditor(text: m.premise).font(.body).frame(minHeight: 80)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
            HStack(spacing: 12) {
                field("Reporter", m.reporter)
                field("Editor", m.editor)
            }
            next(.claims)
        }
    }

    private func claimsStage(_ m: Binding<FactCheckMemo>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            header("Claim-by-claim verification",
                   JournalisticVerification.disciplineNote)
            ForEach(m.claims) { $c in
                VStack(alignment: .leading, spacing: 6) {
                    TextField("The claim, as it will appear in copy", text: $c.text, axis: .vertical)
                        .textFieldStyle(.roundedBorder).lineLimit(1...2).font(.callout.weight(.medium))
                    HStack(spacing: 8) {
                        Picker("Status", selection: $c.status) {
                            Text("—").tag(Optional<ClaimVerification>.none)
                            ForEach(ClaimVerification.allCases, id: \.self) { Text($0.label).tag(Optional($0)) }
                        }.frame(maxWidth: 220)
                        if c.status?.mustBeLabelledAlleged == true {
                            Label("Must run as alleged", systemImage: "exclamationmark.bubble")
                                .font(.caption2).foregroundStyle(.orange)
                        }
                        Spacer()
                        Button { m.wrappedValue.claims.removeAll { $0.id == c.id } } label: { Image(systemName: "xmark.circle") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                    TextField("Sources supporting it", text: $c.sources).textFieldStyle(.roundedBorder).font(.caption)
                    TextField("Independent corroboration — or its absence", text: $c.corroboration).textFieldStyle(.roundedBorder).font(.caption)
                }
                .padding(10).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            }
            Button { m.wrappedValue.claims.append(JClaim()) } label: { Label("Add claim", systemImage: "plus") }
            next(.reply)
        }
    }

    private func replyStage(_ m: Binding<FactCheckMemo>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            header("Right of reply",
                   "Anyone facing a claim short of verified gets the allegations put to them in full, with a real deadline — and their response (or silence) goes on the record.")
            if m.wrappedValue.claims.contains(where: { $0.status?.mustBeLabelledAlleged == true }) && m.wrappedValue.replies.isEmpty {
                Label("This story has claims short of verified — the memo won't complete without at least one reply entry.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            ForEach(m.replies) { $r in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        TextField("Subject (person / org)", text: $r.subject).textFieldStyle(.roundedBorder)
                        TextField("yyyy-mm-dd contacted", text: $r.contactedDate).textFieldStyle(.roundedBorder).frame(width: 160)
                        TextField("Method", text: $r.method).textFieldStyle(.roundedBorder).frame(width: 120)
                        Button { m.wrappedValue.replies.removeAll { $0.id == r.id } } label: { Image(systemName: "xmark.circle") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                    TextField("What was put to them (in full)", text: $r.claimSummary, axis: .vertical)
                        .textFieldStyle(.roundedBorder).lineLimit(1...2)
                    HStack(spacing: 8) {
                        TextField("Deadline", text: $r.deadline).textFieldStyle(.roundedBorder).frame(width: 180)
                        TextField("Response — or 'no response by deadline'", text: $r.response).textFieldStyle(.roundedBorder)
                    }
                }
                .padding(10).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            }
            Button { m.wrappedValue.replies.append(ReplyEntry()) } label: { Label("Add reply entry", systemImage: "plus") }
            next(.memo)
        }
    }

    private func memoStage(_ m: Binding<FactCheckMemo>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            header("The memo", "The pre-publication checks, then the exact memo the editor reviews.")
            Toggle("Every unverified/disputed claim is framed as ALLEGED in copy", isOn: m.allegedLabellingConfirmed)
            Toggle("A corrections path exists post-publication", isOn: m.correctionsPathConfirmed)
            if !m.wrappedValue.isComplete(.memo) {
                Label("The memo completes when both checks are confirmed.", systemImage: "lock.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            Text("Memo preview").font(.callout.weight(.semibold))
            ScrollView([.horizontal, .vertical]) {
                Text(FactCheckMemoRenderer.markdown(m.wrappedValue, generatedAt: Date()))
                    .font(.callout.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(16)
            }
            .frame(maxHeight: 360)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
            HStack(spacing: 10) {
                Button { copyMemo(m.wrappedValue) } label: { Label("Copy", systemImage: "doc.on.doc") }
                Button { showExporter = true } label: { Label("Export Markdown", systemImage: "square.and.arrow.up") }
                #if os(macOS)
                Button { printMemo(m.wrappedValue) } label: { Label("Print / Save as PDF", systemImage: "printer") }
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
    private func next(_ s: FactCheckMemo.Stage) -> some View {
        HStack { Spacer(); Button { stage = s } label: { Label("Next: \(s.title)", systemImage: "arrow.right") }.buttonStyle(.borderedProminent) }
    }

    /// Every deliverable that LEAVES the studio (copy/print/export) carries a
    /// signed seal — content hash, honest stage completion, signer key.
    private func sealed(_ m: FactCheckMemo) -> String {
        let stages = FactCheckMemo.Stage.allCases
        return StudioDeliverableSeal.sealedReport(
            studio: "Journalist Fact-Check", title: m.title,
            report: FactCheckMemoRenderer.markdown(m, generatedAt: Date()),
            stagesComplete: stages.filter { m.isComplete($0) }.count,
            stagesTotal: stages.count, at: Date())
    }
    private var activeReport: String {
        guard let b = activeBinding else { return "" }
        return sealed(b.wrappedValue)
    }
    private var exportFilename: String {
        "fact-check-\((activeBinding?.wrappedValue.title ?? "memo").replacingOccurrences(of: " ", with: "-").lowercased())"
    }
    private func copyMemo(_ m: FactCheckMemo) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sealed(m), forType: .string)
        #endif
    }
    #if os(macOS)
    private func printMemo(_ m: FactCheckMemo) {
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 468, height: 648))
        tv.string = sealed(m)
        tv.font = NSFont.monospacedSystemFont(ofSize: 9, weight: .regular)
        let op = NSPrintOperation(view: tv); op.jobTitle = "Fact-Check Memo — \(m.title)"; op.run()
    }
    #endif
}

#if DEBUG
#Preview("Journalist Studio") {
    JournalistStudioView().frame(width: 1040, height: 760)
}
#endif
