//
//  DatePrecisionTests.swift
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("DatePrecision — Phase G.1 rendering")
struct DatePrecisionTests {
    /// Snapshot the rendered phrases for each precision tier so a
    /// regression in renderPhrase is caught immediately.
    @Test("instant precision renders date + time")
    func instant() {
        let date = ISO8601DateFormatter().date(from: "2025-03-14T09:12:00Z")!
        let phrase = DatePrecision.instant.renderPhrase(date: date)
        #expect(phrase.contains("Mar"))
        #expect(phrase.contains("2025"))
    }

    @Test("day precision drops the time portion")
    func dayPrecision() {
        let date = ISO8601DateFormatter().date(from: "2025-03-14T09:12:00Z")!
        let phrase = DatePrecision.day.renderPhrase(date: date)
        #expect(phrase.contains("Mar"))
        #expect(!phrase.contains(":"))
    }

    @Test("month precision uses 'in March 2025'")
    func monthPrecision() {
        let date = ISO8601DateFormatter().date(from: "2025-03-14T09:12:00Z")!
        let phrase = DatePrecision.month.renderPhrase(date: date)
        #expect(phrase.contains("March"))
        #expect(phrase.contains("2025"))
    }

    @Test("year precision uses 'during 2025'")
    func yearPrecision() {
        let date = ISO8601DateFormatter().date(from: "2025-03-14T09:12:00Z")!
        let phrase = DatePrecision.year.renderPhrase(date: date)
        #expect(phrase.contains("2025"))
        #expect(phrase.contains("during"))
    }

    @Test("decade precision uses 'in the 2020s'")
    func decadePrecision() {
        let date = ISO8601DateFormatter().date(from: "2025-03-14T09:12:00Z")!
        let phrase = DatePrecision.decade.renderPhrase(date: date)
        #expect(phrase.contains("2020s"))
    }
}
