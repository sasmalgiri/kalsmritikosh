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
import OSLog
import UniformTypeIdentifiers
#if canImport(AppKit)
import AppKit
#endif

public struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var providerIDs: [String] = []
    @State private var manifests: [ModelManifest] = []
    @State private var pins: [ModelCapability: String] = [:]
    @State private var allowCloud: Bool = PrivacyGate.shared.allowCloudRouting
    @State private var threadCoalescing: Bool = UserDefaults.standard.bool(forKey: "kalsmritikosh.moveA.threadCoalescing")
    @State private var showIngestGuide = false
    /// SURFACE STYLE switch — classic vs catalog-driven analytic launchers.
    @AppStorage(FeatureFlags.preferClassicSurfacesKey) private var preferClassicSurfaces = false
    /// CONFORMANCE STYLE switch — classic checklist readout vs strict per-rule assessment.
    @AppStorage(FeatureFlags.classicConformanceKey) private var classicConformance = false
    /// CUSTOM PROTOCOL STUDIO (roadmap 2.0) — shipped OFF by owner decision.
    @AppStorage(FeatureFlags.customProtocolStudioKey) private var customProtocolStudio = false
    @State private var showT3InResults: Bool = UserDefaults.standard.object(forKey: "kalsmritikosh.history.showT3InResults") as? Bool ?? false
    @State private var baselineRunning = false
    @State private var baselineStatus: String?
    @State private var baselineReportURL: URL?
    @State private var smokeRunning = false
    @State private var smokeStatus: String?
    @State private var smokeFailures: [String] = []
    @State private var fastEvalRunning = false
    @State private var fastEvalStatus: String?
    @State private var fastEvalReportURL: URL?
    @State private var gate3Running = false
    @State private var gate3Status: String?
    @State private var gate3ReportURL: URL?
    @State private var allDiagnosticsRunning = false
    @State private var allDiagnosticsStatus: String?
    @State private var allDiagnosticsURL: URL?
    @State private var releaseReadinessRunning = false
    @State private var releaseReadinessReport: ReleaseReadiness.Report?
    @State private var releaseReadinessStatus: String?
    @State private var realDataProbeRunning = false
    @State private var realDataProbeStatus: String?
    @State private var realDataProbeURL: URL?
    @State private var selfEvalRunning = false
    @State private var selfEvalStatus: String?
    @State private var milestoneRunning = false
    @State private var milestoneStatus: String?
    @State private var legacyRecoveryRunning = false
    @State private var legacyRecoveryStatus: String?
    @State private var wipeReingestRunning = false
    @State private var wipeReingestStatus: String?
    @State private var rebuildBondsRunning = false
    @State private var rebuildBondsStatus: String?
    @State private var rebuildSynthQRunning = false
    @State private var rebuildSynthQStatus: String?
    @State private var healthCheckRunning = false
    @State private var healthCheckStatus: String?
    @State private var healthCheckURL: URL?
    @State private var inventoryRunning = false
    @State private var inventoryStatus: String?
    @State private var inventoryURL: URL?
    @State private var modelAdviceExpanded: Bool = false
    @State private var ollamaPullRunning: Bool = false
    @State private var ollamaPullStatus: String?
    @State private var ollamaPullFraction: Double = 0

    // G2-3 BYO — bring-your-own model registries surfaced in Settings.
    @State private var ggufEntries: [GGUFRegistry.Entry] = []
    @State private var cloudEntries: [CloudEndpointRegistry.Endpoint] = []
    @State private var mlxModels: [MLXDiscovery.UserMLXModel] = []
    @State private var ggufImporterPresented: Bool = false
    // Cloud endpoint form fields.
    @State private var newCloudName: String = ""
    @State private var newCloudBaseURL: String = "https://api.openai.com/v1"
    @State private var newCloudModelName: String = "gpt-4o-mini"
    @State private var newCloudAPIKey: String = ""
    @State private var newCloudContextWindow: String = "128000"
    @State private var newCloudFamily: String = "openai"
    @State private var newCloudTier: ModelManifest.Tier = .large
    @State private var cloudFormError: String?

    private let surfacedCapabilities: [ModelCapability] = [
        .reasoning, .summarization, .extraction,
        .classification, .routing, .embedding
    ]

    /// Everyday users never need the model/provider/diagnostics machinery —
    /// the app auto-selects the best model for the device. Those sections live
    /// under a collapsed "Advanced" disclosure, off by default.
    @AppStorage("kalsmritikosh.settings.showAdvanced") private var showAdvanced = false
    /// Collapses the many individual diagnostic tools so only the single
    /// "release readiness" check is prominent. Off by default.
    @AppStorage("kalsmritikosh.settings.showMoreDiagnostics") private var showMoreDiagnostics = false

    /// D-10 — anchor requested by the ⌘K palette / menu bar. When set, the
    /// matching group is expanded, scrolled into view, and flashed twice.
    @Binding private var anchor: SettingsAnchor?
    @State private var flashedAnchor: SettingsAnchor?

    public init(anchor: Binding<SettingsAnchor?> = .constant(nil)) {
        self._anchor = anchor
    }

    public var body: some View {
        ScrollViewReader { proxy in
            settingsScroll
                .onChange(of: anchor) { _, new in
                    if let new { reveal(new, proxy: proxy) }
                }
                .task {
                    if let a = anchor { reveal(a, proxy: proxy) }
                }
        }
    }

    private var settingsScroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Settings").font(Theme.display(28, .bold))
                    Text("Kalsmritikosh runs itself — it picks the best on-device model for your Mac automatically. Set your privacy and background preferences here; everything technical is under Advanced.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    selfCheckChip
                }

                // ── Everyday settings — each category collapsed behind its
                //    header so Settings opens minimal. Click a header to expand.
                if let advice = appState.modelChoiceAdvice, advice.severity != .ok {
                    modelChoiceBanner(advice)
                }
                #if DEBUG
                if let setup = appState.ollamaSetupSuggestion {
                    settingsGroup("Local model setup", "cpu", anchor: .localModelSetup) { ollamaSetupSection(setup) }
                }
                #endif
                settingsGroup("Answering & modes", "slider.horizontal.3", anchor: .answeringModes) { systemModeSection }
                settingsGroup("Privacy", "hand.raised", anchor: .privacy) { privacySection }
                settingsGroup("Background maintenance", "moon.zzz", anchor: .backgroundMaintenance) { maintenanceSection }
                settingsGroup("Ingest options", "tray.and.arrow.down", anchor: .ingestOptions) { optionalIngestSection }
                settingsGroup("Your data", "trash", anchor: .yourData) { dataSection }
                settingsGroup("Help & feedback", "envelope", anchor: .helpFeedback) { feedbackSection }
                settingsGroup("Legal & privacy", "checkmark.shield", anchor: .legalPrivacy) { legalSection }

                // ── Advanced (collapsed by default) ───────────────────────
                Divider()
                DisclosureGroup(isExpanded: $showAdvanced) {
                    VStack(alignment: .leading, spacing: 24) {
                        intelligenceSection
                        Divider()
                        diagnosticsSection
                        // P2.6/P8.7 — model picker, provider list, BYO models,
                        // per-tier pinning and the evaluation runner are
                        // developer/internal tools, not consumer settings.
                        // SIXTEENTH REVIEW: the picker moved here too — the
                        // Release build registers only Apple Foundation Models
                        // + the bundled BGE models, so there is nothing to
                        // pick, and its copy referenced cloud/LAN/BYO models
                        // that do not exist in Release. DEBUG/internal only.
                        #if DEBUG
                        Divider()
                        modelPickerSection
                        Divider()
                        providersSection
                        Divider()
                        userModelsSection
                        Divider()
                        pinningSection
                        Divider()
                        narrativeEvalSection
                        #endif
                    }
                    .padding(.top, 12)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "wrench.and.screwdriver")
                            .foregroundStyle(Theme.brand)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Advanced").font(.title3.bold())
                            Text("Answering depth and diagnostics — power users only. The app works fully without touching these.")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
        .background(AuroraBackdrop(intensity: 0.5))
        .task {
            await reload()
            // Zero-touch: run the fast self-check automatically the first
            // time Settings opens (no LLM, seconds) so the verdict is shown
            // without the user hunting for a button. Cached on AppState, so
            // navigating away and back does not re-run it.
            await appState.runFastSelfCheckIfNeeded()
        }
    }

    /// Compact, always-visible self-check verdict at the very top of
    /// Settings. Auto-populated — the user never clicks to see it. Tapping
    /// re-runs the fast checks on demand.
    @ViewBuilder
    private var selfCheckChip: some View {
        if let r = appState.selfCheckReport {
            let passed = r.checks.filter(\.passed).count
            let ok = r.checks.allSatisfy { $0.passed || !$0.blocker }
            Button {
                Task { await runReleaseReadiness(mode: .fast) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: ok ? "checkmark.seal.fill" : "exclamationmark.octagon.fill")
                        .foregroundStyle(ok ? .green : .red)
                    Text(ok ? "Self-check passed" : "Self-check found issues")
                        .font(.caption.weight(.semibold))
                    Text("\(passed)/\(r.checks.count) checks · all formats")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                    if releaseReadinessRunning {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background((ok ? Color.green : Color.red).opacity(0.10), in: Capsule())
                .overlay(Capsule().stroke((ok ? Color.green : Color.red).opacity(0.30), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("Re-run the fast self-check (deterministic logic + all Convert formats). No LLM, a few seconds.")  // jargon-ok: developer diagnostics
        } else {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Running self-check…")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    /// HISTORY Phase F.4 — narrative-eval history. The
    /// EvalDashboardView reads NarrativeEvalReportStore for past runs
    /// (persisted by SmokeTest when KALSMRITIKOSH_NARRATIVE_EVAL=1) and
    /// renders each with delta arrows vs the previous run.
    private var narrativeEvalSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Narrative Eval History").font(.title3.bold())
            Text("Each run of the in-app SmokeTest with `KALSMRITIKOSH_NARRATIVE_EVAL=1` lands here. Coverage / citation density / contradiction recall / confidence RMSE — arrows show movement vs the previous run.")
                .font(.caption).foregroundStyle(.secondary)
            EvalDashboardView()
                .frame(minHeight: 300)
        }
    }

    private var diagnosticsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Diagnostics").font(.title3.bold())

            // THE one check to run before shipping — a single verdict banner
            // with a Fast (seconds) and Deep (full) button. Everything else is
            // tucked into the collapsed "More tools" group below so there is no
            // wall of buttons to choose between.
            // Release-readiness + eval/smoke harnesses are developer tools —
            // they speak in Gates, fixtures, and ship checks. DEBUG only.
            #if DEBUG
            releaseReadinessBanner
            #endif

            DisclosureGroup(isExpanded: $showMoreDiagnostics) {
              VStack(alignment: .leading, spacing: 8) {
            #if DEBUG
            Text("**Run Full Diagnostics** — one-button orchestrator. Runs the smoke test + Fast Eval + Gate 3 Multi-hop in sequence and writes a single unified `diagnostics-summary.md` you can share. ~10–12 minutes end-to-end.")  // jargon-ok: developer diagnostics
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button {
                    Task { await runAllDiagnostics() }
                } label: {
                    if allDiagnosticsRunning {
                        Label("Running…", systemImage: "hourglass")
                    } else {
                        Label("Run Full Diagnostics", systemImage: "play.circle.fill")
                    }
                }
                .disabled(allDiagnosticsRunning)
                if let url = allDiagnosticsURL {
                    Button {
                        #if canImport(AppKit)
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                        #endif
                    } label: {
                        Label("Reveal summary", systemImage: "doc.text")
                    }
                }
            }
            if let status = allDiagnosticsStatus {
                Text(status)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Divider().padding(.vertical, 4)

            Text("Generate the Gate 1 baseline. Boots an isolated copy of Kalsmritikosh into a temp directory, ingests the bundled ProjectDelta fixture, runs the EvalKit harness through the freshly-booted brain, and writes `eval-report.md` to the app container's Documents folder. Your real database is untouched.")
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

            Divider().padding(.vertical, 4)

            Text("Fast Eval — runs only 4 representative questions (1 per class). ~5 minutes vs ~20. Directional signal only; not a Gate 1 verdict.")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button {
                    Task { await runFastEval() }
                } label: {
                    if fastEvalRunning {
                        Label("Running…", systemImage: "hourglass")
                    } else {
                        Label("Run Fast Eval (4 questions)", systemImage: "bolt.fill")
                    }
                }
                .disabled(fastEvalRunning)
                if let url = fastEvalReportURL {
                    Button {
                        #if canImport(AppKit)
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                        #endif
                    } label: {
                        Label("Reveal in Finder", systemImage: "folder")
                    }
                }
            }
            if let status = fastEvalStatus {
                Text(status)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Divider().padding(.vertical, 4)
            #endif

            Text("Generate Knowledge Inventory — per-file readout of EVERYTHING Kalsmritikosh extracted from your archive: source path, content preview, entities, events, bonds. Pair against your originals to spot ingest gaps. Writes `knowledge-inventory.md` to ~/Documents/EvalBaselines/.")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button {
                    Task { await runInventory() }
                } label: {
                    if inventoryRunning {
                        Label("Generating…", systemImage: "hourglass")
                    } else {
                        Label("Generate Knowledge Inventory", systemImage: "list.bullet.rectangle")
                    }
                }
                .disabled(inventoryRunning)
                if let url = inventoryURL {
                    Button {
                        #if canImport(AppKit)
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                        #endif
                    } label: {
                        Label("Open inventory", systemImage: "doc.text")
                    }
                }
            }
            if let status = inventoryStatus {
                Text(status)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Divider().padding(.vertical, 4)

            Text("Check Data Health — read-only audit of your LIVE database. Counts every layer (files, KOs, chunks, entities, events, vectors, bonds, memory) and flags incomplete ingestion (KOs without chunks, entities without fact_type, etc.). Writes data-health-report.md to ~/Documents/EvalBaselines/. Safe to run anytime.")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button {
                    Task { await runHealthCheck() }
                } label: {
                    if healthCheckRunning {
                        Label("Auditing…", systemImage: "hourglass")
                    } else {
                        Label("Check Data Health", systemImage: "stethoscope")
                    }
                }
                .disabled(healthCheckRunning)
                if let url = healthCheckURL {
                    Button {
                        #if canImport(AppKit)
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                        #endif
                    } label: {
                        Label("Open report", systemImage: "doc.text")
                    }
                }
            }
            if let status = healthCheckStatus {
                Text(status)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            // A4 — synthetic questions are internal/debug-only; the rebuild
            // control is not shown in consumer release.
            #if DEBUG
            Divider().padding(.vertical, 4)

            Text("Rebuild synthetic questions — runs the heuristic generator over chunks of KOs ingested BEFORE the G2 wiring landed. Populates synthetic_questions + its FTS index so the question-shaped retrieval layer can match. No LLM calls; runs in seconds. Idempotent — KOs that already have questions are skipped.")  // jargon-ok: developer diagnostics
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button {
                    Task { await rebuildSyntheticQuestions() }
                } label: {
                    if rebuildSynthQRunning {
                        Label("Rebuilding…", systemImage: "hourglass")
                    } else {
                        Label("Rebuild Synthetic Questions", systemImage: "questionmark.bubble")
                    }
                }
                .disabled(rebuildSynthQRunning)
            }
            if let status = rebuildSynthQStatus {
                Text(status)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            // (DEBUG block continues: bond rebuild, Gate 3, and the smoke test
            // are developer/maintenance harnesses, not consumer settings.)

            Divider().padding(.vertical, 4)

            Text("Rebuild typed bonds — walks your existing knowledge_objects and re-runs BondConstructor against the already-extracted entities + events. Use this once after upgrading to a build that ships the fact_bonds table (v13) so your production archive picks up bonds without forcing a full re-ingest. Idempotent — safe to re-run.")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button {
                    Task { await rebuildBonds() }
                } label: {
                    if rebuildBondsRunning {
                        Label("Rebuilding…", systemImage: "hourglass")
                    } else {
                        Label("Rebuild Typed Bonds", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .disabled(rebuildBondsRunning)
            }
            if let status = rebuildBondsStatus {
                Text(status)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Divider().padding(.vertical, 4)

            Text("Gate 3 Multi-hop — runs only M1..M4, the typed-multihop subset the bond engine is designed to answer. Watch the Walk cov. / Walk steps/Q columns in the report to verify the schema-aware retrieval layer is firing.")  // jargon-ok: developer diagnostics
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button {
                    Task { await runGate3Multihop() }
                } label: {
                    if gate3Running {
                        Label("Running…", systemImage: "hourglass")
                    } else {
                        Label("Run Gate 3 Multi-hop (M1–M4)", systemImage: "point.3.connected.trianglepath.dotted")  // jargon-ok: developer diagnostics
                    }
                }
                .disabled(gate3Running)
                if let url = gate3ReportURL {
                    Button {
                        #if canImport(AppKit)
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                        #endif
                    } label: {
                        Label("Reveal in Finder", systemImage: "folder")
                    }
                }
            }
            if let status = gate3Status {
                Text(status)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Divider().padding(.vertical, 4)

            Text("Run the in-process smoke test. Boots an isolated AppState into a temp directory, ingests the bundled ProjectDelta fixture, runs every T1–T13 + G2-TEMPORAL + G2-1.5 assertion, and reports pass/fail counts. Your real database is untouched.")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button {
                    Task { await runSmokeTest() }
                } label: {
                    if smokeRunning {
                        Label("Running…", systemImage: "hourglass")
                    } else {
                        Label("Run Smoke Test", systemImage: "checkmark.circle")
                    }
                }
                .disabled(smokeRunning)
            }
            if let status = smokeStatus {
                Text(status)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if !smokeFailures.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(smokeFailures.enumerated()), id: \.offset) { _, line in
                        Text("• \(line)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }
                .padding(.leading, 8)
            }
            #endif
              }
            } label: {
                Label("More diagnostic tools (advanced)", systemImage: "wrench.and.screwdriver")
                    .font(.callout.weight(.medium))
            }
        }
    }

    /// One-button release gate. Visually distinct from the other
    /// diagnostics buttons so the user knows this is THE check to
    /// run before public distribution. PASS → safe to ship without
    /// TestFlight; FAIL → see report for blockers.
    @ViewBuilder
    private var releaseReadinessBanner: some View {
        // Prefer a run started here; otherwise show the auto self-check that
        // ran when Settings first opened — so the verdict + per-check list is
        // visible with zero clicks.
        let displayed = releaseReadinessReport ?? appState.selfCheckReport
        let verdictColor: Color = {
            guard let r = displayed else { return .blue }
            return r.releaseReady ? .green : .red
        }()
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: displayed.map { $0.releaseReady ? "checkmark.seal.fill" : "exclamationmark.octagon.fill" } ?? "shippingbox.fill")
                    .font(.title)
                    .foregroundStyle(verdictColor)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Release Readiness")
                        .font(.title3.bold())
                    Text("One button checks whether the app is ready to share. It runs the built-in tests and audits, then shows a single verdict — **green means ready**. Takes a couple of minutes; no internet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // THE single action. Runs the fast gate (no LLM, ~2–5 min) — the
            // right default for "is it ready". The slower/real-data variants are
            // small secondary links below so they don't compete for the click.
            Button {
                Task { await runReleaseReadiness(mode: .fast) }
            } label: {
                if releaseReadinessRunning {
                    Label("Checking…", systemImage: "hourglass")
                } else {
                    Label("Check if ready to ship", systemImage: "checkmark.seal.fill")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(verdictColor)
            .disabled(releaseReadinessRunning || realDataProbeRunning)

            // Secondary, de-emphasized options.
            HStack(spacing: 16) {
                Button("Full deep check (slow)") {
                    Task { await runReleaseReadiness(mode: .deep) }
                }
                .disabled(releaseReadinessRunning)
                Button("Test on my real files") {
                    Task { await runRealDataProbe() }
                }
                .disabled(realDataProbeRunning)
                if realDataProbeRunning { ProgressView().controlSize(.mini) }
                Button("Retrieval self-check") {
                    Task { await runRetrievalSelfEval() }
                }
                .disabled(selfEvalRunning)
                if selfEvalRunning { ProgressView().controlSize(.mini) }
                Button("Rebuild legal milestones") {
                    Task { await runMilestoneBackfill() }
                }
                .disabled(milestoneRunning)
                .help("Scan ingested documents for legal/patent milestones (filed, hearing, objection, granted) and add them as dated events — the story spine.")
                if milestoneRunning { ProgressView().controlSize(.mini) }
                Button("Recover legacy .doc/.xls") {
                    Task { await runLegacyRecovery() }
                }
                .disabled(legacyRecoveryRunning)
                .help("Re-ingest legacy Word/Excel (.doc/.xls) files that failed before the real OLE2 parsers landed. Idempotent.")
                if legacyRecoveryRunning { ProgressView().controlSize(.mini) }
                Button(role: .destructive) {
                    Task { await runWipeReingest() }
                } label: { Text("Wipe & re-ingest everything") }
                .disabled(wipeReingestRunning)
                .help("Start fresh: erase all ingested data and re-ingest every source folder through the current pipeline. Destructive — clears the ledger (workspaces/reviews too). Runs in place; no relaunch needed.")
                if wipeReingestRunning { ProgressView().controlSize(.mini) }
                if let url = realDataProbeURL {
                    Button("Reveal probe") {
                        #if canImport(AppKit)
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                        #endif
                    }
                }
                if let report = releaseReadinessReport {
                    Button("Reveal report") {
                        #if canImport(AppKit)
                        NSWorkspace.shared.activateFileViewerSelecting([report.reportURL])
                        #endif
                    }
                }
                Spacer(minLength: 0)
            }
            .font(.caption)
            .buttonStyle(.borderless)
            if let report = displayed {
                HStack(spacing: 6) {
                    Image(systemName: report.releaseReady ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(verdictColor)
                    Text(report.releaseReady ? "RELEASE READY: YES" : "RELEASE READY: NO")
                        .font(.headline)
                        .foregroundStyle(verdictColor)
                    Text(String(format: "· %.1fs · %d checks", report.totalSeconds, report.checks.count))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(report.checks.enumerated()), id: \.offset) { _, check in
                        HStack(alignment: .top, spacing: 6) {
                            Text(check.passed ? "✓" : (check.blocker ? "✗" : "⚠"))
                                .foregroundStyle(check.passed ? .green : (check.blocker ? .red : .orange))
                                .frame(width: 14, alignment: .leading)
                            Text(check.name).font(.caption.monospaced())
                            Spacer()
                            Text(check.detail)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                }
                .padding(.leading, 4)
                .padding(.top, 4)
            } else if let status = releaseReadinessStatus {
                Text(status)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            if let status = realDataProbeStatus {
                Divider().padding(.vertical, 2)
                Text(status)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let status = selfEvalStatus {
                Divider().padding(.vertical, 2)
                Text(status)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let status = milestoneStatus {
                Divider().padding(.vertical, 2)
                Text(status)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let status = legacyRecoveryStatus {
                Divider().padding(.vertical, 2)
                Text(status)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let status = wipeReingestStatus {
                Divider().padding(.vertical, 2)
                Text(status)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(verdictColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(verdictColor.opacity(0.35), lineWidth: 1)
        )
    }

    private func runReleaseReadiness(mode: ReleaseReadiness.Mode) async {
        releaseReadinessRunning = true
        releaseReadinessReport = nil
        releaseReadinessStatus = mode == .fast
            ? "Fast gate — schema → deterministic logic → convert exporters → engine/MoE → bundle → capability → live health (no LLM)…"  // jargon-ok: developer diagnostics
            : "Deep eval — everything in Fast PLUS smoke + Fast Eval + Gate 3 (LLM-heavy, may take hours)…"  // jargon-ok: developer diagnostics
        defer { releaseReadinessRunning = false }
        let result = await ReleaseReadiness.run(appState, mode: mode)
        releaseReadinessReport = result
        appState.recordSelfCheck(result)
        releaseReadinessStatus = nil
    }

    /// Runs a handful of questions against the user's LIVE archive (read-only)
    /// and reports LLM calls + latency + which real files got cited — the
    /// real-data complement to the fixture-based Fast/Deep evals.
    private func runRealDataProbe() async {
        realDataProbeRunning = true
        realDataProbeURL = nil
        realDataProbeStatus = "Probing your archive (read-only) — asking questions about your real entities…"
        defer { realDataProbeRunning = false }
        let result = await RealDataProbe.run(appState)
        realDataProbeURL = result.reportURL
        if result.results.isEmpty {
            realDataProbeStatus = "No questions could be built — is anything ingested yet?"
            return
        }
        realDataProbeStatus = """
        ✓ Real-data probe: \(result.questionCount) question(s)
        avg \(String(format: "%.1f", result.avgCallsPerQuestion)) LLM call(s)/question · avg \(String(format: "%.1f", result.avgLatencySeconds))s/question · \(String(format: "%.1f", result.totalSeconds))s total  // jargon-ok: developer diagnostics
        Report: \(result.reportURL?.lastPathComponent ?? "—")
        """
    }

    /// Label-free retrieval quality on the user's own data: recall@k for whether
    /// the index returns a chunk when queried with text drawn from it. Read-only.
    private func runRetrievalSelfEval() async {
        selfEvalRunning = true
        selfEvalStatus = "Sampling your chunks and measuring retrieval recall (read-only)…"
        defer { selfEvalRunning = false }
        guard let report = await appState.runRetrievalSelfEval() else {
            selfEvalStatus = "Retrieval self-check unavailable — the vector layer isn't ready yet."
            return
        }
        selfEvalStatus = """
        ✓ Retrieval self-check: \(report.summary)
        Measures whether the index finds what it stored — a real quality signal, but NOT the human-labelled answer-accuracy benchmark.
        """
    }

    /// Rebuild the legal/patent milestone events over already-ingested documents
    /// (new ingests get them automatically). Additive — inserts dated events; it
    /// never deletes.
    private func runMilestoneBackfill() async {
        milestoneRunning = true
        milestoneStatus = "Scanning documents for filed / hearing / objection / grant milestones…"
        defer { milestoneRunning = false }
        let n = await appState.backfillLegalMilestones()
        milestoneStatus = n > 0
            ? "✓ Added \(n) milestone event(s). Open Timeline or ask about the matter to see the full story."
            : "No legal/patent milestones found in the current documents."
    }

    /// Re-ingest legacy .doc/.xls files that failed before the real OLE2 parsers
    /// landed. Idempotent + per-document atomic.
    private func runLegacyRecovery() async {
        legacyRecoveryRunning = true
        legacyRecoveryStatus = "Re-ingesting legacy .doc / .xls files that failed before…"
        defer { legacyRecoveryRunning = false }
        legacyRecoveryStatus = await appState.recoverLegacyDocuments()
    }

    /// Start fresh: erase all ingested data + force a full re-ingest.
    private func runWipeReingest() async {
        wipeReingestRunning = true
        wipeReingestStatus = "Erasing all data, then re-ingesting every source folder…"
        defer { wipeReingestRunning = false }
        wipeReingestStatus = await appState.wipeAndReingestEverything()
    }

    private func runFastEval() async {
        fastEvalRunning = true
        fastEvalStatus = "Booting isolated AppState + running 4 questions…"
        defer { fastEvalRunning = false }
        do {
            let result = try await Gate1Baseline.generateFast()
            fastEvalReportURL = result.reportURL
            let providerLine = result.reasoningProviderID.map {
                "Reasoning provider: \($0)"
            } ?? "Reasoning provider: none (heuristic floor)"
            fastEvalStatus = """
            ✓ Report written
            \(result.reportURL.path)
            \(providerLine)
            ingested fixtures: \(result.ingestedFixtureFiles) in \(String(format: "%.1f", result.ingestSeconds))s
            questions evaluated: \(result.questionCount) in \(String(format: "%.1f", result.querySeconds))s
            """
        } catch {
            fastEvalReportURL = nil
            fastEvalStatus = "✗ Failed: \(error)"
        }
    }

    private func runAllDiagnostics() async {
        allDiagnosticsRunning = true
        allDiagnosticsStatus = "Running smoke + Fast Eval + Gate 3 Multi-hop… (~10–12 min)"  // jargon-ok: developer diagnostics
        defer { allDiagnosticsRunning = false }
        do {
            let result = try await Gate1Baseline.generateAllDiagnostics()
            allDiagnosticsURL = result.summaryURL
            let smokeLine: String
            if let smoke = result.smoke {
                smokeLine = "Smoke: \(smoke.ok ? "✓" : "✗") \(smoke.assertionsPassed.count) passed, \(smoke.assertionsFailed.count) failed"
            } else {
                smokeLine = "Smoke: ⚠️ \(result.smokeError ?? "no result")"
            }
            let fastLine = result.fastEval != nil ? "Fast Eval: ✓ \(result.fastEval!.questionCount)Q" : "Fast Eval: ⚠️ \(result.fastEvalError ?? "no result")"
            let gate3Line = result.gate3 != nil ? "Gate 3: ✓ \(result.gate3!.questionCount)Q" : "Gate 3: ⚠️ \(result.gate3Error ?? "no result")"
            allDiagnosticsStatus = """
            \(result.allPassed ? "✓ ALL PASSED" : "⚠️ PARTIAL/FAILED") · \(String(format: "%.1f", result.totalSeconds))s total
            \(smokeLine)
            \(fastLine)
            \(gate3Line)
            Unified summary: \(result.summaryURL.path)
            """
        } catch {
            allDiagnosticsURL = nil
            allDiagnosticsStatus = "✗ Orchestrator failed: \(error)"
        }
    }

    private func runInventory() async {
        inventoryRunning = true
        inventoryStatus = "Reading every KO and dumping extracted facts…"
        defer { inventoryRunning = false }
        do {
            let result = try await KnowledgeInventory.generate(appState)
            inventoryURL = result.reportURL
            inventoryStatus = """
            ✓ Inventory written
            \(result.reportURL.path)
            Files audited: \(result.filesAudited)
            Entities listed: \(result.totalEntities)
            Events listed: \(result.totalEvents)
            Bonds emitted from these KOs: \(result.totalBonds)
            """
        } catch {
            inventoryURL = nil
            inventoryStatus = "✗ Failed: \(error)"
        }
    }

    private func runHealthCheck() async {
        healthCheckRunning = true
        healthCheckStatus = "Auditing live database…"
        defer { healthCheckRunning = false }
        do {
            let result = try await DataHealthCheck.run(appState)
            healthCheckURL = result.reportURL
            let verdict = result.issuesFound == 0
                ? "✓ Clean — no issues detected"
                : "⚠️ \(result.issuesFound) issue(s) flagged — see report"
            healthCheckStatus = """
            \(verdict)
            \(result.summary)
            Report: \(result.reportURL.path)
            """
        } catch {
            healthCheckURL = nil
            healthCheckStatus = "✗ Failed: \(error)"
        }
    }

    private func rebuildSyntheticQuestions() async {
        rebuildSynthQRunning = true
        rebuildSynthQStatus = "Generating synthetic questions for existing chunks…"
        defer { rebuildSynthQRunning = false }
        guard let objects = appState.objects,
              let chunks = appState.chunks,
              let synthRepo = appState.syntheticQuestions else {
            rebuildSynthQStatus = "✗ AppState not booted — cannot reach repositories."
            return
        }
        let started = Date()
        let backfill = SyntheticQuestionsBackfill(
            knowledgeObjects: objects,
            chunks: chunks,
            syntheticQuestions: synthRepo
        )
        let stats = await backfill.run()
        let elapsed = Date().timeIntervalSince(started)
        let total = (try? await synthRepo.count()) ?? 0
        rebuildSynthQStatus = """
        ✓ Rebuild complete in \(String(format: "%.1f", elapsed))s
        KOs scanned: \(stats.knowledgeObjects)
        Questions written: \(stats.questionsWritten)
        Skipped (already had questions or no chunks): \(stats.skipped)
        Failed: \(stats.failed)
        Total synthetic questions in ledger now: \(total)
        """
    }

    private func rebuildBonds() async {
        rebuildBondsRunning = true
        rebuildBondsStatus = "Walking knowledge_objects + writing bonds…"
        defer { rebuildBondsRunning = false }
        guard let objects = appState.objects,
              let entities = appState.entities,
              let events = appState.events,
              let factBonds = appState.factBonds else {
            rebuildBondsStatus = "✗ AppState not booted — cannot reach repositories."
            return
        }
        let started = Date()
        let constructor = BondConstructor(repository: factBonds)
        let backfill = BondBackfill(
            knowledgeObjects: objects,
            entities: entities,
            events: events,
            constructor: constructor
        )
        let stats = await backfill.run()
        let elapsed = Date().timeIntervalSince(started)
        let total = (try? await factBonds.count()) ?? 0
        rebuildBondsStatus = """
        ✓ Rebuild complete in \(String(format: "%.1f", elapsed))s
        KOs scanned: \(stats.knowledgeObjects)
        Bonds written / upserted: \(stats.bondsWritten)
        Skipped (no entities or events): \(stats.skipped)
        Failed: \(stats.failed)
        Total bonds in ledger now: \(total)
        """
    }

    private func runGate3Multihop() async {
        gate3Running = true
        gate3Status = "Booting isolated AppState + running M1..M4…"
        defer { gate3Running = false }
        do {
            let result = try await Gate1Baseline.generateGate3Multihop()
            gate3ReportURL = result.reportURL
            let providerLine = result.reasoningProviderID.map {
                "Reasoning provider: \($0)"
            } ?? "Reasoning provider: none (heuristic floor)"
            gate3Status = """
            ✓ Report written
            \(result.reportURL.path)
            \(providerLine)
            ingested fixtures: \(result.ingestedFixtureFiles) in \(String(format: "%.1f", result.ingestSeconds))s
            questions evaluated: \(result.questionCount) in \(String(format: "%.1f", result.querySeconds))s
            """
        } catch {
            gate3ReportURL = nil
            gate3Status = "✗ Failed: \(error)"
        }
    }

    private func runSmokeTest() async {
        smokeRunning = true
        smokeStatus = "Booting isolated AppState + ingesting fixture…"
        smokeFailures = []
        defer { smokeRunning = false }
        do {
            let result = try await runProjectDeltaSmokeTest()
            smokeFailures = result.assertionsFailed
            smokeStatus = """
            \(result.ok ? "✓ PASSED" : "✗ FAILED") — \(result.assertionsPassed.count) checks, \(result.assertionsFailed.count) failures
            ingested: \(result.ingested) files · entities: \(result.entityCount) · events: \(result.eventCount) · memory: \(result.memoryObjectCount)
            answer refused: \(result.answer.refused) · citations: \(result.answer.citations.count) · confidence: \(String(format: "%.2f", result.answer.confidence.value))
            """
        } catch {
            smokeStatus = "✗ Threw: \(error)"
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
            let coverageLine = result.coverageProbeURL.map { "Ingest coverage: \($0.path)" } ?? "Ingest coverage: (not written)"
            let reasoningLine = result.reasoningProviderID.map {
                "Reasoning provider: \($0) (LLM-on baseline)"  // jargon-ok: developer diagnostics
            } ?? "Reasoning provider: none (HEURISTIC FLOOR baseline)"
            baselineStatus = """
            ✓ Report written
            \(result.reportURL.path)
            \(reasoningLine)
            ingested fixtures: \(result.ingestedFixtureFiles) in \(String(format: "%.1f", result.ingestSeconds))s
            questions evaluated: \(result.questionCount) in \(String(format: "%.1f", result.querySeconds))s
            \(coverageLine)
            \(probeLine)
            """
        } catch {
            baselineReportURL = nil
            baselineStatus = "✗ Failed: \(error)"
        }
    }

    /// Phase L — App Store readiness. The chat + browser loaders
    /// read SQLite files that, on a non-sandboxed install, live in
    /// other apps' containers (`~/Library/Messages/chat.db`,
    /// `~/Library/Safari/History.db`, browser profile dirs).
    ///
    /// **App Store builds**: the sandbox blocks direct reads of
    /// those paths regardless of the flag. The user has to manually
    /// export / copy the file to a folder they've already granted
    /// the app access to (via the "Add folder" picker in Sources).
    ///
    /// **Developer ID / outside-the-store builds**: same flag, same
    /// UI — but the user can also point the picker at the real
    /// container path after granting Full Disk Access in System
    /// Settings.
    ///
    /// All three flags default OFF (except plain-text chat exports,
    /// which default ON because they're file-system-only and pose no
    /// other-app-data risk).
    private var optionalIngestSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Optional ingest").font(.title3.bold())
            Text("These loaders read external chat + browser data that requires explicit user authorization. Off by default. **App Store**: the sandbox enforces this regardless of toggle.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider().padding(.vertical, 4)
            Toggle("OCR images during ingest", isOn: Binding(
                get: { FeatureFlags.shared.ocrDuringIngest },
                set: { FeatureFlags.shared.ocrDuringIngest = $0 }
            ))
            Text("Reads text out of images and scanned pages. This is the **slowest part of ingest** — Apple Vision processes one image at a time, so archives with many images (e.g. email attachments) take much longer. Turn OFF for much faster ingest when you don't need to search text inside images. Applies to newly-ingested files.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider().padding(.vertical, 4)
            Toggle("Managed evidence copies (keep originals reopenable)", isOn: Binding(
                get: { FeatureFlags.shared.managedEvidenceMode },
                set: { FeatureFlags.shared.managedEvidenceMode = $0 }
            ))
            Text("EV-005. Default OFF (**reference mode**): Kalsmritikosh keeps a bookmark + hash + the derived evidence, and your files stay where they are — but if a file is later moved or replaced, its exact original bytes may no longer reopen. Turn ON (**managed mode**) to also keep a local, read-only, content-addressed copy of each ingested file, so every version can always be reopened byte-for-byte — recommended for investigations and legal matters. Costs disk (identical files are stored once). Applies to newly-ingested files.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider().padding(.vertical, 4)
            Toggle("iMessage (chat.db)", isOn: Binding(
                get: { FeatureFlags.shared.iMessageLoaderEnabled },
                set: { FeatureFlags.shared.iMessageLoaderEnabled = $0 }
            ))
            Text("Reads ~/Library/Messages/chat.db when it appears in a watched folder. Requires Full Disk Access for the original path; in the App Store build, copy chat.db to an Kalsmritikosh-watched folder first. Takes effect on next app launch.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider().padding(.vertical, 4)
            Toggle("Browser history (Safari, Chrome, Brave, Edge, Arc)", isOn: Binding(
                get: { FeatureFlags.shared.browserHistoryLoaderEnabled },
                set: { FeatureFlags.shared.browserHistoryLoaderEnabled = $0 }
            ))
            Text("Reads Safari History.db or Chromium History when copied into a watched folder. Both browsers lock the file while running — Kalsmritikosh reads a copy. Takes effect on next app launch.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider().padding(.vertical, 4)
            Toggle("Chat exports (WhatsApp, Signal, Slack TXT)", isOn: Binding(
                get: { FeatureFlags.shared.chatExportLoaderEnabled },
                set: { FeatureFlags.shared.chatExportLoaderEnabled = $0 }
            ))
            Text("Plain-text exports — no system access required. Recognized by filename prefix (WhatsApp Chat …, _chat …, signal-…, slack-export…). Default on. Takes effect on next app launch.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Background maintenance controls. Idle-driven summarization /
    /// distillation runs only while the Mac is idle; the user chooses
    /// how it behaves (Off / Ask first / Automatic+notify / silent) and
    /// how long the machine must be idle first.
    @State private var maintenanceMode: MaintenanceMode = FeatureFlags.shared.maintenanceMode
    @State private var maintenanceIdleMinutes: Int = FeatureFlags.shared.maintenanceIdleMinutes
    /// Status line for the on-demand "Distill memory now" button.
    @State private var distillStatus: String?
    /// "Delete all my data" confirmation + status.
    @State private var confirmDeleteAll = false
    @State private var deleteAllStatus: String?
    /// Which everyday Settings categories are expanded. Empty = all collapsed,
    /// so Settings shows a minimal list of category headers by default.
    @State private var openSettingsGroups: Set<String> = []

    /// Ledger-first LLM budget. Kalsmritikosh is a ledger-based
    /// historical AI, not a RAG chatbot — it spends its LLM budget on
    /// durable ledger objects, not on generating data for every chunk.
    /// These toggles control the expensive optional enrichment passes;
    /// all default OFF so ingest is fast and the app is usable while the
    /// ledger fills.
    /// Master architecture selector — the three systems we're comparing.
    /// Switching presets the whole enrichment pipeline; the RAG + expert
    /// + ledger answer stack is identical across modes.
    private var systemModeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "bolt")
                    .foregroundStyle(Theme.brand)
                Text("Engine").font(.title3.bold())
            }
            Text("This build runs a single pipeline: the minimum-AI, ledger-first engine. Ingestion uses no generative AI — rules, semantic indexing and a full-text index only. The model is used only at question time, to explain the evidence it retrieves.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Label("Ledger event-driven · minimum AI", systemImage: "checkmark.seal.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(Theme.brand)

            Label("Ingest: AI off · Semantic index on · Full-text on · Ledger on",
                  systemImage: "gauge.with.dots.needle.33percent")
                .font(.caption2).foregroundStyle(.secondary)

            Button("File-type ingest guide") { showIngestGuide = true }
                .font(.caption)
                .buttonStyle(.borderless)

            Divider().padding(.vertical, 4)

            Toggle(isOn: $preferClassicSurfaces) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Prefer classic surfaces").font(.callout.weight(.medium))
                    Text("Use the previous fixed Analyze launchers instead of the newer catalog-driven studio launchers. Both surfaces stay available; this only changes which the persona hub offers by default.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)

            Toggle(isOn: $classicConformance) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Classic conformance mode (disables enforcement)").font(.callout.weight(.medium))
                    Text("Restores the previous behavior IN FULL: the legacy checklist readout, AND findings approval is no longer blocked by the per-rule conformance gate, AND assessments are not recorded or sealed. Deliverables produced in classic mode carry no conformance certificate. Switching back to strict never deletes recorded assessments.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)

            Toggle(isOn: $customProtocolStudio) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Custom protocol studio").font(.callout.weight(.medium))
                    Text("Author your organization's own constitution on the Compliance Board: AI drafts from your SOP text, you structure and test every rule, then sign it as an offline pack. Off by default — the built-in doctrines govern until you opt in.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
        }
        .sheet(isPresented: $showIngestGuide) { IngestGuideView() }
    }


    /// Collapsible wrapper so each Settings category is hidden behind a click —
    /// Settings opens as a short list of headers, expand only what you need.
    /// D-10: every group carries a SettingsAnchor (palette-coverage.sh fails
    /// CI if one is missing) so ⌘K can expand, scroll to, and flash it.
    @ViewBuilder
    private func settingsGroup<Content: View>(_ title: String, _ icon: String, anchor: SettingsAnchor, @ViewBuilder _ content: @escaping () -> Content) -> some View {
        DisclosureGroup(isExpanded: Binding(
            get: { openSettingsGroups.contains(title) },
            set: { open in
                if open { openSettingsGroups.insert(title) } else { openSettingsGroups.remove(title) }
            }
        )) {
            content().padding(.top, 6).padding(.leading, 2)
        } label: {
            Label(title, systemImage: icon).font(.headline)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.brand.opacity(flashedAnchor == anchor ? 0.18 : 0))
        )
        .padding(.horizontal, -6)
        .id(anchor)
    }

    /// D-10 — expand the anchored group, scroll it to the top, and flash it
    /// twice so the eye lands on the right place; then clear the request so
    /// the same anchor can fire again later.
    private func reveal(_ a: SettingsAnchor, proxy: ScrollViewProxy) {
        openSettingsGroups.insert(groupTitle(for: a))
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))   // let the group expand first
            withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(a, anchor: .top) }
            for _ in 0..<2 {
                withAnimation(.easeIn(duration: 0.18)) { flashedAnchor = a }
                try? await Task.sleep(for: .milliseconds(300))
                withAnimation(.easeOut(duration: 0.18)) { flashedAnchor = nil }
                try? await Task.sleep(for: .milliseconds(200))
            }
            anchor = nil
        }
    }

    private func groupTitle(for a: SettingsAnchor) -> String {
        switch a {
        case .localModelSetup:       return "Local model setup"
        case .answeringModes:        return "Answering & modes"
        case .privacy:               return "Privacy"
        case .backgroundMaintenance: return "Background maintenance"
        case .ingestOptions:         return "Ingest options"
        case .yourData:              return "Your data"
        case .helpFeedback:          return "Help & feedback"
        case .legalPrivacy:          return "Legal & privacy"
        }
    }

    /// Your data — the global "erase everything" control. Always visible so it's
    /// easy to find (the app previously only had a per-folder forget in Sources).
    private var dataSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "trash").foregroundStyle(.red)
                Text("Your data").font(.title3.bold())
            }
            Text("Erase everything Kalsmritikosh has learned — all ingested documents, the extracted ledger, timeline, entities, and search index. **Your original files on disk are not touched**; you can re-add them any time. This cannot be undone.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button(role: .destructive) {
                    confirmDeleteAll = true
                } label: {
                    if appState.deletingAllData {
                        Label("Erasing…", systemImage: "hourglass")
                    } else {
                        Label("Delete all my data", systemImage: "trash")
                    }
                }
                .disabled(appState.deletingAllData)
                if let s = deleteAllStatus {
                    Text(s).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .alert("Delete all your data?", isPresented: $confirmDeleteAll) {
            Button("Cancel", role: .cancel) {}
            Button("Delete everything", role: .destructive) {
                Task {
                    deleteAllStatus = "Erasing…"
                    let n = await appState.deleteAllData()
                    deleteAllStatus = "Erased. \(n) tables cleared — re-add folders in Sources to start fresh."
                }
            }
        } message: {
            Text("This permanently erases the ingested ledger (documents, timeline, entities, search index). Your original files on disk are NOT affected. This cannot be undone.")
        }
    }

    /// Help & feedback — a privacy-safe "Report a problem": composes a draft in
    /// the USER'S OWN mail app (mailto:). Kalsmritikosh itself sends nothing and
    /// collects nothing; the user sees and can edit every character before
    /// deciding to send. Keeps "Data Not Collected" truthful.
    private var feedbackSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "envelope")
                    .foregroundStyle(Theme.brand)
                Text("Help & feedback").font(.title3.bold())
            }
            Text("Found a problem or have an idea? Tell us — early feedback shapes what gets built next. The button below opens a draft in your own Mail app: Kalsmritikosh itself sends nothing, and you see and can edit everything (including the app/system version lines) before you choose to send.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                let v = FeedbackMail.currentVersions()
                if let url = FeedbackMail.reportProblemURL(appVersion: v.app, osVersion: v.os) {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Label("Report a problem / send feedback", systemImage: "paperplane")
            }
            .buttonStyle(.borderedProminent)
            .guidance(GuidanceTip("Report a problem",
                                  what: "Opens a pre-filled draft in your own Mail app addressed to support. The app makes no network call and attaches none of your documents — only the visible text you choose to send."))
            Text("Or email \(FeedbackMail.supportAddress) directly. Never include privileged or confidential case material in a report.")
                .font(.caption2).foregroundStyle(.tertiary)
                .textSelection(.enabled)
        }
    }

    /// Legal & Privacy — accuracy disclaimer, privacy posture, terms, and
    /// third-party notices. Always visible (not hidden under Advanced) so the
    /// declarations are easy to find.
    private var legalSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.shield")
                    .foregroundStyle(Theme.brand)
                Text("Legal & Privacy").font(.title3.bold())
            }
            Text(LegalNotice.disclaimerHeadline)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.orange)

            legalItem("Accuracy — verify every answer", LegalNotice.accuracyStatement, "exclamationmark.triangle")
            legalItem("AI output — human review required", LegalNotice.aiOutputStatement, "brain")
            legalItem("Privacy — private by design", LegalNotice.privacyStatement, "lock.shield")
            legalItem("Terms — provided “as is”", LegalNotice.termsStatement, "doc.text")
            legalItem("No professional relationship", LegalNotice.noRelationshipStatement, "person.crop.circle.badge.xmark")
            legalItem("Standards & SOPs — interpretation, not certification", LegalNotice.sopStatement, "checkmark.seal")
            legalItem("Warranty & liability", LegalNotice.liabilityStatement, "shield.lefthalf.filled")
            legalItem("Your responsibilities — data, backup, lawful use", LegalNotice.responsibilityStatement, "externaldrive.badge.checkmark")
            legalItem("Payments & subscriptions", LegalNotice.subscriptionStatement, "creditcard")
            legalItem("Changes to these notices", LegalNotice.changesStatement, "clock.arrow.2.circlepath")
            legalItem("Acknowledgments", LegalNotice.thirdPartyStatement, "shippingbox")

            Text("Notices version \(LegalNotice.termsVersion)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
            // The counsel note is an owner/developer reminder, not a user
            // notice — kept in LegalNotice for the repo, not shown in the app.
        }
    }

    private func legalItem(_ title: String, _ body: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: icon)
                .font(.callout.weight(.medium))
            Text(body)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 2)
    }

    /// Answering intelligence — the on-device MoE reasoning dials + the
    /// fully-private switch. All read/write FeatureFlags / PrivacyGate live;
    /// they take effect on the next question (no relaunch needed).
    private var intelligenceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("Answering intelligence").font(.title3.bold())
                InfoPopoverButton(
                    title: "Speed vs. depth",
                    message: "Each option below adds on-device model passes: better, more faithful answers but slower replies. Turn them off for speed — answers stay grounded in your evidence either way.",
                    systemImage: "brain.head.profile",
                    bullets: [
                        "Fully private (no AI) — fastest, rule-based only",
                        "Parallel expert council + Self-critique — deepest, slowest",
                        "Off ⇒ ~1 pass · All on ⇒ several passes per answer"
                    ]
                )
            }
            Text("How the on-device brain composes answers. The deeper options give better, more faithful answers but run more model passes, so replies take longer. Turn them off for speed. All answers stay grounded in your evidence either way.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider().padding(.vertical, 2)

            // Fully private (no LLM) — PrivacyGate.
            Toggle("Fully private (no AI)", isOn: Binding(
                get: { PrivacyGate.shared.offlineNoLLM },
                set: { PrivacyGate.shared.offlineNoLLM = $0 }
            ))
            Text("Uses NO generative model at all (on-device or cloud). Answers come purely from the rule-based ledger + experts. Maximum privacy and speed; plainer, bullet-style answers. On-device search/embeddings still work.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider().padding(.vertical, 2)

            // GK (owner decision) — the General-Knowledge Lane.
            Toggle("Answer general questions too (clearly marked)", isOn: Binding(
                get: { FeatureFlags.shared.generalKnowledgeLane },
                set: { FeatureFlags.shared.generalKnowledgeLane = $0 }
            ))
            Text("When your documents don't hold the answer, the on-device AI may add a separate block marked \u{201C}Not from your documents\u{201D}. It may be wrong, carries no sources, and never enters your evidence, exports, or receipts. Off by default.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider().padding(.vertical, 2)

            Toggle("Apple AI writes the final answer", isOn: Binding(
                get: { FeatureFlags.shared.llmAnswerSynthesis },
                set: { FeatureFlags.shared.llmAnswerSynthesis = $0 }
            ))
            Text("The on-device model composes the answer prose from the experts' verified findings. Off = deterministic bullet answer from the ledger (fast).")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Parallel expert council (MoE)", isOn: Binding(
                get: { FeatureFlags.shared.moeCouncil },
                set: { FeatureFlags.shared.moeCouncil = $0 }
            ))
            Text("A top-k gate runs specialist \u{201C}super-experts\u{201D} (Analyst, Skeptic, Historian, Connector, Quant) in parallel and folds their perspectives into the answer. Highest quality; adds several model passes (slower).")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Self-critique + refine", isOn: Binding(
                get: { FeatureFlags.shared.llmSelfCritique },
                set: { FeatureFlags.shared.llmSelfCritique = $0 }
            ))
            Text("After drafting, the model fact-checks itself against the findings and revises. Improves faithfulness; adds ~2 model passes.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Relevance-gated experts", isOn: Binding(
                get: { FeatureFlags.shared.expertRelevanceGating },
                set: { FeatureFlags.shared.expertRelevanceGating = $0 }
            ))
            Text("Only runs the experts that have supporting evidence for the question instead of all of them. Recommended on — faster with no quality loss.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var maintenanceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Background maintenance").font(.title3.bold())
            Text("Kalsmritikosh keeps your knowledge base tidy (summaries + distilled memories) while your Mac is idle, and stops the moment you come back. Choose how it behaves.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Mode", selection: $maintenanceMode) {
                ForEach(MaintenanceMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: maintenanceMode) { _, newValue in
                FeatureFlags.shared.maintenanceMode = newValue
            }
            Text(maintenanceMode.detail)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if maintenanceMode != .off {
                Divider().padding(.vertical, 2)
                HStack {
                    Text("Start after idle for")
                        .font(.callout)
                    Picker("", selection: $maintenanceIdleMinutes) {
                        Text("1 min").tag(1)
                        Text("2 min").tag(2)
                        Text("5 min").tag(5)
                        Text("10 min").tag(10)
                        Text("15 min").tag(15)
                        Text("30 min").tag(30)
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                    .onChange(of: maintenanceIdleMinutes) { _, newValue in
                        FeatureFlags.shared.maintenanceIdleMinutes = newValue
                    }
                    Spacer()
                }
                Text("Takes effect immediately — no relaunch needed.")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            Divider().padding(.vertical, 2)

            // On-demand distillation — the manual half of the distill pair
            // (the background pass above is the idle half). Always available,
            // independent of the maintenance mode: builds distilled memories
            // for the top subjects right now. The ledger-first engine does no
            // distillation at ingest, so this is how a user warms memory
            // without waiting for idle time or asking a question first.
            HStack {
                Button {
                    Task {
                        distillStatus = "Distilling memory…"
                        let count = await appState.distillMemory()
                        distillStatus = "Distilled \(count) subject(s)."
                    }
                } label: {
                    Label("Distill memory now", systemImage: "brain.head.profile")
                }
                .disabled(appState.isDistillingMemory)
                if let distillStatus {
                    Text(distillStatus)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            Text("Builds distilled memories for the top people and organizations in your ledger right now. Runs on demand; also happens automatically during idle maintenance when enabled above.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var privacySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Privacy").font(.title3.bold())
            // RELEASE-READINESS (fifteenth review): the cloud-routing toggle is a
            // DEV-ONLY control. The release product contract is zero network —
            // PrivacyGate is compile-locked to no-cloud in Release, so showing a
            // toggle there would contradict the shipped behavior.
            #if DEBUG
            Toggle("Allow cloud-routed providers (dev builds only)", isOn: $allowCloud)
                .onChange(of: allowCloud) { _, newValue in
                    PrivacyGate.shared.allowCloudRouting = newValue
                }
            Text("Dev-build control. When off, the CapabilityRegistry never returns providers whose privacy tier is `cloud`. In Release builds this gate is compile-locked off and no cloud or local-network provider is reachable.")
                .font(.caption).foregroundStyle(.secondary)
            #else
            Label("All processing is on-device. Cloud routing is compiled out of this build.", systemImage: "lock.shield")
                .font(.caption).foregroundStyle(.secondary)
            #endif

            Divider().padding(.vertical, 4)

            Toggle("Coalesce email threads (Move A)", isOn: $threadCoalescing)
                .onChange(of: threadCoalescing) { _, newValue in
                    UserDefaults.standard.set(newValue, forKey: "kalsmritikosh.moveA.threadCoalescing")
                }
            Text("When on, email ingest folds an entire reply chain into a single KO instead of one KO per message. Memory distillation gets the whole conversation in one shot; storage drops on busy mailboxes. **Requires re-ingest of affected mailboxes** to take effect.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider().padding(.vertical, 4)

            Toggle("Show low-quality (T3) entities in results", isOn: $showT3InResults)
                .onChange(of: showT3InResults) { _, newValue in
                    UserDefaults.standard.set(newValue, forKey: "kalsmritikosh.history.showT3InResults")
                }
            Text("HISTORY Phase A. When off, the retriever filters out entities tagged T3 (mail-server hostnames like `Tyzpr01mb4530`, weekday tokens, base64-ish IDs) from results — they stay on disk, just don't pollute answers. Flip on to see everything every extractor produced.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// G2-3 onboarding — first-launch flow when the user has no
    /// reasoning model yet. Walks them through installing Ollama
    /// and pulling the recommended model. The pull runs in-app
    /// with a live progress bar; the user can also reveal the
    /// terminal command if they prefer to do it themselves.
    @ViewBuilder
    private func ollamaSetupSection(_ setup: OllamaSetupAdvisor.SetupSuggestion) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: setup.action == .installOllama ? "arrow.down.app" : "square.and.arrow.down")
                    .font(.title2)
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 4) {
                    Text(setup.action == .installOllama
                         ? "Install a local model to enable answers"
                         : "Download a reasoning model")
                        .font(.headline)
                    Text(setup.summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            switch setup.action {
            case .installOllama:
                Text("Step 1 — install Ollama")
                    .font(.callout.weight(.medium))
                Text(setup.ollamaInstallInstructions)
                    .font(.caption.monospaced())
                    .padding(8)
                    .background(Color.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                    .textSelection(.enabled)
                if let url = URL(string: "https://ollama.com/download") {
                    Link("Open ollama.com/download", destination: url)
                        .font(.callout)
                }
                if let model = setup.recommendedModel {
                    Divider().padding(.vertical, 4)
                    Text("Step 2 — pull \(model.displayName)")
                        .font(.callout.weight(.medium))
                    Text("After Ollama is running, return to Kalsmritikosh and Settings will offer a one-tap download.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

            case .pullRecommendedModel:
                if let model = setup.recommendedModel {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Ollama is running")
                            .font(.callout)
                    }
                    Divider().padding(.vertical, 4)
                    Text("Recommended model: \(model.displayName)")
                        .font(.callout.weight(.medium))
                    Text(model.reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Download size: \(formatBytes(model.approxDiskBytes))  •  context: \(model.contextWindow) tokens")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        Button {
                            Task { await pullModel(modelTag: model.modelTag) }
                        } label: {
                            if ollamaPullRunning {
                                Label("Downloading…", systemImage: "hourglass")
                            } else {
                                Label("Download with Ollama", systemImage: "arrow.down.circle.fill")
                            }
                        }
                        .disabled(ollamaPullRunning)
                        Text("or run:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("ollama pull \(model.modelTag)")
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                    if ollamaPullRunning {
                        ProgressView(value: ollamaPullFraction)
                            .progressViewStyle(.linear)
                    }
                    if let status = ollamaPullStatus {
                        Text(status)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }

            case .nothingNeeded:
                EmptyView()
            }
        }
        .padding(12)
        .background(Color.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.blue.opacity(0.30), lineWidth: 1)
        )
    }

    private func pullModel(modelTag: String) async {
        ollamaPullRunning = true
        ollamaPullStatus = "Connecting…"
        ollamaPullFraction = 0
        defer { ollamaPullRunning = false }
        let installer = OllamaInstaller()
        let stream = await installer.pull(modelTag: modelTag)
        for await event in stream {
            switch event {
            case .success(let progress):
                ollamaPullStatus = progress.status
                ollamaPullFraction = progress.fractionComplete
                if progress.isComplete {
                    ollamaPullStatus = "Downloaded \(modelTag). Relaunch Kalsmritikosh to start using it."
                }
            case .failure(let err):
                ollamaPullStatus = "Download failed: \(err)"
            }
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        let mb = Double(bytes) / 1_048_576
        return String(format: "%.0f MB", mb)
    }

    /// G2-3 — surfaces ModelChoiceAdvisor's output to the user.
    /// Hidden when severity is `.ok` (current model is the best fit).
    /// Expandable on tap to show the detail bullets (RAM math etc.).
    @ViewBuilder
    private func modelChoiceBanner(_ advice: ModelChoiceRecommendation) -> some View {
        let palette = bannerPalette(for: advice.severity)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: palette.icon)
                    .foregroundStyle(palette.foreground)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 4) {
                    Text(palette.title)
                        .font(.headline)
                        .foregroundStyle(palette.foreground)
                    Text(advice.summary)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button {
                    withAnimation { modelAdviceExpanded.toggle() }
                } label: {
                    Image(systemName: modelAdviceExpanded ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.borderless)
            }
            if modelAdviceExpanded {
                Divider()
                ForEach(advice.details, id: \.self) { line in
                    HStack(alignment: .top, spacing: 6) {
                        Text("•").foregroundStyle(.secondary)
                        Text(line)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let name = advice.recommendedProviderName {
                    Text("Recommended: \(name)")
                        .font(.caption.monospaced())
                        .padding(.top, 2)
                        .foregroundStyle(palette.foreground)
                }
            }
        }
        .padding(12)
        .background(palette.background.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(palette.background.opacity(0.35), lineWidth: 1)
        )
    }

    private struct BannerPalette {
        let icon: String
        let title: String
        let foreground: Color
        let background: Color
    }

    private func bannerPalette(for severity: ModelChoiceRecommendation.Severity) -> BannerPalette {
        switch severity {
        case .ok:
            return .init(icon: "checkmark.seal.fill", title: "Model fits your device",
                        foreground: .green, background: .green)
        case .suggestion:
            return .init(icon: "lightbulb", title: "Upgrade available",
                        foreground: .blue, background: .blue)
        case .warning:
            return .init(icon: "exclamationmark.triangle", title: "Tight fit",
                        foreground: .orange, background: .orange)
        case .critical:
            return .init(icon: "exclamationmark.octagon.fill", title: "Model won't run well",
                        foreground: .red, background: .red)
        }
    }

    /// G2-3 BYO — three subsections so the user can bring their own
    /// MLX checkpoints, GGUF files, and cloud endpoints. Each subsection
    /// surfaces what's currently registered + actions to add / remove.
    private var userModelsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Your models").font(.title3.bold())
            Text("Kalsmritikosh auto-detects models you've already installed (Ollama, MLX). You can also add `.gguf` files or your own cloud endpoint below.")
                .font(.caption).foregroundStyle(.secondary)

            mlxSubsection
            Divider().padding(.vertical, 4)
            ggufSubsection
            Divider().padding(.vertical, 4)
            cloudSubsection
        }
        .task { await reloadUserModels() }
    }

    // MARK: - MLX

    private var mlxSubsection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "cpu").foregroundStyle(.purple)
                Text("MLX checkpoints").font(.body.weight(.medium))
                Spacer()
                Text("\(mlxModels.count) detected").font(.caption).foregroundStyle(.secondary)
            }
            Text("Drop an MLX model directory into the folder below; Kalsmritikosh reads its `config.json` and registers it at the next launch.")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button {
                    revealMLXFolder()
                } label: {
                    Label("Open MLX Models folder", systemImage: "folder")
                }
                Button {
                    Task { mlxModels = MLXDiscovery.list() }
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
            }
            if mlxModels.isEmpty {
                Text("No MLX checkpoints registered.")
                    .font(.caption.italic()).foregroundStyle(.secondary)
            } else {
                ForEach(mlxModels, id: \.id) { m in
                    HStack {
                        Text(m.displayName).font(.callout)
                        Spacer()
                        Text("\(formatBytes(m.sizeBytes)) · ctx \(m.contextWindow) · \(m.tier.rawValue)")
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func revealMLXFolder() {
        let dir = MLXDiscovery.defaultUserModelsDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        #if canImport(AppKit)
        NSWorkspace.shared.open(dir)
        #endif
    }

    // MARK: - GGUF

    private var ggufSubsection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "doc.badge.plus").foregroundStyle(.indigo)
                Text("GGUF files").font(.body.weight(.medium))
                Spacer()
                Text("\(ggufEntries.count) added").font(.caption).foregroundStyle(.secondary)
            }
            Text("Add any `.gguf` file (Hugging Face, TheBloke, custom builds). Kalsmritikosh parses its header for context-length + family.")
                .font(.caption).foregroundStyle(.secondary)
            Button {
                ggufImporterPresented = true
            } label: {
                Label("Add .gguf file…", systemImage: "plus.circle")
            }
            .fileImporter(
                isPresented: $ggufImporterPresented,
                allowedContentTypes: [.data],
                allowsMultipleSelection: false
            ) { result in
                Task { await handleGGUFImport(result) }
            }
            if ggufEntries.isEmpty {
                Text("No GGUF files added.")
                    .font(.caption.italic()).foregroundStyle(.secondary)
            } else {
                ForEach(ggufEntries, id: \.id) { e in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(e.displayName).font(.callout)
                            Text(e.filePath).font(.caption2.monospaced()).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(formatBytes(e.sizeBytes)) · ctx \(e.contextWindow)")
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                        Button {
                            Task {
                                if let reg = appState.ggufRegistry {
                                    await reg.remove(id: e.id)
                                    ggufEntries = await reg.load()
                                }
                            }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
    }

    private func handleGGUFImport(_ result: Result<[URL], Error>) async {
        guard let reg = appState.ggufRegistry else { return }
        switch result {
        case .success(let urls):
            for url in urls {
                guard url.startAccessingSecurityScopedResource() else { continue }
                defer { url.stopAccessingSecurityScopedResource() }
                _ = try? await reg.add(fileURL: url)
            }
            ggufEntries = await reg.load()
        case .failure(let err):
            KalsmritikoshLog.app.error("GGUF import failed: \(String(describing: err), privacy: .public)")
        }
    }

    // MARK: - Cloud

    private var cloudSubsection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "cloud").foregroundStyle(.blue)
                Text("Cloud endpoints").font(.body.weight(.medium))
                Spacer()
                Text("\(cloudEntries.count) added").font(.caption).foregroundStyle(.secondary)
            }
            Text("Bring your own OpenAI / Anthropic / Azure / custom endpoint. API keys are stored in macOS Keychain. PrivacyGate still gates whether cloud calls are made.")
                .font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Group {
                    TextField("Display name (e.g. \"OpenAI 4o-mini\")", text: $newCloudName)
                    TextField("Base URL", text: $newCloudBaseURL)
                    TextField("Model name", text: $newCloudModelName)
                    SecureField("API key (stored in Keychain)", text: $newCloudAPIKey)
                    HStack {
                        TextField("Context window (tokens)", text: $newCloudContextWindow)
                        TextField("Family", text: $newCloudFamily)
                        Picker("Tier", selection: $newCloudTier) {
                            Text("small").tag(ModelManifest.Tier.small)
                            Text("medium").tag(ModelManifest.Tier.medium)
                            Text("large").tag(ModelManifest.Tier.large)
                        }
                        .pickerStyle(.menu)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                HStack {
                    Button {
                        Task { await addCloudEndpoint() }
                    } label: {
                        Label("Add endpoint", systemImage: "plus.circle.fill")
                    }
                    if let err = cloudFormError {
                        Text(err).font(.caption).foregroundStyle(.red)
                    }
                }
            }
            .padding(8)
            .background(Color.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))

            if cloudEntries.isEmpty {
                Text("No cloud endpoints added.")
                    .font(.caption.italic()).foregroundStyle(.secondary)
            } else {
                ForEach(cloudEntries, id: \.id) { e in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(e.displayName).font(.callout)
                            Text("\(e.baseURL) · \(e.modelName)").font(.caption2.monospaced()).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("ctx \(e.contextWindow) · \(e.tier.rawValue)")
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                        Button {
                            Task {
                                if let reg = appState.cloudEndpointRegistry {
                                    await reg.remove(id: e.id)
                                    cloudEntries = await reg.load()
                                }
                            }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
    }

    private func addCloudEndpoint() async {
        guard let reg = appState.cloudEndpointRegistry else { return }
        guard !newCloudName.isEmpty, !newCloudBaseURL.isEmpty,
              !newCloudModelName.isEmpty, !newCloudAPIKey.isEmpty
        else {
            cloudFormError = "All fields are required."
            return
        }
        guard let ctx = Int(newCloudContextWindow), ctx > 0 else {
            cloudFormError = "Context window must be a positive integer."
            return
        }
        let id = "provider.cloud.byo.\(newCloudName.replacingOccurrences(of: " ", with: "_").lowercased())"
        let endpoint = CloudEndpointRegistry.Endpoint(
            id: id,
            displayName: newCloudName,
            baseURL: newCloudBaseURL,
            modelName: newCloudModelName,
            contextWindow: ctx,
            tier: newCloudTier,
            family: newCloudFamily
        )
        do {
            try await reg.add(endpoint, apiKey: newCloudAPIKey)
            cloudEntries = await reg.load()
            cloudFormError = nil
            // Clear the API key only — keep the URL+model so the user
            // can quickly add a sibling endpoint variant.
            newCloudAPIKey = ""
            newCloudName = ""
        } catch {
            cloudFormError = "Save failed: \(error)"
        }
    }

    // MARK: - Reload helpers

    private func reloadUserModels() async {
        mlxModels = MLXDiscovery.list()
        if let g = appState.ggufRegistry { ggufEntries = await g.load() }
        if let c = appState.cloudEndpointRegistry { cloudEntries = await c.load() }
    }

    // MARK: - Device-aware model chooser

    /// How well a model fits THIS device, from hardware RAM vs the model's
    /// minimum. Built-in Apple / cloud models (minRAM == 0) always fit.
    private nonisolated enum DeviceFit {
        case fits, tight, tooBig
        var label: String {
            switch self {
            case .fits:   return "Fits your device"
            case .tight:  return "Tight on this device"
            case .tooBig: return "Too big for this device"
            }
        }
        var symbol: String {
            switch self {
            case .fits:   return "checkmark.circle.fill"
            case .tight:  return "exclamationmark.triangle.fill"
            case .tooBig: return "xmark.octagon.fill"
            }
        }
        var color: Color {
            switch self {
            case .fits:   return .green
            case .tight:  return .orange
            case .tooBig: return .red
            }
        }
    }

    private func deviceFit(_ m: ModelManifest) -> DeviceFit {
        let ram = appState.hardware?.totalRAMBytes ?? 0
        guard m.minRAMBytes > 0, ram > 0 else { return .fits }
        if Double(m.minRAMBytes) <= Double(ram) * 0.7 { return .fits }
        if m.minRAMBytes <= ram { return .tight }
        return .tooBig
    }

    /// Reasoning-capable models the user can actually pin (manifest id is a
    /// live provider id), sorted best-fit-first then by tier.
    private var reasoningModels: [ModelManifest] {
        manifests
            .filter { $0.capabilities.contains(.reasoning) && providerIDs.contains($0.id) }
            .sorted { a, b in
                let fa = deviceFit(a), fb = deviceFit(b)
                if fa != fb {
                    // fits < tight < tooBig
                    func rank(_ f: DeviceFit) -> Int { f == .fits ? 0 : (f == .tight ? 1 : 2) }
                    return rank(fa) < rank(fb)
                }
                // bigger (more capable) tier first within a fit class
                let order = ModelManifest.Tier.allCases
                return (order.firstIndex(of: a.tier) ?? 0) > (order.firstIndex(of: b.tier) ?? 0)
            }
    }

    private func manifestSubtitle(_ m: ModelManifest) -> String {
        var parts: [String] = ["\(m.tier.rawValue) tier"]
        if m.minRAMBytes > 0 {
            parts.append("\(m.minRAMBytes / 1_073_741_824) GB RAM")
        }
        parts.append("\(max(1, m.contextWindow / 1000))K context")
        parts.append(m.privacyLevel.rawValue)
        return parts.joined(separator: " · ")
    }

    private func privacySymbol(_ p: PrivacyLevel) -> String {
        switch p {
        case .onDevice:     return "lock.fill"
        case .localNetwork: return "network"
        case .cloud:        return "cloud"
        }
    }

    /// The primary "which model does the thinking" chooser. Selecting a model
    /// pins the `.reasoning` capability (ModelUserPreferences), which
    /// CapabilityRegistry honours first when resolving. "Auto" clears the pin.
    private var modelPickerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Your AI model").font(.title3.bold())
                InfoPopoverButton(
                    title: "Pick the model that fits your Mac",
                    message: "This is the model the brain uses to reason over your archive. Bigger models are smarter but need more memory.",
                    systemImage: "cpu",
                    bullets: [
                        "“Auto” picks the best fit for your hardware automatically",
                        "Each option shows whether it fits your device’s memory",
                        "On-device models keep everything private; cloud/LAN models leave your Mac"
                    ]
                )
            }

            if let hw = appState.hardware {
                let gb = Double(hw.totalRAMBytes) / 1_073_741_824
                HStack(spacing: 8) {
                    Image(systemName: hw.isAppleSilicon ? "cpu.fill" : "cpu")
                        .foregroundStyle(Theme.brand)
                    Text("This Mac: \(hw.chipName) · \(String(format: "%.0f", gb)) GB RAM · \(hw.tier.rawValue) tier")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Text("Choose which model reasons over your archive. Auto adapts to your device; pick one to override.")
                .font(.caption).foregroundStyle(.secondary)

            // Auto (clears the reasoning pin)
            modelRow(
                title: "Auto — best fit for your device",
                subtitle: appState.modelChoiceAdvice?.recommendedProviderName.map { "Currently favours: \($0)" }
                    ?? "Ranks every model by your hardware + measured speed",
                selected: pins[.reasoning] == nil,
                fit: nil,
                recommended: false,
                symbol: "wand.and.stars"
            ) {
                ModelUserPreferences.shared.clearPin(for: .reasoning)
                pins[.reasoning] = nil
            }

            ForEach(reasoningModels, id: \.id) { m in
                modelRow(
                    title: m.displayName,
                    subtitle: manifestSubtitle(m),
                    selected: pins[.reasoning] == m.id,
                    fit: deviceFit(m),
                    recommended: appState.modelChoiceAdvice?.recommendedProviderID == m.id,
                    symbol: privacySymbol(m.privacyLevel)
                ) {
                    ModelUserPreferences.shared.setPin(m.id, for: .reasoning)
                    pins[.reasoning] = m.id
                }
            }

            if reasoningModels.isEmpty {
                Text("Only the built-in Apple model is available right now. Add local models (Ollama / MLX / GGUF) or a cloud endpoint below to unlock more choices.")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
        }
    }

    @ViewBuilder
    private func modelRow(
        title: String,
        subtitle: String,
        selected: Bool,
        fit: DeviceFit?,
        recommended: Bool,
        symbol: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Theme.brand : .secondary)
                Image(systemName: symbol)
                    .foregroundStyle(Theme.brand)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title).font(.body.weight(.medium))
                        if recommended {
                            Text("Recommended")
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Theme.brand.opacity(0.15), in: Capsule())
                                .foregroundStyle(Theme.brand)
                        }
                    }
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if let fit {
                    HStack(spacing: 4) {
                        Image(systemName: fit.symbol)
                        Text(fit.label)
                    }
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(fit.color)
                }
            }
            .padding(10)
            .background(
                selected ? Theme.brand.opacity(0.08) : Color.primary.opacity(0.03),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(selected ? Theme.brand.opacity(0.40) : Color.primary.opacity(0.08), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
