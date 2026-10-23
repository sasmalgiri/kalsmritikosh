//
//  PersonaStudioShell.swift
//  Kalsmritikosh
//
//  The shared staged-studio shell used by the persona studios: list screen with
//  cards, real-life stage stepper with completion gates, report preview with
//  Copy / Export / Print, JSON persistence, and automatic audit-trail recording
//  (created · example loaded · report copied/exported/printed) so every
//  deliverable's history is preserved and presentable on demand.
//

import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

// MARK: - Protocols

public protocol StudioStageProtocol: CaseIterable, Hashable {
    var title: String { get }
    var systemImage: String { get }
}

public protocol StudioDeliverable: Codable, Identifiable where ID == UUID {
    associatedtype Stage: StudioStageProtocol
    var title: String { get set }
    var updatedAt: Date { get set }
    var history: [StudioAuditEntry]? { get set }
    func isComplete(_ s: Stage) -> Bool
    var completionFraction: Double { get }
}

/// A2/A3 — a studio that can be filled from a case and whose export is gated on provenance:
/// every filled field rests on a case document or is marked as the investigator's entry.
public protocol CaseBackedStudio {
    var history: [StudioAuditEntry]? { get set }
    var provenance: StudioProvenance? { get set }
    /// Every filled field by path, for the export gate.
    var gateValues: [String: String] { get }
    mutating func prefill(from facts: StudioCaseFacts)
    /// A privilege log needs the privileged sources (it describes them; it never prints them).
    static var needsPrivilegedSources: Bool { get }
}

extension CaseBackedStudio {
    public static var needsPrivilegedSources: Bool { false }
}

// MARK: - Configuration

public struct StudioConfig<M: StudioDeliverable> {
    public var name: String
    public var icon: String
    public var blurb: String
    /// D-7 — optional jurisdiction disclosure rendered as a caption under the
    /// blurb, for studios whose template cites a named national instrument.
    public var jurisdiction: String? = nil
    public var storeKey: String
    public var filenamePrefix: String
    public var newItem: (Date) -> M
    public var sampleItem: (Date) -> M
    public var subtitle: (M) -> String
    public var render: (M, Date) -> String
}

// MARK: - Shell

public struct PersonaStudioShell<M: StudioDeliverable, StageContent: View>: View {
    private let config: StudioConfig<M>
    private let stageContent: (Binding<M>, M.Stage, @escaping (M.Stage) -> Void) -> StageContent

    @AppStorage private var storeBlob: String
    @State private var items: [M] = []
    @State private var loaded = false
    @State private var activeID: UUID?
    @State private var stage: M.Stage?
    @State private var showExporter = false
    @State private var showHistory = false
    @Environment(AppState.self) private var appState
    @State private var caseChoices: [StudioCaseChoice] = []
    @State private var filling = false
    @State private var fillMessage: String?
    /// The report action waiting on the provenance gate, and the fields that stopped it.
    @State private var gatedAction: String?
    @State private var gatedFields: [String] = []

    public init(config: StudioConfig<M>,
                @ViewBuilder stageContent: @escaping (Binding<M>, M.Stage, @escaping (M.Stage) -> Void) -> StageContent) {
        self.config = config
        self.stageContent = stageContent
        _storeBlob = AppStorage(wrappedValue: "", config.storeKey)
    }

    private var stages: [M.Stage] { Array(M.Stage.allCases) }
    private var currentStage: M.Stage? { stage ?? stages.first }

