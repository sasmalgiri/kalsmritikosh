//
//  LiveDashboardView.swift
//  Kalsmritikosh
//
//  Phase J.13 — live observability. A single SwiftUI surface that
//  shows the running state of the system: the ingest workflow as a
//  swim-lane, file-area coverage, in-flight ingest, background
//  services, performance counters, and a small entity-graph viz.
//
//  Renders from `appState.liveMetrics` which is an @Observable
//  polling ~every 2 seconds. No additional polling here — the view
//  redraws when SwiftUI tracks a change in `current`.
//

import SwiftUI
import Charts

public struct LiveDashboardView: View {
    @Environment(AppState.self) private var appState
    @State private var rootCoverage: [(displayName: String, fileCount: Int)] = []
    @State private var tierCounts: [EnrichmentTier: Int] = [:]
    @State private var gapCount: Int = 0

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if let live = appState.liveMetrics {
                    snapshotRow(live.current)
                    llmBudgetPanel(live.current)
                    enrichmentTiersPanel()
                    pipelineStrip(live.current.pipelineCounters)
                    throughputChart(live.throughput)
                    Divider().padding(.vertical, 4)
                    HStack(alignment: .top, spacing: 18) {
                        fileAreasPanel
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                        formatBreakdownPanel(live.formatCounts)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    Divider().padding(.vertical, 4)
                    coveragePanel(live.current)
                    Divider().padding(.vertical, 4)
                    HStack(alignment: .top, spacing: 18) {
                        servicesPanel(live.serviceStatuses)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                        performancePanel(live.current)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                } else {
                    ContentUnavailableView(
                        "Live metrics not booted yet",
                        systemImage: "waveform.path.ecg",
                        description: Text("Wait for AppState to finish booting; the live polling task starts as the final boot step.")
                    )
                }
                Spacer(minLength: 24)
            }
            .padding(18)
        }
        .task {
            await loadRootCoverage()
        }
        .task {
            await loadEnrichmentTiers()
        }
        .onAppear {
            // Phase J.13 — start polling only while the Live tab is
            // visible. Saves ~0.5–1% continuous CPU when the user is
            // on Ask / History / Notebook / etc.
            appState.liveMetrics?.start()
        }
        .onDisappear {
            appState.liveMetrics?.stop()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(systemName: "waveform.path.ecg")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text("Live")
                        .font(.title2.weight(.semibold))
                    InfoPopoverButton(
                        title: "Live dashboard",
                        message: "A real-time window into ingestion and the engine while you work — updates as files are processed and questions are answered.",
                        systemImage: "waveform.path.ecg",
                        bullets: [
                            "Pipeline stages + throughput (files/sec)",
                            "Enrichment tiers (hot/warm/cold) and detected gaps",
                            "Provider health, cache hit-rate, LLM call counts"
                        ]
                    )
                }
                Text("Real-time view of ingestion and the engine — pipeline stages, throughput, enrichment tiers, gaps and service health.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let last = appState.liveMetrics?.current.capturedAt,
               last > .distantPast {
                Text("updated \(last.formatted(date: .omitted, time: .standard))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Snapshot

    @ViewBuilder
    private func snapshotRow(_ sample: LiveMetrics.Sample) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 6), spacing: 12) {
            snapshotCell("Files", sample.fileCount, "doc.on.doc")
            snapshotCell("Objects", sample.objectCount, "shippingbox")
            snapshotCell("Chunks", sample.chunkCount, "rectangle.split.3x1")
            snapshotCell("Entities", sample.entityCount, "person.2")
            snapshotCell("Events", sample.eventCount, "calendar.badge.clock")
            snapshotCell("Causal links", sample.causalLinkCount, "arrow.triangle.branch", tint: .purple)
            snapshotCell("Counterfactuals", sample.hypotheticalLinkCount, "questionmark.bubble", tint: .indigo)
            snapshotCell("Memories", sample.memoryCount, "brain.head.profile")
            snapshotCell("Summaries", sample.summaryCount, "text.book.closed")
            snapshotCell("Investigations", sample.investigationCount, "magnifyingglass.circle")
            snapshotCell("Saved Q", sample.savedQueryCount, "bookmark")
            snapshotCell(
                "In flight",
                sample.ingestActiveCount,
                "tray.full",
                tint: sample.ingestActiveCount > 0 ? .green : .secondary
            )
        }
    }

