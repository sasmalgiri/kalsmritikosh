//
//  FindingClassification.swift
//  Kalsmritikosh
//
//  The recognized way a workplace / compliance investigation classifies each
//  allegation's finding. A free-text "finding" or a bare yes/no invites
//  imprecise language; the standard vocabulary (substantiated · partially ·
//  unsubstantiated · inconclusive) makes the outcome — and its reasoning —
//  unambiguous, on the balance of probabilities.
//
//  Load-bearing discipline: "unsubstantiated" means the EVIDENCE didn't meet the
//  bar — never that the complainant was dishonest.
//
//  Pure reference value; the allegation-matrix DataLab template surfaces it.
//

import Foundation

public nonisolated enum FindingClassification: String, Codable, Sendable, CaseIterable, Equatable {
    case substantiated
    case partiallySubstantiated
    case unsubstantiated
    case inconclusive

    public var label: String {
        switch self {
        case .substantiated: return "Substantiated"
        case .partiallySubstantiated: return "Partially substantiated"
        case .unsubstantiated: return "Unsubstantiated"
        case .inconclusive: return "Inconclusive"
        }
    }
    public var detail: String {
        switch self {
        case .substantiated:
            return "The evidence is strong enough to conclude, on the balance of probabilities, that the conduct occurred."
        case .partiallySubstantiated:
            return "Some elements of the allegation are made out on the evidence; others are not."
        case .unsubstantiated:
            return "There is insufficient evidence to prove or disprove the allegation — not a finding that the complainant was dishonest."
        case .inconclusive:
            return "It was not possible to determine what happened — typically credible but conflicting accounts with no corroboration."
        }
    }
}

public nonisolated enum FindingClassifications {
    public static let all = FindingClassification.allCases

    public static var helpSummary: String {
        "Classify each: " + all.map(\.label).joined(separator: " · ") + "."
    }

    public static let disciplineNote =
        "State each finding on the balance of probabilities with plain reasoning (\u{201C}because X, supported by Y\u{201D}). \u{201C}Unsubstantiated\u{201D} means the evidence didn\u{2019}t meet the bar — not that the complainant lied."
}
