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

    enum Step: Int { case welcome, hardware, folder, done }

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
        case .done:
            doneStep
        }
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
            if !appState.bookmarks.roots.isEmpty {
                Text("\(appState.bookmarks.roots.count) folder(s) added.")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
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
}
