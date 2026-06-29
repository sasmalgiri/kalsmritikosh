//
//  OnboardingView.swift
//  Kalsmritikosh
//
//  First-run flow: introduces Atlas, surfaces detected hardware tier,
//  lists which capability tiers will be auto-recommended, and lets the
//  user pick their first folder to index. Skippable; reappears only
//  when no folders + no KOs exist.
//

import SwiftUI

#if canImport(AppKit)
import AppKit
#endif

public struct OnboardingView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var step: Step = .welcome
    @State private var detectedTier: String = "—"
    @State private var providerCount: Int = 0
    @State private var ramGB: Int = 0

    enum Step: Int { case welcome, hardware, folder, scope, done }

    /// Counts pulled from the live ledger after the user picks a
    /// folder, so the scope step can say "here's exactly what
    /// kalsmritikosh has indexed so far" rather than abstract claims.
    @State private var scopeCounts: ScopeCounts = .empty

    public struct ScopeCounts: Sendable {
        public var files: Int
        public var objects: Int
        public var entities: Int
        public var events: Int
        public var memoryObjects: Int

        public static let empty = ScopeCounts(files: 0, objects: 0, entities: 0, events: 0, memoryObjects: 0)
    }

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .padding(40)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(minWidth: 640, minHeight: 480)
        .task { await loadProfile() }
        .onChange(of: step) { _, newStep in
            if newStep == .scope {
                Task { await loadScopeCounts() }
            }
        }
    }

    private var header: some View {
        VStack(spacing: 6) {
            Image(systemName: "books.vertical.fill")
                .font(.system(size: 32))
                .foregroundStyle(.tint)
            Text("Welcome to Atlas")
                .font(.title.bold())
            Text("Your private knowledge operating system")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 20)
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome:
            welcomeStep
        case .hardware:
            hardwareStep
        case .folder:
            folderStep
        case .scope:
            scopeStep
        case .done:
            doneStep
        }
    }

    /// Trust-and-transparency panel: shows exactly which file
    /// categories kalsmritikosh processes, what the enrichment
    /// ladder produces, and (once any data exists) the live ledger
    /// counts so the user can verify what's actually been indexed.
    private var scopeStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("What kalsmritikosh can see")
                .font(.headline)
            Text("From every folder you add, kalsmritikosh reads:")
                .font(.callout)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                seeRow("Documents", "PDF, DOCX/DOC, TXT, MD, RTF, ODT, EPUB", "doc.text")
                seeRow("Spreadsheets", "XLSX/XLS, CSV, ODS", "tablecells")
                seeRow("Presentations", "PPTX/PPT", "rectangle.on.rectangle")
                seeRow("Email", "MBOX, EML, EMLX (Apple Mail), MSG, PST/OST, NSF (Lotus)", "envelope")
                seeRow("Images", "PNG, JPG, HEIC, TIFF, WebP (with OCR)", "photo")
                seeRow("Audio & Video", "MP3, WAV, M4A, MP4, MOV (transcribed)", "waveform")
                seeRow("Archives", "ZIP — expanded then ingested", "archivebox")
            }
            Divider().padding(.vertical, 6)
            Text("What it extracts (privacy-first, on-device):")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: 18) {
                scopeCount("Files", scopeCounts.files)
                scopeCount("Objects", scopeCounts.objects)
                scopeCount("Entities", scopeCounts.entities)
                scopeCount("Events", scopeCounts.events)
                scopeCount("Memory", scopeCounts.memoryObjects)
            }
            Text("Open the Completeness tab anytime to see per-file ingest health, or the Knowledge tab to browse what's been extracted.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: 560)
    }

    private func seeRow(_ title: String, _ formats: String, _ icon: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(.tint).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                Text(formats).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func scopeCount(_ label: String, _ n: Int) -> some View {
        VStack(spacing: 2) {
            Text("\(n)")
                .font(.title3.monospaced())
                .foregroundStyle(n > 0 ? .primary : .secondary)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(minWidth: 60)
    }

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            bullet("Everything stays on your Mac. No cloud unless you opt in.")
            bullet("Atlas ingests documents, emails, spreadsheets, presentations, images, audio, and video.")
            bullet("It extracts entities, events, timelines, summaries, and a memory layer per project / person / company.")
            bullet("Ask any question — answers come back with cited evidence and a confidence score.")
        }
        .frame(maxWidth: 520)
    }

    private var hardwareStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Detected hardware").font(.headline)
            HStack {
                Label("Memory", systemImage: "memorychip")
                Spacer()
                Text("\(ramGB) GB")
                    .font(.callout.monospaced())
            }
            HStack {
                Label("Tier", systemImage: "speedometer")
                Spacer()
                Text(detectedTier.capitalized)
                    .font(.callout.monospaced())
            }
            HStack {
                Label("AI providers ready", systemImage: "brain")
                Spacer()
                Text("\(providerCount)")
                    .font(.callout.monospaced())
            }
            Divider().padding(.vertical, 8)
            Text("Atlas will dynamically pick a model that fits your hardware. You can override in Settings later.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: 520)
    }

    private var folderStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Pick your first folder").font(.headline)
            Text("Choose a folder Atlas should monitor. Documents inside become searchable, summarizable, and answerable. You can add more later from the Sources tab.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 520, alignment: .leading)
            Button {
                pickFolder()
            } label: {
                Label("Choose folder…", systemImage: "folder.badge.plus")
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            // Phase L — App Store reviewer affordance. Lets a
            // reviewer (or a curious user) ingest the bundled
            // ProjectDelta fixture in one click instead of having
            // to provide their own data.
            if let demoURL = Self.bundledDemoArchiveURL() {
                Button {
                    tryDemoArchive(at: demoURL)
                } label: {
                    Label("Try the demo archive", systemImage: "sparkles")
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                }
                .controlSize(.small)
                Text("Loads the bundled ProjectDelta fixture (~8 sample emails + contracts) so you can see Atlas reconstruct a project narrative without ingesting your own data first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 520, alignment: .leading)
            }
            if !appState.bookmarks.roots.isEmpty {
                Text("\(appState.bookmarks.roots.count) folder(s) added.")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
    }

    /// Resolve the bundled demo archive's URL. Returns nil when the
    /// fixture isn't shipped in the bundle (e.g. unit-test builds
    /// where Resources/Fixtures was stripped).
    static func bundledDemoArchiveURL() -> URL? {
        Bundle.main.url(forResource: "ProjectDelta",
                        withExtension: nil,
                        subdirectory: "Fixtures")
    }

    private func tryDemoArchive(at url: URL) {
        try? appState.bookmarks.register(url: url)
    }

    private var doneStep: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 36))
                .foregroundStyle(.green)
            Text("You're ready.").font(.title3.bold())
            Text("Open the Sources tab to ingest your folder, then ask a question on the Ask tab.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
        }
    }

    private var footer: some View {
        HStack {
            if step != .welcome {
                Button("Back") {
                    step = Step(rawValue: step.rawValue - 1) ?? .welcome
                }
            }
            Spacer()
            Button(step == .done ? "Finish" : "Continue") {
                if step == .done {
                    dismiss()
                } else {
                    step = Step(rawValue: step.rawValue + 1) ?? .done
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(step == .folder && appState.bookmarks.roots.isEmpty)
        }
        .padding()
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.tint)
            Text(text).font(.callout)
        }
    }

    private func pickFolder() {
        #if canImport(AppKit)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? appState.bookmarks.register(url: url)
        #endif
    }

    private func loadProfile() async {
        if let hw = appState.hardware {
            detectedTier = hw.tier.rawValue
            ramGB = Int(hw.totalRAMBytes / 1_073_741_824)
        }
        if let caps = appState.capabilities {
            providerCount = await caps.allProviders().count
        }
    }

    /// Pull live counts from each repo. Each lookup is independent
    /// so a single failing repo doesn't blank the panel — the field
    /// stays at its last value (zero on first load).
    private func loadScopeCounts() async {
        var next = ScopeCounts.empty
        if let files = appState.files {
            next.files = (try? await files.count()) ?? 0
        }
        if let objects = appState.objects {
            next.objects = (try? await objects.count()) ?? 0
        }
        if let entities = appState.entities {
            next.entities = (try? await entities.canonicalCount()) ?? 0
        }
        if let events = appState.events {
            next.events = (try? await events.count()) ?? 0
        }
        if let memories = appState.memoryRepo {
            next.memoryObjects = (try? await memories.count()) ?? 0
        }
        await MainActor.run { self.scopeCounts = next }
    }
}
