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
    case aiSubjectResolution    // M2 — AI clusters same-subject document copies into one topic
    case topicProsePolish       // M3 — AI smooths each topic spine into prose (fact-preserving)
    // (L6 document-class labelling is shipped core — always on, migration v123 —
    //  so it is not an optional module here.)
    // Retrieval
    case crossEncoderRerank     // R2 — cross-encoder rerank on the answer path
    case correctiveRetrieval    // R3 — re-retrieve on weak evidence
    case hydeExpansion          // R4 — hypothetical-answer query expansion
    case boilerplateEmbedSkip   // I1 — skip learned boilerplate templates at embed time
    case passwordProtectedFiles // A4 — open encrypted files (empty-password unlock; classify the rest)
    case importLifecycle        // A2 — unified per-source lifecycle state + omission disclosure
    case mediaTranscription     // M — transcribe audio/video on-device (Apple Speech)
    // Answer composition
    case aiComposeEveryAnswer   // compose EVERY grounded answer with the model (not just escalated)
    case storyReviewerLoop      // Lane C — record approve/correct/reject verdicts on story items
    case actorComposer          // A1 — dedicated "who did X" actor answer door
    case progressiveStreaming   // A2 — stream instant→synthesis→verified to the UI
    case topicSeededComposers   // A3 — seed the matched topic into the model composers
    // Ingest integrity (v3 plan, Phase 1). Each new unit ships behind its own
    // switch so it can be turned off in isolation if it misbehaves, rather than
    // requiring a revert. NOTE what is deliberately NOT switchable: the
    // entity-insert CASCADE fix. Both states of `strictDerivation` are
    // non-corrupting — it chooses HOW to degrade, never whether to corrupt.
    case recordDerivationFailures // P1.2 — persist WHY a tolerated write failed
    case strictDerivation         // P1.1 — abort the KO vs skip only dependent stages
    case derivationCompleteMarker // P1.3 — mark a KO's derivation complete/resumable
    // Extraction (v3 plan, Phase 2)
    case poaGrantorRecovery       // P2.7 — store a lowercase POA grantor via the formula
    case documentLevelFTS         // P2.2 — whole-document FTS fallback (cross-chunk phrases)
    // Universality (v3 plan, Phase 3)
    case openFieldExtraction      // P3.1 — `Label: value` facts from ANY domain
    case openFieldAsking          // P3.4 — resolve a question against the ledger's real fields
    case openFactTypes            // P3.2 — derive a type id for documents outside the curated enum
    case historyChapterReadback   // P2.1/P2.5 — read chapters + persist alternative accounts

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .topicMinimization:    return "Topic minimization"
        case .autoTopics:           return "Auto-build topics"
        case .summariesAtIdle:      return "Summaries at idle"
        case .historyAtIdle:        return "History at idle"
        case .eventSlotFill:        return "Event detail fill (5W+H)"
        case .proseSubjectBinding:  return "Plain-document subject binding"
        case .aiSubjectResolution:  return "AI subject resolution (merge duplicate topics)"
        case .topicProsePolish:     return "AI topic prose"
        case .crossEncoderRerank:   return "Cross-encoder reranking"
        case .correctiveRetrieval:  return "Corrective re-retrieval"
        case .hydeExpansion:        return "Hypothetical query expansion"
        case .boilerplateEmbedSkip: return "Boilerplate embed-skip"
        case .passwordProtectedFiles: return "Password-protected files"
        case .importLifecycle:      return "Import & coverage lifecycle"
        case .mediaTranscription:   return "Transcribe audio & video"
        case .aiComposeEveryAnswer: return "AI writes every answer"
        case .storyReviewerLoop:    return "Story review (approve / correct / reject)"
        case .actorComposer:        return "Actor answers (who did X)"
        case .progressiveStreaming: return "Progressive answer streaming"
        case .topicSeededComposers: return "Topic-first composition"
        case .recordDerivationFailures: return "Record why an import step failed"
        case .strictDerivation:     return "Strict derivation (stop on a failed step)"
        case .derivationCompleteMarker: return "Track unfinished imports"
        case .poaGrantorRecovery:   return "Read names from authorisation forms"
        case .documentLevelFTS:     return "Whole-document keyword search"
        case .openFieldExtraction:  return "Read labelled fields from any document"
        case .openFieldAsking:      return "Ask about any field we found"
        case .openFactTypes:        return "Group unfamiliar document kinds"
        case .historyChapterReadback: return "Story chapters & recorded disagreements"
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
        case .aiSubjectResolution:  return "Before topics are built, the on-device model groups labels that name the same real-world subject (e.g. several copies of one résumé) into a single topic — but only merges when the two share enough evidence terms. Turns document-shaped topics into real-world-subject topics."
        case .topicProsePolish:     return "Smooth each topic's fact spine into 2–4 sentences of connected prose with the on-device model, under a fact-preserving guard (never adds/removes a name, number, or date). Off leaves the plain fact list."
        case .crossEncoderRerank:   return "Reorder retrieved passages with a cross-encoder so the most on-target passage leads. Reorder-only; never drops evidence."
        case .correctiveRetrieval:  return "When first-pass evidence is weak, re-retrieve once with expanded terms before answering or abstaining."
        case .hydeExpansion:        return "On a weak vector pass, expand the query with a hypothetical answer and fuse the results. Never shown or cited."
        case .boilerplateEmbedSkip: return "Skip embedding of learned, cross-document boilerplate templates. Still fully searchable; just down-ranked."
        case .passwordProtectedFiles: return "Open encrypted PDFs that use owner-only protection (empty user password); files that truly need a password are tracked as such instead of failing silently."
        case .mediaTranscription:   return "Read speech in recordings and videos using Apple's on-device speech model, so a recording becomes quotable evidence with timecodes (\u{201C}the call at 12:04\u{201D}). Nothing leaves your Mac. On by default. Transcription is slow and the first run asks permission and installs Apple's speech model; turn it OFF for faster ingest — audio/video are still kept and searchable by name and date either way. Takes effect on next app launch, for newly-ingested files."
        case .importLifecycle:      return "Show one honest lifecycle state per source (queued / processing / searchable / partial / needs-password / couldn't-read / excluded) and disclose when results may omit a source."
        case .aiComposeEveryAnswer: return "When the on-device model is available, compose every grounded answer as fluent prose (not just complex ones). Grounding is preserved — the model rewrites over the verified evidence and citations; if no model is available it falls back to the exact deterministic answer."
        case .storyReviewerLoop:    return "Let you approve, correct, or reject individual beats of a reconstructed story; rejected beats drop and corrected beats are prioritized when the story is rebuilt."
        case .actorComposer:        return "Route who-did-this questions to the passage naming the acting party and compose a grounded answer."
        case .progressiveStreaming: return "Render the answer as it forms — instant context, then synthesis, then the verified result."
        case .topicSeededComposers: return "Give the model composer the matched topic first, so answers lead with the topic rather than raw facts."
        case .recordDerivationFailures: return "When a step of an import fails in a way that can be tolerated — an embedding, one file inside a zip, an email attachment — record WHY, so a gap in your library can be explained instead of just being smaller than expected. Off reverts to a log line only, and the import report loses its reasons."
        case .strictDerivation:     return "If a file's people-and-organisations step fails, stop processing that file rather than continuing with the steps that depend on it. Off still never produces wrong data — it skips only the dependent step (events) and keeps the text, chunks and facts, so you get a partial file instead of none. Either way nothing incorrect is stored."
        case .derivationCompleteMarker: return "Mark each file as fully processed only when every step finished, so an import interrupted by a crash or shutdown can be spotted and finished later. Without it, a half-processed file looks identical to a fully-processed one that simply had little in it."
        case .openFactTypes:        return "Group documents of a kind the app does not have a built-in name for. A vehicle service record, a shipping manifest and a school report are none of the eleven built-in kinds, so today each is filed as \u{201C}unclassified\u{201D} and the health panel counts it as a problem. With this on, such a document is grouped by the fields it actually contains, so two service records from different garages land together — without the app inventing a name it cannot justify. Needs \u{201C}Read labelled fields from any document\u{201D}."
        case .openFieldAsking:      return "Let a question reach any field found in your documents, not just the ones built in. Ask \u{201C}what is the chassis number\u{201D} and it resolves against the fields actually present in your library — no synonym list to maintain. It can only match a field that genuinely exists, so the worst case is the same honest \u{201C}not found\u{201D} you get today. Pairs with \u{201C}Read labelled fields from any document\u{201D}: extraction without this fills a library you cannot question."
        case .openFieldExtraction:  return "Pull facts out of any document that states them as a label and a value — \u{201C}Policy Number: 4471-99812\u{201D}, \u{201C}Registration No: MH-12-AB-1234\u{201D}, \u{201C}Roll No: 21BCE1043\u{201D} — no matter what kind of document it is. Until now facts came only from eleven built-in document types (patents, invoices, contracts, medical, property and so on), so a shipping manifest, a car service record or a school report produced searchable text but no structured facts. Fields the built-in types already handle are left to them, so nothing about those changes. Off keeps the built-in types only."
        case .documentLevelFTS:     return "Also search each document's full text, not only its individual passages. A phrase whose words fall either side of a passage boundary — a name, an address, a clause — can never match the passage index, because no single passage contains all of it. Runs only when the passage search finds nothing, so precise passage hits still lead."
        case .historyChapterReadback: return "Read back the chapter structure of a reconstructed story, and keep a record of disagreements found between sources so the same contradiction is not rediscovered on every rebuild. Off falls back to an unchaptered list and forgets disagreements between builds."
        case .poaGrantorRecovery:   return "Read the person's name out of a power-of-attorney or authorisation form even when the form is typed in lower case (\u{201C}I, jane doe having\u{201D}). Restricted to that exact document phrasing, so ordinary sentences that begin with \u{201C}I\u{201D} are never mistaken for a name. Off keeps the stricter rule, which needs the name capitalised."
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
             .passwordProtectedFiles, .importLifecycle, .storyReviewerLoop,
             .aiComposeEveryAnswer, .aiSubjectResolution, .topicProsePolish,
             .mediaTranscription,
             .recordDerivationFailures, .strictDerivation, .derivationCompleteMarker,
             .poaGrantorRecovery, .documentLevelFTS, .historyChapterReadback,
             .openFieldExtraction, .openFieldAsking, .openFactTypes:
            return true
        }
    }

    /// Default state when the user has never toggled it. Implemented modules are
    /// ON by default (they ARE the current behaviour) — EXCEPT modules that change
    /// how the ledger scopes/derives, which default OFF so the old behaviour stands
    /// until the owner opts in.
    public var defaultEnabled: Bool {
        switch self {
        case .proseSubjectBinding, .aiSubjectResolution:
            return false   // ledger-scoping change — opt-in, old behaviour is the default
        case .openFieldExtraction, .openFieldAsking, .openFactTypes:
            // Defaults ON: this is the product's central promise, and a
            // universality feature nobody switches on is a universality
            // feature nobody has. It is safe to default on because it only
            // ADDS fields the eleven packs do not own — see
            // OpenFieldExtractor.reservedFields — so existing extraction is
            // byte-identical either way.
            return true
        default:
            return implemented
        }
    }

    /// Grouping for the Settings list.
    public var group: String {
        switch self {
        case .topicMinimization, .autoTopics, .summariesAtIdle, .historyAtIdle,
             .eventSlotFill, .proseSubjectBinding, .aiSubjectResolution, .topicProsePolish:
            return "Knowledge synthesis"
        case .crossEncoderRerank, .correctiveRetrieval, .hydeExpansion, .boilerplateEmbedSkip,
             .passwordProtectedFiles, .importLifecycle, .mediaTranscription:
            return "Retrieval"
        case .actorComposer, .progressiveStreaming, .topicSeededComposers, .storyReviewerLoop,
             .aiComposeEveryAnswer:
            return "Answer composition"
        case .recordDerivationFailures, .strictDerivation, .derivationCompleteMarker:
            return "Import integrity"
        case .poaGrantorRecovery, .documentLevelFTS, .historyChapterReadback:
            return "Extraction & search"
        case .openFieldExtraction, .openFieldAsking, .openFactTypes:
            return "Universality"
        }
    }

    /// Whether this module CALLS the on-device generative model. AI modules are
    /// force-disabled under the Fully-private AI regime (the capability registry
    /// refuses every generative spec there, so they can only no-op). Deterministic
    /// modules — even ML ones like the CoreML cross-encoder — are NOT listed here.
    public var requiresAI: Bool {
        switch self {
        case .aiSubjectResolution, .topicProsePolish, .aiComposeEveryAnswer,
             .eventSlotFill, .hydeExpansion, .topicSeededComposers:
            return true
        default:
            return false
        }
    }

    /// Prerequisite modules that must be EFFECTIVELY enabled for this one to do
    /// anything. The topic-refinement steps all run inside the topic build, which
    /// `.autoTopics` drives — turning off Auto-build topics leaves them nothing to
    /// act on, so they depend on it. (Kept minimal + true: the codebase's modules
    /// are otherwise independent by design.)
    public var dependsOn: [KnowledgeModule] {
        switch self {
        case .topicMinimization, .aiSubjectResolution, .topicProsePolish, .topicSeededComposers:
            return [.autoTopics]
        case .openFactTypes:
            // A derived type id is a fingerprint of the document's DISCOVERED
            // fields, so without the extractor there are no fields to
            // fingerprint and this can only ever decline.
            return [.openFieldExtraction]
        case .openFieldAsking:
            // Asking about discovered fields is meaningless without the
            // extractor that discovers them — the inventory would only ever
            // contain the eleven packs' own fields, which the curated
            // vocabulary already covers.
            return [.openFieldExtraction]
        default:
            return []
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
        // Regime gate — an AI module is dead under Fully-private (no model to call).
        if m.requiresAI, !FeatureFlags.aiRegimeValue().allowsAI { return false }
        // Dependency gate — each prerequisite must be EFFECTIVELY enabled (recursive).
        for dep in m.dependsOn where !isEnabled(dep) { return false }
        // Stored preference, else the code default.
        let d = UserDefaults.standard
        if d.object(forKey: m.storageKey) == nil { return m.defaultEnabled }
        return d.bool(forKey: m.storageKey)
    }

    /// Why a module can't run under the current regime / prerequisites, for the
    /// Settings UI to grey it out and explain, or nil when it is freely togglable.
    /// The stored preference is NEVER erased — flip back to a permissive regime or
    /// re-enable the prerequisite and the module returns to the user's own choice.
    public nonisolated static func disabledReason(_ m: KnowledgeModule) -> String? {
        guard m.implemented else { return "Not available in this build" }
        if m.requiresAI, !FeatureFlags.aiRegimeValue().allowsAI {
            return "Needs AI — choose “AI · evidence-gated” or “AI · free” above"
        }
        for dep in m.dependsOn where !isEnabled(dep) {
            return "Requires “\(dep.title)”"
        }
        return nil
    }

    public nonisolated static func setEnabled(_ m: KnowledgeModule, _ on: Bool) {
        UserDefaults.standard.set(on, forKey: m.storageKey)
    }

    /// The persisted key, for SwiftUI bindings that need it.
    public nonisolated static func storageKey(_ m: KnowledgeModule) -> String { m.storageKey }
}
