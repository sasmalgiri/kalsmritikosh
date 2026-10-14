//
//  NoNetworkAttestation.swift
//  Kalsmritikosh
//
//  W0-C — the in-app read of the offline claim (ported from mailin). Reads THIS
//  process's own signed entitlements via Code Signing Services. The main app may
//  claim "cannot reach the network" only when entitlements are readable, it is
//  sandboxed, and neither network entitlement is granted. An unreadable
//  dictionary reads as "cannot demonstrate", never as "safe".
//

import Foundation
import Security

nonisolated enum NoNetworkAttestation {

    struct Verdict: Sendable {
        let readable: Bool
        let sandboxed: Bool
        let client: Bool
        let server: Bool

        var mainAppCannotConnect: Bool { readable && sandboxed && !client && !server }

        var summary: String {
            if !readable { return "Could not read this app's signed entitlements, so its offline status cannot be shown here." }
            if mainAppCannotConnect {
                return ConnectivityMode.onlineAvailableInThisBuild
                    ? "This app has no network permission (checked from its signature). Online mode uses a separate helper that Private mode never starts."
                    : "This app has no network permission (checked from its signature) and no network helper: it cannot reach the network."
            }
            return "Warning: this build's signature grants network access to the main app."
        }
    }

    static func verdict() -> Verdict {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let ents = dict[kSecCodeInfoEntitlementsDict as String] as? [String: Any] else {
            return Verdict(readable: false, sandboxed: false, client: false, server: false)
        }
        return Verdict(readable: true,
                       sandboxed: ents["com.apple.security.app-sandbox"] as? Bool == true,
                       client: ents["com.apple.security.network.client"] as? Bool == true,
                       server: ents["com.apple.security.network.server"] as? Bool == true)
    }
}
