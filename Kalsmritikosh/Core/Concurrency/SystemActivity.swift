//
//  SystemActivity.swift
//  Kalsmritikosh
//
//  Cross-platform user-idle probe. On macOS it reads seconds since the
//  last HID input (mouse/keyboard) so background maintenance can run
//  ONLY while the machine is idle and pause the moment the user returns.
//
//  On iOS there is no equivalent "system idle" concept (apps are
//  suspended when the user leaves), so `idleSeconds()` returns 0 —
//  callers treat that as "the user is active", which means idle-gated
//  maintenance simply never fires on iOS. That's the intended behaviour.
//

import Foundation

#if os(macOS)
import CoreGraphics
#endif

public enum SystemActivity {
    /// Seconds since the last user input event. 0 == active right now.
    /// Returns 0 on platforms without an idle API.
    public nonisolated static func idleSeconds() -> TimeInterval {
        #if os(macOS)
        // kCGAnyInputEventType == 0xFFFFFFFF — "time since ANY input".
        let anyInput = CGEventType(rawValue: ~0) ?? .null
        let seconds = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState,
            eventType: anyInput
        )
        return seconds.isFinite ? seconds : 0
        #else
        return 0
        #endif
    }

    /// True when the machine has been idle for at least `threshold`
    /// seconds (no keyboard/mouse activity).
    public nonisolated static func isIdle(threshold: TimeInterval) -> Bool {
        idleSeconds() >= threshold
    }
}
