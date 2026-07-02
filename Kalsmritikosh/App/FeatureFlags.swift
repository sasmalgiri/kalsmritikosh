//
//  FeatureFlags.swift
//  Kalsmritikosh
//
//  Phase L (App Store readiness) — runtime feature gates for ingest
//  surfaces that touch other apps' data. ALL flags default OFF so a
//  vanilla Mac App Store install behaves identically to a sandboxed
//  archive reader. Users opt in via Settings.
//
//  Why this exists: iMessage, Safari, and Chromium loaders read
//  SQLite files in other apps' containers. Even though the sandbox
//  already blocks unauthorized reads (the OS denies them at the
//  syscall level), App Store reviewers flag any app that ADVERTISES
//  these capabilities by default. Defaulting OFF + an explicit
//  Settings toggle gated behind a warning satisfies the review
//  criterion ("only read other apps' data when the user explicitly
//  authorized it for this app").
//
//  Persistence: UserDefaults. Cheap, system-managed, survives app
//  updates. No Keychain needed — the flag value isn't a secret.
//

import Foundation
import Observation

/// The three architectures we're evaluating side-by-side. Selecting a
/// mode presets the whole enrichment pipeline; the retrieval/answer
/// stack (RAG + experts + verifier + ledger) is identical across all
/// three — only how much meaning we extract, and WHEN, changes.
public enum SystemMode: String, CaseIterable, Identifiable, Sendable {
    /// System 1 — the original "most diligent" pipeline: eager deep
    /// enrichment (context-prefix on every chunk + memory distillation
    /// per entity) at ingest. Deepest ledger, slowest + most expensive
    /// ingest (~10h/100MB). Full RAG + experts on top, unchanged.
    case fullLLM

    /// System 2 — importance-tiered. Cold data gets cheap rule passes;
    /// only hot/important data gets deep LLM enrichment. (Tiering engine
    /// in progress — currently behaves like ledger-first for cold.)
    case hotWarmCold

    /// System 3 — ledger-first, event-driven. Near-zero-LLM ingest
    /// (rule extraction only), memory warmed on demand, LLM reserved for
    /// query-time interpretation + narration. Gap detection +
    /// investigation templates in progress.
    case ledgerEventDriven

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .fullLLM:          return "Full LLM (deepest, slowest)"
        case .hotWarmCold:      return "Hot / Warm / Cold (tiered)"
        case .ledgerEventDriven: return "Ledger event-driven (fastest)"
        }
    }

    /// Compact label for the always-visible active-mode badge.
    public var shortLabel: String {
        switch self {
        case .fullLLM:           return "Full LLM"
        case .hotWarmCold:       return "Hot / Warm / Cold"
        case .ledgerEventDriven: return "Ledger"
        }
    }

    /// SF Symbol used by the chooser + badge.
    public var symbolName: String {
        switch self {
        case .fullLLM:           return "brain.head.profile"
        case .hotWarmCold:       return "flame"
        case .ledgerEventDriven: return "bolt"
        }
    }

    public var detail: String {
        switch self {
        case .fullLLM:
            return "Original pipeline. Eager deep extraction of every chunk + entity during ingest. Richest ledger up front; ingest can take hours. Full RAG + experts unchanged."
        case .hotWarmCold:
            return "Cheap rule passes for everything; deep LLM only for important/hot data. Balances depth and cost. (Tiering engine still being built.)"
        case .ledgerEventDriven:
            return "Rule-based ingest (near-zero LLM), memory warmed on demand, LLM only at query time. Fastest ingest; history recreated from the structured ledger."
        }
    }

    /// The enrichment policy this mode implies. AppState reads this at
    /// boot to wire the pipeline. The individual FeatureFlags toggles
    /// are advanced overrides; the mode is the master preset.
    public struct EnrichmentPolicy: Sendable {
        public let eagerMemoryDistillation: Bool
        public let contextPrefixBackfill: Bool
        /// System 3 / Stage-2 — one document-card LLM call per file (first
        /// chunk only). Mutually exclusive with `contextPrefixBackfill`
        /// (which already covers every chunk, so the card is redundant).
        public let firstChunkCard: Bool

        public init(
            eagerMemoryDistillation: Bool,
            contextPrefixBackfill: Bool,
            firstChunkCard: Bool = false
        ) {
            self.eagerMemoryDistillation = eagerMemoryDistillation
            self.contextPrefixBackfill = contextPrefixBackfill
            self.firstChunkCard = firstChunkCard
        }
    }

    public var policy: EnrichmentPolicy {
        switch self {
        case .fullLLM:
            return .init(eagerMemoryDistillation: true, contextPrefixBackfill: true)
        case .hotWarmCold:
            // Cheap ingest + one document-card call per file; deep LLM only
            // for the hot slice (TierPromoter).
            return .init(eagerMemoryDistillation: false, contextPrefixBackfill: false, firstChunkCard: true)
        case .ledgerEventDriven:
            // Rules + one document-card call per file; LLM otherwise reserved
            // for query time.
            return .init(eagerMemoryDistillation: false, contextPrefixBackfill: false, firstChunkCard: true)
        }
    }
}

