//
//  SettingsView.swift
//  Kalsmritikosh
//
//  Lets the user see which providers the CapabilityRegistry currently
//  knows about, pin a specific provider per capability tier (reasoning,
//  summarization, embedding, etc.), and toggle the PrivacyGate that
//  decides whether cloud providers are eligible.
//

import SwiftUI

public struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var providerIDs: [String] = []
    @State private var manifests: [ModelManifest] = []
    @State private var pins: [ModelCapability: String] = [:]
    @State private var allowCloud: Bool = PrivacyGate.shared.allowCloudRouting
    @State private var baselineRunning = false
    @State private var baselineStatus: String?
    @State private var baselineReportURL: URL?

    private let surfacedCapabilities: [ModelCapability] = [
        .reasoning, .summarization, .extraction,
        .classification, .routing, .embedding
    ]

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Settings").font(.largeTitle.bold())

                privacySection
                Divider()
                providersSection
                Divider()
                pinningSection
                Divider()
                diagnosticsSection
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .task { await reload() }
    }

    private var diagnosticsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Diagnostics").font(.title3.bold())
            Text("Generate the Gate 1 baseline. Boots an isolated copy of Atlas into a temp directory, ingests the bundled ProjectDelta fixture, runs the EvalKit harness through the freshly-booted brain, and writes `eval-report.md` to the app container's Documents folder. Your real database is untouched.")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button {
                    Task { await runBaseline() }
                } label: {
                    if baselineRunning {
                        Label("Running…", systemImage: "hourglass")
                    } else {
                        Label("Generate Gate 1 Baseline", systemImage: "checkmark.seal")
                    }
                }
                .disabled(baselineRunning)
                if let url = baselineReportURL {
                    Button {
                        #if canImport(AppKit)
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                        #endif
                    } label: {
                        Label("Reveal in Finder", systemImage: "folder")
                    }
                }
            }
            if let status = baselineStatus {
                Text(status)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private func runBaseline() async {
        baselineRunning = true
        baselineStatus = "Booting isolated AppState…"
        defer { baselineRunning = false }
        do {
            let result = try await Gate1Baseline.generate()
            baselineReportURL = result.reportURL
            let probeLine = result.retrievalProbeURL.map { "L1 retrieval probe: \($0.path)" } ?? "L1 retrieval probe: (not written)"
            baselineStatus = """
            ✓ Report written
            \(result.reportURL.path)
            ingested fixtures: \(result.ingestedFixtureFiles) in \(String(format: "%.1f", result.ingestSeconds))s
            questions evaluated: \(result.questionCount) in \(String(format: "%.1f", result.querySeconds))s
            \(probeLine)
            """
        } catch {
            baselineReportURL = nil
            baselineStatus = "✗ Failed: \(error)"
        }
    }

    private var privacySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Privacy").font(.title3.bold())
            Toggle("Allow cloud-routed providers", isOn: $allowCloud)
                .onChange(of: allowCloud) { _, newValue in
                    PrivacyGate.shared.allowCloudRouting = newValue
                }
            Text("When off, the CapabilityRegistry never returns providers whose privacy tier is `cloud`. Local-network providers (Ollama on this machine) are always allowed regardless.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var providersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Registered providers").font(.title3.bold())
            if manifests.isEmpty {
                Text("No providers registered.").foregroundStyle(.secondary)
            } else {
                ForEach(manifests, id: \.id) { manifest in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(manifest.displayName).font(.body.weight(.medium))
                            Spacer()
                            Text(manifest.privacyLevel.rawValue)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Text(manifest.capabilities.map(\.rawValue).sorted().joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("tier=\(manifest.tier.rawValue) · context=\(manifest.contextWindow)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary.opacity(0.7))
                    }
                    .padding(.vertical, 6)
                }
            }
        }
    }

    private var pinningSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pin a provider per capability").font(.title3.bold())
            Text("Overrides the auto-recommendation. Choose \"Auto\" to let the registry rank by hardware + benchmark.")
                .font(.caption).foregroundStyle(.secondary)

            ForEach(surfacedCapabilities, id: \.self) { capability in
                HStack {
                    Text(capability.rawValue)
                        .font(.callout.monospaced())
                        .frame(width: 180, alignment: .leading)
                    Picker("", selection: Binding(
                        get: { pins[capability] ?? "" },
                        set: { newValue in
                            if newValue.isEmpty {
                                ModelUserPreferences.shared.clearPin(for: capability)
                                pins[capability] = nil
                            } else {
                                ModelUserPreferences.shared.setPin(newValue, for: capability)
                                pins[capability] = newValue
                            }
                        }
                    )) {
                        Text("Auto").tag("")
                        ForEach(providerIDs, id: \.self) { id in
                            Text(id).tag(id)
                        }
                    }
                    .labelsHidden()
                }
            }
        }
    }

    private func reload() async {
        guard let registry = appState.capabilities else { return }
        let mans = await registry.allManifests().sorted { $0.displayName < $1.displayName }
        let providers = await registry.allProviders().map(\.id).sorted()
        await MainActor.run {
            self.manifests = mans
            self.providerIDs = providers
            var dict: [ModelCapability: String] = [:]
            for cap in surfacedCapabilities {
                if let id = ModelUserPreferences.shared.pinnedProvider(for: cap) {
                    dict[cap] = id
                }
            }
            self.pins = dict
        }
    }
}
