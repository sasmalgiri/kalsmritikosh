//
//  BackgroundWorkPolicyTests.swift
//  KalsmritikoshTests
//
//  SHELL-003 — the pure background-work decision. Proves foreground/explicit work (P0–P4) always runs,
//  deferred background work (P5–P6) runs only when enabled + not interactive + no higher-priority work
//  is active + the trigger (idle / off-hours) is satisfied, that P6 yields even to active P5, and that
//  the off-hours window (including overnight wrap and weekday) is respected. Pure — no data.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("SHELL-003 — background-work policy")
struct BackgroundWorkPolicyTests {

    private let utc: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }()
    private func at(hour: Int, minute: Int) -> Date {
        utc.date(from: DateComponents(year: 2026, month: 8, day: 3, hour: hour, minute: minute))!   // a fixed UTC day
    }
    private func weekday(_ d: Date) -> Int { utc.component(.weekday, from: d) }

    private func inputs(enabled: Bool = true, trigger: BackgroundWorkTrigger = .idle, idle: TimeInterval = 300,
                        interactive: Bool = false, active: Set<BackgroundWorkPriority> = [],
                        now: Date = Date(timeIntervalSinceReferenceDate: 0),
                        offStart: Int = 22 * 60, offEnd: Int = 6 * 60, days: Set<Int> = [1, 2, 3, 4, 5, 6, 7]) -> BackgroundWorkInputs {
        BackgroundWorkInputs(preference: BackgroundWorkPreference(enabled: enabled, trigger: trigger, idleThresholdSeconds: 120,
                                                                 offHoursStartMinute: offStart, offHoursEndMinute: offEnd, offHoursWeekdays: days),
                             now: now, idleSeconds: idle, isInteractiveActive: interactive, activeWorkPriorities: active)
    }

    @Test("Foreground/explicit work (P0–P4) always runs, regardless of preference or activity")
    func foregroundAlwaysRuns() {
        let hostile = inputs(enabled: false, idle: 0, interactive: true, active: [.uiInteraction])
        for p in [BackgroundWorkPriority.uiInteraction, .askSearchDataLab, .fullEvidence, .jobWorkflow, .ingestion] {
            #expect(BackgroundWorkPolicy.permits(p, inputs: hostile))
        }
    }

    @Test("Background Work OFF blocks deferred work (P5–P6)")
    func disabledBlocksDeferred() {
        let i = inputs(enabled: false)
        #expect(!BackgroundWorkPolicy.permits(.requiredDeferred, inputs: i))
        #expect(!BackgroundWorkPolicy.permits(.optionalMaintenance, inputs: i))
    }

    @Test("Idle mode: deferred work runs once idle meets the threshold, and is blocked while the user is active")
    func idleTrigger() {
        #expect(BackgroundWorkPolicy.permits(.optionalMaintenance, inputs: inputs(idle: 300)))
        #expect(!BackgroundWorkPolicy.permits(.optionalMaintenance, inputs: inputs(idle: 10)))   // user active
    }

    @Test("An interactive query in flight blocks deferred work even when idle")
    func interactiveBlocks() {
        #expect(!BackgroundWorkPolicy.permits(.requiredDeferred, inputs: inputs(idle: 999, interactive: true)))
    }

    @Test("Higher-priority active work blocks lower deferred work; P6 yields even to active P5")
    func priorityPreemption() {
        // Foreground P1 active → both deferred priorities yield.
        let fg = inputs(active: [.askSearchDataLab])
        #expect(!BackgroundWorkPolicy.permits(.requiredDeferred, inputs: fg))
        #expect(!BackgroundWorkPolicy.permits(.optionalMaintenance, inputs: fg))
        // Only P5 active → P6 yields but P5 itself may still run.
        let p5 = inputs(active: [.requiredDeferred])
        #expect(!BackgroundWorkPolicy.permits(.optionalMaintenance, inputs: p5))
        #expect(BackgroundWorkPolicy.permits(.requiredDeferred, inputs: p5))
    }

    @Test("Off-hours: deferred work runs inside the window and is blocked outside it")
    func offHoursWindow() {
        // Window 22:00–06:00 (overnight wrap).
        #expect(BackgroundWorkPolicy.permits(.optionalMaintenance, inputs: inputs(trigger: .offHours, now: at(hour: 2, minute: 0))))
        #expect(!BackgroundWorkPolicy.permits(.optionalMaintenance, inputs: inputs(trigger: .offHours, now: at(hour: 12, minute: 0))))
        // A same-day window 09:00–17:00.
        #expect(BackgroundWorkPolicy.permits(.optionalMaintenance, inputs: inputs(trigger: .offHours, now: at(hour: 10, minute: 0), offStart: 9 * 60, offEnd: 17 * 60)))
        #expect(!BackgroundWorkPolicy.permits(.optionalMaintenance, inputs: inputs(trigger: .offHours, now: at(hour: 20, minute: 0), offStart: 9 * 60, offEnd: 17 * 60)))
    }

    @Test("Off-hours respects the enabled weekdays")
    func offHoursWeekday() {
        let now = at(hour: 2, minute: 0)
        let otherDays = Set(1...7).subtracting([weekday(now)])
        #expect(!BackgroundWorkPolicy.permits(.optionalMaintenance, inputs: inputs(trigger: .offHours, now: now, days: otherDays)))
        #expect(BackgroundWorkPolicy.permits(.optionalMaintenance, inputs: inputs(trigger: .offHours, now: now, days: [weekday(now)])))
    }

    @Test("A zero-width off-hours window never permits deferred work")
    func offHoursZeroWidth() {
        #expect(!BackgroundWorkPolicy.permits(.optionalMaintenance, inputs: inputs(trigger: .offHours, now: at(hour: 3, minute: 0), offStart: 3 * 60, offEnd: 3 * 60)))
    }

    @Test("The priority ladder is the fixed closed set with the expected ordering")
    func priorityLadder() {
        #expect(BackgroundWorkPriority.allCases.count == 7)
        #expect(BackgroundWorkPriority.uiInteraction < BackgroundWorkPriority.optionalMaintenance)
        #expect(BackgroundWorkPriority.uiInteraction.isForegroundOrExplicit)
        #expect(BackgroundWorkPriority.ingestion.isForegroundOrExplicit)
        #expect(BackgroundWorkPriority.requiredDeferred.isDeferredBackground)
        #expect(BackgroundWorkPriority.optionalMaintenance.isDeferredBackground)
    }
}
