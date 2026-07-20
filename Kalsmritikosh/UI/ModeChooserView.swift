//
//  ModeChooserView.swift
//  Kalsmritikosh
//
//  First-run (and on-demand) chooser for the three system architectures.
//  On a fresh install this is shown BEFORE the engine boots, so the chosen
//  mode takes effect immediately. Re-openable later from the active-mode
//  badge in the sidebar; a post-boot change applies on the next launch.
//

import SwiftUI

public struct ModeChooserView: View {
    @Environment(AppState.self) private var appState

    /// First run: the user MUST pick (no cancel / no interactive dismiss).
    let mustChoose: Bool

    private let estimator = IngestEstimator()

    public init(mustChoose: Bool) { self.mustChoose = mustChoose }

    public var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header
                ForEach(SystemMode.allCases) { mode in
                    modeCard(mode)
                }
                if appState.modeAppliesNextLaunch {
                    Label("Changing the mode now applies on the next launch.", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
                if !mustChoose {
                    Button("Cancel") { appState.showModeChooser = false }
                        .buttonStyle(.borderless)
                        .padding(.top, 2)
                }
            }
            .padding(28)
            .frame(maxWidth: 600)
        }
        .frame(minWidth: 560, minHeight: 520)
        .background(AuroraBackdrop(intensity: 0.4))
        .interactiveDismissDisabled(mustChoose)
    }

    private var header: some View {
        VStack(spacing: 6) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(Theme.brandGradient())
            Text("How should Kalsmritikosh process your files?")
                .font(Theme.display(23, .bold))
                .foregroundStyle(Theme.brandGradient())
                .multilineTextAlignment(.center)
            Text("Pick an ingestion path. **Full LLM** (assertive) extracts the most meaning up front — richest ledger, slowest. **Ledger event-driven** (fast) runs rules + embeddings only and defers the LLM to question time. Each card shows how it behaves and roughly how long it takes per 100 MB. You can change this later in Settings.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func modeCard(_ mode: SystemMode) -> some View {
        let est = estimator.estimateMixed(sizeMB: 100, mode: mode)
        let isCurrent = FeatureFlags.shared.systemMode == mode
        return Button {
            appState.chooseMode(mode)
        } label: {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: mode.symbolName)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Theme.brand)
                    .frame(width: 46, height: 46)
                    .background(Theme.brand.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(mode.label)
                            .font(.headline)
                            .foregroundStyle(.primary)
                        if isCurrent {
                            Text("current")
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Theme.brand.opacity(0.15), in: .capsule)
                                .foregroundStyle(Theme.brand)
                        }
                    }
                    Text(mode.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("~\(IngestEstimator.humanDuration(est.totalSeconds)) / 100 MB · reference config")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(Theme.brandAlt)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface(cornerRadius: 14, tint: isCurrent ? Theme.brand : nil)
        }
        .buttonStyle(.plain)
    }
}
