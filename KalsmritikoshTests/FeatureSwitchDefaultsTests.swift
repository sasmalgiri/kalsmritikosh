//
//  FeatureSwitchDefaultsTests.swift
//  KalsmritikoshTests
//
//  Owner instruction 2026-11-15: "All preview should be active, and all tracker should be active as well,
//  no surprise." This guard keeps it true:
//   * every built product module defaults ON, except the documented keep-off list
//     (`ProductModule.offByDefault`, each with a reason and the decision it rests on);
//   * no built module is still a hidden preview, and no UI string says "(preview)";
//   * the case map (the old "Case map (preview)" switch) is on by default, and a person's OFF is kept;
//   * the engine switches that default off are exactly the documented ones;
//   * the scope migration's revision 2 releases the old OFF pins and keeps every real choice;
//   * docs/FEATURE_SWITCHES.md is generated from this file and the code: when it differs, the fresh text
//     is printed between ===SCOPE_DOC_BEGIN docs/FEATURE_SWITCHES.md=== and ===SCOPE_DOC_END=== (the
//     sandboxed host cannot write the repository).
//  Deterministic; no network.
//

import Foundation
import Testing
@testable import Kalsmritikosh

private let switchesRepoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

@Suite("Owner 2026-11-15 — every built feature on, no hidden switch")
struct FeatureSwitchDefaultsTests {

    // MARK: - Product modules

