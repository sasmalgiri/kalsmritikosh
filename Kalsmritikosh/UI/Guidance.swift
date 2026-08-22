//
//  Guidance.swift
//  Kalsmritikosh
//
//  A single, reusable way to explain any control. Attach `.guidance(_:enabled:)`
//  to a button or field and the user gets:
//    • a native hover tooltip (macOS shows these even on DISABLED controls), and
//    • a small ⓘ affordance that is ALWAYS clickable — even when the control it
//      describes is disabled — opening a short popover that says what the control
//      is and, when it's disabled, exactly what condition unlocks it.
//
//  This is the piece the app was missing: a disabled button can't be clicked, so
//  users never learned WHY it was off or what it does. The ⓘ closes that gap
//  without cluttering the UI — it stays hidden until you hover, and reveals
//  itself automatically whenever the control is disabled.
//

import SwiftUI

/// What a control is and when it can be used. Keep `what` to one plain sentence;
/// set `enabledWhen` to the human condition that turns the control on (nil if the
/// control is always available).
public struct GuidanceTip: Sendable, Equatable {
    public let title: String
    public let what: String
    public let enabledWhen: String?

    public init(_ title: String, what: String, enabledWhen: String? = nil) {
        self.title = title
        self.what = what
        self.enabledWhen = enabledWhen
    }

    /// One-line text for the native `.help()` tooltip. Includes the unlock
    /// condition when the control is currently disabled.
    func helpText(enabled: Bool) -> String {
        if !enabled, let cond = enabledWhen { return "\(title) — \(what)  •  Available when: \(cond)" }
        return "\(title) — \(what)"
    }
}

public extension View {
    /// Explain this control. `enabled` should mirror the same condition passed to
    /// `.disabled(...)` so the popover can show the unlock hint when it's off.
    func guidance(_ tip: GuidanceTip, enabled: Bool = true) -> some View {
        modifier(GuidanceModifier(tip: tip, enabled: enabled))
    }
}

private struct GuidanceModifier: ViewModifier {
    let tip: GuidanceTip
    let enabled: Bool

    @State private var hovering = false
    @State private var showPopover = false

    // Show the ⓘ on hover, and keep it visible whenever the control is disabled
    // (that's exactly when people most need to know why they can't proceed).
    private var badgeVisible: Bool { hovering || !enabled }

    func body(content: Content) -> some View {
        content
            .help(tip.helpText(enabled: enabled))
            .onHover { hovering = $0 }
            .overlay(alignment: .topTrailing) {
                Button {
                    showPopover.toggle()
                } label: {
                    Image(systemName: enabled ? "info.circle.fill" : "questionmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(enabled ? Color.accentColor : Color.orange)
                        .background(Circle().fill(.background))
                }
                .buttonStyle(.plain)
                .help("What is this?")
                .opacity(badgeVisible ? 1 : 0)
                .allowsHitTesting(badgeVisible)
                .offset(x: 7, y: -7)
                .popover(isPresented: $showPopover, arrowEdge: .top) {
                    GuidancePopover(tip: tip, enabled: enabled)
                }
                .accessibilityLabel("Help for \(tip.title)")
            }
    }
}

private struct GuidancePopover: View {
    let tip: GuidanceTip
    let enabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(tip.title).font(.headline)
            Text(tip.what)
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let cond = tip.enabledWhen {
                Divider()
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: enabled ? "checkmark.circle.fill" : "lock.circle.fill")
                        .foregroundStyle(enabled ? .green : .orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(enabled ? "Ready to use" : "Not available yet")
                            .font(.caption.weight(.semibold))
                        Text(enabled ? "This control is active." : "Available when: \(cond)")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 260, alignment: .leading)
    }
}
