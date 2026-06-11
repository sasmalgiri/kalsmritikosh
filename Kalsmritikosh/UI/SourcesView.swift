//
//  SourcesView.swift
//  Kalsmritikosh
//
//  Folder picker + recently ingested KnowledgeObjects.
//

import SwiftUI

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
        }
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
                    .font(.title2.bold())
                Text("\(fileCount) file(s) ingested")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
                Text("Add a folder to start building your knowledge base.")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(appState.bookmarks.roots) { root in
                    HStack {
                        Image(systemName: "folder")
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
                    .padding(.vertical, 4)
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
                            .foregroundStyle(.tint)
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
                    .padding(.vertical, 4)
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
        case .unknown: return "doc"
        }
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
