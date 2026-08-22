//
//  GenealogicalProofStandard.swift
//  Kalsmritikosh
//
//  The five elements of the Genealogical Proof Standard (GPS) — the recognized
//  bar a genealogical conclusion must clear. A research log or proof argument
//  that doesn't name the elements makes it easy to stop short (a few records, no
//  conflict resolution, an unwritten conclusion).
//
//  Pure reference value (no schema, no engine); the genealogy research-log
//  DataLab template surfaces it so the standard is explicit while you work.
//

import Foundation

public nonisolated struct GPSElement: Sendable, Identifiable, Equatable {
    public let id: String
    public let number: Int
    public let title: String
    public let detail: String
    public init(id: String, number: Int, title: String, detail: String) {
        self.id = id; self.number = number; self.title = title; self.detail = detail
    }
}

public nonisolated enum GenealogicalProofStandard {

    public static let elements: [GPSElement] = [
        .init(id: "exhaustive", number: 1, title: "Reasonably exhaustive research",
              detail: "Search the sources that could answer the question — including negative (nil) results."),
        .init(id: "citations", number: 2, title: "Complete and accurate source citations",
              detail: "Every fact carries a citation that lets another researcher reopen the exact source."),
        .init(id: "analysis", number: 3, title: "Analysis and correlation of the evidence",
              detail: "Weigh each source (original vs derivative; primary vs secondary information) and correlate across records."),
        .init(id: "conflicts", number: 4, title: "Resolution of conflicting evidence",
              detail: "Where records disagree, resolve the conflict with reasoning — both are kept, never averaged away."),
        .init(id: "conclusion", number: 5, title: "A soundly reasoned, written conclusion",
              detail: "A coherent, cited proof argument states the conclusion and how the evidence supports it.")
    ]

    /// One-line summary for a field's help / template note.
    public static var helpSummary: String {
        "Genealogical Proof Standard: " + elements.map { "\($0.number). \($0.title)" }.joined(separator: " · ") + "."
    }

    public static let disciplineNote =
        "A conclusion meets the GPS only when all five elements are satisfied — a documented nil search counts toward the first."
}
