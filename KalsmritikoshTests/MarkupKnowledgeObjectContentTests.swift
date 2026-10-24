//
//  MarkupKnowledgeObjectContentTests.swift
//  KalsmritikoshTests
//
//  Case bench 2026-10-24 — an ingested HTML file's KnowledgeObject content was the raw
//  markup, so the incident event extracted from it (and the "When did the accident …
//  happen?" answer quoting that event) read `<p class="p1">On May 19, 2003, …`. The KO
//  content of an HTML/XML source is its readable text: no tags, entities decoded, and a
//  sentence wrapped in inline spans (Cocoa HTML Writer) stays on one line.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("HTML / XML KnowledgeObject content is readable text, never markup")
struct MarkupKnowledgeObjectContentTests {

    /// The shape Cocoa HTML Writer produces (TextEdit "Save as HTML").
    private let cocoaHTML = """
    <!DOCTYPE html PUBLIC "-//W3C//DTD HTML 4.01//EN" "http://www.w3.org/TR/html4/strict.dtd">
    <html>
    <head>
    <meta http-equiv="Content-Type" content="text/html; charset=UTF-8">
    <title></title>
    <meta name="Generator" content="Cocoa HTML Writer">
    <style type="text/css">
    p.p1 {margin: 0.0px 0.0px 0.0px 0.0px; font: 12.0px Helvetica}
    </style>
    </head>
    <body>
    <p class="p1">NTSB Identification: SEA03LA084</p>
    <p class="p1">On May 19, 2003, about 1330 Pacific daylight time, a <span class="s1">Cessna 172N</span> was substantially damaged &amp; the pilot was not injured.</p>
    </body>
    </html>
    """

    @Test("TextLoader gives an .html source readable content: no tags, no attributes, no style")
    func htmlIngestHasNoMarkup() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("markup-ko-\(UUID().uuidString).html")
        try Data(cocoaHTML.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let ko = try await TextLoader().ingest(fileAt: url, type: .html)
        #expect(!ko.content.contains("<p"))
        #expect(!ko.content.contains("class="))
        #expect(!ko.content.contains("<span"))
        #expect(!ko.content.contains("Helvetica"))          // <style> body skipped
        #expect(!ko.content.contains("&amp;"))
        #expect(ko.content.contains("NTSB Identification: SEA03LA084"))
        // The sentence survives whole, on one line, despite the inline <span>.
        #expect(ko.content.contains(
            "On May 19, 2003, about 1330 Pacific daylight time, a Cessna 172N was substantially damaged & the pilot was not injured."))
    }

    @Test("Well-formed and malformed XML both become their element texts")
    @MainActor
    func xmlReadableText() {
        let good = "<?xml version=\"1.0\"?><case id=\"x\"><date>2003-05-19</date><note>a &lt; b</note></case>"
        #expect(TextLoader.readableMarkupText(decoded: good, data: Data(good.utf8), type: .xml) == "2003-05-19\na < b")
        let bad = "<case><date>2003-05-19</date><note>unclosed"
        let text = TextLoader.readableMarkupText(decoded: bad, data: Data(bad.utf8), type: .xml)
        #expect(!text.contains("<"))
        #expect(text.contains("2003-05-19"))
    }
}
