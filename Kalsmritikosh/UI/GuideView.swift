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
                walkthroughSection
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
            Text("What every screen does, and the words the app uses for how well a fact is known. Investigations Made Easy answers only from the documents you add — nothing is invented.")
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
                            .scaledFont(15, weight: .semibold, relativeTo: .body)
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

    /// U-3 — how to run each kind of investigation in the app, from the same templates a new case uses.
    private var walkthroughSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Running an investigation", "folder.badge.person.crop")
            Text("1. Cases → New case: record how it came in and pick the kind of investigation. 2. Triage it: rate it and accept, decline or refer. 3. Work the plan and the tasks; add sources and register exhibits. 4. Hold the interviews and record statements. 5. Link evidence to each allegation, then record your finding and why. 6. Close the case with your reasons. The app organises, finds and documents — the decisions are yours.")
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

#if DEBUG
#Preview("Guide") {
    GuideView(onNavigate: { _ in })
        .environment(AppState())
        .frame(width: 1040, height: 720)
}
#endif
