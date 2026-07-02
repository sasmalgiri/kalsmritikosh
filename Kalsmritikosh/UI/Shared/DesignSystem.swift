//
//  DesignSystem.swift
//  Kalsmritikosh
//
//  Cross-platform (macOS + iOS) design language: reusable gradients,
//  materials, card surfaces, button styles, and animated primitives
//  (shimmer, thinking indicator, typing cursor, count-up, pop-in).
//
//  Everything here is pure SwiftUI — no AppKit/UIKit — so it compiles
//  and behaves on both platforms. macOS-only affordances (hover) are
//  no-ops on iOS by design.
//

import SwiftUI

// MARK: - Theme tokens

public enum Theme {
    /// Corner radii scale.
    public enum Radius {
        public static let sm: CGFloat = 8
        public static let md: CGFloat = 14
        public static let lg: CGFloat = 20
        public static let xl: CGFloat = 28
    }

    // MARK: Signature palette (violet → blue), tuned for a LIGHT UI
    //
    // Contrast targets (WCAG 2.2 AA): normal text 4.5:1, large text /
    // graphics 3:1. Verified on white (#FFFFFF):
    //   • brand   #664CEB → white text ≈ 5.7:1  (AA normal ✓)
    //   • brand   #664CEB → on white   ≈ 5.7:1  (AA normal ✓ for accent text)
    //   • brandAlt#3B6BE6 → white text ≈ 4.8:1  (AA normal ✓)
    // The user-bubble gradient uses `bubbleGradient` (both stops ≥4.5:1
    // with white). `brandPink` is decorative (aurora only) and exempt.

    /// Primary brand hue — deep violet (AA-safe against white both ways).
    public static let brand = Color(red: 0.40, green: 0.30, blue: 0.92)
    /// Secondary brand hue — deep blue.
    public static let brandAlt = Color(red: 0.23, green: 0.42, blue: 0.90)
    /// Tertiary accent for aurora depth — magenta/pink (decorative).
    public static let brandPink = Color(red: 0.82, green: 0.42, blue: 0.86)
    /// Deep indigo used as the far end of the bubble gradient so white
    /// body text stays ≥4.5:1 across the whole fill.
    public static let brandDeep = Color(red: 0.34, green: 0.26, blue: 0.80)

    /// Standard spring used for interactive state changes.
    public static let springFast = Animation.spring(response: 0.32, dampingFraction: 0.72)
    public static let springSoft = Animation.spring(response: 0.5, dampingFraction: 0.8)

    // MARK: Typography — bold rounded display

    /// Rounded display font for hero titles / big numbers. Rounded gives
    /// the app a distinct, modern (non-generic) personality.
    public static func display(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    /// Brand gradient — violet → blue. Used on hero glyphs, prominent
    /// buttons, and chips (graphics / large text → 3:1 target).
    public static func brandGradient(_ opacity: Double = 1) -> LinearGradient {
        LinearGradient(
            colors: [brand.opacity(opacity), brandAlt.opacity(opacity)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// Bubble gradient for white body text — both stops clear 4.5:1
    /// against white (violet → deep indigo). Use this behind normal-size
    /// white text; use `brandGradient` for graphics/large text only.
    public static var bubbleGradient: LinearGradient {
        LinearGradient(
            colors: [brand, brandDeep],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// Very soft top-down accent wash for empty-state / content backdrops.
    public static var backdropWash: LinearGradient {
        LinearGradient(
            colors: [brand.opacity(0.06), Color.clear],
            startPoint: .top,
            endPoint: .center
        )
    }
}

// MARK: - Aurora backdrop

/// Signature animated backdrop: three softly-blurred colour blobs drift
/// behind content, Linear/Raycast style. Sits in the content layer as a
/// standard background (not Liquid Glass). Subtle by design — it reads
/// as depth, not decoration. Cross-platform.
public struct AuroraBackdrop: View {
    var intensity: Double = 1.0
    @State private var drift = false
    /// Honour the system "Reduce Motion" accessibility setting — the
    /// blobs sit still (no continuous animation) when it's on.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    public init(intensity: Double = 1.0) { self.intensity = intensity }

    public var body: some View {
        ZStack {
            Rectangle().fill(.background)

            blob(Theme.brand, size: 520)
                .offset(x: drift ? -140 : -90, y: drift ? -180 : -140)
            blob(Theme.brandAlt, size: 460)
                .offset(x: drift ? 160 : 120, y: drift ? -60 : -10)
            blob(Theme.brandPink, size: 420)
                .offset(x: drift ? 60 : 110, y: drift ? 200 : 240)
        }
        .ignoresSafeArea()
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 14).repeatForever(autoreverses: true)) {
                drift = true
            }
        }
    }

    private func blob(_ color: Color, size: CGFloat) -> some View {
        // Kept light: soft pastel wash on white so near-black body text
        // over any blob still clears WCAG AA comfortably.
        Circle()
            .fill(color.opacity(0.18 * intensity))
            .frame(width: size, height: size)
            .blur(radius: 130)
    }
}

// MARK: - Card surface

/// A modern "card": material fill, hairline stroke, soft rounded rect.
/// Optional tint colours the stroke + adds a faint glow on hover.
public struct CardSurface: ViewModifier {
    var cornerRadius: CGFloat = Theme.Radius.md
    var tint: Color? = nil
    var hovering: Bool = false

    public func body(content: Content) -> some View {
        content
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(
                        hovering ? (tint ?? .accentColor).opacity(0.5) : Color.secondary.opacity(0.14),
                        lineWidth: 1
                    )
            )
            .shadow(color: hovering ? (tint ?? .accentColor).opacity(0.20) : .clear, radius: 9, y: 3)
    }
}

public extension View {
    func cardSurface(cornerRadius: CGFloat = Theme.Radius.md, tint: Color? = nil, hovering: Bool = false) -> some View {
        modifier(CardSurface(cornerRadius: cornerRadius, tint: tint, hovering: hovering))
    }

    /// Turns a `List` row's content into a floating card on a
    /// transparent row: pads the content, gives it a card surface, and
    /// clears the default separator + row background so the aurora shows
    /// between cards. Use as the LAST modifier on a row inside a List.
    func floatingCardRow(cornerRadius: CGFloat = Theme.Radius.md) -> some View {
        self
            .padding(12)
            .cardSurface(cornerRadius: cornerRadius)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: 14, bottom: 4, trailing: 14))
    }
}

