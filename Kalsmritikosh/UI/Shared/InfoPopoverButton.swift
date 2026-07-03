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

import SwiftUI

public struct InfoPopoverButton: View {
    private let title: String
    private let message: String
    private let systemImage: String
    private let bullets: [String]

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
    }

    public var body: some View {
        Button {
            showing.toggle()
        } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(.secondary)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(title)   // hover tooltip as a bonus
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
            }
            .padding(18)
            .frame(width: 340)
        }
    }
}
