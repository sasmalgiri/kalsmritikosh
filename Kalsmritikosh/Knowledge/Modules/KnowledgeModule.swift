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
    case proseSubjectBinding    // A3 — bind subject-less prose facts to a resolved subject
    // (L6 document-class labelling is shipped core — always on, migration v123 —
    //  so it is not an optional module here.)
    // Retrieval
    case crossEncoderRerank     // R2 — cross-encoder rerank on the answer path
    case correctiveRetrieval    // R3 — re-retrieve on weak evidence
    case hydeExpansion          // R4 — hypothetical-answer query expansion
    case boilerplateEmbedSkip   // I1 — skip learned boilerplate templates at embed time
    case passwordProtectedFiles // A4 — open encrypted files (empty-password unlock; classify the rest)
    case importLifecycle        // A2 — unified per-source lifecycle state + omission disclosure
    // Answer composition
    case storyReviewerLoop      // Lane C — record approve/correct/reject verdicts on story items
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
        case .proseSubjectBinding:  return "Plain-document subject binding"
        case .crossEncoderRerank:   return "Cross-encoder reranking"
        case .correctiveRetrieval:  return "Corrective re-retrieval"
        case .hydeExpansion:        return "Hypothetical query expansion"
        case .boilerplateEmbedSkip: return "Boilerplate embed-skip"
        case .passwordProtectedFiles: return "Password-protected files"
        case .importLifecycle:      return "Import & coverage lifecycle"
        case .storyReviewerLoop:    return "Story review (approve / correct / reject)"
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
        case .proseSubjectBinding:  return "Attach facts from plain documents to the subject they name, so prose archives produce subject-scoped answers (not just source-scoped). Off keeps the current, more conservative behaviour."
        case .crossEncoderRerank:   return "Reorder retrieved passages with a cross-encoder so the most on-target passage leads. Reorder-only; never drops evidence."
        case .correctiveRetrieval:  return "When first-pass evidence is weak, re-retrieve once with expanded terms before answering or abstaining."
        case .hydeExpansion:        return "On a weak vector pass, expand the query with a hypothetical answer and fuse the results. Never shown or cited."
        case .boilerplateEmbedSkip: return "Skip embedding of learned, cross-document boilerplate templates. Still fully searchable; just down-ranked."
        case .passwordProtectedFiles: return "Open encrypted PDFs that use owner-only protection (empty user password); files that truly need a password are tracked as such instead of failing silently."
        case .importLifecycle:      return "Show one honest lifecycle state per source (queued / processing / searchable / partial / needs-password / couldn't-read / excluded) and disclose when results may omit a source."
        case .storyReviewerLoop:    return "Let you approve, correct, or reject individual beats of a reconstructed story; rejected beats drop and corrected beats are prioritized when the story is rebuilt."
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
             .correctiveRetrieval, .hydeExpansion, .summariesAtIdle, .historyAtIdle,
             .topicSeededComposers, .actorComposer, .progressiveStreaming,
             .eventSlotFill, .boilerplateEmbedSkip, .proseSubjectBinding,
             .passwordProtectedFiles, .importLifecycle, .storyReviewerLoop:
            return true
        }
    }

    /// Default state when the user has never toggled it. Implemented modules are
    /// ON by default (they ARE the current behaviour) — EXCEPT modules that change
    /// how the ledger scopes/derives, which default OFF so the old behaviour stands
    /// until the owner opts in.
    public var defaultEnabled: Bool {
        switch self {
        case .proseSubjectBinding:
            return false   // ledger-scoping change — opt-in, old behaviour is the default
        default:
            return implemented
        }
    }

    /// Grouping for the Settings list.
    public var group: String {
        switch self {
        case .topicMinimization, .autoTopics, .summariesAtIdle, .historyAtIdle,
             .eventSlotFill, .proseSubjectBinding:
            return "Knowledge synthesis"
        case .crossEncoderRerank, .correctiveRetrieval, .hydeExpansion, .boilerplateEmbedSkip,
             .passwordProtectedFiles, .importLifecycle:
            return "Retrieval"
        case .actorComposer, .progressiveStreaming, .topicSeededComposers, .storyReviewerLoop:
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
