//
//  SystemEngine.swift
//  Kalsmritikosh
//
//  The three architectures we ship in ONE codebase are modeled as three
//  independent `SystemEngine`s. Exactly one is constructed at boot from
//  the active `SystemMode`; it owns everything that makes that system
//  distinct — its ingest policy, its background maintenance engine, and
//  how it reacts to answers. There is NO cross-mode gating scattered
//  through AppState any more: each engine is a single, self-contained
//  file you can read top-to-bottom to understand one system.
//
//  What is DELIBERATELY shared (and must stay identical across all three,
//  per the architecture invariants): the retrieval / RAG / expert /
//  verifier / ledger answer stack. Engines only change how much meaning
//  is extracted, and WHEN — never how a question is answered.
//
//    System 1 — FullLLMEngine          : eager deep enrichment at ingest.
//    System 2 — HotWarmColdEngine       : proactive importance tiering.
//    System 3 — LedgerEventDrivenEngine : proactive rule-based gap upkeep.
//

import Foundation

/// The collaborators an engine may need to run its own maintenance and
/// hooks. AppState builds this once at boot (all deps are already local
/// there) and hands it to the single active engine. Everything here is
/// `Sendable`; the LLM-heavy plumbing (incremental updater, context-prefix
/// backfiller) is driven by AppState directly from `engine.ingestPolicy`,
/// so those concrete types don't leak into the engines.
public struct SystemEngineContext: Sendable {
    // System 2 (tiering) dependencies. Optional so an engine can degrade
    // gracefully rather than trap if a repo failed to boot.
    public let enrichment: EnrichmentStatusRepository?
    public let objects: KnowledgeObjectRepository?
    public let entities: EntitiesRepository?
    public let events: EventsRepository?
    public let distiller: MemoryDistiller

    /// System 3 — rule-based gap scan over the ledger (no LLM). Returns
    /// the number of gaps found so the UI can report "maintained just now".
    public let scanForGaps: @Sendable () async -> Int
    /// Report each proactive gap pass back to the UI layer.
    public let onGapScan: @Sendable (Int) -> Void

    /// System 2 — capture the citation signal from a shipped answer.
    /// Bumps each cited object's citation count; the tier promoter folds
    /// that into importance on its next idle pass.
    public let bumpCitations: @Sendable ([UUID]) async -> Void

    public init(
        enrichment: EnrichmentStatusRepository?,
        objects: KnowledgeObjectRepository?,
        entities: EntitiesRepository?,
        events: EventsRepository?,
        distiller: MemoryDistiller,
        scanForGaps: @escaping @Sendable () async -> Int,
        onGapScan: @escaping @Sendable (Int) -> Void,
        bumpCitations: @escaping @Sendable ([UUID]) async -> Void
    ) {
        self.enrichment = enrichment
        self.objects = objects
        self.entities = entities
        self.events = events
        self.distiller = distiller
        self.scanForGaps = scanForGaps
        self.onGapScan = onGapScan
        self.bumpCitations = bumpCitations
    }
}

/// One of the three architectures. Constructed once per launch from the
/// active `SystemMode`; only this engine's maintenance runs, so engines
/// need no self-gating on mode.
public protocol SystemEngine: Sendable {
    /// Which architecture this engine implements.
    nonisolated var mode: SystemMode { get }

    /// The ingest enrichment this system wants. AppState reads this to
    /// wire the (mode-independent) incremental updater + context-prefix
    /// backfiller. Advanced FeatureFlags overrides are OR'd in by AppState.
    nonisolated var ingestPolicy: SystemMode.EnrichmentPolicy { get }

    /// Start this engine's own background maintenance.
    func activate(_ context: SystemEngineContext) async

    /// Stop background maintenance (used on teardown).
    func deactivate() async

    /// React to a shipped, verified answer (System 2 uses this for the
    /// citation signal; the others no-op).
    func onAnswer(_ answer: VerifiedAnswer) async
}

/// Builds the single engine for the active mode. Adding a fourth system
/// is one case here plus one new engine file — nothing else changes.
public enum SystemEngineFactory {
    public static func make(_ mode: SystemMode) -> any SystemEngine {
        switch mode {
        case .fullLLM:           return FullLLMEngine()
        case .hotWarmCold:       return HotWarmColdEngine()
        case .ledgerEventDriven: return LedgerEventDrivenEngine()
        }
    }
}
