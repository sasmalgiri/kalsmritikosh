//
//  EmailHeaderAnswererTests.swift
//  KalsmritikoshTests
//
//  Closed-case simulation, Enron mailboxes, 2026-10-26: who sent the email "<subject>", when, to
//  whom, what it said; how many emails one person sent another — from the messages' own headers.
//

import Testing
import Foundation
@testable import Kalsmritikosh

@Suite("Email questions answered from the message headers")
struct EmailHeaderAnswererTests {

    static let one = """
        From: debra.perlingiere@enron.com
        To: russell.diamond@enron.com, jennifer.blay@enron.com
        Subject: Heartland Energy Group
        Date: Thu, 10 Aug 2000 06:21:00 -0700 (PDT)

        Please see the attached confirmation I will send out to re-confirm under the master agreement.
        """
    static let two = """
        From: debra.perlingiere@enron.com
        To: robin.masciangelo@enron.com
        Subject: Atmos Energy Corp.
        Date: Thu, 8 Nov 2001 09:00:00 -0800 (PST)

        Here is a redline and clean version of requested changes by Atmos.
        """
    static let three = """
        From: debra.perlingiere@enron.com
        To: robin.masciangelo@enron.com
        Subject: RE: Contract list
        Date: Fri, 9 Nov 2001 10:00:00 -0800 (PST)

        Robin, the list is attached.
        """
    let messages = [one, two, three].compactMap { EmailHeaderAnswerer.message(objectID: UUID(), text: $0) }

    func ask(_ q: String) throws -> VerifiedAnswer {
        let parsed = try #require(EmailHeaderAnswerer.parse(q))
        return try #require(EmailHeaderAnswerer.answer(parsed, messages: messages))
    }

    @Test("Sender, date, recipients and content of the email a subject names")
    func bySubject() throws {
        #expect(try ask("Who sent the email \"Heartland Energy Group\"?").body == "From: debra.perlingiere@enron.com")
        #expect(try ask("When was the email \"Heartland Energy Group\" sent?").body == "Date: Thu, 10 Aug 2000 06:21:00 -0700 (PDT)")
        #expect(try ask("Who received the email \"Heartland Energy Group\"?").body.contains("russell.diamond@enron.com"))
        #expect(try ask("What did the email \"Heartland Energy Group\" say?").body.contains("re-confirm under the master agreement"))
        // A reply's "RE:" is the same subject.
        #expect(try ask("Who sent the email \"Contract list\"?").body == "From: debra.perlingiere@enron.com")
        // "the email" names the message, not an address field.
        #expect(IdentityFieldResolver.questionFieldType("Who sent the email \"Heartland Energy Group\"?") == nil)
    }

    @Test("Claude-written rewordings of email questions parse to the same ask")
    func rewordings() {
        #expect(EmailHeaderAnswerer.parse("Who's the sender listed on \"Heartland Energy Group\"?") == .sender(subject: "Heartland Energy Group"))
        #expect(EmailHeaderAnswerer.parse("To whom was \"Heartland Energy Group\" addressed?") == .recipients(subject: "Heartland Energy Group"))
        #expect(EmailHeaderAnswerer.parse("What's the timestamp on the email \"Heartland Energy Group\"?") == .sentDate(subject: "Heartland Energy Group"))
        #expect(EmailHeaderAnswerer.parse("What was the content of the email \"Heartland Energy Group\"?") == .content(subject: "Heartland Energy Group"))
        #expect(EmailHeaderAnswerer.parse("How many times did Debra Perlingiere email Robin Masciangelo in total?") == nil
                || EmailHeaderAnswerer.parse("How many times did Debra Perlingiere email Robin Masciangelo?") == .count(from: "Debra Perlingiere", to: "Robin Masciangelo"))
        #expect(EmailHeaderAnswerer.parse("How many times did Debra Perlingiere email Robin Masciangelo?") == .count(from: "Debra Perlingiere", to: "Robin Masciangelo"))
        // The email's own Date header is its date, not "another event's".
        #expect(DateQuestionGate.hasPublicationAnchoredDate("Date: Thu, 10 Aug 2000 06:21:00 -0700 (PDT)"))
        // "content" names a part of every email, so it is never "not mentioned".
        #expect(AbsentAttributeGate.askedFor("What was the content of the email \"X\"?") == nil)
    }

    @Test("How many emails one person sent another; an email to someone never written to is unrecorded")
    func betweenPeople() throws {
        #expect(try ask("How many emails did Debra Perlingiere send to Robin Masciangelo?").body.hasPrefix("2 of the emails found are from Debra Perlingiere to Robin Masciangelo"))
        let none = try ask("When did Debra Perlingiere email Zelda Quackenbush?")
        #expect(none.refused)
        #expect(none.body == "None of the emails found from Debra Perlingiere is addressed to Zelda Quackenbush.")
        // A sender that is an organisation or an address, never found at all: said so.
        let org = try ask("When did EDIS Service email Zelda Quackenbush?")
        #expect(org.refused && org.body == "None of the emails found is from EDIS Service to Zelda Quackenbush.")
        // An unknown subject is left to the normal pipeline.
        let parsed = try #require(EmailHeaderAnswerer.parse("Who sent the email \"Nothing like this\"?"))
        #expect(EmailHeaderAnswerer.answer(parsed, messages: messages) == nil)
    }
}