// MARK: - Button styles

/// Springy press feedback — scales down + dims briefly. Works on tap
/// (iOS) and click (macOS).
public struct PressableButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.94
    public init(scale: CGFloat = 0.94) { self.scale = scale }
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(Theme.springFast, value: configuration.isPressed)
    }
}

public extension ButtonStyle where Self == PressableButtonStyle {
    static var pressable: PressableButtonStyle { PressableButtonStyle() }
}

// MARK: - Shimmer (loading placeholder / skeleton)

private struct Shimmer: ViewModifier {
    @State private var phase: CGFloat = -1
    var active: Bool
    func body(content: Content) -> some View {
        content.overlay {
            if active {
                GeometryReader { geo in
                    let width = geo.size.width
                    LinearGradient(
                        colors: [.clear, Color.white.opacity(0.35), .clear],
                        startPoint: .leading, endPoint: .trailing
                    )
                    .frame(width: width * 0.6)
                    .offset(x: phase * width * 1.6)
                    .blendMode(.plusLighter)
                }
                .mask(content)
                .allowsHitTesting(false)
                .onAppear {
                    withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                        phase = 1
                    }
                }
            }
        }
    }
}

public extension View {
    /// Sweeps a soft highlight across the view while `active`.
    func shimmering(_ active: Bool = true) -> some View {
        modifier(Shimmer(active: active))
    }
}

// MARK: - Thinking indicator (three bouncing dots)

/// Animated "assistant is thinking" indicator. Three dots bounce in a
/// staggered wave. Cross-platform.
public struct ThinkingIndicator: View {
    var tint: Color = .accentColor
    @State private var animating = false
    public init(tint: Color = .accentColor) { self.tint = tint }

    public var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(tint.opacity(0.75))
                    .frame(width: 7, height: 7)
                    .scaleEffect(animating ? 1 : 0.5)
                    .opacity(animating ? 1 : 0.4)
                    .animation(
                        .easeInOut(duration: 0.6)
                            .repeatForever()
                            .delay(Double(i) * 0.18),
                        value: animating
                    )
            }
        }
        .onAppear { animating = true }
    }
}

// MARK: - Blinking typing cursor

public struct TypingCursor: View {
    var tint: Color = .accentColor
    @State private var on = true
    public init(tint: Color = .accentColor) { self.tint = tint }
    public var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(tint)
            .frame(width: 2, height: 15)
            .opacity(on ? 1 : 0)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.55).repeatForever()) { on = false }
            }
    }
}

// MARK: - Count-up number

/// Animates an integer from 0 → value when it appears / changes. Great
/// for dashboard stat tiles.
public struct CountUpText: View {
    let value: Int
    var format: (Int) -> String = { "\($0)" }
    @State private var shown: Double = 0
    public init(_ value: Int, format: @escaping (Int) -> String = { "\($0)" }) {
        self.value = value
        self.format = format
    }
    public var body: some View {
        Text(format(Int(shown)))
            .contentTransition(.numericText())
            .onAppear {
                withAnimation(.easeOut(duration: 0.8)) { shown = Double(value) }
            }
            .onChange(of: value) { _, newValue in
                withAnimation(.easeOut(duration: 0.6)) { shown = Double(newValue) }
            }
    }
}

// MARK: - Pop-in transition

public extension AnyTransition {
    /// Scale + fade + slight upward slide — the standard entrance for
    /// list rows / chat bubbles / cards.
    static var popIn: AnyTransition {
        .asymmetric(
            insertion: .scale(scale: 0.94)
                .combined(with: .opacity)
                .combined(with: .move(edge: .bottom)),
            removal: .opacity
        )
    }
}
