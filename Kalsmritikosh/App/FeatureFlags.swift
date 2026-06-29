//
//  FeatureFlags.swift
//  Kalsmritikosh
//
//  Phase L (App Store readiness) — runtime feature gates for ingest
//  surfaces that touch other apps' data. ALL flags default OFF so a
//  vanilla Mac App Store install behaves identically to a sandboxed
//  archive reader. Users opt in via Settings.
//
//  Why this exists: iMessage, Safari, and Chromium loaders read
//  SQLite files in other apps' containers. Even though the sandbox
//  already blocks unauthorized reads (the OS denies them at the
//  syscall level), App Store reviewers flag any app that ADVERTISES
//  these capabilities by default. Defaulting OFF + an explicit
//  Settings toggle gated behind a warning satisfies the review
//  criterion ("only read other apps' data when the user explicitly
//  authorized it for this app").
//
//  Persistence: UserDefaults. Cheap, system-managed, survives app
//  updates. No Keychain needed — the flag value isn't a secret.
//

import Foundation
import Observation

@MainActor
@Observable
public final class FeatureFlags {
    public static let shared = FeatureFlags()

    /// Phase K — iMessage loader (reads ~/Library/Messages/chat.db
    /// when a user-selected folder contains a copy of it). Default
    /// OFF for App Store builds. When the user enables this they're
    /// asked to manually export chat.db to a watched folder first.
    public var iMessageLoaderEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.kIMessage) }
        set { UserDefaults.standard.set(newValue, forKey: Self.kIMessage) }
    }

    /// Phase K — Safari and Chromium history loaders. Same shape as
    /// iMessage: OFF by default, opt-in via Settings, requires the
    /// user to have placed a copy of History.db / History in a
    /// watched folder.
    public var browserHistoryLoaderEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.kBrowserHistory) }
        set { UserDefaults.standard.set(newValue, forKey: Self.kBrowserHistory) }
    }

    /// Phase K — WhatsApp / Signal / Slack text-export loader. Plain-
    /// text reading — no Full Disk Access angle — but kept behind a
    /// flag for parity with the other chat-surface loaders so the
    /// Settings UI groups all three under one "personal chat" toggle.
    public var chatExportLoaderEnabled: Bool {
        get {
            // Plain-text exports are safe by default — no system access.
            // Default ON unless the user has explicitly turned them off.
            if UserDefaults.standard.object(forKey: Self.kChatExport) == nil { return true }
            return UserDefaults.standard.bool(forKey: Self.kChatExport)
        }
        set { UserDefaults.standard.set(newValue, forKey: Self.kChatExport) }
    }

    // MARK: - Storage keys

    private static let kIMessage         = "atlas.feature.imessageLoader.enabled"
    private static let kBrowserHistory   = "atlas.feature.browserHistory.enabled"
    private static let kChatExport       = "atlas.feature.chatExport.enabled"
}
