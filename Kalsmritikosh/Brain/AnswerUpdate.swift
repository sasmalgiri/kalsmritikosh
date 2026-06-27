//
//  AnswerUpdate.swift
//  Kalsmritikosh
//
//  G2-PROGRESSIVE — the streaming update event the brain emits as the
//  pipeline phases complete. Defined here so callers (AskView, future
//  TTFVC eval column) can subscribe without depending on each phase
//  being implemented yet.
//
//  Trust contract (UPDATE — GATE2_ROADMAP G2-PROGRESSIVE):
//  Every Phase 1..3 emission MUST surface a visible "verifying / synthesizing
//  / reading sources" tag in the UI. The user must never mistake a Phase 1
//  preview for a verified answer. Phase 4 is the only "answer is locked".
//

import Foundation

/// Streaming brain update. Phases yield in order — when a phase is
/// not yet implemented or doesn't apply (e.g. no cached memory for
/// Phase 1), it is simply omitted from the stream. Phase 4 (verified)
/// is the only guaranteed terminal event for a non-refused answer.
public enum AnswerUpdate: Sendable {
    /// Phase 1 — instant cached read (< 500 ms target). The body and
    /// citations come from the MemoryObject for the resolved subject,
    /// IF the subject and a confident-enough cached narrative exist.
    /// UI MUST surface this with a "🕒 Quick read · verifying…" tag.
    case instant(body: String, citations: [VerifiedAnswer.Citation])

    /// Phase 2 — streaming synthesis tokens (2-5 s typical). Each
    /// event carries one token / sentence delta. UI appends in place;
    /// shows "✎ Synthesizing…" with blinking cursor.
    case synthesisToken(String)

    /// Phase 3 — incremental expert findings (5-30 s). One event per
    /// expert as it produces findings. UI grows the citation list and
    /// the body. Tag: "🔍 Reading sources… N citations".
    case expertFindingsArrived(ExpertFindings)

    /// HISTORY Phase D.7 — one narrative chapter just landed from the
    /// composer. The UI renders the chapter's title + subtitle
    /// immediately and streams its prose into a card. Tag: "📖
    /// Composing chapter N…". Emitted ONLY for reconstructive
    /// intents (.reconstructTimeline / .reconstructProject /
    /// .reconstructRelationship); flat factual questions never see it.
    case chapterReady(NarrativeChapter)

    /// Phase 4 — locked, verified answer (30-60 s typical). This is
    /// the SAME value the legacy `MasterBrain.answer(question:)`
    /// returns; the legacy method is now a thin wrapper that collects
    /// this from the stream. UI swaps in the Quality Strip; tag goes
    /// away.
    case verified(VerifiedAnswer)
}
