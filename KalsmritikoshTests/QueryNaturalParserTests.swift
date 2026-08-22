//
//  QueryNaturalParserTests.swift
//  KalsmritikoshTests
//
//  The plain-language → builder parser. It only ever produces a LedgerQuery
//  from the safe catalog (never SQL), so these lock the mapping.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("QueryNaturalParser — plain language fills the builder")
struct QueryNaturalParserTests {

    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
    }
    // Fixed "now" = 2024-06-15 12:00 UTC, so relative dates are deterministic.
    private var now: Date { utc.date(from: DateComponents(year: 2024, month: 6, day: 15, hour: 12))! }

    private func parse(_ s: String) -> QueryNaturalParser.Parsed {
        QueryNaturalParser.parse(s, now: now, calendar: utc)!
    }
    private func filter(_ p: QueryNaturalParser.Parsed, _ key: String) -> QueryFilter? {
        p.query.filters.first { $0.fieldKey == key }
    }

    @Test("‘documents added last month’ → documents, date between last month")
    func documentsLastMonth() {
        let p = parse("documents added last month")
        #expect(p.query.subjectID == "documents")
        let f = filter(p, "added")
        #expect(f?.op == .between)
        #expect(f?.value == "2024-05-01")
        #expect(f?.value2 == "2024-05-31")
    }

    @Test("‘organizations with confidence over 0.8’ → people, kind + confidence")
    func orgsConfidence() {
        let p = parse("organizations with confidence over 0.8")
        #expect(p.query.subjectID == "people")
        #expect(filter(p, "confidence")?.op == .greaterThan)
        #expect(filter(p, "confidence")?.value == "0.8")
        #expect(filter(p, "kind")?.op == .isEqual)
        #expect(filter(p, "kind")?.value == "organization")
    }

    @Test("‘open conflicts’ → conflicts, status is open")
    func openConflicts() {
        let p = parse("open conflicts")
        #expect(p.query.subjectID == "conflicts")
        #expect(filter(p, "status")?.value == "open")
    }

    @Test("‘top 5 relationships’ → relationships, limit 5, sorted by weight desc")
    func topRelationships() {
        let p = parse("top 5 relationships")
        #expect(p.query.subjectID == "relationships")
        #expect(p.query.limit == 5)
        #expect(p.query.sortFieldKey == "weight")
        #expect(p.query.sortDescending)
    }

    @Test("‘events in 2024’ → events, date between the year")
    func eventsYear() {
        let p = parse("events in 2024")
        #expect(p.query.subjectID == "events")
        let f = filter(p, "date")
        #expect(f?.op == .between)
        #expect(f?.value == "2024-01-01")
        #expect(f?.value2 == "2024-12-31")
    }

    @Test("‘people named Alice’ → name contains Alice; empty input → nil")
    func namedAndEmpty() {
        let p = parse("people named Alice")
        #expect(p.query.subjectID == "people")
        #expect(filter(p, "name")?.op == .contains)
        #expect(filter(p, "name")?.value == "Alice")
        #expect(QueryNaturalParser.parse("   ") == nil)
    }
}
