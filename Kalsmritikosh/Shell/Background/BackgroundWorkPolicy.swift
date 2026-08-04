//
//  BackgroundWorkPolicy.swift
//  Kalsmritikosh
//
//  SHELL-003 (product shell) — the ONE authority that decides whether a piece of optional/deferred
//  background work may run RIGHT NOW. Every background worker asks this one policy instead of each
//  independently checking idle state. The decision is pure and deterministic over its inputs (the user
//  preference, the wall clock, the HID idle time, whether an interactive query is in flight, and which
//  work priorities are already active), so it is fully testable without real hardware. Foreground and
//  explicit user work (P0–P4) always runs; only deferred background work (P5–P6) is gated, and it never
//  competes with anything of higher priority — optional maintenance (P6) yields even to required
//  deferred work (P5), and both yield to the user (P0–P4).
//

import Foundation

/// The fixed priority ladder. Lower rawValue = higher priority. P0–P4 are foreground / explicit user
/// work that always runs; P5–P6 are deferred background work governed by the gate.
public nonisolated enum BackgroundWorkPriority: Int, Codable, Sendable, Equatable, CaseIterable, Comparable {
    case uiInteraction = 0        // P0 UI / navigation
    case askSearchDataLab = 1     // P1 Ask / Search / DataLab
    case fullEvidence = 2         // P2 explicit Full Evidence
    case jobWorkflow = 3          // P3 active job / workflow
    case ingestion = 4            // P4 explicit ingestion
    case requiredDeferred = 5     // P5 required deferred work
    case optionalMaintenance = 6  // P6 optional maintenance

    public nonisolated static func < (lhs: BackgroundWorkPriority, rhs: BackgroundWorkPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// P0–P4 always run: they are foreground interaction or work the user explicitly asked for.
    public nonisolated var isForegroundOrExplicit: Bool { rawValue <= 4 }
    /// P5–P6 are the only priorities the background gate may pause.
    public nonisolated var isDeferredBackground: Bool { rawValue >= 5 }
}

/// What triggers deferred background work.
public nonisolated enum BackgroundWorkTrigger: String, Codable, Sendable, Equatable, CaseIterable {
    case idle
    case offHours
}

/// The user's minimal background-work preference (Simple settings: On/Off + Idle/Off-hours + schedule).
public nonisolated struct BackgroundWorkPreference: Sendable, Equatable, Codable {
    public var enabled: Bool
    public var trigger: BackgroundWorkTrigger
    public var idleThresholdSeconds: TimeInterval
    public var offHoursStartMinute: Int          // minutes since local midnight, 0..1439
    public var offHoursEndMinute: Int            // exclusive; wraps past midnight when start > end
    public var offHoursWeekdays: Set<Int>        // Gregorian weekday 1..7 (1 = Sunday)

    public nonisolated init(enabled: Bool = true, trigger: BackgroundWorkTrigger = .idle,
                            idleThresholdSeconds: TimeInterval = 120,
                            offHoursStartMinute: Int = 22 * 60, offHoursEndMinute: Int = 6 * 60,
                            offHoursWeekdays: Set<Int> = [1, 2, 3, 4, 5, 6, 7]) {
        self.enabled = enabled; self.trigger = trigger; self.idleThresholdSeconds = idleThresholdSeconds
        self.offHoursStartMinute = offHoursStartMinute; self.offHoursEndMinute = offHoursEndMinute
        self.offHoursWeekdays = offHoursWeekdays
    }

    public nonisolated static let `default` = BackgroundWorkPreference()
}

/// The live signals the policy reads. Passed in (rather than sampled inside) so the decision is pure.
public nonisolated struct BackgroundWorkInputs: Sendable {
    public var preference: BackgroundWorkPreference
    public var now: Date
    public var idleSeconds: TimeInterval                       // from SystemActivity
    public var isInteractiveActive: Bool                      // from QueryPriorityGate
    public var activeWorkPriorities: Set<BackgroundWorkPriority>

    public nonisolated init(preference: BackgroundWorkPreference, now: Date, idleSeconds: TimeInterval,
                            isInteractiveActive: Bool, activeWorkPriorities: Set<BackgroundWorkPriority>) {
        self.preference = preference; self.now = now; self.idleSeconds = idleSeconds
        self.isInteractiveActive = isInteractiveActive; self.activeWorkPriorities = activeWorkPriorities
    }
}

public nonisolated enum BackgroundWorkPolicy {

    /// The one decision. Foreground/explicit work always runs; deferred background work runs only when
    /// enabled, no interactive query is in flight, nothing of strictly higher priority is active, and
    /// the chosen trigger (idle / off-hours) is satisfied.
    public nonisolated static func permits(_ priority: BackgroundWorkPriority, inputs: BackgroundWorkInputs) -> Bool {
        if priority.isForegroundOrExplicit { return true }
        guard inputs.preference.enabled else { return false }
        if inputs.isInteractiveActive { return false }
        // Never compete with anything of strictly higher priority (this is what keeps P6 below P0–P5).
        if inputs.activeWorkPriorities.contains(where: { $0 < priority }) { return false }
        switch inputs.preference.trigger {
        case .idle:
            return inputs.idleSeconds >= inputs.preference.idleThresholdSeconds
        case .offHours:
            return isWithinOffHours(inputs.preference, now: inputs.now)
        }
    }

    /// Whether `now` falls in the configured off-hours window on an enabled weekday. The window is
    /// [start, end); when start > end it wraps past midnight. A fixed Gregorian calendar keeps it
    /// deterministic and host-independent for tests.
    public nonisolated static func isWithinOffHours(_ pref: BackgroundWorkPreference, now: Date) -> Bool {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let comp = cal.dateComponents([.hour, .minute, .weekday], from: now)
        guard let hour = comp.hour, let minute = comp.minute, let weekday = comp.weekday else { return false }
        guard pref.offHoursWeekdays.contains(weekday) else { return false }
        let m = hour * 60 + minute
        let s = pref.offHoursStartMinute, e = pref.offHoursEndMinute
        if s == e { return false }
        if s < e { return m >= s && m < e }
        return m >= s || m < e   // overnight wrap
    }
}
