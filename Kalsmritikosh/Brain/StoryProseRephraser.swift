//
//  StoryProseRephraser.swift
//  Kalsmritikosh
//
//  P4-U3 (GO 2 REVISED) — the optional prose layer OVER the deterministic
//  story renderer: it may REPHRASE a chapter's truth content, never extend
//  it. The renderer is extended, never paralleled — this consumes the
//  renderer's output and returns either grounded prose or nil.
//
//    · GROUNDING GATE (pure, CI-proven): the rephrased text must carry
//      EXACTLY the truth content's numbers and dates (none lost, none
//      invented) and may introduce no new proper nouns — connectives and
//      plain words only (the connective gate).
//    · FM unavailable or gate failed → nil; the caller keeps the
//      deterministic prose. Deterministic mode = identical truth content,
//      plainer prose — a STATE, not an error.
//

import Foundation
import os

public enum StoryProseRephraser {
    private static let logger = Logger(subsystem: "ecosanskritiinnovation.Kalsmritikosh", category: "brain")

    /// Connectives and plain sentence-lead words the gate always allows even
    /// when capitalized mid-prose. Data, not code.
    nonisolated static let allowedLeads: Set<String> = [
        "the", "a", "an", "in", "on", "at", "by", "then", "after", "later",
        "before", "during", "meanwhile", "next", "first", "finally", "it",
        "this", "that", "these", "those", "there", "and", "but", "also",
    ]

    /// The pure gate. `truth` is the deterministic gist + sentences the
    /// rephrase stood on.
    public nonisolated static func grounded(candidate: String, truth: String) -> Bool {
        // Numbers and dates: exact set equality — nothing lost, nothing invented.
        guard digitTokens(candidate) == digitTokens(truth) else { return false }
        // Proper nouns: every capitalized token must already appear in the
        // truth (case-insensitive) or be an allowed connective.
        let truthWords = Set(words(truth).map { $0.lowercased() })
        for word in words(candidate) where word.first?.isUppercase == true {
            let lower = word.lowercased()
            if !truthWords.contains(lower) && !allowedLeads.contains(lower) { return false }
        }
        return true
    }

    /// Rephrase one chapter's prose via the capability registry. Returns nil
    /// (deterministic mode) when FM is unavailable, generation fails, or the
    /// gate rejects — the caller keeps the renderer's prose unchanged.
    public static func rephrase(gist: String, sentences: String,
                                capabilities: CapabilityRegistry) async -> String? {
        let truth = gist + " " + sentences
        let spec = CapabilitySpec.reasoning(contextTokens: 2_000, purpose: "story.prose")
        guard let provider = try? await capabilities.resolve(spec),
              await provider.isAvailable() else {
            logger.info("story.prose: deterministic mode (FM unavailable)")
            return nil
        }
        let prompt = """
        You rewrite dated notes as one short flowing paragraph. Keep every \
        number and date EXACTLY as written. Do not add names, numbers, or facts.

        Notes:
        \(truth)
        """
        guard let candidate = try? await provider.generate(prompt: prompt, options: GenerationOptions()),
              !candidate.isEmpty else {
            logger.info("story.prose: deterministic mode (generation failed)")
            return nil
        }
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard grounded(candidate: trimmed, truth: truth) else {
            logger.info("story.prose: rephrase REJECTED by the grounding gate — deterministic prose kept")
            return nil
        }
        // RS-U6 — the stamp rides OUTSIDE the gated candidate (receipt, not
        // content): the prose passed the gate; the receipt names its author.
        return trimmed + "\n\n(" + LegalNotice.modelStamp() + ")"
    }

    // MARK: - token helpers (pure)

    nonisolated static func digitTokens(_ text: String) -> Set<String> {
        Set(text.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && $0.contains(where: \.isNumber) }
            .map { $0.lowercased() })
    }

    nonisolated private static func words(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }
}
