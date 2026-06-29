//
//  NotebookView.swift
//  Kalsmritikosh
//
//  HISTORY Phase I.B — Investigation Notebook. Lists past
//  Plan-and-Solve investigations the user has run (auto-saved from
//  InvestigationRunner) and lets them re-read the original question,
//  every sub-question + sub-answer, and the synthesis without
//  re-running the LLM.
//
//  Reading-only surface — no re-run button in v1 (the user can
//  re-issue the question from AskView if they want a fresh
//  investigation). Delete is supported so the notebook doesn't grow
//  unbounded with throwaway test questions.
//

import SwiftUI
#if canImport(AppKit)
import AppKit
import UniformTypeIdentifiers
#endif

public struct NotebookView: View {
    @Environment(AppState.self) private var appState

    @State private var headers: [InvestigationHeader] = []
    @State private var selectedID: UUID?
    @State private var detail: Investigation?
    @State private var loading: Bool = false
    @State private var error: String?

    public init() {}

    public var body: some View {
        NavigationSplitView {
            list
        } detail: {
            detailPane
        }
        .task { await refresh() }
    }

    // MARK: - List

    private var list: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "notebook")
                    .foregroundStyle(.tint)
                Text("Notebook")
                    .font(.headline)
                Spacer()
                Button {
                    Task { await refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("Reload notebook")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()
            if headers.isEmpty {
                placeholder
            } else {
                List(selection: $selectedID) {
                    ForEach(headers) { header in
                        row(for: header)
                            .tag(header.id as UUID?)
                            .contextMenu {
                                Button("Delete", role: .destructive) {
                                    Task { await delete(header) }
                                }
                            }
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .frame(minWidth: 280, idealWidth: 320)
        .onChange(of: selectedID) { _, newValue in
            Task { await loadDetail(id: newValue) }
        }
    }

    private var placeholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "notebook")
                .font(.system(size: 36))
                .foregroundStyle(.tint)
            Text("No investigations yet.")
                .font(.callout.weight(.medium))
            Text("Run an investigation from the Ask tab — the magnifying-glass button next to Send opens a focused planner.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func row(for header: InvestigationHeader) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(header.question)
                .font(.callout.weight(.medium))
                .lineLimit(2)
            HStack(spacing: 6) {
                Text(header.createdAt.formatted(date: .abbreviated, time: .shortened))
                if header.synthesis != nil {
                    Text("· complete")
                        .foregroundStyle(.green)
                } else {
                    Text("· no synthesis")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detailPane: some View {
        if loading {
            ProgressView("Loading investigation…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let err = error {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(err).font(.callout).foregroundStyle(.secondary)
            }
            .padding(40)
            .frame(maxWidth: .infinity)
        } else if let inv = detail {
            detailBody(inv)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "arrow.left")
                    .foregroundStyle(.secondary)
                Text("Pick an investigation from the list.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func detailBody(_ inv: Investigation) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Spacer()
                    Button {
                        Task { await exportReport(for: inv) }
                    } label: {
                        Label("Export report…", systemImage: "square.and.arrow.up")
                    }
                    .help("Render this investigation as a markdown report and save it.")
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Original question")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(inv.question)
                        .font(.title3.weight(.medium))
                        .textSelection(.enabled)
                }
                dashboard(for: inv)
                Divider()
                VStack(alignment: .leading, spacing: 14) {
                    Text("Sub-questions")
                        .font(.headline)
                    ForEach(Array(inv.steps.enumerated()), id: \.element.id) { idx, step in
                        stepRow(idx: idx + 1, step: step)
                    }
                }
                if let synthesis = inv.synthesis, !synthesis.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: "sparkles")
                                .foregroundStyle(.tint)
                            Text("Synthesis")
                                .font(.headline)
                        }
                        Text(synthesis)
                            .font(.body)
                            .textSelection(.enabled)
                            .padding(10)
                            .background(.tint.opacity(0.08), in: .rect(cornerRadius: 8))
                    }
                }
                Spacer(minLength: 24)
            }
            .padding(20)
        }
    }

    /// Phase J.9 — Vol 28 §Investigation Dashboard. Compact metric
    /// row above the per-step findings: how many steps completed,
    /// average confidence, total citation count, distinct source
    /// files touched, and a coverage badge ("strong / partial /
    /// weak") rolled up from the per-step confidences.
    @ViewBuilder
    private func dashboard(for inv: Investigation) -> some View {
        let metrics = Self.dashboardMetrics(for: inv)
        VStack(alignment: .leading, spacing: 8) {
            Text("Investigation dashboard")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 18) {
                metricCell(label: "Steps", value: "\(metrics.completedSteps)/\(metrics.totalSteps)")
                metricCell(label: "Avg confidence", value: String(format: "%.0f%%", metrics.avgConfidence * 100))
                metricCell(label: "Citations", value: "\(metrics.totalCitations)")
                metricCell(label: "Source files", value: "\(metrics.distinctObjectIDs)")
                metricCell(label: "Coverage", value: metrics.coverageLabel)
                    .foregroundStyle(metrics.coverageTint)
                Spacer()
            }
            if !metrics.outstanding.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Outstanding")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                    ForEach(Array(metrics.outstanding.enumerated()), id: \.offset) { _, line in
                        Text("• \(line)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.05))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
        )
        .cornerRadius(10)
    }

    @ViewBuilder
    private func metricCell(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.title3.weight(.semibold))
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    struct DashboardMetrics {
        let completedSteps: Int
        let totalSteps: Int
        let avgConfidence: Double
        let totalCitations: Int
        let distinctObjectIDs: Int
        let coverageLabel: String
        let coverageTint: Color
        let outstanding: [String]
    }

    static func dashboardMetrics(for inv: Investigation) -> DashboardMetrics {
        let total = inv.steps.count
        let answered = inv.steps.filter { $0.answer != nil }
        let completed = answered.count
        let confs = answered.compactMap { $0.answer?.confidence.value }
        let avg = confs.isEmpty ? 0 : confs.reduce(0, +) / Double(confs.count)
        let citations = answered.reduce(0) { $0 + ($1.answer?.citations.count ?? 0) }
        let distinct = Set(answered.flatMap { $0.answer?.citations.map(\.objectID) ?? [] }).count
        let coverageRatio = total == 0 ? 0 : Double(completed) / Double(total)
        let label: String
        let tint: Color
        let effective = coverageRatio * max(avg, 0.1)
        switch effective {
        case 0.7...:    label = "strong";  tint = .green
        case 0.4..<0.7: label = "partial"; tint = .orange
        default:        label = "weak";    tint = .red
        }
        var outstanding: [String] = []
        let missing = inv.steps.filter { $0.answer == nil }
        for step in missing {
            outstanding.append("Sub-question \(step.id.uuidString.prefix(8)) still has no answer.")
        }
        let lowConf = answered.filter { ($0.answer?.confidence.value ?? 1.0) < 0.4 }
        for step in lowConf {
            outstanding.append("Sub-question \(step.id.uuidString.prefix(8)) answered with low confidence.")
        }
        if inv.synthesis == nil {
            outstanding.append("Synthesis not yet computed.")
        }
        return DashboardMetrics(
            completedSteps: completed,
            totalSteps: total,
            avgConfidence: avg,
            totalCitations: citations,
            distinctObjectIDs: distinct,
            coverageLabel: label,
            coverageTint: tint,
            outstanding: outstanding
        )
    }

    @ViewBuilder
    private func stepRow(idx: Int, step: InvestigationStep) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(idx).")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.tint)
                Text(step.question)
                    .font(.callout.weight(.medium))
                    .textSelection(.enabled)
                Spacer()
            }
            if let answer = step.answer {
                Text(answer.answerText ?? answer.body)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.leading, 18)
                let pct = Int(answer.confidence.value * 100)
                Text("Confidence \(pct)% · \(answer.citations.count) citation(s)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 18)
            } else {
                Text("(no answer recorded)")
                    .font(.callout.italic())
                    .foregroundStyle(.secondary)
                    .padding(.leading, 18)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - I/O

    private func refresh() async {
        guard let repo = appState.investigations else { return }
        do {
            let list = try await repo.recent()
            await MainActor.run { self.headers = list }
        } catch {
            await MainActor.run { self.error = "\(error)" }
        }
    }

    private func loadDetail(id: UUID?) async {
        guard let id, let repo = appState.investigations else {
            await MainActor.run { self.detail = nil }
            return
        }
        await MainActor.run { self.loading = true; self.error = nil }
        do {
            let inv = try await repo.load(id)
            await MainActor.run {
                self.detail = inv
                self.loading = false
            }
        } catch {
            await MainActor.run {
                self.error = "\(error)"
                self.loading = false
            }
        }
    }

    private func delete(_ header: InvestigationHeader) async {
        guard let repo = appState.investigations else { return }
        try? await repo.delete(header.id)
        await refresh()
        await MainActor.run {
            if selectedID == header.id {
                selectedID = nil
                detail = nil
            }
        }
    }

    /// Phase J.3 — Vol 25 ¶9 / Vol 28 §Report Builder. Renders the
    /// selected investigation as a markdown report (executive
    /// summary + findings + appendices) and saves it via a macOS
    /// save panel. Citations are hyperlinked to the resolved source
    /// files when KnowledgeObjectRepository can map them.
    private func exportReport(for inv: Investigation) async {
        let builder = InvestigationReportBuilder()
        let markdown = await builder.render(
            investigation: inv,
            objects: appState.objects
        )
        await MainActor.run {
            #if canImport(AppKit)
            let savePanel = NSSavePanel()
            savePanel.title = "Save investigation report"
            savePanel.nameFieldStringValue = Self.suggestedFilename(for: inv)
            if let mdType = UTType(filenameExtension: "md") {
                savePanel.allowedContentTypes = [mdType]
            }
            savePanel.canCreateDirectories = true
            if savePanel.runModal() == .OK, let url = savePanel.url {
                do {
                    try markdown.write(to: url, atomically: true, encoding: .utf8)
                } catch {
                    self.error = "Failed to write report: \(error.localizedDescription)"
                }
            }
            #endif
        }
    }

    private static func suggestedFilename(for inv: Investigation) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let date = formatter.string(from: inv.createdAt)
        let safe = inv.question
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9\\s]", with: "", options: .regularExpression)
            .split(separator: " ")
            .prefix(6)
            .joined(separator: "-")
        let stub = safe.isEmpty ? "investigation" : safe
        return "\(date)-\(stub).md"
    }
}