/// How idle maintenance (background summarization / distillation while
/// the Mac is idle) behaves. User-configurable in Settings.
public enum MaintenanceMode: String, CaseIterable, Identifiable, Sendable {
    /// Never run idle maintenance.
    case off
    /// Ask the user before each pass (a prompt appears when idle).
    case ask
    /// Run automatically and show a status banner on start / stop.
    case notify
    /// Run automatically and silently — no banner, fully hands-off.
    case automatic

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .off:       return "Off"
        case .ask:       return "Ask first"
        case .notify:    return "Automatic + notify"
        case .automatic: return "Automatic (silent)"
        }
    }

    public var detail: String {
        switch self {
        case .off:       return "Never run background maintenance."
        case .ask:       return "Prompt me before each pass when my Mac goes idle."
        case .notify:    return "Run while idle and show a small banner when it starts and stops."
        case .automatic: return "Run while idle, silently — don't show me anything."
        }
    }
}

@MainActor
@Observable
public final class FeatureFlags {
    public static let shared = FeatureFlags()

    /// Phase K — iMessage loader (reads ~/Library/Messages/chat.db
    /// when a user-selected folder contains a copy of it). Default
    /// OFF for App Store builds. When the user enables this they're
    /// asked to manually export chat.db to a watched folder first.
    public var iMessageLoaderEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.kIMessage) }
        set { UserDefaults.standard.set(newValue, forKey: Self.kIMessage) }
    }

    /// Phase K — Safari and Chromium history loaders. Same shape as
    /// iMessage: OFF by default, opt-in via Settings, requires the
    /// user to have placed a copy of History.db / History in a
    /// watched folder.
    public var browserHistoryLoaderEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.kBrowserHistory) }
        set { UserDefaults.standard.set(newValue, forKey: Self.kBrowserHistory) }
    }

    /// Phase K — WhatsApp / Signal / Slack text-export loader. Plain-
    /// text reading — no Full Disk Access angle — but kept behind a
    /// flag for parity with the other chat-surface loaders so the
    /// Settings UI groups all three under one "personal chat" toggle.
    public var chatExportLoaderEnabled: Bool {
        get {
            // Plain-text exports are safe by default — no system access.
            // Default ON unless the user has explicitly turned them off.
            if UserDefaults.standard.object(forKey: Self.kChatExport) == nil { return true }
            return UserDefaults.standard.bool(forKey: Self.kChatExport)
        }
        set { UserDefaults.standard.set(newValue, forKey: Self.kChatExport) }
    }

    /// Master architecture selector (the three systems we're comparing).
    /// Defaults to `.fullLLM` — the original "most diligent" baseline —
    /// so evaluation starts from the reference system. Read at boot to
    /// preset the enrichment pipeline via `SystemMode.policy`.
    public var systemMode: SystemMode {
        get {
            guard let raw = UserDefaults.standard.string(forKey: Self.kSystemMode),
                  let mode = SystemMode(rawValue: raw) else { return .fullLLM }
            return mode
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Self.kSystemMode) }
    }

    /// Thread-safe read of the current system mode for non-main-actor
    /// contexts. UserDefaults is thread-safe.
    public nonisolated static func systemModeValue() -> SystemMode {
        guard let raw = UserDefaults.standard.string(forKey: kSystemMode),
              let mode = SystemMode(rawValue: raw) else { return .fullLLM }
        return mode
    }

    /// Whether the user has EXPLICITLY chosen a system mode. False on a
    /// fresh install, which triggers the first-run mode chooser before the
    /// engine boots. Set true the first time the user picks a mode.
    public var systemModeChosen: Bool {
        get { UserDefaults.standard.bool(forKey: Self.kSystemModeChosen) }
        set { UserDefaults.standard.set(newValue, forKey: Self.kSystemModeChosen) }
    }

    /// Ledger-AI v28 — global context-prefix backfill. OFF by default.
    ///
    /// When enabled, the backfiller writes `context_prefix` AND re-embeds
    /// the chunk's vector from `prefix + text`, so the LLM work improves
    /// semantic retrieval (not just a text column). It stays opt-in
    /// because it's LLM-heavy — best reserved for hot/pinned data or a
    /// deliberate overnight sweep.
    ///
    /// Default OFF means a fresh archive stays fully FTS + entity +
    /// event searchable immediately without the LLM prefix sweep on the
    /// critical path.
    public var contextPrefixBackfillEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.kContextPrefixBackfill) }
        set { UserDefaults.standard.set(newValue, forKey: Self.kContextPrefixBackfill) }
    }

    /// Idle-maintenance mode. Default `.notify` — runs while idle and
    /// keeps the user informed. Users can switch to Ask / Automatic /
    /// Off in Settings.
    public var maintenanceMode: MaintenanceMode {
        get {
            guard let raw = UserDefaults.standard.string(forKey: Self.kMaintenanceMode),
                  let mode = MaintenanceMode(rawValue: raw) else { return .notify }
            return mode
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Self.kMaintenanceMode) }
    }

    /// Minutes the Mac must be idle before a maintenance pass may begin.
    /// Default 2. Range enforced by the Settings picker.
    public var maintenanceIdleMinutes: Int {
        get {
            let v = UserDefaults.standard.object(forKey: Self.kMaintenanceIdleMinutes) as? Int
            return v ?? 2
        }
        set { UserDefaults.standard.set(newValue, forKey: Self.kMaintenanceIdleMinutes) }
    }

    /// Thread-safe read of the idle-minutes setting for use from
    /// non-main-actor contexts (the scheduler's @Sendable closure).
    /// UserDefaults is thread-safe, so this needs no actor hop.
    public nonisolated static func maintenanceIdleMinutesValue() -> Int {
        (UserDefaults.standard.object(forKey: kMaintenanceIdleMinutes) as? Int) ?? 2
    }

    /// Ledger-first LLM reduction. OFF by default: no per-subject memory
    /// distillation during ingest — the single biggest ingest LLM saving
    /// (the "Distilled memory for …" storm in the logs). Answers still
    /// come from the ledger layers below memory (events, entities,
    /// timeline, FTS). Turn ON to eagerly pre-warm memory during ingest.
    /// Takes effect on next app launch.
    public var ingestTimeMemoryDistillation: Bool {
        get { UserDefaults.standard.bool(forKey: Self.kIngestDistill) }
        set { UserDefaults.standard.set(newValue, forKey: Self.kIngestDistill) }
    }

    // MARK: - Storage keys

    private nonisolated static let kSystemMode             = "atlas.feature.systemMode"
    private nonisolated static let kSystemModeChosen       = "atlas.feature.systemModeChosen"
    private nonisolated static let kMaintenanceMode        = "atlas.feature.maintenance.mode"
    private nonisolated static let kMaintenanceIdleMinutes = "atlas.feature.maintenance.idleMinutes"
    private static let kIngestDistill    = "atlas.feature.ingestTimeMemoryDistillation.enabled"
    private static let kIMessage         = "atlas.feature.imessageLoader.enabled"
    private static let kBrowserHistory   = "atlas.feature.browserHistory.enabled"
    private static let kChatExport       = "atlas.feature.chatExport.enabled"
    private static let kContextPrefixBackfill = "atlas.feature.contextPrefixBackfill.enabled"
}
