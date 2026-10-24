//
//  AppLock.swift
//  Kalsmritikosh
//
//  W2-7 — lock the app with Touch ID or the Mac password (ported in spirit from
//  mailin's BiometricLockManager). Locks when the Mac sleeps or the screen
//  locks, and when the user comes back after more than the idle limit. While
//  locked, the window shows only the unlock screen.
//
//  App lock decides WHO CAN OPEN THE APP; it does not encrypt anything. Data at
//  rest is protected separately: the ledger database file is encrypted with
//  SQLCipher (AES-256) using a key kept in this Mac's Keychain (see
//  AppState+LedgerEncryption.swift), and the copies of original files in the
//  evidence vault rely on FileVault and the app sandbox.
//

import Foundation
import Observation
import LocalAuthentication
#if canImport(AppKit)
import AppKit
#endif

@MainActor
@Observable
public final class AppLock {
    public static let shared = AppLock()

    public private(set) var locked = false
    public private(set) var lastError: String?
    private var resignedAt: Date?
    private var observers: [NSObjectProtocol] = []

    private static let idleKey = "kalsmritikosh.applock.idleMinutes"
    /// Minutes away before the app locks on return (default 5).
    public static var idleMinutes: Int {
        get { (UserDefaults.standard.object(forKey: idleKey) as? Int) ?? 5 }
        set { UserDefaults.standard.set(max(1, newValue), forKey: idleKey) }
    }

    public func start() {
        guard observers.isEmpty else { return }
        #if canImport(AppKit)
        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in AppLock.shared.lockIfEnabled() }
        })
        observers.append(ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in AppLock.shared.lockIfEnabled() }
        })
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in AppLock.shared.resignedAt = Date() }
        })
        observers.append(nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in
                let lock = AppLock.shared
                if AppLock.shouldLockOnReturn(resignedAt: lock.resignedAt, now: Date(), idleMinutes: AppLock.idleMinutes) {
                    lock.lockIfEnabled()
                }
                lock.resignedAt = nil
            }
        })
        #endif
        // Locked at launch when the module is on.
        lockIfEnabled()
    }

    /// Coming back locks the app only after more than the idle limit away.
    nonisolated static func shouldLockOnReturn(resignedAt: Date?, now: Date, idleMinutes: Int) -> Bool {
        guard let resignedAt else { return false }
        return now.timeIntervalSince(resignedAt) > Double(idleMinutes) * 60
    }

    /// How the person proves it is them. Tests replace it; the app uses LocalAuthentication.
    struct Authenticator {
        /// nil when this Mac can authenticate; otherwise why it can't.
        var unavailableReason: @MainActor () -> String?
        var evaluate: @MainActor () async throws -> Bool
    }

    var authenticator = Authenticator(
        unavailableReason: {
            let context = LAContext()
            var error: NSError?
            return context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) ? nil : (error?.localizedDescription ?? "This Mac has no way to verify you.")
        },
        evaluate: {
            let context = LAContext()
            context.localizedCancelTitle = "Cancel"
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "unlock your archive")
        })

    public func lockIfEnabled() {
        if ProductModuleFlags.isEnabled(.appLock) { locked = true }
    }

    public func unlock() async {
        if let reason = authenticator.unavailableReason() {
            // No way to authenticate on this Mac: never leave the user locked out.
            lastError = reason
            locked = false
            return
        }
        do {
            if try await authenticator.evaluate() {
                locked = false
                lastError = nil
            }
        } catch {
            lastError = error.localizedDescription
        }
    }
}
