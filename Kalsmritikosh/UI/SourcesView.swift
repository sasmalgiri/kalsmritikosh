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
    @State private var fileCount: Int = 0
    @State private var ingesting = false
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
                    }
                    .padding(12)
                    .cardSurface(cornerRadius: 12)
                }
            }
        }
    }

    private func refresh() async {
        guard let files = appState.files, let objects = appState.objects else { return }
        fileCount = (try? await files.count()) ?? 0
        recents = (try? await objects.recent(limit: 25)) ?? []
    }

    private func runIngestion() async {
        ingesting = true
        _ = await appState.ingestAllRoots()
        await refresh()
        ingesting = false
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
