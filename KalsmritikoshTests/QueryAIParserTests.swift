//
//  QueryAIParserTests.swift
//  KalsmritikoshTests
//
//  The optional AI path may only fill the SAME safe builder. These lock the
//  guarantee: whatever JSON a model returns, it is validated against the fixed
//  catalog — unknown subjects reject, unknown/invalid fields & choices drop,
//  limits clamp, and free text stays a plain value (it becomes a bound
//  parameter downstream, never SQL).
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("QueryAIParser — model JSON is validated against the catalog")
struct QueryAIParserTests {

    private func filter(_ p: QueryNaturalParser.Parsed, _ key: String) -> QueryFilter? {
        p.query.filters.first { $0.fieldKey == key }
    }

    @Test("A well-formed object maps to a real subject + filters")
    func wellFormed() throws {
        let p = try #require(QueryAIParser.decode(
            #"{"subject":"people","filters":[{"field":"kind","op":"isEqual","value":"organization"},{"field":"confidence","op":"greaterThan","value":"0.8"}],"limit":25}"#))
        #expect(p.query.subjectID == "people")
        #expect(filter(p, "kind")?.value == "organization")
        #expect(filter(p, "confidence")?.op == .greaterThan)
        #expect(p.query.limit == 25)
    }

    @Test("Fenced / chatty output is tolerated (JSON extracted)")
    func fenced() throws {
        let p = try #require(QueryAIParser.decode(
            "Sure! Here you go:\n```json\n{\"subject\":\"conflicts\",\"filters\":[{\"field\":\"status\",\"op\":\"isEqual\",\"value\":\"open\"}]}\n```"))
        #expect(p.query.subjectID == "conflicts")
        #expect(filter(p, "status")?.value == "open")
    }

    @Test("An unknown subject rejects the whole thing")
    func unknownSubject() {
        #expect(QueryAIParser.decode(#"{"subject":"secrets","filters":[]}"#) == nil)
        #expect(QueryAIParser.decode("not json at all") == nil)
    }

    @Test("Unknown field, wrong operator, and bogus choice are dropped")
    func invalidFiltersDropped() throws {
        let p = try #require(QueryAIParser.decode("""
        {"subject":"people","filters":[
          {"field":"ssn","op":"isEqual","value":"x"},
          {"field":"name","op":"greaterThan","value":"y"},
          {"field":"kind","op":"isEqual","value":"alien"},
          {"field":"name","op":"contains","value":"Alice"}
        ]}
        """))
        // Only the last, fully-valid filter survives.
        #expect(p.query.filters.count == 1)
        #expect(filter(p, "name")?.op == .contains)
        #expect(filter(p, "name")?.value == "Alice")
    }

    @Test("An injection string survives only as an inert value; limit clamps")
    func injectionIsInertAndClamps() throws {
        let p = try #require(QueryAIParser.decode(
            #"{"subject":"documents","filters":[{"field":"file","op":"contains","value":"'; DROP TABLE files;--"}],"limit":99999}"#))
        // It's kept as a plain filter value (bound param downstream), not executed.
        #expect(filter(p, "file")?.value == "'; DROP TABLE files;--")
        #expect(p.query.limit == 1000) // clamped
        // Sanity: it still compiles to a SELECT-only, parameterized statement.
        let c = try #require(LedgerQueryCompiler.compile(p.query))
        #expect(c.sql.hasPrefix("SELECT "))
        #expect(!c.sql.uppercased().contains("DROP"))
    }

    @Test("‘between’ without a second value is dropped")
    func betweenNeedsTwo() throws {
        let p = try #require(QueryAIParser.decode(
            #"{"subject":"events","filters":[{"field":"date","op":"between","value":"2024-01-01"}]}"#))
        #expect(p.query.filters.isEmpty)
    }
}
