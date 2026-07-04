//
//  Narrative.swift
//  Kalsmritikosh
//
//  HISTORY Phase D.1 — value types the narrative composer pipeline
//  hands off between stages. The composer recreates the user's
//  history as a chronologically-ordered sequence of `Chapter`s, each
//  with prose grounded in cited evidence and per-sentence claim
//  citations the UI can click through.
//
//  Why a dedicated narrative shape rather than reusing VerifiedAnswer?
//    - VerifiedAnswer is a flat blob of body + citations. The
//      composer's contract is stronger: every sentence carries the
//      specific event/object IDs that grounded it, and contradictions
//      are surfaced rather than averaged away.
//    - The Phase E NarrativeView renders chapters as cards with
//      individual headings, timeframes, and per-claim citation pills.
//      Doing that off VerifiedAnswer.body would require regex-parsing
//      the rendered text.
//    - Streaming (Phase D.7) yields one chapter at a time. A flat
//      blob can't tell the UI which chapter just landed.
//
//  Quality-or-nothing: if a chapter has < 2 events with non-empty
//  narrative slots, the composer SKIPS it rather than padding with
//  thin prose. Empty narratives still ship — the brain surfaces
//  "I found events but not enough structured detail to narrate them"
//  rather than fabricating a story.
//

import Foundation

/// One chronological chapter of the reconstructed narrative. A
/// chapter spans a contiguous timeframe and groups the events the
/// composer considered together when generating prose.
public nonisolated struct NarrativeChapter: Sendable, Codable, Hashable {
    public let id: UUID
    /// Display heading (e.g. "March 2023 — Patent draft circulation").
    public let title: String
    /// Optional 1-line subtitle giving the topic anchor when the
    /// chapter was scoped to a B.2 community.
    public let subtitle: String?
    /// Chapter timeframe — earliest event date through latest.
    /// Encoded as separate `start` and `end` fields for SQLite/JSON
    /// round-trip cleanliness.
    public let timeframeStart: Date
    public let timeframeEnd: Date
    /// Chronologically-ordered events the chapter narrates.
    public let eventIDs: [Event.ID]
    /// Topic community anchoring the chapter (Phase B.2). nil for
    /// time-only chapters (e.g. an "Activity around early 2023" cut).
    public let topicCommunityID: UUID?
    /// The rendered chapter text. Empty when the composer ran but
    /// produced no usable prose (quality-or-nothing) — the brain
    /// surfaces the chapter as a heading + event list instead.
    public let prose: String
    /// Per-sentence evidence trail. The composer aligns each
    /// generated sentence with the event/object ids it drew from so
    /// the UI can pin citation pills next to each sentence.
    public let claimCitations: [NarrativeClaimCitation]
    /// Conflicts detected between the events fed to this chapter
    /// (e.g. two competing dates for the same fact, two contradictory
    /// status assertions). Phase D.5.
    public let contradictions: [VerifiedAnswer.Contradiction]
    /// HISTORY Phase G.5 — typed causal / temporal links between the
    /// events in this chapter. Surfaced in the composer's prose as
    /// inline "led to" / "enabled" / "followed" verbs, AND in the UI
    /// as a small badge surface ("3 causal links" + expandable list).
    /// Empty when the CausalDiscoverer hasn't proposed any link
    /// touching this chapter's events.
    public let causalLinks: [CausalLink]
    /// 0..1 composer-side confidence for the chapter. Drops when:
    ///   - the LLM refused / returned empty
    ///   - too few populated slots fed the LLM
    ///   - claim verification (D.4) dropped citations
    public let confidence: Double

    public init(
        id: UUID = UUID(),
        title: String,
        subtitle: String? = nil,
        timeframeStart: Date,
        timeframeEnd: Date,
        eventIDs: [Event.ID],
        topicCommunityID: UUID? = nil,
        prose: String,
        claimCitations: [NarrativeClaimCitation] = [],
        contradictions: [VerifiedAnswer.Contradiction] = [],
        causalLinks: [CausalLink] = [],
        confidence: Double
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.timeframeStart = timeframeStart
        self.timeframeEnd = timeframeEnd
        self.eventIDs = eventIDs
        self.topicCommunityID = topicCommunityID
        self.prose = prose
        self.claimCitations = claimCitations
        self.contradictions = contradictions
        self.causalLinks = causalLinks
        self.confidence = max(0.0, min(1.0, confidence))
    }
}

/// One sentence's evidence trail. The composer emits one per
/// sentence in the rendered prose. `sentenceIndex` is the
/// 0-based offset into the chapter's sentence stream when split
/// on terminal punctuation.
public nonisolated struct NarrativeClaimCitation: Sendable, Codable, Hashable {
    public let sentenceIndex: Int
    public let evidenceObjectIDs: [KnowledgeObject.ID]
    public let evidenceEventIDs: [Event.ID]
    /// 0..1 trust score for the citation. Computed from the source
    /// events' quality tier + dateConfidence + slot provenance mix.
    public let confidence: Double

    public init(
        sentenceIndex: Int,
        evidenceObjectIDs: [KnowledgeObject.ID],
        evidenceEventIDs: [Event.ID],
        confidence: Double
    ) {
        self.sentenceIndex = sentenceIndex
        self.evidenceObjectIDs = evidenceObjectIDs
        self.evidenceEventIDs = evidenceEventIDs
        self.confidence = max(0.0, min(1.0, confidence))
    }
}

