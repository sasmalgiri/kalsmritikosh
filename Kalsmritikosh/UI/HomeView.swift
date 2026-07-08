//
//  HomeView.swift
//  Kalsmritikosh
//
//  The landing surface (mirrors ReCreateHistory's HomeScreen): a hero, an
//  "add documents" call-to-action, and the 5 persona cards — each a use-case
//  lens with example questions and the screens that matter most for it.
//

import SwiftUI

public struct HomeView: View {
    @Environment(AppState.self) private var appState
    /// Drives the RootView router so persona links jump to a screen.
    let onNavigate: (Destination) -> Void

    public init(onNavigate: @escaping (Destination) -> Void) {
        self.onNavigate = onNavigate
    }

    private let columns = [GridItem(.adaptive(minimum: 300), spacing: 16)]

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                hero
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(GuideContent.personas) { personaCard($0) }
                }
            }
            .padding(20)
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Theme.brandGradient(), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Kalsmritikosh")
                        .font(Theme.display(26, .bold))
                        .foregroundStyle(Theme.brandGradient())
                    Text("Reconstruct history from your documents — cited, evidence-gated answers.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 10) {
                Button {
                    onNavigate(.sources)
                } label: {
                    Label("Add your documents", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.brand)

                Button {
                    onNavigate(.ask)
                } label: {
                    Label("Ask a question", systemImage: "bubble.left.and.text.bubble.right")
                }
                .buttonStyle(.bordered)

                Button {
                    onNavigate(.guide)
                } label: {
                    Label("Full guide", systemImage: "book")
                }
                .buttonStyle(.borderless)
            }
            Text("Pick the lens that fits your work — every path answers only from what you ingest.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .cardSurface(cornerRadius: 16, tint: Theme.brand)
    }

    private func personaCard(_ p: GuidePersona) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text(p.emoji).font(.system(size: 26))
                Text(p.title).font(.title3.weight(.semibold))
            }
            Text(p.tagline)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Example questions — click to open Ask.
            VStack(alignment: .leading, spacing: 6) {
                Text("TRY ASKING")
                    .font(.system(size: 9, weight: .heavy)).tracking(0.5)
                    .foregroundStyle(.tertiary)
                ForEach(p.examples.prefix(3), id: \.self) { q in
                    Button {
                        appState.pendingAskQuestion = q
                        onNavigate(.ask)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.turn.down.right").font(.caption2).foregroundStyle(Theme.brand)
                            Text(q).font(.caption).foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider()

            // Key screens for this persona.
            VStack(alignment: .leading, spacing: 6) {
                ForEach(p.keyScreens, id: \.label) { screen in
                    Button {
                        onNavigate(screen.dest)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: screen.dest.icon)
                                .font(.caption).foregroundStyle(Theme.brand)
                                .frame(width: 18)
                            Text(screen.label).font(.caption.weight(.medium))
                            Text("· \(screen.why)").font(.caption2).foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: 14)
    }
}