    @Test func everyBuiltModuleDefaultsOnExceptTheDocumentedOnes() {
        for m in ProductModule.allCases where m.implemented {
            let keptOff = ProductModule.offByDefault[m] != nil
            #expect(m.spec.defaultEnabled != keptOff,
                    "\(m.rawValue): default \(m.spec.defaultEnabled ? "ON" : "OFF") but \(keptOff ? "is" : "is not") on the keep-off list")
        }
        for (m, off) in ProductModule.offByDefault {
            #expect(m.implemented, "\(m.rawValue) is listed as kept off but is not built")
            #expect(!off.why.isEmpty && !off.decision.isEmpty, "\(m.rawValue) has no reason")
        }
    }

    /// The keep-off list is exactly the categories the instruction allows: privacy and consent gates, owner
    /// decisions, the security lock, a diagnostic, retired surfaces and the 1.1 team feature.
    @Test func theKeepOffListIsExactlyTheAllowedOnes() {
        let expected: Set<ProductModule> = [
            .onlineAnswers, .leastDataOnline, .onlinePIIMasking,          // Online AI: opt-in, consent before any send
            .spotlightIndex, .folderSync, .questionMonitors,              // copy data out / automated monitoring (2026-11-06)
            .devonthinkImport, .sendToDevonthink,                         // owner decision 2026-11-06
            .appLock,                                                     // security choice; agent decision for owner review
            .extraParsers,                                                // unmeasured formats + other apps' data (launch claim, App Review)
            .archiveSelfScore,                                            // diagnostic
            .studioOutputs, .contentCreatorPersona,                       // retired
            .teamReview                                                   // D-TEAM, 1.1
        ]
        #expect(Set(ProductModule.offByDefault.keys) == expected)
        // The privacy-sensitive connections are never on by default (and never switched on by a preset or migration).
        #expect(ProductModule.neverSwitchedOnAutomatically.isSubset(of: expected))
        for m in ProductModule.allCases where m.spec.requiresOnline { #expect(expected.contains(m), "\(m.rawValue) needs Online but defaults on") }
    }

    /// Nothing built hides behind "Show preview features" any more: the one module still marked preview (team review)
    /// is out of the v1 scope, and its switch is not listed in Settings.
    @Test func noBuiltModuleIsAHiddenPreview() {
        for m in ProductModule.allCases where m.implemented && m.spec.preview {
            #expect(ProductModuleFlags.outOfV1Scope.contains(m), "\(m.rawValue) is still a hidden preview")
        }
        #expect(!ProductModule.locationMap.spec.preview && ProductModule.locationMap.spec.defaultEnabled)
        #expect(ProductModule.teamReview.disposition == .deferred && ProductModule.teamReview.family == .notInThisVersion)
    }

    // MARK: - Case map

    @Test func caseMapsAreOnByDefaultAndAnOffIsKept() throws {
        let name = "kalsmritikosh.tests.switches.\(UUID().uuidString)"
        let store = try #require(UserDefaults(suiteName: name))
        defer { store.removePersistentDomain(forName: name) }
        #expect(CaseMapPreview.defaultOn)
        #expect(CaseMapPreview.isEnabled(store), "never touched: on")
        CaseMapPreview.set(false, store)
        #expect(!CaseMapPreview.isEnabled(store), "the person's OFF is kept")
        CaseMapPreview.set(true, store)
        #expect(CaseMapPreview.isEnabled(store))
    }

    // MARK: - No "(preview)" wording left in the interface

    @Test func noInterfaceStringSaysPreview() throws {
        let ui = switchesRepoRoot.appendingPathComponent("Kalsmritikosh/UI")
        let files = FileManager.default.enumerator(at: ui, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        #expect(!files.isEmpty)
        for f in files {
            let text = try String(contentsOf: f, encoding: .utf8)
            #expect(!text.contains("(preview)\""), "\(f.lastPathComponent) still labels something \"(preview)\"")
            #expect(!text.contains("Show preview features"), "\(f.lastPathComponent) still shows the preview switch")
            #expect(!text.contains("Case map (preview)"), "\(f.lastPathComponent) still names the case map a preview")
        }
    }

    // MARK: - Engine switches

    /// Engine components (Settings ▸ Advanced ▸ Show engine components) that default off are exactly the documented ones.
    @Test func engineSwitchesThatDefaultOffAreTheDocumentedOnes() {
        let off = Set(KnowledgeModule.allCases.filter { $0.implemented && !$0.defaultEnabled })
        #expect(off == Set(FeatureSwitchesDocument.engineOff.keys))
    }

    // MARK: - Earlier installs

    @Test func revisionTwoReleasesTheOldOffPinsAndKeepsRealChoices() throws {
        let name = "kalsmritikosh.tests.switches.\(UUID().uuidString)"
        let store = try #require(UserDefaults(suiteName: name))
        defer { store.removePersistentDomain(forName: name) }
        // An install where revision 1 ran: it pinned the old OFF defaults; the person switched watchlists off themselves.
        store.set(1, forKey: ModuleScopeMigration.revisionKey)
        store.set(false, forKey: ProductModuleFlags.storageKey(.writtenNotes))
        store.set(false, forKey: ProductModuleFlags.storageKey(.searchCoverageBadge))
        store.set(true, forKey: ProductModuleFlags.storageKey(.devonthinkImport))
        store.set(false, forKey: ProductModuleFlags.storageKey(.watchlists))
        store.set(false, forKey: ProductModuleFlags.storageKey(.spotlightIndex))
        #expect(ModuleScopeMigration.run(store).isEmpty)
        #expect(store.object(forKey: ProductModuleFlags.storageKey(.writtenNotes)) == nil)
        #expect(store.object(forKey: ProductModuleFlags.storageKey(.searchCoverageBadge)) == nil)
        #expect(store.object(forKey: ProductModuleFlags.storageKey(.devonthinkImport)) as? Bool == true)
        #expect(store.object(forKey: ProductModuleFlags.storageKey(.watchlists)) as? Bool == false)
        #expect(store.object(forKey: ProductModuleFlags.storageKey(.spotlightIndex)) as? Bool == false)
        #expect(store.integer(forKey: ModuleScopeMigration.revisionKey) == ModuleScopeMigration.revision)
        // Once only.
        store.set(false, forKey: ProductModuleFlags.storageKey(.writtenNotes))
        #expect(ModuleScopeMigration.run(store).isEmpty)
        #expect(store.object(forKey: ProductModuleFlags.storageKey(.writtenNotes)) as? Bool == false)
    }

    @Test func anOlderInstallNoLongerGetsTheOldOffPins() throws {
        let name = "kalsmritikosh.tests.switches.\(UUID().uuidString)"
        let store = try #require(UserDefaults(suiteName: name))
        defer { store.removePersistentDomain(forName: name) }
        store.set(true, forKey: "kalsmritikosh.onboarding.shown")
        let pinned = ModuleScopeMigration.run(store)
        #expect(Set(pinned) == [.devonthinkImport, .sendToDevonthink])
        for m in ModuleScopeMigration.revisionOnePinnedOff {
            #expect(store.object(forKey: ProductModuleFlags.storageKey(m)) == nil, "\(m.rawValue) pinned off")
        }
        for m in ProductModule.neverSwitchedOnAutomatically {
            #expect(store.object(forKey: ProductModuleFlags.storageKey(m)) as? Bool != true, "\(m.rawValue) switched on")
        }
    }

    // MARK: - The published list

    @Test func committedSwitchListMatchesTheCode() throws {
        let rendered = FeatureSwitchesDocument.render()
        Attachment.record(rendered, named: "FEATURE_SWITCHES.md")
        let committed = (try? String(contentsOf: switchesRepoRoot.appendingPathComponent("docs/FEATURE_SWITCHES.md"), encoding: .utf8)) ?? ""
        if committed != rendered { print("===SCOPE_DOC_BEGIN docs/FEATURE_SWITCHES.md===\n" + rendered + "===SCOPE_DOC_END===") }
        #expect(committed == rendered, "docs/FEATURE_SWITCHES.md is stale — regenerate it from the attached render")
    }
}

/// Renders docs/FEATURE_SWITCHES.md: every switch, its release default, and for each one kept off the reason and the
/// decision it rests on. Product modules and engine components come from the code; the other switches are listed here
/// with their defaults as the code sets them (each row names the code that sets it).
enum FeatureSwitchesDocument {

    /// Engine components (KnowledgeModule) that default off, with why and the decision.
    static let engineOff: [KnowledgeModule: (why: String, decision: String)] = [
        .proseSubjectBinding: ("Changes how facts from plain documents are scoped to a subject, which changes answers.",
                               "Kept as the code's opt-in (ledger-scoping change); the scaffolding-only mandate (2026-11-06) allows no answer-quality change. Unified path AI-34 (owner 2026-11-22): ON when AI is on."),
        // Updated for AI-42 (owner 2026-11-23): AI does the thinking — the old on-device answer stack's modules are switched off.
        .aiSubjectResolution: ("Uses the on-device AI to merge topics.",
                               "Switched off — AI-42 (owner 2026-11-23, AI does the thinking): default off and not offered; RetiredPaths.onDeviceAnswerStack restores it."),
        .aiComposeEveryAnswer: ("The on-device model rewrote every answer.",
                                "Switched off — AI-42 (owner 2026-11-23, AI does the thinking): default off and not offered; RetiredPaths.onDeviceAnswerStack restores it."),
        .topicSeededComposers: ("Fed the matched topic to the on-device answer composers.",
                                "Switched off — AI-42 (owner 2026-11-23, AI does the thinking): default off and not offered; RetiredPaths.onDeviceAnswerStack restores it."),
        .actorComposer: ("A rule door for who-did-this questions.",
                         "Switched off — AI-42 (owner 2026-11-23, AI does the thinking): default off and not offered; RetiredPaths.onDeviceAnswerStack restores it."),
        .onlineRecordReading: ("Sends document text about a person to your cloud AI.",
                               "Online is opt-in, every send behind the case's consent (SHIP_DECISIONS 2026-10-15, 2026-11-04 (9); privacy policy)."),
        .inducedSchema: ("Lets a model name fields that are then written into the ledger.",
                         "A model-assisted ledger writer stays a deliberate choice (code note); AI is off by default (SHIP_DECISIONS 2026-10-24). Unified path AI-34 (owner 2026-11-22): ON when AI is on. Its facts stay marked llmInduced.")
    ]

    /// Switches outside the two module lists: (switch, where, release default, what it controls, user-facing?, decision).
    static let otherSwitches: [(String, String, String, String, String, String)] = [
        ("Case maps", "CaseMapPreview (CaseWorkspace.swift); case top bar", "ON", "Each case opens on its map", "yes",
         "Turned ON 2026-11-15 (was “Case map (preview)”, off). A person's OFF is kept."),
        ("Use AI to write answers", "EvidenceOnlyRelease.aiEnabled; Settings ▸ Modules", "OFF", "Any generative model in answers", "yes",
         "KEPT OFF — owner decision 2026-10-24 (evidence-only by default; AI is a switch)."),
        ("Connection: Private / Online", "ConnectivityMode; Settings ▸ Modules ▸ Connection", "Private", "Whether anything may leave the Mac", "yes",
         "KEPT Private — O-1 2026-10-15 and the privacy policy: Online is opt-in, per-case consent before any send."),
        ("AI regime (fully private / gated)", "FeatureFlags.aiMode + PrivacyGate.offlineNoLLM", "gated (only when AI is on)", "How the AI may answer", "yes (with AI on)",
         "AI-42 (owner 2026-11-23): “AI · free” (unconstrained) is switched off and not offered; RetiredPaths.unconstrainedAIMode restores it."),
        ("AI-only answer options (general knowledge, final-answer prose)", "FeatureFlags; Settings ▸ Advanced", "ON (inert while AI is off)", "How AI answers are written", "yes (with AI on)",
         "Unchanged — AI answer behaviour. Full power / Lightning no longer switches the AI off (AI-42)."),
        ("Council, self-critique, relevance-gated experts", "FeatureFlags (moeCouncil, llmSelfCritique, expertRelevanceGating)", "OFF", "The old on-device answer stack", "no",
         "Switched off — AI-42 (owner 2026-11-23, AI does the thinking): not offered; RetiredPaths.onDeviceAnswerStack restores them."),
        ("Retired paths (AI does the thinking)", "RetiredPaths (FeatureFlags.swift)", "OFF", "Unconstrained mode, SystemMode presets, local generative models, the old answer stack, rule causal links, counterfactual labels, rule contradictions, rule drafts, rule facts in the case briefing, three retired modules", "no",
         "Owner decision 2026-11-23 (docs/AI_AGENT_SPLIT_2026-11-23.md, AI-41..43): switched off reversibly; no data deleted; privacy, consent and erasure unchanged."),
        ("Show unconfirmed AI readings", "UnverifiedAnswerPolicy; Settings ▸ Advanced", "OFF", "Showing an AI reading the evidence check could not confirm", "yes (with AI on)",
         "KEPT OFF — evidence-gate safety policy (U-1); AI answer behaviour."),
        ("iMessage loader / Browser history loader", "FeatureFlags; Settings ▸ Ingest options", "OFF", "Older loaders for Messages and browser databases", "yes",
         "KEPT OFF — App Review: other apps' data only when the person authorises it. The newer readers for the same files are “More file types”, also kept off (see section 1)."),
        ("Chat exports (WhatsApp, Signal, Slack)", "FeatureFlags; Settings ▸ Ingest options", "ON", "Plain-text chat exports", "yes", "Unchanged."),
        ("OCR images during ingest", "FeatureFlags; Settings ▸ Ingest options", "ON", "Text recognition at import", "yes", "Unchanged."),
        ("Managed evidence copies", "FeatureFlags.managedEvidenceMode; Settings ▸ Ingest options", "ON", "Encrypted copies of originals", "yes", "Unchanged (IN-02, 2026-11-08)."),
        ("Background maintenance", "FeatureFlags.maintenanceMode; Settings ▸ Background maintenance", "Automatic", "Idle-time tidying", "yes",
         "Unchanged (2026-09-20). Help and the glossary said “off by default”; corrected 2026-11-15."),
        ("Transcribe audio & video", "KnowledgeModule.mediaTranscription", "ON", "On-device speech to text at import", "yes",
         "Unchanged (2026-10-31: the module defaults on; the older “audio off by design” note is superseded)."),
        ("Prefer classic surfaces", "FeatureFlags.preferClassicSurfaces; Settings ▸ Answering & modes", "OFF", "Older Analyze launchers instead of the studios", "yes",
         "KEPT OFF — an alternative style, not a hidden feature; both surfaces are reachable."),
        ("Classic conformance mode", "FeatureFlags.classicConformance; Settings ▸ Answering & modes", "OFF", "Turns OFF conformance enforcement", "yes",
         "KEPT OFF — ON would weaken a safeguard (owner request 2026-08-25: strict is the default)."),
        ("Custom protocol studio", "FeatureFlags.customProtocolStudio; Settings ▸ Answering & modes", "ON", "Authoring your own constitution (AI drafts)", "yes",
         "Turned ON — Unified path AUTO-14 (owner 2026-11-22; was OFF by the 2026-08-25 request). Its AI drafting needs AI on; a person's OFF is kept."),
        ("Context-prefix backfill / ingest-time memory distillation / first-chunk card", "FeatureFlags + ReleaseCapabilityProfile.current()", "OFF (ON when AI is on)", "Generative AI during import", "no",
         "OFF while AI is off — release profile: no generative AI at ingest (single-mode 2026-07-08, GOV-001). Unified path AI-34 (owner 2026-11-22): with AI on, the v1AIOn profile turns these on, with background AI upkeep and AI re-ranking."),
        ("Show all jobs", "PersonaJobsView; Professional Jobs", "OFF", "List every phase's jobs at once, and the jobs a profession's list leaves out (Investigator: Data Lab, Causal analysis, CAPA register, Effectiveness review)", "yes",
         "Display preference — every job is one click away and found by ⌥⌘F; the jobs left out of a profession's list are named on the screen with why (Ease fixes B, 2026-11-15); not hidden."),
        ("Keep each email thread as one document", "Settings ▸ Advanced", "ON", "How mailboxes are split at import", "yes",
         "Turned ON — Unified path IN-22 (owner 2026-11-22). Mailboxes added before keep their earlier shape until added again; a person's OFF is kept."),
        ("Show low-quality names in results", "Settings ▸ Advanced", "OFF", "Showing machine-like names", "yes", "Display filter; nothing is hidden from the record."),
        ("Auto-complete steps when filled", "Work Center", "OFF", "Steps tick themselves", "yes", "A working preference, not a feature."),
        ("Show engine components / More diagnostic tools / Advanced", "Settings disclosures", "collapsed", "Troubleshooting controls", "yes",
         "Collapsed, not hidden (scope 2026-11-06 §6)."),
        ("Menu-bar panel", "ProductModule.menuBarAsk", "ON", "Ask from the menu bar", "yes", "Turned ON 2026-11-15; the unit-test host never adds the item.")
    ]

    /// Developer-only or not built: never on in Release.
    static let notInRelease: [(String, String)] = [
        ("--ui-walk-* arguments, --acceptance-case, --pa-prod-gui-smoke, sample/acceptance fixtures", "DEBUG builds only (GUI walks and acceptance checks)."),
        ("ProductModuleFlags.TestOverride, PaidUse.TestOverride, ConnectivityMode overrides", "DEBUG / test host only."),
        ("Benchmarks and eval harnesses (narrative eval, release-readiness banner, full diagnostics, synthetic questions)", "DEBUG builds only (developer diagnostics)."),
        ("Local model servers (Ollama setup), model picker, provider list, own models, pinning", "DEBUG builds only — no Ollama or third-party model in Release (SHIP_DECISIONS §1, GOV-001)."),
        ("MLX / LlamaCpp / developer cloud providers", "Intentional stubs (CLAUDE.md); developer-only."),
        ("Team review and every team or server feature", "Not available in 1.0 (D-TEAM, 2026-11-13): team cases are planned for 1.1; Settings does not list the switch."),
        ("Sandboxed helper process for document readers (IN-10)", "Not built in 1.0 (D-IN10, 2026-11-13); readers run in the app inside the App Sandbox."),
        ("AI plans and credit packs in the 13 blocked storefronts", "Never offered there (AIRegion, 2026-11-04 (3)); not a switch.")
    ]

    static func cell(_ s: String) -> String { s.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ") }

    static func render() -> String {
        var out = "# Feature switches\n\n"
        out += "_Generated by `FeatureSwitchDefaultsTests` (KalsmritikoshTests/FeatureSwitchDefaultsTests.swift) from the code; do not edit by hand._\n\n"
        out += "Owner instruction 2026-11-15: \u{201C}All preview should be active, and all tracker should be active as well, no surprise.\u{201D} "
        out += "Every built feature is on by default. What stays off is listed below with its reason and the decision it rests on; "
        out += "a test fails if a feature defaults off without being listed here. A stored choice the person made is never overridden.\n\n"

        let built = ProductModule.allCases.filter(\.implemented)
        let on = built.filter { $0.spec.defaultEnabled }
        out += "## 1. Features (Settings ▸ Modules)\n\n"
        out += "\(built.count) built: \(on.count) on by default, \(built.count - on.count) kept off.\n\n"
        out += "| Feature | Plan | Key | Release default | Why off · decision |\n|---|---|---|---|---|\n"
        for m in built.sorted(by: { $0.spec.planID < $1.spec.planID }) {
            let off = ProductModule.offByDefault[m]
            let why = off.map { cell($0.why) + " · " + cell($0.decision) } ?? ""
            out += "| \(cell(m.title)) | \(m.spec.planID) | `\(m.rawValue)` | \(m.spec.defaultEnabled ? "ON" : "**OFF**") | \(why) |\n"
        }

        out += "\n## 2. Engine components (Settings ▸ Advanced ▸ Show engine components)\n\n"
        out += "| Component | Key | Release default | Why off · decision |\n|---|---|---|---|\n"
        for k in KnowledgeModule.allCases.filter(\.implemented).sorted(by: { $0.title < $1.title }) {
            let why = engineOff[k].map { cell($0.why) + " · " + cell($0.decision) } ?? ""
            out += "| \(cell(k.title)) | `\(k.rawValue)` | \(k.defaultEnabled ? "ON" : "**OFF**") | \(why) |\n"
        }

        out += "\n## 3. Other switches\n\n"
        out += "| Switch | Where | Release default | Controls | User-facing | Decision |\n|---|---|---|---|---|---|\n"
        for r in otherSwitches {
            out += "| \(cell(r.0)) | \(cell(r.1)) | \(r.2) | \(cell(r.3)) | \(r.4) | \(cell(r.5)) |\n"
        }

        out += "\n## 4. Never on in a Release build\n\n| What | Why |\n|---|---|\n"
        for r in notInRelease { out += "| \(cell(r.0)) | \(cell(r.1)) |\n" }

        out += "\n## 5. Earlier installs\n\n"
        out += "A switch the person never touched follows the new default (on). A stored value is the person's own choice and is kept, "
        out += "with one exception the code cannot tell apart: on an install where the 2026-11-06 scope migration (revision 1) stored "
        out += "the old OFF default for \u{201C}Search coverage badge\u{201D} and \u{201C}Your own notes\u{201D}, revision 2 removes that stored OFF so both follow "
        out += "the new ON default (Help ▸ What's new says so). The DEVONthink connectors an earlier install had keep their value, and no migration "
        out += "ever switches on Online, Spotlight, folder sync or watched questions.\n"
        return out
    }
}

extension AppState {
    /// The import queue (core, ON by default since 2026-11-15) runs added files in the background and returns at
    /// once. Tests that read their files and then check the result use the queue's documented "off" behaviour —
    /// the files are read in order before this returns — for their own task tree only (never the shared store).
    func ingestFilesInOrder(_ urls: [URL]) async {
        var modules = ProductModuleFlags.TestOverride.modules ?? [:]
        modules[.importQueue] = false
        await ProductModuleFlags.TestOverride.$modules.withValue(modules) { await ingestFiles(urls) }
    }
}
