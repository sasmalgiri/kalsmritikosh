//
//  GuideView.swift
//  Kalsmritikosh
//
//  The searchable offline help (App Store completion instructions §6.5–§6.6): one search field over every
//  `HelpRegistry` topic, the Get started guide first, then tasks, the nine recipes by profession, the
//  screens (each row also jumps to its screen), the words the app uses, reading results carefully, the
//  subscription and troubleshooting. Help links (`SurfaceOpener.openHelp`) land on their topic. Replay the
//  introduction and the sample tutorial from here. Copy lives in HelpRegistry / GuideContent, never here.
//

import SwiftUI

public struct GuideView: View {
    let onNavigate: (Destination) -> Void
    @State private var query = ""
    @State private var expanded: Set<String> = ["get-started"]
    @State private var highlighted: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(onNavigate: @escaping (Destination) -> Void) {
        self.onNavigate = onNavigate
    }

    private var results: [HelpTopic] { HelpRegistry.search(query) }
    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    if searching {
                        searchResults
                    } else {
                        ForEach(HelpKind.allCases, id: \.self) { kind in
                            let topics = HelpRegistry.topics(of: kind)
                            if !topics.isEmpty { section(kind: kind, topics: topics) }
                        }
                        caseTemplates
                    }
                }
                .padding(20)
            }
            .onReceive(NotificationCenter.default.publisher(for: .kalsmritikoshOpenHelp)) { note in
                if let id = note.object as? String { show(id, proxy) }
            }
            // D-1: a link pressed on another screen arrives before the Guide exists; the pending topic is
            // consumed once the Guide is on screen.
            .onAppear { if let id = HelpNavigation.shared.pendingTopic { show(id, proxy) } }
            .onChange(of: HelpNavigation.shared.pendingTopic) { _, id in if let id { show(id, proxy) } }
        }
        .accessibilityIdentifier("help.guide")
    }

    /// Expand, highlight and scroll to a topic; clears the pending request.
    private func show(_ id: String, _ proxy: ScrollViewProxy) {
        guard HelpRegistry.topic(id) != nil else { HelpNavigation.shared.pendingTopic = nil; return }
        query = ""
        expanded.insert(id)
        highlighted = id
        HelpNavigation.shared.pendingTopic = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            if reduceMotion { proxy.scrollTo(id, anchor: .top) } else { withAnimation { proxy.scrollTo(id, anchor: .top) } }
        }
    }

    // MARK: - Header: title, search, replay

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Help")
                .font(Theme.display(24, .bold))
                .foregroundStyle(Theme.brandGradient())
            Text("Searchable, offline, and current with this version. Investigations Made Easy answers only from the documents you add; every claim carries a citation you can open — and a document can still be wrong, so the last check is yours.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search help — for example “export”, “refund”, “namesake”, “cancel trial”", text: $query)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("Search help")
                    .accessibilityIdentifier("help.search")
                if searching {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .accessibilityLabel("Clear search")
                }
            }
            .padding(10)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
            HStack(spacing: 12) {
                Button { HelpTutorial.replay() } label: { Label("Replay the tutorial (sample case)", systemImage: "graduationcap") }
                    .help("Opens the isolated sample case and walks the path from documents to an exported report. Your own documents are not touched.")
                    .accessibilityIdentifier("help.replayTutorial")
                Button { SurfaceOpener.replayOnboarding() } label: { Label("Replay the introduction", systemImage: "hand.wave") }
                    .help("Shows the first-run introduction again. It changes nothing unless you choose to.")
                    .accessibilityIdentifier("help.replayIntro")
                Link(destination: HelpLinks.support) { Label("Support", systemImage: "lifepreserver") }
                    .help("The support page: what to include in a report without sending any document.")
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .cardSurface(cornerRadius: 16, tint: Theme.brand)
    }

    // MARK: - Sections

    private var searchResults: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(results.isEmpty ? "No help topic matches “\(query)”" : "\(results.count) topic\(results.count == 1 ? "" : "s")", "text.magnifyingglass")
            if results.isEmpty {
                Text("Try another word, or the screen’s name. The support page explains how to ask for help without sending your documents.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(results) { topic in topicRow(topic, forceExpanded: true) }
        }
    }

    private func section(kind: HelpKind, topics: [HelpTopic]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(kind.title, kind.symbol)
            if kind == .persona {
                Text("Each recipe is derived from the jobs the profession ships with and their documentation: prerequisites, steps, the work product, what you review, and the professional limits.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(topics) { topic in topicRow(topic, forceExpanded: false) }
        }
    }

    @ViewBuilder
    private func topicRow(_ topic: HelpTopic, forceExpanded: Bool) -> some View {
        let isOpen = forceExpanded || expanded.contains(topic.id)
        VStack(alignment: .leading, spacing: 8) {
            Button {
                if expanded.contains(topic.id) { expanded.remove(topic.id) } else { expanded.insert(topic.id) }
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: topic.destination?.icon ?? topic.kind.symbol)
                        .scaledFont(15, weight: .semibold, relativeTo: .body)
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(Theme.brandGradient(), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(topic.title).font(.callout.weight(.semibold)).multilineTextAlignment(.leading)
                        Text(topic.summary).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: isOpen ? "chevron.down" : "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(topic.title)
            .accessibilityHint(isOpen ? "Collapse" : "Expand")
            .accessibilityAddTraits(isOpen ? [.isSelected] : [])

            if isOpen && (!topic.steps.isEmpty || !topic.notes.isEmpty || topic.destination != nil) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(topic.steps.enumerated()), id: \.offset) { i, step in
                        HStack(alignment: .top, spacing: 8) {
                            Text("\(i + 1).").font(.caption.weight(.bold)).foregroundStyle(Theme.brand).frame(width: 22, alignment: .trailing)
                            Text(step).font(.caption).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    ForEach(topic.notes, id: \.self) { note in
                        Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    if let dest = topic.destination {
                        Button { onNavigate(dest) } label: { Label("Open \(dest.title)", systemImage: "arrow.right.circle") }
                            .controlSize(.small)
                            .accessibilityIdentifier("help.open.\(dest.rawValue)")
                    }
                }
                .padding(.leading, 42)
            }
        }
        .padding(12)
        .cardSurface(cornerRadius: 12)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(highlighted == topic.id ? Theme.brand : .clear, lineWidth: 1.5))
        .id(topic.id)
        .accessibilityIdentifier("help.topic.\(topic.id)")
    }

    /// U-3 — how each kind of investigation is set up, from the same templates a new case uses.
    private var caseTemplates: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Case templates", "folder.badge.person.crop")
            Text("What a new case of each kind starts with: method, evidence to collect, interviews, usual tasks and retention. The app organises, finds and documents — the decisions are yours.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(CaseTemplate.all) { t in
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 6) {
                        if let m = t.plan.method { Text("How: \(m)") }
                        if let e = t.plan.evidenceToCollect { Text("Evidence: \(e)") }
                        if let i = t.plan.interviewsToHold { Text("Interviews: \(i)") }
                        Text("Usual tasks:").fontWeight(.semibold)
                        ForEach(t.tasks, id: \.title) { task in
                            Text("• \(task.title)" + (task.dueInDays.map { " — day \($0)" } ?? ""))
                        }
                        Text("Retention: \(t.retentionPolicy)").foregroundStyle(.secondary)
                    }
                    .font(.caption).fixedSize(horizontal: false, vertical: true).padding(.top, 4)
                } label: {
                    Text(t.title).font(.callout.weight(.semibold))
                }
                .padding(12)
                .cardSurface(cornerRadius: 12)
            }
            Button { onNavigate(.cases) } label: { Label("Open Cases", systemImage: "arrow.right.circle") }
        }
    }

    private func sectionTitle(_ text: String, _ icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(Theme.brand)
            Text(text).font(.headline)
            Spacer()
        }
        .accessibilityAddTraits(.isHeader)
    }
}

#if DEBUG
#Preview("Guide") {
    GuideView(onNavigate: { _ in })
        .environment(AppState())
        .frame(width: 1040, height: 720)
}
#endif