/// Top-level result of a narrative reconstruction. The brain wraps
/// this in a VerifiedAnswer for legacy callers and also yields
/// individual chapters into the AnswerUpdate stream.
public nonisolated struct ReconstructedNarrative: Sendable, Codable {
    public let title: String
    /// 2-3 sentence overall summary (the chapter list's "back of the
    /// book" preview). Computed from the chapter subjects + the
    /// resolved scope, not regenerated per question.
    public let summary: String
    /// Resolved scope ("Project Delta", "Alice Wong", "all data").
    public let scope: NarrativeScope
    /// Chronologically-ordered chapters.
    public let chapters: [NarrativeChapter]
    /// Coverage diagnostics surfaced in the UI ("12 events across
    /// 6 chapters, Jan 2022 – Mar 2024, no gaps > 90 days").
    public let coverage: NarrativeCoverage
    /// Flattened union of all citations across all chapters. Kept
    /// here so legacy VerifiedAnswer callers (EvalKit, the old UI
    /// chat path) don't have to re-flatten on every read.
    public let citations: [VerifiedAnswer.Citation]
    /// Reasons the composer ran a downgraded path (no LLM available,
    /// too few slot-rich events, etc.). Empty list = clean run.
    public let downgrades: [String]

    public init(
        title: String,
        summary: String,
        scope: NarrativeScope,
        chapters: [NarrativeChapter],
        coverage: NarrativeCoverage,
        citations: [VerifiedAnswer.Citation],
        downgrades: [String] = []
    ) {
        self.title = title
        self.summary = summary
        self.scope = scope
        self.chapters = chapters
        self.coverage = coverage
        self.citations = citations
        self.downgrades = downgrades
    }
}

public nonisolated enum NarrativeScope: Codable, Sendable, Hashable {
    case global
    case project(String)
    case person(String)
    case organization(String)
    case folder(String)
    case topic(UUID, String)  // community id + display title
}

public nonisolated struct NarrativeCoverage: Sendable, Codable, Hashable {
    public let earliest: Date?
    public let latest: Date?
    public let totalEvents: Int
    public let chapterCount: Int
    /// Largest temporal gap (in days) between consecutive chapters.
    /// The UI badges narratives with > 90-day gaps so the user knows
    /// the story has cold patches.
    public let largestGapDays: Int

    public init(
        earliest: Date?,
        latest: Date?,
        totalEvents: Int,
        chapterCount: Int,
        largestGapDays: Int
    ) {
        self.earliest = earliest
        self.latest = latest
        self.totalEvents = totalEvents
        self.chapterCount = chapterCount
        self.largestGapDays = largestGapDays
    }
}

/// The shape every composer implementation honours. Implementations:
///   - `RuleBasedNarrativeComposer` (Phase D.8) — deterministic
///     fallback that runs without an LLM
///   - `LLMNarrativeComposer` (Phase D.3) — generates chapter prose
///     via the `.reasoning` capability
///
/// Composers MUST NOT cache between calls — they're stateless given
/// a UserIntent + retrieval set, mirroring the experts' contract.
public protocol NarrativeComposer: Sendable {
    func compose(
        intent: UserIntent,
        retrieval: RetrievalResult,
        eventSlots: [Event.ID: EventNarrativeSlots]
    ) async throws -> ReconstructedNarrative

    /// HISTORY Phase D.7 true-streaming variant. Yields each
    /// chapter as it finishes composing, then the final
    /// `ReconstructedNarrative` (with coverage + flattened
    /// citations) as the last event so the brain has both the
    /// streamed pieces AND a final fold for VerifiedAnswer.
    ///
    /// Default implementation calls `compose` and replays the
    /// chapter list — implementations override to gain real
    /// progressive delivery.
    nonisolated func composeStreaming(
        intent: UserIntent,
        retrieval: RetrievalResult,
        eventSlots: [Event.ID: EventNarrativeSlots]
    ) -> AsyncStream<NarrativeStreamEvent>
}

public extension NarrativeComposer {
    nonisolated func composeStreaming(
        intent: UserIntent,
        retrieval: RetrievalResult,
        eventSlots: [Event.ID: EventNarrativeSlots]
    ) -> AsyncStream<NarrativeStreamEvent> {
        AsyncStream { continuation in
            Task {
                do {
                    let narrative = try await compose(
                        intent: intent,
                        retrieval: retrieval,
                        eventSlots: eventSlots
                    )
                    for chapter in narrative.chapters {
                        continuation.yield(.chapter(chapter))
                    }
                    continuation.yield(.completed(narrative))
                } catch {
                    continuation.yield(.failed("\(error)"))
                }
                continuation.finish()
            }
        }
    }
}

/// One progressive event in the streaming composition pipeline.
public nonisolated enum NarrativeStreamEvent: Sendable {
    case chapter(NarrativeChapter)
    case completed(ReconstructedNarrative)
    case failed(String)
}
