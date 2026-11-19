//
//  HelpLinks.swift
//  Kalsmritikosh
//
//  Stable ways to reach help from anywhere (App Store completion instructions §6.6): open the Guide at
//  one topic, replay the introduction, replay the tutorial, open the support page. Posted as
//  notifications RootView observes, like `SurfaceOpener.open`, so no view threads closures for it.
//

import Foundation

public extension Notification.Name {
    /// Posted with `object: HelpTopic.id` — RootView opens the Guide and the Guide shows that topic.
    static let kalsmritikoshOpenHelp = Notification.Name("kalsmritikosh.openHelp")
    /// Posted without an object — RootView presents the introduction (onboarding) again.
    static let kalsmritikoshReplayOnboarding = Notification.Name("kalsmritikosh.replayOnboarding")
}

/// The topic a Help link asked for, kept until the Guide is on screen to consume it (UI run j, D-1: the
/// notification alone was lost when the Guide was not mounted yet, so "Open in Help" landed at the top).
@MainActor
@Observable
public final class HelpNavigation {
    public static let shared = HelpNavigation()
    public var pendingTopic: String?
}

@MainActor
public extension SurfaceOpener {
    /// Open the Guide at a topic (`HelpRegistry` id). An unknown id opens the Guide at the top.
    static func openHelp(_ topicID: String) {
        HelpNavigation.shared.pendingTopic = topicID
        NotificationCenter.default.post(name: .kalsmritikoshOpenHelp, object: topicID)
    }

    /// Show the introduction again (it never resets the person's settings or work).
    static func replayOnboarding() {
        NotificationCenter.default.post(name: .kalsmritikoshReplayOnboarding, object: nil)
    }
}

/// Public pages the app links to. Only these three, all on the project's own site.
public nonisolated enum HelpLinks {
    public static let support = URL(string: "https://sasmalgiri.github.io/kalsmritikosh/support.html")!
    public static let privacy = URL(string: "https://sasmalgiri.github.io/kalsmritikosh/privacy.html")!
    public static let terms = URL(string: "https://sasmalgiri.github.io/kalsmritikosh/terms.html")!
}
