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

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Settings").font(.largeTitle.bold())

                if let setup = appState.ollamaSetupSuggestion {
                    ollamaSetupSection(setup)
                }

                if let advice = appState.modelChoiceAdvice,
                   advice.severity != .ok {
                    modelChoiceBanner(advice)
                }

                privacySection
                Divider()
                providersSection
                Divider()
                userModelsSection
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

            Text("**Run Full Diagnostics** — one-button orchestrator. Runs the smoke test + Fast Eval + Gate 3 Multi-hop in sequence and writes a single unified `diagnostics-summary.md` you can share. ~10–12 minutes end-to-end.")
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

            Text("Generate Knowledge Inventory — per-file readout of EVERYTHING Atlas extracted from your archive: source path, content preview, entities, events, bonds. Pair against your originals to spot ingest gaps. Writes `knowledge-inventory.md` to ~/Documents/EvalBaselines/.")
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

            Divider().padding(.vertical, 4)

            Text("Rebuild synthetic questions — runs the heuristic generator over chunks of KOs ingested BEFORE the G2 wiring landed. Populates synthetic_questions + its FTS index so the question-shaped retrieval layer can match. No LLM calls; runs in seconds. Idempotent — KOs that already have questions are skipped.")
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

            Text("Gate 3 Multi-hop — runs only M1..M4, the typed-multihop subset the bond engine is designed to answer. Watch the Walk cov. / Walk steps/Q columns in the report to verify the schema-aware retrieval layer is firing.")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button {
                    Task { await runGate3Multihop() }
                } label: {
                    if gate3Running {
                        Label("Running…", systemImage: "hourglass")
                    } else {
                        Label("Run Gate 3 Multi-hop (M1–M4)", systemImage: "point.3.connected.trianglepath.dotted")
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
        }
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
        allDiagnosticsStatus = "Running smoke + Fast Eval + Gate 3 Multi-hop… (~10–12 min)"
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
                "Reasoning provider: \($0) (LLM-on baseline)"
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
                    Text("After Ollama is running, return to Atlas and Settings will offer a one-tap download.")
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
                    ollamaPullStatus = "Downloaded \(modelTag). Relaunch Atlas to start using it."
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
            Text("Atlas auto-detects models you've already installed (Ollama, MLX). You can also add `.gguf` files or your own cloud endpoint below.")
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
            Text("Drop an MLX model directory into the folder below; Atlas reads its `config.json` and registers it at the next launch.")
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
            Text("Add any `.gguf` file (Hugging Face, TheBloke, custom builds). Atlas parses its header for context-length + family.")
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
            AtlasLog.app.error("GGUF import failed: \(String(describing: err), privacy: .public)")
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