    @ViewBuilder
    private func snapshotCell(_ label: String, _ value: Int, _ icon: String, tint: Color = .tint) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(
                        LinearGradient(colors: [tint, tint.opacity(0.7)],
                                       startPoint: .top, endPoint: .bottom),
                        in: RoundedRectangle(cornerRadius: 6)
                    )
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            CountUpText(value) { $0.formatted() }
                .font(.title2.weight(.bold))
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: 12, tint: tint)
    }

    // MARK: - LLM budget (ledger-first reduction)

    @ViewBuilder
    private func llmBudgetPanel(_ sample: LiveMetrics.Sample) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "bolt.badge.clock")
                    .foregroundStyle(Theme.brand)
                Text("LLM budget")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(sample.llmSkipRate * 100))% skipped")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.green)
            }
            HStack(spacing: 10) {
                budgetTile("Calls run", sample.llmCallsRun, "waveform", .blue)
                budgetTile("Skipped", sample.llmCallsSkipped, "bolt.slash", .green)
                budgetTile("Timeouts", sample.llmTimeouts, "clock.badge.exclamationmark", .orange)
                budgetTile("Embed cache", Int(sample.embedHitRate * 100), "externaldrive.badge.checkmark", .purple, suffix: "%")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: 12)
    }

    @ViewBuilder
    private func budgetTile(_ label: String, _ value: Int, _ icon: String, _ tint: Color, suffix: String = "") -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: icon).foregroundStyle(tint).imageScale(.small)
                Text(label).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack(spacing: 0) {
                CountUpText(value).font(.title3.weight(.bold)).monospacedDigit()
                if !suffix.isEmpty { Text(suffix).font(.callout.weight(.semibold)).foregroundStyle(.secondary) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Enrichment tiers (Hot / Warm / Cold)

    @ViewBuilder
    private func enrichmentTiersPanel() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "thermometer.medium")
                    .foregroundStyle(Theme.brand)
                Text("Enrichment tiers (Hot / Warm / Cold)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            HStack(spacing: 10) {
                tierTile(EnrichmentTier.hot.displayName, tierCounts[.hot] ?? 0, "flame", Theme.brand)
                tierTile(EnrichmentTier.warm.displayName, tierCounts[.warm] ?? 0, "sun.max", .orange)
                tierTile(EnrichmentTier.cold.displayName, tierCounts[.cold] ?? 0, "snowflake", .secondary)
                tierTile("Gaps flagged", gapCount, "questionmark.diamond", .pink)
            }
            Text("Only hot documents get deep LLM enrichment in Hot/Warm/Cold mode.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: 12)
    }

    @ViewBuilder
    private func tierTile(_ label: String, _ value: Int, _ icon: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: icon).foregroundStyle(tint).imageScale(.small)
                Text(label).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            CountUpText(value).font(.title3.weight(.bold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Pipeline swim-lane

    @ViewBuilder
    private func pipelineStrip(_ counters: [PipelineMetrics.Stage: Int]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Ingest workflow")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 0) {
                ForEach(Array(PipelineMetrics.Stage.allCases.enumerated()), id: \.element) { idx, stage in
                    let count = counters[stage] ?? 0
                    VStack(spacing: 2) {
                        Text(stage.humanLabel)
                            .font(.caption2.weight(.semibold))
                        Text(count.formatted())
                            .font(.callout.monospacedDigit())
                    }
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(
                        Self.stageColor(for: stage).opacity(0.15),
                        in: .rect(cornerRadius: 6)
                    )
                    if idx < PipelineMetrics.Stage.allCases.count - 1 {
                        Image(systemName: "chevron.right")
                            .imageScale(.small)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 2)
                    }
                }
            }
            if let lastFile = appState.liveMetrics?.current.ingestLastFile {
                Text("last file: \(lastFile)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private static func stageColor(for stage: PipelineMetrics.Stage) -> Color {
        switch stage {
        case .discovered:    return .blue
        case .loaded:        return .teal
        case .chunked:       return .green
        case .embedded:      return .mint
        case .entities:      return .orange
        case .events:        return .pink
        case .relationships: return .purple
        case .bonds:         return .indigo
        }
    }

    // MARK: - Throughput chart

    @ViewBuilder
    private func throughputChart(_ points: [LiveMetrics.ThroughputPoint]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Throughput (last \(points.count) samples)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if points.isEmpty {
                Text("warming up…")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Chart {
                    ForEach(points) { point in
                        ForEach(PipelineMetrics.Stage.allCases, id: \.self) { stage in
                            LineMark(
                                x: .value("Time", point.timestamp),
                                y: .value(stage.humanLabel, point.perStage[stage] ?? 0)
                            )
                            .foregroundStyle(by: .value("Stage", stage.humanLabel))
                            .interpolationMethod(.monotone)
                        }
                    }
                }
                .frame(height: 120)
                .chartXAxis(.hidden)
                .chartLegend(position: .bottom, alignment: .leading)
            }
        }
    }

    // MARK: - File areas

    private var fileAreasPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("File areas")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if rootCoverage.isEmpty {
                Text("No bookmarked roots yet.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(rootCoverage, id: \.displayName) { row in
                    HStack {
                        Image(systemName: "folder")
                            .foregroundStyle(.tint)
                        Text(row.displayName)
                            .font(.callout)
                            .lineLimit(1)
                        Spacer()
                        Text("\(row.fileCount) file\(row.fileCount == 1 ? "" : "s")")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.04))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
        )
        .cornerRadius(10)
    }

    // MARK: - Background services

    private func servicesPanel(_ statuses: [LastRunStatus]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Background services")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(statuses, id: \.serviceID) { status in
                richServicePill(status: status)
            }
            // Health pills for the services that don't yet expose
            // LastRunStatus (status will be added incrementally).
            simplePill(label: "NarrativeSlotBackfiller")
            simplePill(label: "QualityTierBackfiller")
            simplePill(label: "ContextPrefixBackfiller")
            simplePill(label: "NightlyCompressionScheduler")
            simplePill(label: "FolderWatcher",
                       reachable: appState.folderWatcher != nil)
            simplePill(label: "IncrementalUpdater",
                       reachable: appState.incrementalUpdater != nil)
        }
        .padding(12)
        .background(Color.secondary.opacity(0.04))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
        )
        .cornerRadius(10)
    }

    @ViewBuilder
    private func richServicePill(status: LastRunStatus) -> some View {
        let pretty = Self.prettyServiceID(status.serviceID)
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle()
                    .fill(status.idle ? .green : .yellow)
                    .frame(width: 8, height: 8)
                Text(pretty)
                    .font(.caption.monospaced())
                Spacer()
                Text(status.idle ? "idle" : "running")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let finishedAt = status.finishedAt {
                HStack(spacing: 6) {
                    Text("last run \(Self.relativeAgo(finishedAt))")
                    Text("· \(status.resultCount) result\(status.resultCount == 1 ? "" : "s")")
                    if let dur = status.durationSeconds {
                        Text(String(format: "· %.1fs", dur))
                    }
                    Text("· runs total: \(status.runCount)")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            } else {
                Text("not yet run")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func simplePill(label: String, reachable: Bool = true) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(reachable ? .green : .red)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.caption.monospaced())
            Spacer()
            Text(reachable ? "running" : "off")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private static func prettyServiceID(_ id: String) -> String {
        switch id {
        case "kalsmritikosh.causal.discover":       return "CausalDiscoverer"
        case "kalsmritikosh.cooccurrence.builder":  return "CooccurrenceGraphBuilder"
        case "kalsmritikosh.community.detect":      return "AgglomerativeCommunityDetector"
        case "kalsmritikosh.community.summarize":   return "CommunitySummarizer"
        default:                            return id
        }
    }

    private static func relativeAgo(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    // MARK: - Format breakdown

    private func formatBreakdownPanel(_ counts: [LiveMetrics.FormatCount]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Files by format")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if counts.isEmpty {
                Text("No files ingested yet.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                let maxCount = max(1, counts.map(\.count).max() ?? 1)
                ForEach(counts) { row in
                    HStack(alignment: .center, spacing: 8) {
                        Text(row.id.uppercased())
                            .font(.caption2.monospaced())
                            .frame(width: 56, alignment: .leading)
                        GeometryReader { proxy in
                            let frac = Double(row.count) / Double(maxCount)
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.accentColor.opacity(0.6))
                                .frame(width: proxy.size.width * frac, height: 12)
                        }
                        .frame(height: 12)
                        Text("\(row.count)")
                            .font(.caption2.monospacedDigit())
                            .frame(width: 56, alignment: .trailing)
                    }
                }
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.04))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
        )
        .cornerRadius(10)
    }

    // MARK: - Performance

    @ViewBuilder
    private func performancePanel(_ sample: LiveMetrics.Sample) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Performance")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            perfRow("DB on disk", value: Self.formatBytes(sample.dbBytes))
            perfRow("Process RAM", value: Self.formatBytes(Int64(sample.processMemoryBytes)))
            if let hardware = appState.hardware {
                perfRow("Device RAM", value: Self.formatBytes(Int64(hardware.totalRAMBytes)))
                perfRow("CPU cores", value: "\(ProcessInfo.processInfo.activeProcessorCount)")
            }
            if appState.hnswIndex != nil {
                perfRow("HNSW index", value: "ready")
            }
            perfRow("Memory cache", value: "warmed: \(appState.memoryCache != nil ? "✓" : "—")")
            perfRow("Bond graph cache", value: "warmed: \(appState.bondGraphCache != nil ? "✓" : "—")")
        }
        .padding(12)
        .background(Color.secondary.opacity(0.04))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
        )
        .cornerRadius(10)
    }

    @ViewBuilder
    private func perfRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption.monospacedDigit())
        }
    }

    // MARK: - Coverage progress bars

    /// Dynamic % progress for the actual pipeline stages. Each row
    /// shows the live ratio of "rows produced so far" to "candidates"
    /// (typically files or KOs depending on the stage), animated on
    /// every poll so the user sees progress in real time.
    @ViewBuilder
    private func coveragePanel(_ sample: LiveMetrics.Sample) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pipeline coverage")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            // 1. Files → KOs (extraction coverage)
            progressRow(
                label: "Files → KnowledgeObjects",
                numerator: sample.objectCount,
                denominator: sample.fileCount,
                tint: .blue
            )
            // 2. Chunks → embeddings
            progressRow(
                label: "Chunks → Vectors",
                numerator: sample.vectorCount,
                denominator: sample.chunkCount,
                tint: .teal
            )
            // 3. KOs → at least one entity (proxy: entityCount /
            //    objectCount, capped at 100% since a single KO may
            //    contribute many entities).
            progressRow(
                label: "KOs → Entities",
                numerator: min(sample.entityCount, sample.objectCount),
                denominator: sample.objectCount,
                tint: .orange
            )
            // 4. KOs → at least one event.
            progressRow(
                label: "KOs → Events",
                numerator: min(sample.eventCount, sample.objectCount),
                denominator: sample.objectCount,
                tint: .pink
            )
            // 5. Events → causal density (links per 2 events, capped).
            progressRow(
                label: "Events → Causal links",
                numerator: sample.causalLinkCount,
                denominator: max(1, sample.eventCount / 2),
                tint: .purple
            )
            // 6. In-flight indicator (just an indeterminate-feeling
            //    bar based on current activity).
            if sample.ingestActiveCount > 0 {
                HStack(spacing: 8) {
                    Image(systemName: "tray.full.fill")
                        .foregroundStyle(.green)
                    Text("\(sample.ingestActiveCount) file\(sample.ingestActiveCount == 1 ? "" : "s") in flight")
                        .font(.caption.monospacedDigit())
                    if let last = sample.ingestLastFile {
                        Text("· last: \(last)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.04))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
        )
        .cornerRadius(10)
    }

    @ViewBuilder
    private func progressRow(
        label: String,
        numerator: Int,
        denominator: Int,
        tint: Color
    ) -> some View {
        let ratio: Double = denominator <= 0
            ? 0
            : min(1.0, Double(numerator) / Double(denominator))
        let pct = Int((ratio * 100).rounded())
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.caption)
                Spacer()
                Text("\(numerator.formatted()) / \(denominator.formatted())  ·  \(pct)%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(0.15))
                        .frame(height: 8)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(tint.opacity(0.85))
                        .frame(width: proxy.size.width * ratio, height: 8)
                        .animation(.easeInOut(duration: 0.6), value: ratio)
                }
            }
            .frame(height: 8)
        }
    }

    // MARK: - I/O

    private func loadRootCoverage() async {
        var rows: [(String, Int)] = []
        for root in appState.bookmarks.roots {
            let count = await appState.countFiles(underRoot: root)
            rows.append((root.displayName, count))
        }
        await MainActor.run { self.rootCoverage = rows }
    }

    private func loadEnrichmentTiers() async {
        let counts = await appState.enrichment?.countsByTier() ?? [:]
        let gaps = await appState.gapNodes?.count() ?? 0
        await MainActor.run {
            self.tierCounts = counts
            self.gapCount = gaps
        }
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB, .useKB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

private extension Color {
    static var tint: Color { Color.accentColor }
}
