//
//  GuideView.swift
//  Kalsmritikosh
//
//  The "never lost" reference (mirrors ReCreateHistory's GuideScreen): what
//  each screen does, and the glossary of evidence statuses. Screen rows jump
//  to the screen; copy is shared from GuideContent.
//

import SwiftUI

public struct GuideView: View {
    let onNavigate: (Destination) -> Void

    public init(onNavigate: @escaping (Destination) -> Void) {
        self.onNavigate = onNavigate
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                screensSection
                glossarySection
                ForEach(GuideContent.termGroups, id: \.title) { group in
                    glossaryCard(title: group.title, icon: group.symbol, items: group.items)
                }
            }
            .padding(20)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Guide")
                .font(Theme.display(24, .bold))
                .foregroundStyle(Theme.brandGradient())
            Text("What every screen does, and the words the app uses for how well a fact is known. Kalsmritikosh answers only from the documents you add — nothing is invented.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .cardSurface(cornerRadius: 16, tint: Theme.brand)
    }

    private var screensSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("The screens", "square.grid.2x2")
            ForEach(GuideContent.screenGuides, id: \.title) { g in
                Button {
                    onNavigate(g.dest)
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: g.dest.icon)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .background(Theme.brandGradient(), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(g.title).font(.callout.weight(.semibold))
                            Text(g.body).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    }
                    .padding(12)
                    .cardSurface(cornerRadius: 12)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var glossarySection: some View {
        glossaryCard(title: "How facts are graded", icon: "checkmark.seal",
                     items: GuideContent.glossary)
    }

    /// One titled card of term → plain-meaning rows. Shared by the evidence-
    /// status glossary and every plain-language term group.
    private func glossaryCard(
        title: String,
        icon: String,
        items: [(term: String, definition: String)]
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(title, icon)
            ForEach(items, id: \.term) { item in
                HStack(alignment: .top, spacing: 12) {
                    Text(item.term)
                        .font(.caption.weight(.bold))
                        .frame(width: 96, alignment: .leading)
                        .foregroundStyle(Theme.brand)
                    Text(item.definition)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 6)
                Divider()
            }
        }
        .padding(14)
        .cardSurface(cornerRadius: 14)
    }

    private func sectionTitle(_ text: String, _ icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(Theme.brand)
            Text(text).font(.headline)
            Spacer()
        }
    }
}
