//
//  PrivacyGate.swift
//  Atlas chronica memora
//
//  Local toggle that decides whether cloud routing is allowed. Defaults
//  to on-device-only. Persisted in UserDefaults so the choice survives
//  restarts.
//

import Foundation

public final class PrivacyGate: @unchecked Sendable {
    public static let shared = PrivacyGate()

    private let defaultsKey = "atlas.privacy.allowCloud"
    private let queue = DispatchQueue(label: "atlas.privacy")

    public var allowCloudRouting: Bool {
        get { queue.sync { UserDefaults.standard.bool(forKey: defaultsKey) } }
        set { queue.sync { UserDefaults.standard.set(newValue, forKey: defaultsKey) } }
    }
}
