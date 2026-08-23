//
//  EvidentiaryStandard.swift
//  Kalsmritikosh
//
//  INV-19 gap fix — the standard of proof a set of findings is declared to meet.
//  Findings must never be approved without one: an approver who cannot name the
//  threshold they applied has not made the professional judgment the report
//  implies. This is a pure value; the findings service stamps the chosen
//  standard into the recorded approval rationale so every approval states, on
//  its face, the evidentiary bar it was tested against.
//

import Foundation

public nonisolated enum EvidentiaryStandard: String, Codable, Sendable, CaseIterable, Equatable {
    case balanceOfProbabilities
    case preponderance
    case clearAndConvincing
    case beyondReasonableDoubt
    case reasonableGrounds
    case probableCause

    public var label: String {
        switch self {
        case .balanceOfProbabilities: return "Balance of probabilities"
        case .preponderance:          return "Preponderance of the evidence"
        case .clearAndConvincing:     return "Clear and convincing evidence"
        case .beyondReasonableDoubt:  return "Beyond reasonable doubt"
        case .reasonableGrounds:      return "Reasonable grounds to suspect"
        case .probableCause:          return "Probable cause"
        }
    }

    /// A one-line gloss so a non-specialist knows what each bar means.
    public var detail: String {
        switch self {
        case .balanceOfProbabilities: return "More likely than not (>50%). Common civil / workplace standard (UK/Commonwealth)."
        case .preponderance:          return "More likely than not. Common civil standard (US)."
        case .clearAndConvincing:     return "Substantially more likely than not — a heightened civil standard."
        case .beyondReasonableDoubt:  return "No reasonable doubt remains — the criminal standard."
        case .reasonableGrounds:      return "Objective grounds to suspect — an investigative threshold, not a finding of fact."
        case .probableCause:          return "A reasonable basis to believe — an arrest / search threshold."
        }
    }

    /// Stamped into the recorded approval rationale (report == receipt), so the
    /// approval names the threshold applied. Kept stable — it is matched in tests.
    public var rationaleLine: String { "Standard of proof applied: \(label)." }
}
