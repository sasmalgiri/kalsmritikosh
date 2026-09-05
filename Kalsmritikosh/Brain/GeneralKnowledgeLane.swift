//
//  GeneralKnowledgeLane.swift
//  Kalsmritikosh
//
//  GK (owner decision, pre-HOLD-2) — the SECOND LANE. Three classes of
//  question exist: answerable from the archive; about the archive's world
//  but not in it; pure trivia. The archive lane handles the first and runs
//  UNCHANGED and FIRST — its search, its receipt, its honest refusal. This
//  lane may then answer the other two, loudly marked as what it is.
//
//  THE SEPARATION LAWS (the moat, restated):
//    · the lane exists only in the Ask surface — it is NOT part of
//      VerifiedAnswer, so it can never enter the answer ledger, evidence
//      membership, citations, stories, conformance, memory, exports, or
//      the sealed determinism envelope. Exclusion is by CONSTRUCTION.
//    · its rendering ALWAYS leads with the banner — a grounded sentence and
//      an unsourced one never share a block, let alone a sentence.
//    · zero retrieval, one model call; FM unavailable → the honest
//      unavailability note, never a pretense.
//    · nothing unsourced ever wears the clothes of evidence.
//

import Foundation
import os

public enum GeneralKnowledgeLane {
    private static let logger = Logger(subsystem: "ecosanskritiinnovation.Kalsmritikosh", category: "brain")

    /// The banner, verbatim (registered in CLAIMS_APP.md — copy and registry
    /// move together).
    public static let banner =
        "Not from your documents — general knowledge from the on-device AI. It may be wrong; verify before relying on it. No sources."
    /// The deterministic-Mac note: a state, not an error.
    public static let unavailableNote =
        "General knowledge is unavailable on this Mac (the on-device AI is not available). Your documents were still searched — see above."

    /// The conversational-refusal marker (data): a "message to the app"
    /// refusal never triggers general knowledge.
    nonisolated static let conversationalMarker = "message to the app"

    /// PURE eligibility law: the lane may only follow an archive-lane
    /// REFUSAL (out-of-scope or can't-ground), never a grounded answer, a
    /// conflict listing, or a conversational refusal.
    public nonisolated static func eligible(refused: Bool, refusalReason: String?) -> Bool {
        guard refused else { return false }
        if let reason = refusalReason, reason.contains(conversationalMarker) { return false }
        return true
    }

    /// The rendered block: banner FIRST, always — the law a test pins.
    /// RS-U6 — the model stamp closes the block: this text is 100%
    /// AI-authored, so its receipt names the author.
    public nonisolated static func render(_ text: String) -> String {
        banner + "\n\n" + text + "\n\n(" + LegalNotice.modelStamp() + ")"
    }

    /// One bounded model call, zero retrieval. nil = FM unavailable or the
    /// generation failed — the caller shows the unavailability note (when
    /// the setting is on) or nothing.
    public static func answer(question: String, capabilities: CapabilityRegistry) async -> String? {
        let spec = CapabilitySpec.reasoning(contextTokens: 2_000, purpose: "general.knowledge")
        guard let provider = try? await capabilities.resolve(spec),
              await provider.isAvailable() else {
            logger.info("gk: unavailable (deterministic mode)")
            return nil
        }
        let prompt = """
        Answer this general-knowledge question briefly (2–4 sentences), from \
        your own knowledge. If you are not sure, say so plainly. Do not \
        pretend to cite documents — you have none.

        Question: \(question)
        """
        guard let text = try? await provider.generate(prompt: prompt, options: GenerationOptions()),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            logger.info("gk: generation failed — nothing shown")
            return nil
        }
        logger.info("gk: answered (one call, zero retrieval)")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
