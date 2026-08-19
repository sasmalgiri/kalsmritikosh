//
//  SourcesView.swift
//  Kalsmritikosh
//
//  Folder picker + recently ingested KnowledgeObjects.
//

import SwiftUI
import OSLog
import UniformTypeIdentifiers

#if canImport(AppKit)
import AppKit
#endif

public struct SourcesView: View {
    @Environment(AppState.self) private var appState
    @State private var recents: [KnowledgeObjectSummaryRow] = []
    /// The recently-ingested document whose insights panel is open.
    @State private var expandedDocID: KnowledgeObject.ID?
    @State private var fileCount: Int = 0
    @State private var ingesting = false
    /// ING-002 — the last bulk ingest's outcome; drives the failure banner.
    @State private var ingestSummary: IngestBatchSummary?
    /// UX-002 / ING-007 — LIVE ingest activity (parse/embed progress), NOT durable readiness.
    @State private var readiness: AppState.IngestProgress?
    /// USF-002 — durable, multi-dimensional source readiness (searchable / evidence-ready /
    /// analytical / needs-attention). Distinct from live activity above.
    @State private var durableReadiness: SourceReadinessSummary?
    @State private var rootPendingRemoval: BookmarkStore.Root?
    @State private var rootPendingRemovalCount: Int = 0
    /// Minimum-touch: drop folders anywhere on this screen to add them —
    /// no picker panel needed.
    @State private var dropTargeted = false

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let summary = ingestSummary, !summary.failures.isEmpty {
                ingestFailureBanner(summary)
            }
            if let d = durableReadiness, d.total > 0 {
                durableReadinessStrip(d)
            }
            if let r = readiness, (r.filesTotal > 0 || r.embedTotal > 0) {
                readinessStrip(r)
            }
            ScrollView {
                rootsSection
                    .padding(.horizontal)
                Divider().padding(.vertical, 12)
                recentsSection
                    .padding(.horizontal)
            }
            .scrollContentBackground(.hidden)
        }
        .background(AuroraBackdrop(intensity: 0.5))
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            handleFolderDrop(providers)
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Theme.brand, style: StrokeStyle(lineWidth: 3, dash: [9]))
                    .background(Theme.brand.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        Label("Drop folders to add them", systemImage: "folder.badge.plus")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(Theme.brand)
                    )
                    .padding(10)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: dropTargeted)
        .task {
            // Initial load + cheap polling refresh while the view is
            // visible. The task is cancelled by SwiftUI when the view
            // disappears, so this never runs unnecessarily.
            await refresh()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if Task.isCancelled { break }
                await refresh()
            }
        }
        .confirmationDialog(
            rootRemovalTitle,
            isPresented: Binding(
                get: { rootPendingRemoval != nil },
                set: { if !$0 { rootPendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Stop watching (keep what was learned)") {
                if let root = rootPendingRemoval {
                    Task {
                        await appState.removeRoot(root, strategy: .stopWatching)
                        rootPendingRemoval = nil
                        await refresh()
                    }
                }
            }
            Button("Stop and forget everything from this folder", role: .destructive) {
                if let root = rootPendingRemoval {
                    Task {
                        await appState.removeRoot(root, strategy: .stopAndForget)
                        rootPendingRemoval = nil
                        await refresh()
                    }
                }
            }
            Button("Cancel", role: .cancel) { rootPendingRemoval = nil }
        } message: {
            Text("\(rootPendingRemovalCount) file(s) from this folder are in the knowledge base.")
        }
    }

    private var rootRemovalTitle: String {
        if let root = rootPendingRemoval {
            return "Remove \(root.displayName)?"
        }
        return "Remove folder?"
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading) {
                Text("Sources")
                    .font(Theme.display(28, .bold))
                Text("\(fileCount) file(s) ingested")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            InfoPopoverButton(
                title: "Sources = your knowledge base",
                message: "Add folders here. Kalsmritikosh watches them and ingests every supported file into the searchable, answerable ledger.",
                systemImage: "folder.badge.plus",
                bullets: [
                    "New files dropped into a watched folder are ingested automatically",
                    "“Ingest All” re-scans every folder now",
                    "This is different from Convert, which is one-shot and saves nothing"
                ]
            )
            Spacer()
            Button {
                Task { await runIngestion() }
            } label: {
                if ingesting {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Ingest All", systemImage: "arrow.triangle.2.circlepath")
                }
            }
            .disabled(ingesting || appState.bookmarks.roots.isEmpty)
            Button(action: pickFolder) {
                Label("Add Folder…", systemImage: "plus")
            }
        }
        .padding()
    }

    private var rootsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Folders")
                .font(.headline)
            if appState.bookmarks.roots.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Add a folder to start building your knowledge base.")
                        .foregroundStyle(.secondary)
                    // Minimum-touch: the primary action lives right in the
                    // empty state, so the user doesn't have to find the
                    // button in the header.
                    Button(action: pickFolder) {
                        Label("Add Folder…", systemImage: "folder.badge.plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                .padding(.vertical, 8)
            } else {
                ForEach(appState.bookmarks.roots) { root in
                    HStack {
                        Image(systemName: "folder")
                            .foregroundStyle(Theme.brand)
                        VStack(alignment: .leading) {
                            Text(root.displayName)
                            Text(resolvedPath(for: root))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            Task {
                                rootPendingRemovalCount = await appState.countFiles(underRoot: root)
                                rootPendingRemoval = root
                            }
                        } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                    }
                    .padding(12)
                    .cardSurface(cornerRadius: 12)
                }
            }
        }
    }

    private var recentsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recently Ingested")
                .font(.headline)
            if recents.isEmpty {
                Text("Run \"Ingest All\" after adding a folder to see KnowledgeObjects here.")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(recents) { row in
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(alignment: .top) {
                            Image(systemName: icon(for: row.sourceType))
                                .foregroundStyle(Theme.brand)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.sourceFile.lastPathComponent)
                                    .font(.body)
                                Text(row.preview)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Spacer()
                            Text(row.sourceType.rawValue.uppercased())
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                            Image(systemName: expandedDocID == row.id ? "chevron.down" : "chevron.right")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                expandedDocID = expandedDocID == row.id ? nil : row.id
                            }
                        }
                        // COMPETITOR-DNA — who's named here + what else to read.
                        if expandedDocID == row.id {
                            DocumentInsightsPanel(objectID: row.id)
                                .padding(.top, 8)
                        }
                    }
                    .padding(12)
                    .cardSurface(cornerRadius: 12)
                    .help("Click to see who is named in this document and related documents")
                }
            }
        }
    }

    private func refresh() async {
        guard let files = appState.files, let objects = appState.objects else { return }
        fileCount = (try? await files.count()) ?? 0
        let all = (try? await objects.recent(limit: 25)) ?? []
        recents = await appState.screenAuthorizer?.filterRows(all, boundary: .globalOwner) ?? []
        readiness = await appState.ingestProgress()   // UX-002 / ING-007 — LIVE activity
        durableReadiness = await appState.sourceReadinessSummary()   // USF-002 — durable readiness
    }

    private func runIngestion() async {
        ingesting = true
        _ = await appState.ingestAllRoots()
        ingestSummary = appState.lastIngestSummary   // ING-002 — surface which files failed
        await refresh()
        ingesting = false
    }

    /// USF-002 — durable, multi-dimensional readiness counts (never a single percentage). Distinct
    /// from the live activity strip below: these describe what each source can actually do now.
    @ViewBuilder
    private func durableReadinessStrip(_ d: SourceReadinessSummary) -> some View {
        HStack(spacing: 16) {
            durableCount("Searchable", d.searchable, "magnifyingglass", .blue)
            durableCount("Evidence-ready", d.evidenceReady, "checkmark.seal", .green)
            durableCount("Analytical", d.analyticallyReady, "chart.bar.doc.horizontal", .purple)
            if d.needsAttention + d.deferred > 0 {
                durableCount("Needs attention", d.needsAttention + d.deferred, "exclamationmark.triangle", .orange)
            }
            Spacer()
        }
        .padding(.horizontal).padding(.top, 8)
    }

    @ViewBuilder
    private func durableCount(_ title: String, _ count: Int, _ symbol: String, _ tint: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text("\(count)").font(.caption.weight(.semibold).monospacedDigit())
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }

    /// UX-002 / ING-007 — LIVE ingest activity (parse vs embed), separate from durable readiness.
    /// Each dimension shows its own done/total and an in-progress hint; never a single vague %.
    @ViewBuilder
    private func readinessStrip(_ r: AppState.IngestProgress) -> some View {
        HStack(spacing: 16) {
            readinessDimension(
                title: "Parsed", done: r.filesDone, total: r.filesTotal,
                busy: r.parsing, symbol: "doc.text.magnifyingglass")
            readinessDimension(
                title: "Embedded", done: r.embedDone, total: r.embedTotal,
                busy: r.embedding, symbol: "sparkles")
            if r.idle {
                Label("Ready", systemImage: "checkmark.seal.fill")
                    .font(.caption.weight(.semibold)).foregroundStyle(.green)
            }
            Spacer()
        }
        .padding(.horizontal).padding(.top, 8)
    }

    @ViewBuilder
    private func readinessDimension(title: String, done: Int, total: Int,
                                    busy: Bool, symbol: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .foregroundStyle(busy ? Theme.brand : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption2).foregroundStyle(.secondary)
                Text(total > 0 ? "\(done)/\(total)" : "—")
                    .font(.caption.weight(.semibold)).monospacedDigit()
            }
            if busy { ProgressView().controlSize(.mini) }
        }
    }

    /// ING-002 — a neutral banner naming the files that couldn't be processed, so a
    /// bulk ingest never silently drops files. Preserve-not-hide: rows stay on disk;
    /// this only reports what the run could not turn into evidence.
    @ViewBuilder
    private func ingestFailureBanner(_ summary: IngestBatchSummary) -> some View {
        let shown = summary.failures.prefix(5)
        VStack(alignment: .leading, spacing: 4) {
            Label(summary.headline, systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.orange)
            ForEach(Array(shown.enumerated()), id: \.offset) { _, f in
                Text("• \(f.fileName) — \(f.stage == .timeout ? "timed out" : "couldn't be processed")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if summary.failures.count > shown.count {
                Text("…and \(summary.failures.count - shown.count) more")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private func resolvedPath(for root: BookmarkStore.Root) -> String {
        do {
            let url = try appState.bookmarks.resolve(root)
            defer { appState.bookmarks.stopAccessing(url) }
            return url.path
        } catch {
            return "<unavailable>"
        }
    }

    private func icon(for type: SourceType) -> String {
        switch type.category {
        case .document: return "doc.text"
        case .spreadsheet: return "tablecells"
        case .presentation: return "rectangle.on.rectangle"
        case .email: return "envelope"
        case .image: return "photo"
        case .audio: return "waveform"
        case .video: return "video"
        case .archive: return "archivebox"
        case .chat: return "message"
        case .browserHistory: return "safari"
        case .unknown: return "doc"
        }
    }

    /// Register every dropped directory as a watched root. Files (non-dirs)
    /// are ignored — this screen watches folders, not individual files.
    private func handleFolderDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            handled = true
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.hasDirectoryPath else { return }
                Task { @MainActor in
                    do { try appState.bookmarks.register(url: url) }
                    catch { KalsmritikoshLog.ui.error("Drop-registered folder failed: \(String(describing: error), privacy: .public)") }
                    await refresh()
                }
            }
        }
        return handled
    }

    private func pickFolder() {
        #if canImport(AppKit)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Select Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try appState.bookmarks.register(url: url) }
        catch { print("Bookmark registration failed: \(error)") }
        #endif
    }
}
