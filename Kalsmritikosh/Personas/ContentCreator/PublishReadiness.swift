//
//  PublishReadiness.swift
//  Kalsmritikosh
//
//  A publish-readiness checklist for independent creators. "Show your work"
//  means more than a draft: claims verified to a source, sources vetted,
//  conflicting accounts shown (not averaged), rights cleared, and material
//  connections disclosed. A free-text content log makes it easy to skip the
//  unglamorous last steps — the ones that get creators into trouble.
//
//  Pure reference value (no schema, no engine); the content & disclosure DataLab
//  template surfaces it so the pre-publish bar stays visible.
//

import Foundation

public nonisolated struct PublishCheck: Sendable, Identifiable, Equatable {
    public let id: String
    public let title: String
    public let detail: String
    public init(id: String, title: String, detail: String) {
        self.id = id; self.title = title; self.detail = detail
    }
}

public nonisolated enum PublishReadiness {

    public static let checks: [PublishCheck] = [
        .init(id: "claims", title: "Every claim checked to a source",
              detail: "Each factual claim is verified against evidence, not memory — publish it as fact only if it's cited."),
        .init(id: "sources", title: "Sources vetted",
              detail: "Each source's reliability and independence is assessed before you rely on it."),
        .init(id: "conflicts", title: "Conflicts shown, not averaged",
              detail: "Where accounts disagree, present both — don't split the difference into a false middle."),
        .init(id: "rights", title: "Rights & clearances secured",
              detail: "Clips, images, and quotes have their usage rights / clearances recorded."),
        .init(id: "disclosure", title: "Material connections disclosed",
              detail: "Sponsorships, affiliate links, gifts, and AI-generated material are disclosed (e.g. FTC guidance)."),
        .init(id: "corrections", title: "A corrections path",
              detail: "There's a way to correct the record after publication, and it's tracked to done.")
    ]

    /// One-line summary for a field's help / template note.
    public static var helpSummary: String {
        "Before publishing: " + checks.map(\.title).joined(separator: " · ") + "."
    }

    public static let disciplineNote =
        "Publish a claim as fact only when it's cited and checked; disclose material connections before it goes out."
}
