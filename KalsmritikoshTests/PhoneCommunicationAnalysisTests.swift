//
//  PhoneCommunicationAnalysisTests.swift
//  KalsmritikoshTests
//
//  G3 — the pure call & message analysis over phone/chat message rows: contact
//  pairs, per-party totals with missed calls and call seconds, monthly volume,
//  and the honest coverage count of rows that cannot be analysed.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Call & message analysis (G3)")
struct PhoneCommunicationAnalysisTests {

    private let ids = (0..<6).map { _ in UUID() }

    private var rows: [PhoneRecordRow] {
        [
            // Answered incoming call Dave → owner, 2:05.
            PhoneRecordRow(blockID: ids[0], platform: "Cellebrite UFDR", recordID: "calls#c1",
                           authorID: "+1 555-0100", authorHandle: "Dave", recipients: ["+15550999"],
                           direction: "incoming", durationSeconds: 125, callStatus: "Established",
                           timestamp: "2019-03-14T11:00:00Z"),
            // Missed call, same pair.
            PhoneRecordRow(blockID: ids[1], platform: "Cellebrite UFDR", recordID: "calls#c2",
                           authorID: "+1 555-0100", authorHandle: "Dave", recipients: ["+15550999"],
                           direction: "incoming", durationSeconds: 0, callStatus: "Missed",
                           timestamp: "2019-03-20T08:00:00Z"),
            // Owner texts Dave; Dave's number spelled differently — normalised to the same party.
            PhoneRecordRow(blockID: ids[2], platform: "Cellebrite UFDR", recordID: "sms:Messages:+15550100#s1",
                           authorID: "+15550999", recipients: ["+1 (555) 0100"], direction: "outgoing",
                           timestamp: "2019-04-02T10:00:00Z"),
            // Read before party facts existed: counted, not analysed.
            PhoneRecordRow(blockID: ids[3], platform: "Cellebrite UFDR", recordID: "chat:x#m1",
                           authorID: "15550001@s.whatsapp.net", authorHandle: "Alice",
                           timestamp: "2019-04-05T09:00:00Z"),
            // Names only the sender.
            PhoneRecordRow(blockID: ids[4], platform: "Cellebrite UFDR", recordID: "sms:Messages:+15550003#s2",
                           authorID: "+15550003", authorHandle: "Carol", direction: "incoming",
                           timestamp: "2019-04-06T09:00:00Z"),
            // The first call again, reached through a second copy of the report.
            PhoneRecordRow(blockID: ids[5], platform: "Cellebrite UFDR", recordID: "calls#c1",
                           authorID: "+1 555-0100", authorHandle: "Dave", recipients: ["+15550999"],
                           direction: "incoming", durationSeconds: 125, callStatus: "Established",
                           timestamp: "2019-03-14T11:00:00Z")
        ]
    }

    @Test("Pairs: calls, messages, call seconds, first/last contact and a sample block")
    func pairs() throws {
        let report = PhoneCommunicationAnalysis.analyse(rows)
        #expect(report.pairs.count == 1)
        let pair = try #require(report.pairs.first)
        #expect(pair.partyA == "+15550100")
        #expect(pair.partyB == "+15550999")
        #expect(pair.calls == 2)
        #expect(pair.messages == 1)
        #expect(pair.contacts == 3)
        #expect(pair.callSeconds == 125)
        #expect(pair.firstContact == PhoneCommunicationAnalysis.parseTimestamp("2019-03-14T11:00:00Z"))
        #expect(pair.lastContact == PhoneCommunicationAnalysis.parseTimestamp("2019-04-02T10:00:00Z"))
        #expect(pair.sampleBlockID == ids[0])
        #expect(report.names["+15550100"] == "Dave")
    }

    @Test("Per-party totals include missed calls and one-sided records")
    func partyTotals() throws {
        let report = PhoneCommunicationAnalysis.analyse(rows)
        let dave = try #require(report.parties.first { $0.party == "+15550100" })
        #expect(dave.calls == 2)
        #expect(dave.missedCalls == 1)
        #expect(dave.messages == 1)
        #expect(dave.callSeconds == 125)
        let owner = try #require(report.parties.first { $0.party == "+15550999" })
        #expect(owner.calls == 2 && owner.missedCalls == 1 && owner.messages == 1)
        let carol = try #require(report.parties.first { $0.party == "+15550003" })
        #expect(carol.messages == 1 && carol.calls == 0)
        // The row without party facts names nobody in the totals.
        #expect(!report.parties.contains { $0.party.contains("whatsapp") })
    }

    @Test("Monthly volume splits calls from messages; every dated record counts")
    func monthly() {
        let report = PhoneCommunicationAnalysis.analyse(rows)
        #expect(report.monthly == [
            PhoneMonthVolume(month: "2019-03", calls: 2, messages: 0),
            PhoneMonthVolume(month: "2019-04", calls: 0, messages: 3)
        ])
    }

    @Test("Coverage: records without party data and one-sided records are counted, duplicates once")
    func coverage() {
        let report = PhoneCommunicationAnalysis.analyse(rows)
        #expect(report.totalRecords == 5)
        #expect(report.pairedRecords == 3)
        #expect(report.withoutPartyData == 1)
        #expect(report.oneSided == 1)
        #expect(report.coverageLine.contains("re-read the phone reports to analyse these"))
        #expect(report.coverageLine.contains("3 of 5"))
    }

    @Test("Party normalisation strips spacing only; country codes and handles are untouched")
    func normalisation() {
        #expect(PhoneCommunicationAnalysis.normalizeParty(" +1 (555) 010-0100 ") == "+15550100100")
        #expect(PhoneCommunicationAnalysis.normalizeParty("0555 0100") == "05550100")
        #expect(PhoneCommunicationAnalysis.normalizeParty("Bob Lee") == "Bob Lee")
        #expect(PhoneCommunicationAnalysis.normalizeParty("15550001@s.whatsapp.net") == "15550001@s.whatsapp.net")
        #expect(PhoneCommunicationAnalysis.normalizeParty("1-2") == "1-2")
    }
}
