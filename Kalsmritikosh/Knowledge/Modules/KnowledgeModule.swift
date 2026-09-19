//
//  KnowledgeModule.swift
//  Kalsmritikosh
//
//  The MODULE SWITCHBOARD (owner request 2026-09-19). Every knowledge-synthesis
//  and answer-quality capability that can be independently turned on/off lives
//  here as one enum case with its own persisted flag. This is the single place
//  to see what exists, what's on, and where each is wired — so a capability can
//  be tracked, toggled, and updated in isolation.
//
//  Adding a new module is three steps:
//   1. add a `case` here with title/detail/defaultEnabled/implemented,
//   2. gate its code path with `KnowledgeModuleFlags.isEnabled(.yourCase)`,
//   3. it auto-appears in Settings → Modules (implemented cases only).
//
//  Reads are `nonisolated` over UserDefaults (thread-safe), matching the
//  FeatureFlags convention, so any actor/pipeline context can consult a flag
//  without an actor hop. Toggling a call-time-gated module takes effect on the
//  next run of that module; boot-constructed ones note "next launch".
//

import Foundation

public enum KnowledgeModule: String, CaseIterable, Sendable, Identifiable {
    // Ledger synthesis
    case topicMinimization      // fold thin topics into their closest substantive topic
    case autoTopics             // rebuild deduped + minimized topics on the idle pass (L1)
    case summariesAtIdle        // L2 — build heuristic summaries on the idle pass
    case historyAtIdle          // L3 — persist reconstructed history on the idle pass
    case eventSlotFill          // L4 — optional FM 5W+H slot fill
    case documentClass          // L6 — persisted document-class labelling
    // Retrieval
    case crossEncoderRerank     // R2 — cross-encoder rerank on the answer path
    case correctiveRetrieval    // R3 — re-retrieve on weak evidence
    case hydeExpansion          // R4 — hypothetical-answer query expansion
    case boilerplateEmbedSkip   // I1 — skip learned boilerplate templates at embed time
    // Answer composition
    case actorComposer          // A1 — dedicated "who did X" actor answer door
    case progressiveStreaming   // A2 — stream instant→synthesis→verified to the UI
    case topicSeededComposers   // A3 — seed the matched topic into the model composers

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .topicMinimization:    return "Topic minimization"
        case .autoTopics:           return "Auto-build topics"
        case .summariesAtIdle:      return "Summaries at idle"
        case .historyAtIdle:        return "History at idle"
        case .eventSlotFill:        return "Event detail fill (5W+H)"
        case .documentClass:        return "Document-class labelling"
        case .crossEncoderRerank:   return "Cross-encoder reranking"
        case .correctiveRetrieval:  return "Corrective re-retrieval"
        case .hydeExpansion:        return "Hypothetical query expansion"
        case .boilerplateEmbedSkip: return "Boilerplate embed-skip"
        case .actorComposer:        return "Actor answers (who did X)"
        case .progressiveStreaming: return "Progressive answer streaming"
        case .topicSeededComposers: return "Topic-first composition"
        }
    }

    public var detail: String {
        switch self {
        case .topicMinimization:    return "A topic with too little evidence folds into its closest substantive topic, keeping topics few and meaningful."
        case .autoTopics:           return "Rebuild deduplicated, minimized topics automatically while the Mac is idle — no manual button."
        case .summariesAtIdle:      return "Build per-document and per-community summaries during idle maintenance."
        case .historyAtIdle:        return "Reconstruct and store per-subject history chapters during idle maintenance."
        case .eventSlotFill:        return "Fill missing who/where/when/why/how event details with the on-device model, under a fact-preserving guard."
        case .documentClass:        return "Classify and store each document's class so extraction packs can gate by it."
        case .crossEncoderRerank:   return "Reorder retrieved passages with a cross-encoder so the most on-target passage leads. Reorder-only; never drops evidence."
        case .correctiveRetrieval:  return "When first-pass evidence is weak, re-retrieve once with expanded terms before answering or abstaining."
        case .hydeExpansion:        return "On a weak vector pass, expand the query with a hypothetical answer and fuse the results. Never shown or cited."
        case .boilerplateEmbedSkip: return "Skip embedding of learned, cross-document boilerplate templates. Still fully searchable; just down-ranked."
        case .actorComposer:        return "Route who-did-this questions to the passage naming the acting party and compose a grounded answer."
        case .progressiveStreaming: return "Render the answer as it forms — instant context, then synthesis, then the verified result."
        case .topicSeededComposers: return "Give the model composer the matched topic first, so answers lead with the topic rather than raw facts."
        }
    }

    /// Whether the code path exists today. Only implemented modules are shown in
    /// Settings and consulted at runtime; flip to `true` when the module lands.
    public var implemented: Bool {
        switch self {
        case .topicMinimization, .autoTopics, .crossEncoderRerank,
             .correctiveRetrieval, .hydeExpansion, .summariesAtIdle, .historyAtIdle:
            return true
        case .eventSlotFill, .documentClass,
             .boilerplateEmbedSkip, .actorComposer, .progressiveStreaming,
             .topicSeededComposers:
            return false
        }
    }

    /// Default state when the user has never toggled it.
    public var defaultEnabled: Bool {
        // Implemented modules are on by default (they are the current behaviour);
        // not-yet-implemented modules default off.
        implemented
    }

    /// Grouping for the Settings list.
    public var group: String {
        switch self {
        case .topicMinimization, .autoTopics, .summariesAtIdle, .historyAtIdle,
             .eventSlotFill, .documentClass:
            return "Knowledge synthesis"
        case .crossEncoderRerank, .correctiveRetrieval, .hydeExpansion, .boilerplateEmbedSkip:
            return "Retrieval"
        case .actorComposer, .progressiveStreaming, .topicSeededComposers:
            return "Answer composition"
        }
    }

    fileprivate var storageKey: String { "kalsmritikosh.module.\(rawValue)" }
}

/// Thread-safe, `nonisolated` accessor over UserDefaults — callable from any
/// actor or pipeline context (matches the FeatureFlags convention).
public enum KnowledgeModuleFlags {

    public nonisolated static func isEnabled(_ m: KnowledgeModule) -> Bool {
        // A module with no code path can never be "on" at runtime.
        guard m.implemented else { return false }
        let d = UserDefaults.standard
        if d.object(forKey: m.storageKey) == nil { return m.defaultEnabled }
        return d.bool(forKey: m.storageKey)
    }

    public nonisolated static func setEnabled(_ m: KnowledgeModule, _ on: Bool) {
        UserDefaults.standard.set(on, forKey: m.storageKey)
    }

    /// The persisted key, for SwiftUI bindings that need it.
    public nonisolated static func storageKey(_ m: KnowledgeModule) -> String { m.storageKey }
}
