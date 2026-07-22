//
//  EntityReconciliationAuditTests.swift
//  KalsmritikoshTests
//
//  SEM-009 — merges/splits are audited and reversible; undo is itself recorded (append-only
//  history, never erased).
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("SEM-009 EntityReconciliationAudit")
struct EntityReconciliationAuditTests {

    private let a = UUID(), b = UUID(), c = UUID()

    @Test("reverse(merge) is a split that restores the parts")
    func reverseMerge() {
        let inv = EntityReconciliationAudit.reverse(.merge(winner: a, losers: [b, c]))
        if case let .split(original, results) = inv {
            #expect(original == a)
            #expect(Set(results) == Set([a, b, c]))
        } else { Issue.record("expected split") }
    }

    @Test("reverse(split) is a merge that restores the original")
    func reverseSplit() {
        let inv = EntityReconciliationAudit.reverse(.split(original: a, results: [a, b]))
        if case let .merge(winner, losers) = inv {
            #expect(winner == a)
            #expect(losers == [b])
        } else { Issue.record("expected merge") }
    }

    @Test("undoLast appends an audited inverse without erasing history")
    func undoAppends() {
        var audit = EntityReconciliationAudit()
        audit.record(ReconciliationEvent(op: .merge(winner: a, losers: [b]), initiatedByHuman: true, atMillis: 1))
        let inv = audit.undoLast(atMillis: 2, byHuman: true)
        #expect(inv != nil)
        #expect(audit.history.count == 2)          // original + undo, both retained
    }

    @Test("undo of empty audit is nil")
    func undoEmpty() {
        var audit = EntityReconciliationAudit()
        #expect(audit.undoLast(atMillis: 1, byHuman: true) == nil)
    }
}
