//
//  WorkplaceFairnessPrinciples.swift
//  Kalsmritikosh
//
//  The procedural-fairness (natural-justice) principles a workplace / compliance
//  investigation must satisfy to "stand up later". Findings can be correct on the
//  evidence and still be overturned if the PROCESS was unfair — the respondent
//  wasn't told the allegations, wasn't given a chance to respond, or the
//  decision-maker was biased. A free-text case file makes it easy to skip one.
//
//  Pure reference value (no schema, no engine); the allegation-matrix DataLab
//  template surfaces the checklist so fairness is deliberate and visible.
//

import Foundation

public nonisolated struct FairnessPrinciple: Sendable, Identifiable, Equatable {
    public let id: String
    public let title: String
    public let detail: String
    public init(id: String, title: String, detail: String) {
        self.id = id; self.title = title; self.detail = detail
    }
}

public nonisolated enum WorkplaceFairnessPrinciples {

    public static let principles: [FairnessPrinciple] = [
        .init(id: "notice", title: "Notice of the allegations",
              detail: "The respondent is told the specific allegations against them, in enough detail to respond."),
        .init(id: "respond", title: "A fair opportunity to respond",
              detail: "The respondent can answer the allegations and put forward their account and evidence before a finding."),
        .init(id: "impartial", title: "An impartial decision-maker",
              detail: "The investigator/decision-maker is unbiased and has no conflict of interest; apprehended bias is avoided."),
        .init(id: "evidence", title: "Decision on the evidence",
              detail: "The finding rests on the evidence gathered, weighed on the balance of probabilities — not assumption or reputation."),
        .init(id: "consistent", title: "Consistent, timely process",
              detail: "The process follows policy, treats like cases alike, and is conducted without undue delay."),
        .init(id: "confidential", title: "Confidentiality & support",
              detail: "Information is shared on a need-to-know basis; parties are told what support is available.")
    ]

    /// One-line checklist for a field's help / template note.
    public static var helpSummary: String {
        "Procedural fairness: " + principles.map(\.title).joined(separator: " · ") + "."
    }

    public static let disciplineNote =
        "A finding can be right on the evidence yet fail if the process was unfair — confirm each fairness step before you conclude."
}
