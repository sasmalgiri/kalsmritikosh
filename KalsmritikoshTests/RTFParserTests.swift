//
//  RTFParserTests.swift
//  KalsmritikoshTests
//
//  A3 — RTFStructuralParser: paragraph segmentation with accurate character
//  ranges (the decode-independent part). RTF→text decode is exercised on real
//  fixtures by the ingestion smoke test. Add to the test target to run.
//

import Testing
import Foundation
@testable import Kalsmritikosh

struct RTFParserTests {

    @Test func paragraphSpansTrackCharacterRanges() {
        let text = "First line\n\nSecond line\nThird"
        let spans = RTFStructuralParser.paragraphSpans(text)
        #expect(spans.count == 3)
        #expect(spans[0].text == "First line")
        // Range of the first paragraph is the first line's span.
        #expect(spans[0].range == 0..<10)
        // Reopening the range in the source yields the paragraph text.
        let chars = Array(text)
        let slice = String(chars[spans[2].range])
        #expect(slice == "Third")
    }

    @Test func blankLinesSkippedButOffsetsStayAccurate() {
        let text = "A\n\n\nB"
        let spans = RTFStructuralParser.paragraphSpans(text)
        #expect(spans.map(\.text) == ["A", "B"])
        let chars = Array(text)
        #expect(String(chars[spans[1].range]) == "B")
    }
}
