//
//  FundsTracingMethodTests.swift
//  KalsmritikoshTests
//
//  The recognized funds-tracing methods a forensic accountant must choose between.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("FundsTracingMethods")
struct FundsTracingMethodTests {

    @Test("The catalog is complete, uniquely identified, and described")
    func catalog() {
        let m = FundsTracingMethods.methods
        #expect(m.count >= 4)
        #expect(Set(m.map(\.id)).count == m.count)
        #expect(m.allSatisfy { !$0.name.isEmpty && !$0.detail.isEmpty })
        // The three classic indirect methods are present.
        let names = m.map(\.name).joined(separator: " | ").lowercased()
        #expect(names.contains("net worth"))
        #expect(names.contains("expenditures"))
        #expect(names.contains("bank deposits"))
    }

    @Test("Methods split into exactly the Direct and Indirect families")
    func families() {
        #expect(FundsTracingMethods.families() == ["Direct", "Indirect"])
        #expect(FundsTracingMethods.methods.filter { $0.family == "Indirect" }.count == 3)
        #expect(FundsTracingMethods.helpSummary.contains("Net worth"))
    }

    @Test("The discipline line requires naming the method")
    func discipline() {
        let note = FundsTracingMethods.disciplineNote.lowercased()
        #expect(note.contains("indirect"))
        #expect(note.contains("state the method"))
    }
}
