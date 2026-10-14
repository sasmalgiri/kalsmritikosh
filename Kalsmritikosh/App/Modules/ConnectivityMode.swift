//
//  ConnectivityMode.swift
//  Kalsmritikosh
//
//  O-3 — Private (default) or Online (opt-in). Owner decisions 2026-10-15:
//  Private by default; Online means the user's own cloud AI key only (no local
//  model server, no sync, no MCP); a visible badge and a one-click way back.
//
//  Online needs the separate network helper (O-2): the main app keeps NO network
//  permission. Until a build bundles that helper, Online is reported as not
//  available and every online module stays off — the chosen mode is kept, so it
//  takes effect the day the helper ships.
//

import Foundation

nonisolated public enum ConnectivityMode: String, CaseIterable, Identifiable, Sendable {
    case privateMode = "private"
    case online

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .privateMode: return "Private"
        case .online:      return "Online (your own key)"
        }
    }

    public var summary: String {
        switch self {
        case .privateMode:
            return "Everything happens on this Mac. Nothing is sent anywhere."
        case .online:
            return "Answers may use the cloud AI you choose, with your own key. You see exactly what will be sent first, personal details can be masked, and every send is logged. Switch back to Private at any time."
        }
    }

    private static let key = "kalsmritikosh.connectivity.mode"

    /// Name of the bundled network helper (an XPC service inside the app).
    public static let networkHelperName = "KalsmritikoshNetwork.xpc"

    /// The user's choice. Private when never set.
    public nonisolated static var stored: ConnectivityMode {
        guard let raw = UserDefaults.standard.string(forKey: key),
              let m = ConnectivityMode(rawValue: raw) else { return .privateMode }
        return m
    }

    /// The mode actually in force: Online only when chosen AND possible.
    public nonisolated static var current: ConnectivityMode {
        stored == .online && onlineAvailableInThisBuild ? .online : .privateMode
    }

    public nonisolated static func set(_ m: ConnectivityMode) {
        UserDefaults.standard.set(m.rawValue, forKey: key)
    }

    /// True when this app bundle contains the network helper. Checked on disk,
    /// so it becomes true automatically when the helper target is added.
    public nonisolated static var onlineAvailableInThisBuild: Bool {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents/XPCServices", isDirectory: true)
            .appendingPathComponent(networkHelperName, isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path)
    }
}
