//
//  JournalisticVerification.swift
//  Kalsmritikosh
//
//  The verification steps a claim must clear before it's published as fact. A
//  claim tracker that lists sources but names no standard makes it easy to
//  publish on a single, unchallenged source. The discipline is the shared one —
//  a claim is a cited FACT or it isn't published as one — made explicit for the
//  journalist / content lens.
//
//  Pure reference value (no schema, no engine); the claim-tracker DataLab
//  template surfaces it so the bar stays visible.
//

import Foundation

public nonisolated struct VerificationStep: Sendable, Identifiable, Equatable {
    public let id: String
    public let title: String
    public let detail: String
    public init(id: String, title: String, detail: String) {
        self.id = id; self.title = title; self.detail = detail
    }
}

public nonisolated enum JournalisticVerification {

    public static let steps: [VerificationStep] = [
        .init(id: "corroborate", title: "Independent corroboration",
              detail: "A contested claim is supported by at least two genuinely independent sources — not the same source retold."),
        .init(id: "reliability", title: "Source reliability & motive",
              detail: "Each source's reliability, access, and possible motive to mislead is assessed."),
        .init(id: "provenance", title: "Document / media provenance",
              detail: "Documents, images, and clips are traced to their origin and checked for alteration."),
        .init(id: "reply", title: "Right of reply sought",
              detail: "The subject of a serious claim is given a fair opportunity to comment before publication."),
        .init(id: "label", title: "Verified vs alleged labelled",
              detail: "What's verified is stated as fact; what isn't is clearly framed as alleged or unconfirmed."),
        .init(id: "corrections", title: "A corrections path",
              detail: "There's a way to correct the record after publication, tracked to done.")
    ]

    /// One-line summary for a field's help / template note.
    public static var helpSummary: String {
        "Before publishing: " + steps.map(\.title).joined(separator: " · ") + "."
    }

    public static let disciplineNote =
        "A single source is a lead, not a fact — corroborate independently and seek comment before publishing a contested claim."
}
