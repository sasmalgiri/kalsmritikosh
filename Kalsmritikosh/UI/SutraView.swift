//
//  SutraView.swift
//  Kalsmritikosh
//
//  Read-only inspector for the Sūtra — the constitution the app runs on. Shows
//  the doctrine's phases grouped by tier, each with its method, the surface it
//  earns, its obligations, the decisions reserved for a human, and the
//  conclusions it must never assert; plus the standards of proof and report form.
//

import SwiftUI

public struct SutraView: View {
    private let disciplines = SutraCompiler.builtInDisciplines
    @State private var selectedID = "investigation"

    /// The SAME inspector renders a DIFFERENT discipline — proof that one engine
    /// serves many subjects, each authored as a Sūtra alone (roadmap step 5).
    private var sutra: Sutra {
        disciplines.first { $0.id == selectedID }?.sutra ?? SutraCompiler.shared()
    }

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                ForEach(PhaseTier.allCases, id: \.self) { tier in
                    let phases = sutra.phases(inTier: tier)
                    if !phases.isEmpty { tierSection(tier, phases) }
                }
                proofSection
            }
            .padding(24).frame(maxWidth: 940, alignment: .leading).frame(maxWidth: .infinity, alignment: .top)
        }
        .navigationTitle("Constitution")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("The constitution (Sūtra)", systemImage: "building.columns")
                .font(.largeTitle.weight(.bold))
            Text("The doctrine the app runs on — every phase, the tooling it earns, its obligations, the decisions reserved for a human, and the conclusions it must never assert. Write this once for a discipline and the app becomes its practice.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker("Discipline", selection: $selectedID) {
                ForEach(disciplines, id: \.id) { Text($0.label).tag($0.id) }
            }
            .pickerStyle(.segmented).frame(maxWidth: 520).labelsHidden()
            Text("One engine, many subjects — each discipline is authored as a Sūtra alone (no new screens). Switch and watch the same inspector render a different constitution; the clinical differential's analysis phase reuses the very same Competing-Hypotheses matrix.")
                .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                tag(sutra.title, "doc.text")
                tag("v\(sutra.version)", "number")
                tag(sutra.reliabilityScale, "gauge.with.dots.needle.33percent")
            }
            Text(sutra.provenance).font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func tierSection(_ tier: PhaseTier, _ phases: [SutraPhase]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: tierIcon(tier)).foregroundStyle(.tint)
                Text(tier.label).font(.title3.weight(.semibold))
                if tier.warrantsStudio {
                    Text("earns a studio").font(.caption2.weight(.semibold))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(.tint.opacity(0.15), in: Capsule()).foregroundStyle(.tint)
                }
            }
            ForEach(phases) { phase in phaseCard(phase) }
        }
    }

    private func phaseCard(_ p: SutraPhase) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(p.title).font(.callout.weight(.semibold))
                Spacer()
                if p.method != .none { tag(p.method.label, "function") }
                if let s = p.surface { tag(s, "arrow.up.forward.app") }
            }
            ForEach(p.obligations, id: \.self) { line("checkmark.circle.fill", .green, $0) }
            ForEach(p.humanDecisions, id: \.self) { line("person.crop.circle.badge.checkmark", .blue, "You decide: \($0)") }
            ForEach(p.prohibitedConclusions, id: \.self) { line("nosign", .orange, "Never: \($0)") }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
    }

    private var proofSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal").foregroundStyle(.tint)
                Text("Proof & report").font(.title3.weight(.semibold))
            }
            Text("Standards of proof").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(sutra.standardsOfProof, id: \.self) { line("scalemass", .secondary, $0.label) }
            Text("Report sections").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 6)
            ForEach(Array(sutra.reportSections.enumerated()), id: \.offset) { i, s in
                line("\(min(i + 1, 50)).circle", .secondary, s)
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
    }

    private func line(_ icon: String, _ tint: Color, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: icon).foregroundStyle(tint).font(.caption).frame(width: 16)
            Text(text).font(.caption).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func tag(_ text: String, _ icon: String) -> some View {
        Label(text, systemImage: icon).font(.caption2)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(.quaternary.opacity(0.5), in: Capsule())
    }
    private func tierIcon(_ t: PhaseTier) -> String {
        switch t {
        case .capture: return "tablecells"
        case .analyze: return "brain.head.profile"
        case .readDerive: return "doc.text.magnifyingglass"
        case .decideProduce: return "checkmark.seal"
        }
    }
}

#if DEBUG
#Preview("Constitution") { NavigationStack { SutraView() }.frame(width: 980, height: 760) }
#endif
