//
//  BatchSearchParserTests.swift
//  KalsmritikoshTests
//
//  COMPETITOR-DNA — the batch-search list parser behind Search ▸ Batch list
//  (the Datashare pattern): one query per line, trimmed, blanks dropped,
//  case-insensitive dedupe keeping the first occurrence.
//

import Testing
@testable import Kalsmritikosh

@Suite("BATCH-SEARCH — list parser")
struct BatchSearchParserTests {

    @Test("Lines are trimmed, blanks dropped, duplicates removed case-insensitively")
    func parsing() {
        #expect(BatchSearchParser.parse("Acme Corp\n  J. Doe  \n\nacme corp\nJ. Doe\nRoe Ltd")
                == ["Acme Corp", "J. Doe", "Roe Ltd"])
        #expect(BatchSearchParser.parse("") == [])
        #expect(BatchSearchParser.parse("   \n \n") == [])
        #expect(BatchSearchParser.parse("one") == ["one"])
        // CRLF-pasted lists (from Excel/Windows) parse the same.
        #expect(BatchSearchParser.parse("a\r\nb\r\n") == ["a", "b"])
    }
}
