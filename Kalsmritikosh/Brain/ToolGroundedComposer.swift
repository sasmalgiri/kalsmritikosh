//
//  ToolGroundedComposer.swift
//  Kalsmritikosh
//
//  A3 (closing spec) — TOOL-GROUNDED COMPOSITION, the middle floor:
//  deterministic composer → THIS → quote floor. The model receives ONLY
//  tool results (small, id-bearing) and must cite a result id on every
//  sentence; the DETERMINISTIC SWEEP then verifies each sentence against
//  exactly the result it cites — digits must come from the cited result
//  (or the question), proper nouns must appear there, uncited sentences
//  die. A composition that loses every sentence returns nil and the
//  ladder falls through. Constrained decoding (DynamicGenerationSchema)
//  is the T0 provider's job; in 1.1 THE SWEEP IS THE GATE (A5 decision).
//

import Foundation
import os

public struct ToolGroundedAnswer: Sendable {
    public let sentences: [(text: String, citedID: String)]
    public let citedObjectIDs: [UUID]
    public let receiptLines: [String]
}

public enum ToolGroundedComposer {
    private static let logger = Logger(subsystem: "ecosanskritiinnovation.Kalsmritikosh", category: "brain")

    /// The pure sweep — CI proves it. A sentence survives only when its
    /// cited id exists AND its digits ⊆ (cited text ∪ question) AND its
    /// capitalized words appear in the cited text or the question (or are
    /// plain connectives).
    public nonisolated static func sweep(
        candidate: String,
        question: String,
        results: [ToolResult]
    ) -> [(text: String, citedID: String)] {
        let byID = Dictionary(uniqueKeysWithValues: results.map { ($0.id, $0) })
        var kept: [(String, String)] = []
        // Sentences end with "[id]" — anything else is uncited and dies.
        let pieces = candidate.components(separatedBy: CharacterSet(charactersIn: ".\n"))
        for raw in pieces {
            let sentence = raw.trimmingCharacters(in: .whitespaces)
            guard sentence.count >= 8 else { continue }
            guard let open = sentence.lastIndex(of: "["),
                  let close = sentence.lastIndex(of: "]"), open < close else { continue }
            let id = String(sentence[sentence.index(after: open)..<close])
                .trimmingCharacters(in: .whitespaces)
            guard let result = byID[id] else { continue }
            let body = String(sentence[..<open]).trimmingCharacters(in: .whitespaces)
            guard !body.isEmpty else { continue }
            let truth = result.text + " " + question
            guard StoryProseRephraser.digitTokens(body)
                .isSubset(of: StoryProseRephraser.digitTokens(truth)) else { continue }
            // Proper nouns: reuse the grounding gate's noun law.
            let truthWords = Set(truth.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
            let nounsOK = body.components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.first?.isUppercase == true }
                .allSatisfy { truthWords.contains($0.lowercased())
                    || StoryProseRephraser.allowedLeads.contains($0.lowercased()) }
            guard nounsOK else { continue }
            kept.append((body + ".", id))
        }
        return kept
    }

    /// One model call over the gathered results. nil = FM unavailable,
    /// generation failed, or the sweep kept nothing — the ladder falls
    /// through, never a dead end.
    public static func compose(
        question: String,
        plan: QuestionPlan,
        results: [ToolResult],
        capabilities: CapabilityRegistry
    ) async -> ToolGroundedAnswer? {
        guard !results.isEmpty else { return nil }
        let spec = CapabilitySpec.reasoning(contextTokens: 3_000, purpose: "ledger.compose")
        guard let provider = try? await capabilities.resolve(spec),
              await provider.isAvailable() else {
            logger.info("ledger.compose: deterministic mode (FM unavailable)")
            return nil
        }
        let toolBlock = results.map { "[\($0.id)] \($0.text)" }.joined(separator: "\n")
        let prompt = """
        Answer the question using ONLY the numbered results below. Write 1–3 \
        short sentences. END every sentence with the id of the result it uses, \
        in brackets, like [T1]. Never state anything the results do not say; \
        if they do not answer it, write exactly: NOT ANSWERED.

        Question: \(question)

        Results:
        \(toolBlock)
        """
        guard let text = try? await provider.generate(prompt: prompt, options: GenerationOptions()),
              !text.contains("NOT ANSWERED") else {
            logger.info("ledger.compose: model abstained or failed")
            return nil
        }
        let kept = sweep(candidate: text, question: question, results: results)
        guard !kept.isEmpty else {
            logger.info("ledger.compose: SWEEP kept nothing — falling through")
            return nil
        }
        let byID = Dictionary(uniqueKeysWithValues: results.map { ($0.id, $0) })
        var seen = Set<UUID>()
        let objects = kept.flatMap { byID[$0.citedID]?.objectIDs ?? [] }.filter { seen.insert($0).inserted }
        let receipt = [
            "Plan: \(plan.shape)\(plan.field.map { " · field \($0)" } ?? "")\(plan.subjectMention.map { " · subject \($0)" } ?? "")",
            "Tools consulted: \(results.map(\.id).joined(separator: ", ")) — every sentence cites one and was checked against it.",
            LegalNotice.modelStamp(),
        ]
        return ToolGroundedAnswer(sentences: kept, citedObjectIDs: objects, receiptLines: receipt)
    }
}
