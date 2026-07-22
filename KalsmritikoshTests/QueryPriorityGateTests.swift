//
//  QueryPriorityGateTests.swift
//  KalsmritikoshTests
//
//  ING-006 — interactive work pre-empts background: while a query holds priority, a
//  background task parked at a yield point stays suspended, and resumes when the query ends.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Query priority gate (ING-006)")
struct QueryPriorityGateTests {

    @Test("No interactive query → clearance is immediate")
    func immediateWhenIdle() async {
        let gate = QueryPriorityGate()
        #expect(await gate.isInteractiveActive == false)
        await gate.awaitClearance()   // returns at once
    }

    @Test("Background parks while interactive is active, resumes when it ends")
    func backgroundYields() async {
        let gate = QueryPriorityGate()
        await gate.beginInteractive()
        #expect(await gate.isInteractiveActive == true)

        let resumed = Resumed()
        let bg = Task {
            await gate.awaitClearance()
            await resumed.mark()
        }
        // Give the background task a chance to park.
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(await resumed.value == false)   // still parked

        await gate.endInteractive()
        await bg.value
        #expect(await resumed.value == true)     // released
        #expect(await gate.isInteractiveActive == false)
    }

    @Test("Nested interactive queries only release background when the last ends")
    func nested() async {
        let gate = QueryPriorityGate()
        await gate.beginInteractive()
        await gate.beginInteractive()
        await gate.endInteractive()
        #expect(await gate.isInteractiveActive == true)   // one still active
        await gate.endInteractive()
        #expect(await gate.isInteractiveActive == false)
    }

    private actor Resumed {
        private(set) var value = false
        func mark() { value = true }
    }
}
