//
//  InsightsView.swift
//  Kalsmritikosh
//
//  The flagship System-3 surface. Two rule-based, LLM-free lenses on
//  the ledger:
//
//  1. Missing links (gaps) — the rule-based gap scanner flags events
//     that look incomplete: a start with no end, a promise with no
//     follow-through, a reference to a document that never landed. Each
//     GapNode carries its own reason and a likelihood.
//  2. Investigation — pick any event and interrogate it structurally.
//     Fishbone groups the event's contributing causes by category;
//     5-Whys walks the causal chain backward one relation at a time.
//
//  Everything here reads through appState and renders straight from the
//  structured store — no model is ever consulted.
//

import SwiftUI

public struct InsightsView: View {
    @Environment(AppState.self) private var appState

    // Gaps
    @State private var gaps: [GapNode] = []
    @State private var gapCount: Int = 0
    @State private var scanning = false
    @State private var loadingGaps = false

    // Contradictions
    @State private var contradictions: [Contradiction] = []

    // Investigation
    @State private var events: [Event] = []
    @State private var selectedEvent: Event?
    @State private var fishbone: Fishbone?
    @State private var whys: FiveWhysResult?
    @State private var investigating = false

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                gapsSection
                contradictionsSection
                investigationSection
            }
            .padding(24)
        }
        .background(AuroraBackdrop(intensity: 0.5))
        .task {
            await reloadGaps()
            await reloadContradictions()
            await loadEvents()
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Insights")
                    .font(Theme.display(34, .bold))
                    .foregroundStyle(Theme.brandGradient())
                InfoPopoverButton(
                    title: "What Insights finds",
                    message: "Rule-based analysis over your ledger — no LLM. Surfaces likely-missing documents and facts your sources disagree on, and lets you interrogate any event.",
                    systemImage: "lightbulb.max",
                    bullets: [
                        "Gaps: numbered-sequence holes, dangling references, orphaned replies",
                        "Contradictions: the same fact stated differently by two sources",
                        "Fishbone & 5-Whys: trace an event's causes"
                    ]
                )
            }
            Text("Missing links and rule-based investigation — no LLM, all from your ledger.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let last = appState.ledgerLastMaintainedAt {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(Theme.brand)
                        .imageScale(.small)
                    Text("Ledger auto-maintained · \(appState.proactiveGapCount) gaps · \(last.formatted(date: .omitted, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Theme.brand.opacity(0.10), in: Capsule())
                .overlay(Capsule().stroke(Theme.brand.opacity(0.25), lineWidth: 1))
            }
        }
    }

    // MARK: - Gaps

    private var gapsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Likely missing (gaps)")
                        .font(.title3.weight(.semibold))
                    HStack(spacing: 6) {
                        CountUpText(gapCount)
                            .font(Theme.display(20, .bold))
                            .foregroundStyle(Theme.brand)
                        Text(gapCount == 1 ? "gap" : "gaps")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                scanButton
            }

            if gaps.isEmpty {
                emptyGaps
            } else {
                VStack(spacing: 10) {
                    ForEach(gaps) { gap in
                        gapRow(gap)
                            .transition(.popIn)
                    }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(tint: Theme.brand)
    }

    private var scanButton: some View {
        Button {
            runScan()
        } label: {
            HStack(spacing: 6) {
                if scanning {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "sparkle.magnifyingglass")
                }
                Text(scanning ? "Scanning…" : "Scan")
            }
        }
        .buttonStyle(.borderedProminent)
        .tint(Theme.brand)
        .disabled(scanning)
    }

    private var emptyGaps: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.seal")
                .foregroundStyle(.secondary)
            Text("No gaps detected yet — tap Scan.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func gapRow(_ gap: GapNode) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: gap.kind.systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.brand)
                .frame(width: 34, height: 34)
                .background(Theme.brand.opacity(0.12), in: .rect(cornerRadius: 9))

            VStack(alignment: .leading, spacing: 4) {
                Text(gap.kind.displayName.uppercased())
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Theme.brand)
                Text(gap.description)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
                Text(gap.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 8) {
                confidencePill(gap.confidence)
                Button("Dismiss") { dismiss(gap) }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
        }
        .padding(12)
        .cardSurface(cornerRadius: 12)
    }

    private func confidencePill(_ confidence: Double) -> some View {
        Text("~\(Int(confidence * 100))% likely")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Theme.brand.opacity(0.14), in: .capsule)
            .foregroundStyle(Theme.brand)
    }

    // MARK: - Contradictions

    private var contradictionsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Contradictions")
                        .font(.title3.weight(.semibold))
                    HStack(spacing: 6) {
                        CountUpText(contradictions.count)
                            .font(Theme.display(20, .bold))
                            .foregroundStyle(Theme.brandAlt)
                        Text(contradictions.count == 1 ? "conflict" : "conflicts")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }

            if contradictions.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.seal")
                        .foregroundStyle(.secondary)
                    Text("No conflicting claims found — tap Scan above.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
            } else {
                VStack(spacing: 10) {
                    ForEach(contradictions) { c in
                        contradictionRow(c)
                            .transition(.popIn)
                    }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(tint: Theme.brandAlt)
    }

    @ViewBuilder
    private func contradictionRow(_ c: Contradiction) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.brandAlt)
                .frame(width: 34, height: 34)
                .background(Theme.brandAlt.opacity(0.12), in: .rect(cornerRadius: 9))

            VStack(alignment: .leading, spacing: 6) {
                Text(c.description)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                // Both sides, never averaged away.
                claimLine("A", c.claimA)
                claimLine("B", c.claimB)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 8) {
                severityPill(c.severity)
                Button("Dismiss") { setStatus(c, .dismissed) }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
        }
        .padding(12)
        .cardSurface(cornerRadius: 12)
    }

    private func claimLine(_ tag: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(tag)
                .font(.caption2.weight(.bold))
                .foregroundStyle(Theme.brandAlt)
                .frame(width: 14, alignment: .leading)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func severityPill(_ s: Contradiction.Severity) -> some View {
        let color: Color = s == .high ? .red : (s == .medium ? .orange : .secondary)
        return Text(s.displayName)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.14), in: .capsule)
            .foregroundStyle(color)
    }

    // MARK: - Investigation

    private var investigationSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Investigate an event")
                .font(.title3.weight(.semibold))

            eventPicker

            HStack(spacing: 10) {
                Button {
                    runFishbone()
                } label: {
                    Label("Fishbone", systemImage: "fish")
                }
                .buttonStyle(.bordered)
                .tint(Theme.brand)

                Button {
                    runFiveWhys()
                } label: {
                    Label("5 Whys", systemImage: "arrow.turn.down.right")
                }
                .buttonStyle(.bordered)
                .tint(Theme.brandAlt)

                if investigating {
                    ProgressView().controlSize(.small)
                }
                Spacer()
            }
            .disabled(selectedEvent == nil || investigating)

            if let fishbone {
                fishboneView(fishbone)
                    .transition(.popIn)
            }
            if let whys {
                fiveWhysView(whys)
                    .transition(.popIn)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(tint: Theme.brandAlt)
    }

    private var eventPicker: some View {
        Menu {
            if events.isEmpty {
                Text("No events available")
            }
            ForEach(events) { event in
                Button {
                    select(event)
                } label: {
                    Text("\(event.title) · \(shortDate(event.date))")
                }
            }
        } label: {
            HStack {
                Image(systemName: "calendar")
                    .foregroundStyle(Theme.brand)
                if let selectedEvent {
                    Text(selectedEvent.title)
                        .lineLimit(1)
                    Text(shortDate(selectedEvent.date))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Choose an event…")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .cardSurface(cornerRadius: 10)
        }
        .menuStyle(.borderlessButton)
    }

    // MARK: Fishbone rendering

    @ViewBuilder
    private func fishboneView(_ fb: Fishbone) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "target")
                    .foregroundStyle(Theme.brand)
                Text(fb.effect.title)
                    .font(.headline)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.brand.opacity(0.10), in: .rect(cornerRadius: 10))

            if fb.bones.isEmpty {
                Text("No contributing causes found.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(fb.bones) { bone in
                    boneCard(bone)
                }
            }
        }
    }

    @ViewBuilder
    private func boneCard(_ bone: FishboneBone) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(bone.category.uppercased())
                .font(.caption.weight(.bold))
                .foregroundStyle(Theme.brand)
            ForEach(bone.causes) { cause in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.top, 3)
                    Text("\(cause.relation.renderVerb): \(cause.event.title)")
                        .font(.callout)
                    Spacer(minLength: 4)
                    Text("\(Int(cause.confidence * 100))%")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: 12)
    }

    // MARK: 5-Whys rendering

    @ViewBuilder
    private func fiveWhysView(_ result: FiveWhysResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "questionmark.circle")
                    .foregroundStyle(Theme.brandAlt)
                Text(result.effect.title)
                    .font(.headline)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.brandAlt.opacity(0.10), in: .rect(cornerRadius: 10))

            if result.chain.isEmpty {
                Text("No causal chain found.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(result.chain) { step in
                    whyStepRow(step)
                }
            }
        }
    }

    @ViewBuilder
    private func whyStepRow(_ step: WhyStep) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("Why #\(step.depth)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Theme.brandAlt)
                Text("\(Int(step.confidence * 100))%")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
            Text(step.question)
                .font(.callout.weight(.medium))
            HStack(spacing: 4) {
                Image(systemName: "arrow.turn.down.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("\(step.relation.renderVerb): \(step.cause.title)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: 12)
        // Indent deepens with each step for a connected, cascading feel.
        .padding(.leading, CGFloat(step.depth - 1) * 18)
    }

    // MARK: - Data / actions

    private func reloadGaps() async {
        loadingGaps = true
        defer { loadingGaps = false }
        let loaded = await appState.gapNodes?.all() ?? []
        let count = await appState.gapNodes?.count() ?? loaded.count
        withAnimation(Theme.springSoft) {
            gaps = loaded
            gapCount = count
        }
    }

    private func runScan() {
        scanning = true
        Task {
            _ = await appState.scanForGaps()
            _ = await appState.scanForContradictions()
            await reloadGaps()
            await reloadContradictions()
            scanning = false
        }
    }

    private func reloadContradictions() async {
        let loaded = await appState.contradictions?.open() ?? []
        withAnimation(Theme.springSoft) {
            contradictions = loaded
        }
    }

    private func setStatus(_ c: Contradiction, _ status: Contradiction.Status) {
        Task {
            await appState.contradictions?.setStatus(c.id, status)
            withAnimation(Theme.springSoft) {
                contradictions.removeAll { $0.id == c.id }
            }
        }
    }

    private func dismiss(_ gap: GapNode) {
        Task {
            await appState.gapNodes?.dismiss(gap.id)
            withAnimation(Theme.springSoft) {
                gaps.removeAll { $0.id == gap.id }
                gapCount = max(0, gapCount - 1)
            }
        }
    }

    private func loadEvents() async {
        let loaded = (try? await appState.events?.recent(limit: 100)) ?? []
        events = loaded
        if selectedEvent == nil { selectedEvent = loaded.first }
    }

    private func select(_ event: Event) {
        selectedEvent = event
        // A new subject invalidates any prior investigation output.
        withAnimation(Theme.springSoft) {
            fishbone = nil
            whys = nil
        }
    }

    private func runFishbone() {
        guard let event = selectedEvent else { return }
        investigating = true
        Task {
            let result = await appState.fishbone(forEventID: event.id)
            withAnimation(Theme.springSoft) {
                fishbone = result
                whys = nil
            }
            investigating = false
        }
    }

    private func runFiveWhys() {
        guard let event = selectedEvent else { return }
        investigating = true
        Task {
            let result = await appState.fiveWhys(forEventID: event.id)
            withAnimation(Theme.springSoft) {
                whys = result
                fishbone = nil
            }
            investigating = false
        }
    }

    private func shortDate(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .omitted)
    }
}
