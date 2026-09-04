//
//  ComposeTwin.swift
//  Kalsmritikosh
//
//  P3-U4 part 2 (GO 2 REVISED + owner guardrails) — the COMPOSE TWIN: an
//  independent AI reading of the SAME evidence, compared against the shipped
//  answer. The owner's fence, verbatim in code:
//
//    · POST-HOC and NON-BLOCKING — the answer has already shipped; the twin
//      never delays, changes, or competes with it
//    · EXCLUDED from sealed envelopes — it never touches answer text,
//      citations, confidence, or evidence membership (parity is safe by
//      construction)
//    · Q0 and refusals never invoke it; FM-unavailable SKIPS with an honest
//      receipt note (deterministic mode is a state)
//    · agreement → the "independent AI reading agreed" badge signal;
//      disagreement → a VERIFY-FLAG, never a competing answer
//
//  The comparator is pure and deterministic (CI-proves it); only the runner
//  touches the model.
//

import Foundation
import os

public enum TwinVerdict: Sendable, Equatable {
    case agreed
    case disagreed(detail: String)
    case skipped(reason: String)

    /// The quality-strip line, plain language (RC-8).
    public var stripLine: String {
        switch self {
        case .agreed:                return "Independent AI reading agreed."
        case .disagreed(let d):      return "Worth a second look: an independent AI reading differed (\(d))."
        case .skipped(let reason):   return "Independent AI check not run (\(reason))."
        }
    }
}

public enum ComposeTwinComparator {

    /// Compare the shipped answer against the twin's independent reading on
    /// the VALUES that matter: numbers, dates-as-written, and yes/no polarity.
    /// Prose wording differences are noise; a value difference is the signal.
    public nonisolated static func compare(primary: String, twin: String) -> TwinVerdict {
        let pValues = values(of: primary)
        let tValues = values(of: twin)

        // Yes/no polarity: if the primary asserts one, the twin must not
        // assert the opposite.
        if let pPol = polarity(of: primary), let tPol = polarity(of: twin), pPol != tPol {
            return .disagreed(detail: "the readings disagree on yes versus no")
        }
        // Every value the primary asserts should appear in the twin's reading.
        let missing = pValues.subtracting(tValues)
        if !missing.isEmpty && !tValues.isEmpty {
            let shown = missing.sorted().prefix(3).joined(separator: ", ")
            return .disagreed(detail: "the value\(missing.count > 1 ? "s" : "") \(shown) did not appear in the second reading")
        }
        return .agreed
    }

    /// Digit-bearing tokens ≥2 chars — the numbers and dates an answer stands on.
    nonisolated static func values(of text: String) -> Set<String> {
        Set(text.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 && $0.contains(where: \.isNumber) }
            .map { $0.lowercased() })
    }

    nonisolated static func polarity(of text: String) -> Bool? {
        let t = text.lowercased().trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("yes") { return true }
        if t.hasPrefix("no ") || t.hasPrefix("no —") || t.hasPrefix("no,") || t.hasPrefix("no record") { return false }
        return nil
    }
}

/// The post-hoc runner. Fired AFTER an answer ships; its only outputs are a
/// log line, a counter, and the advisory verdict for the quality strip.
public struct ComposeTwinRunner: Sendable {
    private static let logger = Logger(subsystem: "ecosanskritiinnovation.Kalsmritikosh", category: "brain")

    /// Independent reading via the capability registry (never a model name).
    /// `snippets` are the same evidence excerpts the answer stood on.
    public static func run(
        question: String,
        shippedAnswer: String,
        snippets: [String],
        capabilities: CapabilityRegistry
    ) async -> TwinVerdict {
        guard !snippets.isEmpty else {
            return .skipped(reason: "no evidence excerpts to re-read")
        }
        let spec = CapabilitySpec.reasoning(contextTokens: 2_000, purpose: "twin.compose")
        guard let provider = try? await capabilities.resolve(spec),
              await provider.isAvailable() else {
            let verdict = TwinVerdict.skipped(reason: "on-device AI unavailable on this Mac")
            logger.info("twin.compose: skipped — FM unavailable")
            return verdict
        }
        let evidence = snippets.prefix(6).enumerated()
            .map { "[\($0.offset + 1)] \($0.element.prefix(400))" }
            .joined(separator: "\n")
        let prompt = """
        Answer the question strictly and only from these excerpts. One or two \
        sentences. If the excerpts do not answer it, say "No answer in the excerpts."

        Question: \(question)

        Excerpts:
        \(evidence)
        """
        let full = "You answer only from the provided excerpts. Never use outside knowledge.\n\n" + prompt
        guard let reading = try? await provider.generate(prompt: full, options: GenerationOptions()),
              !reading.isEmpty else {
            logger.info("twin.compose: skipped — the independent reading failed")
            return .skipped(reason: "the independent reading did not complete")
        }
        let verdict = ComposeTwinComparator.compare(primary: shippedAnswer, twin: reading)
        switch verdict {
        case .agreed:
            logger.info("twin.compose: AGREED")
        case .disagreed(let d):
            logger.info("twin.compose: DISAGREED — \(d, privacy: .public)")
        case .skipped:
            break
        }
        return verdict
    }
}
