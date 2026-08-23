//
//  FeedbackMailTests.swift
//  KalsmritikoshTests
//
//  The privacy-safe problem report: a mailto: draft the user fully sees — the
//  app sends nothing. Lock the URL shape and that no hidden data rides along.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("FeedbackMail")
struct FeedbackMailTests {

    @Test("Builds a well-formed mailto: to the published support address")
    func urlShape() throws {
        let url = try #require(FeedbackMail.reportProblemURL(appVersion: "1.0 (42)", osVersion: "macOS 15.6.0"))
        #expect(url.scheme == "mailto")
        let s = url.absoluteString
        #expect(s.contains(FeedbackMail.supportAddress))
        #expect(s.contains("subject="))
        #expect(s.contains("body="))
    }

    @Test("The draft carries ONLY the visible context — versions, no identifiers, no content")
    func draftIsClean() throws {
        let url = try #require(FeedbackMail.reportProblemURL(appVersion: "1.0 (42)", osVersion: "macOS 15.6.0"))
        let decoded = url.absoluteString.removingPercentEncoding ?? ""
        // What must be there (visible, deletable).
        #expect(decoded.contains("App version: 1.0 (42)"))
        #expect(decoded.contains("System: macOS 15.6.0"))
        #expect(decoded.contains("Kalsmritikosh itself sends nothing"))
        // What must NOT be there: anything resembling hidden identifiers.
        #expect(!decoded.lowercased().contains("uuid"))
        #expect(!decoded.lowercased().contains("serial"))
        #expect(!decoded.lowercased().contains("hardware"))
        #expect(!decoded.lowercased().contains("username"))
    }

    @Test("currentVersions reports plausible app + macOS strings")
    func versions() {
        let v = FeedbackMail.currentVersions()
        #expect(v.os.hasPrefix("macOS "))
        #expect(!v.app.isEmpty)
    }
}
