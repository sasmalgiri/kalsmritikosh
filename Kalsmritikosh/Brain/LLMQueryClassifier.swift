//
//  LLMQueryClassifier.swift
//  Kalsmritikosh
//
//  Deterministic, pure mapping from a user question + its detected intent to
//  an LLMQueryClass — and therefore to a hard call budget. Runs BEFORE the
//  first generative call (§5).
//
//  It produces a BASE class from intent + explicit-depth phrasing. Two classes
//  can only be decided later, from deterministic signals the classifier can't
//  see yet, and MasterBrain narrows to them at runtime:
//    - `.deterministic` — when a deterministic answerer can answer with
//      citations (§8.3), overriding to a 0-call budget.
//    - `.unsupported`   — when retrieval finds no groundable evidence (§8.4),
//      overriding to a 0-call refusal.
//

import Foundation

public enum LLMQueryClassifier {

    /// Phrases that promote a reconstruction to *deep* or trigger an
    /// investigation. Kept in sync with MasterBrain.escalationLevel and
    /// LLMNarrativeComposer.chapterBudget so the whole pipeline agrees on
    /// what "the user explicitly asked to go deep" means.
    static func isExplicitDeep(_ q: String) -> Bool {
        let s = q.lowercased()
        return s.contains("deep analysis") || s.contains("in depth") || s.contains("in-depth")
            || s.contains("thorough") || s.contains("deep dive") || s.contains("full reconstruction")
            || s.contains("alternative timeline") || s.contains("alternative reconstruction")
    }

    static func isExplicitInvestigation(_ q: String) -> Bool {
        let s = q.lowercased()
        return s.contains("investigate") || s.contains("investigation")
    }

    /// Whole-utterance conversational/meta detection (§8.4 `.unsupported`).
    /// CONSERVATIVE by design: only SHORT utterances that clearly address the
    /// app itself ("how are you online?", "hello", "who are you") — a longer
    /// archival question that merely contains one of these phrases is never
    /// matched. Found in v1.0-rc5 owner acceptance: such inputs were forced
    /// into `.ordinary`, retrieval keyword-matched unrelated ledger facts,
    /// and the engine shipped a low-confidence fact dump instead of the
    /// honest refusal the evidence contract requires.
    public static func isConversational(_ question: String) -> Bool {
        let normalized = question.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "?!.,;:"))
        guard !normalized.isEmpty, normalized.count <= 48 else { return false }
        let exact: Set<String> = [
            "hi", "hello", "hey", "yo", "ok", "okay", "test", "testing", "help",
            "thanks", "thank you", "good morning", "good afternoon", "good evening",
            "who are you", "what are you", "what can you do", "how do you work",
            "are you there", "are you ok", "are you okay",
        ]
        if exact.contains(normalized) { return true }
        // Short utterances OPENING with a to-the-app phrase, with at most a
        // few trailing characters ("how are you online?", "hi there!").
        let prefixes = ["how are you", "are you online", "are you there",
                        "hello there", "hi there"]
        for p in prefixes where normalized.hasPrefix(p) && normalized.count <= p.count + 12 {
            return true
        }
        return false
    }

    /// Base classification from intent + phrasing. `.deterministic` and
    /// `.unsupported` are applied later by MasterBrain from runtime signals.
    public static func classify(question: String, intent: UserIntent) -> LLMQueryClass {
        if isConversational(question) {
            return .unsupported
        }
        if isExplicitInvestigation(question) {
            return .investigation
        }
        switch intent.kind {
        case .reconstructTimeline, .reconstructProject, .reconstructRelationship:
            return isExplicitDeep(question) ? .deepReconstruction : .reconstruction
        case .riskDetection, .missingInformation:
            return .complex
        case .executiveBriefing:
            return .moderate
        case .factualLookup, .semanticSearch, .unknown:
            return .ordinary
        }
    }
}
