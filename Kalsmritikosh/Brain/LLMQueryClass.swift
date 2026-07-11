//
//  LLMQueryClass.swift
//  Kalsmritikosh
//
//  The hard per-request LLM-call ceiling, keyed by a deterministic
//  classification of the user's question. Classification runs BEFORE the
//  first generative call (see LLMQueryClassifier) and the resulting
//  `callLimit` is loaded into an LLMCallBudget that every nested operation
//  belonging to that one user action shares.
//
//  This is the enforcement counterpart to the adaptive *policy* shipped in
//  9db3f8d/538db0f: the policy decides how much LLM an answer is worth; this
//  class caps how much it may ever spend, so no path (experts + synthesis +
//  council + chapters + fallback + investigation steps) can exceed the
//  documented budget.
//

import Foundation

public enum LLMQueryClass: String, Sendable, Codable, CaseIterable {
    /// Exact structured answer normal code can render — 0 calls.
    case deterministic
    /// One evidence-backed explanatory answer — 1 call.
    case ordinary
    /// One expert + at most one correction pass — 2 calls.
    case moderate
    /// Conflicts / ambiguity / causal / high-risk — ≤3 calls.
    case complex
    /// Normal history/timeline/project/relationship — ≤3 calls.
    case reconstruction
    /// Explicit full / thorough / in-depth reconstruction — ≤5 calls.
    case deepReconstruction
    /// Dedicated Investigation action / explicit "investigate" — ≤5 calls.
    case investigation
    /// Corpus lacks enough evidence — 0 calls (refuse deterministically).
    case unsupported

    /// The hard ceiling on generative LLM calls for one user request.
    public var callLimit: Int {
        switch self {
        case .deterministic:      return 0
        case .ordinary:           return 1
        case .moderate:           return 2
        case .complex:            return 3
        case .reconstruction:     return 3
        case .deepReconstruction: return 5
        case .investigation:      return 5
        case .unsupported:        return 0
        }
    }

    /// Whether an answer in this class must be corroborated by ≥2 distinct
    /// sources before it is trusted. Exact extraction (ordinary/moderate) is
    /// satisfied by a single authoritative source; disputed, causal,
    /// reconstructive, or investigative conclusions are not. (§8.4)
    public var requiresCorroboration: Bool {
        switch self {
        case .complex, .reconstruction, .deepReconstruction, .investigation:
            return true
        case .deterministic, .ordinary, .moderate, .unsupported:
            return false
        }
    }

    /// Maximum number of domain experts this class may fan out to. (§9)
    public var expertLimit: Int {
        switch self {
        case .deterministic, .unsupported, .reconstruction: return 0
        case .ordinary, .moderate:                          return 1
        case .complex, .deepReconstruction, .investigation: return 2
        }
    }
}
