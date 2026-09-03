//
//  EmailDisplayNameSplitterTests.swift
//  KalsmritikoshTests
//
//  GO2R U0-b — the display-name splitter fixture, born from the owner's live
//  archive: the old angle-bracket regex could not see RFC 2822 list commas,
//  so To: lists yielded ", Akhilesh Sharma" person entities and quoted names
//  kept their quotes ("'Arindam Das'"). These are the witnessed strings; the
//  fates are stated. (titleShaped rejection — "… - Career" — is P3-U0's gate,
//  not this splitter: here it must simply come out CLEAN.)
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("U0-b — email display-name splitting (the owner's six strings)")
struct EmailDisplayNameSplitterTests {

    private func personValues(fromHeader header: String) -> [String] {
        EmailLoader.structuredEntities(
            from: ["from": header],
            sourceObjectID: UUID())
        .filter { $0.kind == .person }
        .map(\.value)
    }

    @Test("A To: list never yields a leading-comma person")
    func listCommasNeverLeak() {
        let values = personValues(
            fromHeader: "\"Das, Arindam\" <arindam.das@bajajfinserv.in>, Akhilesh Sharma <ak@example.com>, Guruditsingh Vadhwa <gavadhwa@gmail.com>")
        #expect(values.contains("Das, Arindam"), "quoted Last, First survives with its INTERNAL comma")
        #expect(values.contains("Akhilesh Sharma"))
        #expect(values.contains("Guruditsingh Vadhwa"))
        for v in values {
            #expect(!v.hasPrefix(","), "leading list comma leaked into '\(v)'")
            #expect(!v.hasPrefix("'") && !v.hasPrefix("\""), "quote leaked into '\(v)'")
        }
    }

    @Test("Single-quoted display names lose their quotes")
    func singleQuotesStripped() {
        let values = personValues(fromHeader: "'Arindam Das' <arindam.das@bajajfinserv.in>")
        #expect(values.contains("Arindam Das"), "got \(values)")
        #expect(!values.contains("'Arindam Das'"))
    }

    @Test("A job-portal sender comes out clean (its fate is P3-U0's gate)")
    func jobPortalSenderClean() {
        let values = personValues(fromHeader: "\"Auro Laboratories Ltd - Career\" <jobs@auro.example.com>")
        #expect(values.contains("Auro Laboratories Ltd - Career"), "got \(values)")
        for v in values { #expect(!v.hasPrefix(",") && !v.hasPrefix("\"")) }
    }

    @Test("Email addresses still extract alongside names")
    func addressesSurvive() {
        let entities = EmailLoader.structuredEntities(
            from: ["from": "\"Das, Arindam\" <arindam.das@bajajfinserv.in>, Akhilesh Sharma <ak@example.com>"],
            sourceObjectID: UUID())
        let addrs = entities.filter { $0.kind == .emailAddress }.map(\.value)
        #expect(addrs.contains("arindam.das@bajajfinserv.in"))
        #expect(addrs.contains("ak@example.com"))
    }
}
