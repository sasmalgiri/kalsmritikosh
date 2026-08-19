//
//  FirstRunNudge.swift
//  Kalsmritikosh
//
//  FIRST-RUN-CURVE (owner request 2026-08-19) — the ONE empty-state pattern:
//  every surface that has nothing to show yet explains itself in plain
//  language AND carries a button that takes the user to the action that
//  fills it (usually adding files in Sources). A new user should never meet
//  a screen that says "no data" without a door to walk through.
//
//  Navigation is decoupled: the button posts a notification RootView
//  observes, so any view can offer a jump without threading closures
//  through every initializer.
//

import SwiftUI

public extension Notification.Name {
    /// Posted with `object: Destination.rawValue` — RootView navigates there.
    static let kalsmritikoshNavigate = Notification.Name("kalsmritikosh.navigate")
}

/// Programmatic navigation from anywhere in the UI layer.
@MainActor
public enum SurfaceOpener {
    public static func open(_ destination: Destination) {
        NotificationCenter.default.post(name: .kalsmritikoshNavigate,
                                        object: destination.rawValue)
    }
}

/// The standard "nothing here yet — here's your next step" empty state.
public struct FirstRunNudge: View {
    let icon: String
    let title: String
    let message: String
    let ctaTitle: String
    let destination: Destination

    public init(icon: String,
                title: String,
                message: String,
                ctaTitle: String = "Add your files",
                destination: Destination = .sources) {
        self.icon = icon
        self.title = title
        self.message = message
        self.ctaTitle = ctaTitle
        self.destination = destination
    }

    public var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 36))
                .foregroundStyle(.tint)
            Text(title)
                .font(.title3.weight(.medium))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
            Button {
                SurfaceOpener.open(destination)
            } label: {
                Label(ctaTitle, systemImage: destination.icon)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One-line variant for tight spots (captions under pickers, list footers).
public struct FirstRunHint: View {
    let message: String
    let ctaTitle: String
    let destination: Destination

    public init(message: String,
                ctaTitle: String = "Add your files",
                destination: Destination = .sources) {
        self.message = message
        self.ctaTitle = ctaTitle
        self.destination = destination
    }

    public var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "lightbulb")
                .foregroundStyle(.tint)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(ctaTitle) { SurfaceOpener.open(destination) }
                .controlSize(.small)
        }
        .padding(8)
        .background(.tint.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }
}