    public var body: some View {
        Group {
            if let binding = activeBinding { studio(binding) } else { listScreen }
        }
        .onAppear(perform: load)
        .alert("Some entries have no source", isPresented: Binding(get: { gatedAction != nil }, set: { if !$0 { gatedAction = nil } })) {
            Button("Mark as my entries and continue") { releaseGate() }
            Button("Cancel", role: .cancel) { gatedAction = nil }
        } message: {
            Text("\(gatedFields.count) filled field(s) are neither taken from the case's documents nor marked as your own entry: \(gatedFields.prefix(6).joined(separator: ", "))\(gatedFields.count > 6 ? " …" : ""). A report that leaves the app must say, for every line, which it is.")
        }
        .fileExporter(isPresented: $showExporter,
                      document: RCAMarkdownDocument(text: activeReport),
                      contentType: .plainText,
                      defaultFilename: exportFilename) { result in
            if case .success = result, let b = activeBinding {
                var v = b.wrappedValue
                StudioAudit.record(&v.history, "Report exported as Markdown")
                b.wrappedValue = v
            }
        }
    }

    // MARK: Persistence

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let data = storeBlob.data(using: .utf8),
           let d = try? JSONDecoder().decode([M].self, from: data) { items = d }
    }
    private func persist() {
        if let data = try? JSONEncoder().encode(items), let s = String(data: data, encoding: .utf8) { storeBlob = s }
    }
    private var activeBinding: Binding<M>? {
        guard let id = activeID, let idx = items.firstIndex(where: { $0.id == id }) else { return nil }
        return Binding(get: { items[idx] },
                       set: { items[idx] = $0; items[idx].updatedAt = Date(); persist() })
    }

    // MARK: List

    private var listScreen: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Label(config.name, systemImage: config.icon).font(.largeTitle.weight(.bold))
                    Text(config.blurb).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let jurisdiction = config.jurisdiction {
                        Text(jurisdiction).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack(spacing: 10) {
                    Button { newItem() } label: { Label("New", systemImage: "plus.circle.fill") }
                        .buttonStyle(.borderedProminent)
                        .guidance(GuidanceTip("New",
                                              what: "Starts a new \(config.name) record and walks the real-life stages to the finished hardcopy."))
                    Button { loadSample() } label: { Label("Load a worked example", systemImage: "wand.and.stars") }
                }
                if items.isEmpty {
                    ContentUnavailableView("Nothing here yet", systemImage: config.icon,
                                           description: Text("Create one, or load the worked example to see the finished document."))
                        .frame(maxWidth: .infinity, minHeight: 200)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 14)], spacing: 14) {
                        ForEach(items.sorted { $0.updatedAt > $1.updatedAt }, id: \.id) { m in card(m) }
                    }
                }
            }
            .padding(24).frame(maxWidth: 940, alignment: .leading).frame(maxWidth: .infinity)
        }
        .navigationTitle(config.name)
    }

    private func card(_ m: M) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(m.title.trimmed.isEmpty ? "Untitled" : m.title).font(.headline).lineLimit(1)
            Text(config.subtitle(m)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            ProgressView(value: m.completionFraction).tint(.green)
            HStack {
                Text(m.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button(role: .destructive) { items.removeAll { $0.id == m.id }; persist() } label: { Label("Delete", systemImage: "trash").labelStyle(.iconOnly) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                Button("Open") { activeID = m.id; stage = firstIncomplete(m) }
                    .buttonStyle(.bordered).controlSize(.small)
            }
        }
        .padding(16).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }

    private func newItem() {
        var m = config.newItem(Date())
        StudioAudit.record(&m.history, "Created")
        items.append(m); persist(); activeID = m.id; stage = stages.first
    }
    private func loadSample() {
        let m = config.sampleItem(Date())
        items.append(m); persist(); activeID = m.id; stage = stages.last
    }
    private func firstIncomplete(_ m: M) -> M.Stage? {
        stages.first { !m.isComplete($0) } ?? stages.last
    }

    // MARK: Studio

    private func studio(_ m: Binding<M>) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { activeID = nil } label: { Label("All records", systemImage: "chevron.left").font(.caption) }
                    .buttonStyle(.plain).foregroundStyle(.tint)
                TextField("Title", text: m.title).textFieldStyle(.plain).font(.headline).frame(maxWidth: 360)
                Spacer()
                Button { showHistory.toggle() } label: { Label("History", systemImage: "clock.arrow.circlepath") }
                    .controlSize(.small)
                    .popover(isPresented: $showHistory) { historyPanel(m.wrappedValue) }
                if m.wrappedValue is any CaseBackedStudio { fillFromCaseMenu(m) }
                Button { gate(m, "copy") }
                    label: { Label("Copy", systemImage: "doc.on.doc") }.controlSize(.small)
                Button { gate(m, "export") } label: { Label("Export", systemImage: "square.and.arrow.up") }.controlSize(.small)
                #if os(macOS)
                Button { gate(m, "print") }
                    label: { Label("Print", systemImage: "printer") }.controlSize(.small)
                #endif
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            if let fillMessage {
                Text(fillMessage).font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 20).padding(.bottom, 6).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            stepper(m.wrappedValue)
            Divider()
            ScrollView {
                Group {
                    if let s = currentStage {
                        stageContent(m, s) { stage = $0 }
                    }
                }
                .padding(24).frame(maxWidth: 980, alignment: .leading).frame(maxWidth: .infinity, alignment: .top)
            }
        }
    }

    private func historyPanel(_ m: M) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Document history").font(.headline)
            if let h = m.history, !h.isEmpty {
                ForEach(h.sorted { $0.date < $1.date }) { e in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(e.date.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Text(e.action).font(.caption)
                    }
                }
                Text("This history is printed on the exported hardcopy as an appendix.")
                    .font(.caption2).foregroundStyle(.tertiary)
            } else {
                Text("No recorded events yet.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14).frame(minWidth: 320, alignment: .leading)
    }

    private func stepper(_ m: M) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(stages.enumerated()), id: \.element) { idx, s in
                Button { stage = s } label: {
                    VStack(spacing: 4) {
                        ZStack {
                            Circle().fill(currentStage == s ? AnyShapeStyle(.tint) : (m.isComplete(s) ? AnyShapeStyle(.green.opacity(0.9)) : AnyShapeStyle(.quaternary)))
                                .frame(width: 30, height: 30)
                            Image(systemName: m.isComplete(s) && currentStage != s ? "checkmark" : s.systemImage)
                                .scaledFont(13, weight: .semibold, relativeTo: .body)
                                .foregroundStyle(currentStage == s || m.isComplete(s) ? Color.white : Color.secondary)
                        }
                        Text(s.title).font(.caption2.weight(currentStage == s ? .bold : .regular))
                            .foregroundStyle(currentStage == s ? .primary : .secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                if idx < stages.count - 1 {
                    Rectangle().fill(.quaternary).frame(height: 2).frame(maxWidth: 40)
                }
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }

    // MARK: Report actions

    private func recordAndShare(_ m: Binding<M>, _ action: String) {
        var v = m.wrappedValue
        StudioAudit.record(&v.history, action)
        m.wrappedValue = v
    }
    private var activeReport: String {
        guard let b = activeBinding else { return "" }
        return sealedReport(b.wrappedValue)
    }

    /// Every report that LEAVES the app carries the signed deliverable seal:
    /// content hash, honest stage completion, installation-key signature —
    /// the one shell seals all ten studios.
    private func sealedReport(_ m: M) -> String {
        let complete = stages.filter { m.isComplete($0) }.count
        let report = config.render(m, Date())
        return StudioDeliverableSeal.sealedReport(
            studio: config.name, title: m.title,
            report: report,
            stagesComplete: complete, stagesTotal: stages.count, at: Date())
    }

    // MARK: Case fill + provenance gate (A2/A3)

    private func fillFromCaseMenu(_ m: Binding<M>) -> some View {
        Menu {
            if caseChoices.isEmpty {
                Text("No open cases")
            } else {
                ForEach(caseChoices) { c in
                    Button(c.title) { fill(m, from: c) }
                }
            }
        } label: {
            Label(filling ? "Filling…" : "Fill from case", systemImage: "tray.and.arrow.down")
        }
        .controlSize(.small)
        .disabled(filling)
        .task { caseChoices = await appState.studioCaseChoices() }
        .guidance(GuidanceTip("Fill from case",
                              what: "Fills the empty fields from the case's own documents. Each filled field keeps the source it came from; anything you type or change is marked as your entry."))
    }

    private func fill(_ m: Binding<M>, from choice: StudioCaseChoice) {
        guard let current = m.wrappedValue as? any CaseBackedStudio else { return }
        let privileged = type(of: current).needsPrivilegedSources
        filling = true
        Task {
            defer { filling = false }
            guard let facts = await appState.studioCaseFacts(choice, includePrivileged: privileged),
                  var cb = m.wrappedValue as? any CaseBackedStudio else {
                fillMessage = "The case could not be read."
                return
            }
            let before = cb.provenance?.count ?? 0
            cb.prefill(from: facts)
            let filled = (cb.provenance?.count ?? 0) - before
            if var updated = cb as? M {
                StudioAudit.record(&updated.history, "Filled \(filled) field(s) from case \u{201C}\(choice.title)\u{201D}")
                m.wrappedValue = updated
            }
            fillMessage = filled > 0
                ? "Filled \(filled) field(s) from \u{201C}\(choice.title)\u{201D}; each keeps its source."
                : "Nothing new to fill from \u{201C}\(choice.title)\u{201D} — the case states none of the empty fields."
        }
    }

    /// Run a report action, or hold it until the unsupported fields are resolved.
    private func gate(_ m: Binding<M>, _ action: String) {
        if let cb = m.wrappedValue as? any CaseBackedStudio {
            let missing = StudioExportGate.unsupportedFields(cb.gateValues, provenance: cb.provenance)
            if !missing.isEmpty { gatedFields = missing; gatedAction = action; return }
        }
        perform(m, action)
    }

    private func releaseGate() {
        guard let action = gatedAction, let m = activeBinding else { return }
        gatedAction = nil
        if var cb = m.wrappedValue as? any CaseBackedStudio {
            var p = cb.provenance
            let marked = StudioExportGate.markUnsupportedAsInvestigatorEntries(cb.gateValues, provenance: &p)
            cb.provenance = p
            if var updated = cb as? M {
                StudioAudit.record(&updated.history, "Marked \(marked.count) field(s) as investigator entries")
                m.wrappedValue = updated
            }
        }
        perform(m, action)
    }

    private func perform(_ m: Binding<M>, _ action: String) {
        switch action {
        case "copy": recordAndShare(m, "Report copied to clipboard"); copyReport(m.wrappedValue)
        case "export": showExporter = true
        #if os(macOS)
        case "print": recordAndShare(m, "Report printed / saved as PDF"); printReport(m.wrappedValue)
        #endif
        default: break
        }
    }

    private var exportFilename: String {
        "\(config.filenamePrefix)-\((activeBinding?.wrappedValue.title ?? "report").replacingOccurrences(of: " ", with: "-").lowercased())"
    }
    private func copyReport(_ m: M) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sealedReport(m), forType: .string)
        #endif
    }
    #if os(macOS)
    private func printReport(_ m: M) {
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 468, height: 648))
        tv.string = sealedReport(m)
        tv.font = NSFont.monospacedSystemFont(ofSize: 9, weight: .regular)
        let op = NSPrintOperation(view: tv); op.jobTitle = "\(config.name) — \(m.title)"; op.run()
    }
    #endif
}

// MARK: - Shared stage-editor bits

struct StudioStageHeader: View {
    let title: String
    let blurb: String
    init(_ title: String, _ blurb: String) { self.title = title; self.blurb = blurb }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.title2.weight(.bold))
            Text(blurb).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct StudioField: View {
    let label: String
    @Binding var text: String
    init(_ label: String, _ text: Binding<String>) { self.label = label; _text = text }
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(label, text: $text).textFieldStyle(.roundedBorder)
        }
    }
}

struct StudioReportPreview: View {
    let text: String
    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            Text(text).font(.callout.monospaced()).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(16)
        }
        .frame(maxHeight: 360)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
    }
}
