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
    /// Chosen persona (shared with the sidebar). Empty → show the chooser.
    @AppStorage("kalsmritikosh.persona") private var personaID: String = ""
    /// Filters the persona's work cards.
    @State private var workSearch: String = ""
    /// Data-grounded suggestions derived from the user's own ledger.
    @State private var suggestions: [SuggestedQuestion] = []

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                hero
                if personaID.isEmpty {
                    // No focus chosen yet — offer the persona lenses to pick from.
                    Text("Pick the lens that fits your work.")
                        .font(.caption).foregroundStyle(.secondary)
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(GuideContent.personas) { personaCard($0) }
                    }
                } else {
                    workbench
                }
            }
            .padding(20)
        }
        .task(id: personaID) {
            guard !personaID.isEmpty else { suggestions = []; return }
            suggestions = await appState.suggestedQuestions(for: personaID)
        }
    }

    // MARK: - Persona workbench (task cards for the chosen persona)

    private var workbench: some View {
        let works = PersonaWorkCatalog.works(for: personaID)
        let q = workSearch.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = q.isEmpty ? works : works.filter { $0.searchText.contains(q) }
        return VStack(alignment: .leading, spacing: 14) {
            if !suggestions.isEmpty {
                archiveSuggestions
            }
            HStack(spacing: 8) {
                Text("Your tasks").font(.title3.bold())
                Spacer()
            }
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search your tasks…", text: $workSearch)
                    .textFieldStyle(.plain)
                if !workSearch.isEmpty {
                    Button { workSearch = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color.primary.opacity(0.05), in: Capsule())
            .overlay(Capsule().stroke(Theme.brand.opacity(0.15), lineWidth: 1))

            if filtered.isEmpty {
                Text("No matching task. Try the sidebar, or clear the search.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 30)
            } else {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(filtered) { workCard($0) }
                }
            }
        }
    }

    /// "Questions from your archive" — grounded in the user's own ledger, tap to ask.
    private var archiveSuggestions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles.rectangle.stack")
                    .font(.caption).foregroundStyle(Theme.brand)
                Text("Questions from your archive")
                    .font(.subheadline.weight(.semibold))
            }
            Text("Grounded in what your documents actually contain — tap to ask.")
                .font(.caption2).foregroundStyle(.secondary)
            ForEach(suggestions) { s in
                Button {
                    appState.pendingAskQuestion = s.text
                    onNavigate(.ask)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.turn.down.right")
                            .font(.caption2).foregroundStyle(Theme.brand)
                        Text(s.text).font(.callout).foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 6).padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: 14, tint: Theme.brand)
    }

    private func workCard(_ w: PersonaWork) -> some View {
        Button { run(w) } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: w.icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(Theme.brandGradient(), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.forward.circle.fill")
                        .foregroundStyle(Theme.brand.opacity(0.5))
                }
                Text(w.title).font(.headline).multilineTextAlignment(.leading)
                Text(w.subtitle).font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 128, alignment: .topLeading)
            .cardSurface(cornerRadius: 14)
        }
        .buttonStyle(.plain)
    }

    private func run(_ w: PersonaWork) {
        switch w.action {
        case .open(let dest):
            onNavigate(dest)
        case .ask(let question):
            appState.pendingAskQuestion = question
            onNavigate(.ask)
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
                    Text("Your documents, worked by the professional's own SOP — cited, evidence-gated, to the real deliverable.")
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
            Divider()
            // The four promises — each one answers the loudest complaint
            // users voice about the incumbent tools (subscription shock,
            // cloud exposure, export lock-in, weeks-long learning curves).
            HStack(alignment: .top, spacing: 16) {
                promise("lock.shield", "100% on your Mac",
                        "Nothing ever leaves this computer — no cloud, no account, works offline forever.")
                promise("creditcard", "Yours once",
                        "One purchase. No subscription, no per-page fees, no surprise renewal.")
                promise("square.and.arrow.up", "No lock-in",
                        "Export everything — Word, Excel, PDF, CSV — any time. Your data stays yours.")
                promise("checkmark.seal", "Answers you can check",
                        "Every answer cites the exact document behind it — click and see the source.")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .cardSurface(cornerRadius: 16, tint: Theme.brand)
    }

    private func promise(_ icon: String, _ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.semibold))
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func personaCard(_ p: GuidePersona) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Tap the header to make this your focus (drives the workbench + the
            // "For you" sidebar). Was display-only before.
            Button {
                withAnimation(Theme.springFast) { personaID = p.id }
            } label: {
                HStack(spacing: 10) {
                    Text(p.emoji).font(.system(size: 26))
                    Text(p.title).font(.title3.weight(.semibold))
                    Spacer(minLength: 0)
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(Theme.brand)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Focus the app on this role")
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

            Divider()

            // Primary action — the clear way to pick this persona.
            Button {
                withAnimation(Theme.springFast) { personaID = p.id }
            } label: {
                Label("Choose this focus", systemImage: "checkmark.seal")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.brand)
            .controlSize(.small)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: 14)
    }
}
