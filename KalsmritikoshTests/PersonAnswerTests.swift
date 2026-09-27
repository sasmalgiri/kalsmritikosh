//
//  PersonAnswerTests.swift
//  KalsmritikoshTests
//
//  L5 — person questions from the ledger's own person records.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("L5 — questions about a person")
struct PersonAnswerTests {

    @Test("Who-is questions yield the name; role questions and others do not")
    func names() {
        #expect(PersonAnswerComposer.personName(in: "Who is Gopinath and what did we discuss?") == "gopinath")
        #expect(PersonAnswerComposer.personName(in: "Tell me about Tarun Khurana") == "tarun khurana")
        #expect(PersonAnswerComposer.personName(in: "who is the applicant of the patent?") == nil)
        #expect(PersonAnswerComposer.personName(in: "What is the status?") == nil)
        #expect(PersonAnswerComposer.personName(in: "Who is 555489?") == nil)
    }

    @Test("Own-jobs questions need first person AND a job word")
    func ownJobs() {
        #expect(PersonAnswerComposer.asksOwnJobs("What jobs have I held and at which companies?"))
        #expect(PersonAnswerComposer.asksOwnJobs("Where have I worked?"))
        #expect(!PersonAnswerComposer.asksOwnJobs("Which companies applied for the tender?"))
        #expect(!PersonAnswerComposer.asksOwnJobs("What did I pay Khurana?"))
    }

    @Test("Who-is: the address carrying the name most, its roles, span and subjects — cited, oldest first")
    func whoIs() throws {
        let a = UUID(), b = UUID(), c = UUID()
        func ev(_ ko: UUID, _ t: String, _ secs: Double) -> Event {
            Event(kind: .emailReceived, date: Date(timeIntervalSince1970: secs), title: t, sourceObjectID: ko, dateConfidence: 0.95)
        }
        let rows = [
            PersonAnswerComposer.Correspondence(address: "gopinath@iiprd.com", displayName: "Gopinath D", sourceObjectID: a, role: "from"),
            PersonAnswerComposer.Correspondence(address: "gopinath@iiprd.com", displayName: "Gopinath D", sourceObjectID: b, role: "to"),
            PersonAnswerComposer.Correspondence(address: "gopinath@iiprd.com", displayName: "Gopinath D", sourceObjectID: c, role: "cc"),
            PersonAnswerComposer.Correspondence(address: "gopi.k@other.com", displayName: nil, sourceObjectID: c, role: "cc"),
        ]
        let out = try #require(PersonAnswerComposer.composeWhoIs(name: "gopinath", rows: rows, emailEvents: [
            ev(b, "Word copy of the specification", 1_700_000_000), ev(a, "Patent requirement", 1_697_000_000),
            ev(c, "Word copy of the specification", 1_700_100_000)]))
        #expect(out.primaryText.hasPrefix("Gopinath D <gopinath@iiprd.com> — iiprd.com — appears in 3 emails (sent 1, received or copied 2)"))
        let lines = out.primaryText.components(separatedBy: "\n")
        #expect(lines.contains { $0.hasSuffix("— Patent requirement") })
        #expect(out.primaryText.components(separatedBy: "Word copy of the specification").count == 2, "one line per subject")
        #expect(out.supportingEvents.count == 2)
    }

    @Test("Own jobs: label residue stripped, bare suffixes dropped, duplicates merged")
    func jobs() throws {
        func fact(_ field: String, _ value: String) -> GenericFact {
            GenericFact(subjectLabel: "Shirshendu Sasmal", field: field, value: value,
                        assessment: EvidenceAssessment(basis: .sourceAsserted, origin: .sourceExtraction),
                        confidence: 0.8, sourceBlockIDs: [UUID()])
        }
        let out = try #require(PersonAnswerComposer.composeOwnJobs(ownerLabel: "Shirshendu Sasmal", facts: [
            fact("employer", "Current Organization  Hospira India Pvt. Ltd"), fact("employer", "Hospira India Pvt. Ltd"),
            fact("employer", "Pvt. Ltd"), fact("role", "Production Executive")]))
        #expect(out.text.contains("Employers: Hospira India Pvt. Ltd"))
        #expect(!out.text.contains("Current Organization"))
        #expect(!out.text.contains(" · Pvt. Ltd"))
        #expect(out.text.contains("Roles: Production Executive"))
        #expect(PersonAnswerComposer.composeOwnJobs(ownerLabel: "x", facts: [fact("employer", "Ltd")]) == nil)
    }
}
