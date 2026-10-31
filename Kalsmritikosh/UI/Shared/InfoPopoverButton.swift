//
//  InfoPopoverButton.swift
//  Kalsmritikosh
//
//  A compact "ⓘ" affordance that reveals a short what / why / how popover on
//  tap. Progressive disclosure: the header stays clean (just an icon), and
//  the detail appears only when the user asks for it — the lowest-footprint
//  way to make a screen self-explanatory. Reuse it in any header or next to
//  any control.
//
//  §6.8 — `InfoPopoverButton(topic:)` reads a `HelpRegistry` topic, so the same words appear here, in
//  the Guide and in the manual, and offers "Open in Help". Every information button carries a
//  meaningful accessible name ("Information about <title>"), not just "More information".
//

import SwiftUI

public struct InfoPopoverButton: View {
    private let title: String
    private let message: String
    private let systemImage: String
    private let bullets: [String]
    private let topicID: String?

    @State private var showing = false

    public init(
        title: String,
        message: String,
        systemImage: String = "sparkles",
        bullets: [String] = []
    ) {
        self.title = title
        self.message = message
        self.systemImage = systemImage
        self.bullets = bullets
        self.topicID = nil
    }

    /// The information for a registered help topic: its summary as the message, its steps as bullets,
    /// and a link into the Guide. An unknown id shows a plain "see Help" message rather than nothing.
    public init(topic id: String, systemImage: String = "info.circle") {
        let t = HelpRegistry.topic(id)
        self.title = t?.title ?? "Help"
        self.message = t?.summary ?? "Open Help for this topic."
        self.systemImage = systemImage
        self.bullets = Array((t?.steps ?? []).prefix(5))
        self.topicID = id
    }

    public var body: some View {
        Button {
            showing.toggle()
        } label: { Label("Information about \(title)", systemImage: "info.circle").labelStyle(.iconOnly)
                .scaledFont(15, weight: .regular, relativeTo: .body)
                .foregroundStyle(.secondary)
                .contentShape(Circle()) }
        .buttonStyle(.plain)
        .help(title)   // hover tooltip as a bonus
        .accessibilityLabel("Information about \(title)")
        .accessibilityHint("Shows what this does, what it needs and what follows")
        .accessibilityIdentifier(topicID.map { "info.\($0)" } ?? "info")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                Label(title, systemImage: systemImage)
                    .font(.headline)
                    .foregroundStyle(Theme.brand)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if !bullets.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(bullets, id: \.self) { line in
                            Label(line, systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .labelStyle(.titleAndIcon)
                        }
                    }
                }
                if let topicID {
                    Divider()
                    Button { showing = false; SurfaceOpener.openHelp(topicID) } label: { Label("Open in Help", systemImage: "book") }
                        .controlSize(.small)
                }
            }
            .padding(18)
            .frame(width: 360)
        }
    }
}
