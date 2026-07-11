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

    /// Base classification from intent + phrasing. `.deterministic` and
    /// `.unsupported` are applied later by MasterBrain from runtime signals.
    public static func classify(question: String, intent: UserIntent) -> LLMQueryClass {
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
