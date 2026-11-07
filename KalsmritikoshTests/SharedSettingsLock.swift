//
//  SharedSettingsLock.swift
//  KalsmritikoshTests
//
//  The AI posture lives in process-wide settings: the regime flags in the standard domain, and the
//  "AI off" override some suites place in the argument domain (which outranks the standard one).
//  Suites run in parallel inside one test host, so a suite that forces AI off can make another
//  suite's regime check read the wrong value (CI batch 9, 2026-10-28: AIRegimeMatrixTests failed
//  while a case simulation held the override). Every test that changes these settings holds this
//  lock for as long as its change is in force.
//

import Foundation

actor SharedSettingsLock {
    static let shared = SharedSettingsLock()

    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard held else { held = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty { held = false } else { waiters.removeFirst().resume() }
    }
}
