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

    @Test("Folded subjects, normalised count shapes, and a subject no email has")
    func moreShapes() throws {
        let folded = "From: a.b@enron.com\nTo: c.d@enron.com\nSubject: OnePass Member continental.com Specials\n for Jane Tholt\nDate: Tue, 1 May 2001 10:00:00 -0700\n\nHello."
        let m = try #require(EmailHeaderAnswerer.message(objectID: UUID(), text: folded))
        #expect(m.subject == "OnePass Member continental.com Specials for Jane Tholt")
        #expect(EmailHeaderAnswerer.parse("How many emails Mary Miller sent to Bill Rapp?") == .count(from: "Mary Miller", to: "Bill Rapp"))
        #expect(EmailHeaderAnswerer.parse("When Matt Smith sent an email to Zelda Quackenbush?") == .when(from: "Matt Smith", to: "Zelda Quackenbush"))
        #expect(EmailHeaderAnswerer.parse("I'd like to know the total number of emails that went from Public Relations to All Worldwide — can you provide that?") == .count(from: "Public Relations", to: "All Worldwide"))
        #expect(EmailHeaderAnswerer.parse("I need a count of the emails sent from Exchange Administrator to Kevin Hyatt — how many were there?") == .count(from: "Exchange Administrator", to: "Kevin Hyatt"))
        #expect(EmailHeaderAnswerer.parse("How many total emails went from Enron Announcements to All Houston?") == .count(from: "Enron Announcements", to: "All Houston"))
        #expect(EmailHeaderAnswerer.parse("Do you have a count of how many emails Carol Clair sent to Suzanne Adams?") == .count(from: "Carol Clair", to: "Suzanne Adams"))
        #expect(EmailHeaderAnswerer.parse("How many times did Schedule Crawler email Pete Davis, total?") == .count(from: "Schedule Crawler", to: "Pete Davis"))
        let none = try #require(EmailHeaderAnswerer.answer(.sender(subject: "Nothing like this"), messages: messages))
        #expect(none.refused && none.body == "None of the emails found has the subject “Nothing like this”.")
        #expect(IdentityFieldResolver.questionFieldType("To whom was \"X\" addressed?") == nil)
        #expect(AbsentAttributeGate.askedFor("What exactly did the email \"X\" state?") == nil)
    }

    @Test("How many emails one person sent another; an email to someone never written to is unrecorded")
    func betweenPeople() throws {
        #expect(try ask("How many emails did Debra Perlingiere send to Robin Masciangelo?").body.hasPrefix("2 of the emails found are from Debra Perlingiere to Robin Masciangelo"))
        // A lookup that stopped at its cap gives a floor, never a total.
        let capped = try #require(EmailHeaderAnswerer.answer(.count(from: "Debra Perlingiere", to: "Robin Masciangelo"), messages: messages, complete: false))
        #expect(capped.body.hasPrefix("At least 2 of the emails found") && capped.body.contains("there may be more"))
        let none = try ask("When did Debra Perlingiere email Zelda Quackenbush?")
        #expect(none.refused)
        #expect(none.body == "None of the emails found from Debra Perlingiere is addressed to Zelda Quackenbush.")
        // A sender that is an organisation or an address, never found at all: said so.
        let org = try ask("When did EDIS Service email Zelda Quackenbush?")
        #expect(org.refused && org.body == "None of the emails found is from EDIS Service to Zelda Quackenbush.")
        // An address sender, asked for a date, parses — and an address never written to is refused.
        let n = QuestionCanonicalizer.normalize
        #expect(EmailHeaderAnswerer.parse(n("On what date did feedback@intcx.com send an email to Zelda Quackenbush?")) == .when(from: "feedback@intcx.com", to: "Zelda Quackenbush"))
        #expect(EmailHeaderAnswerer.parse(n("Do you know the date feedback@intcx.com sent an email to Zelda Quackenbush?")) == .when(from: "feedback@intcx.com", to: "Zelda Quackenbush"))
        let addr = try ask("On what date did debra.perlingiere@enron.com send an email to Zelda Quackenbush?")
        #expect(addr.refused)
        // A header that holds only an address ("From: m.miller@…") is still from Mary Miller when the
        // ledger's participant index matched the display name.
        let bare = try #require(EmailHeaderAnswerer.message(objectID: UUID(), text: "From: m.miller@enron.com\nTo: b.rapp@enron.com\nSubject: Survey\nDate: Tue, 15 May 2001 16:50:00 -0700\n\nSee attached."))
        #expect(EmailHeaderAnswerer.answer(.count(from: "Mary Miller", to: "Bill Rapp"), messages: [bare]) == nil)   // header alone: unknown
        let matched = try #require(EmailHeaderAnswerer.answer(.count(from: "Mary Miller", to: "Bill Rapp"), messages: [bare], ledgerPairs: [bare.objectID]))
        #expect(matched.body.hasPrefix("1 of the emails found are from Mary Miller to Bill Rapp"))
        // "Do we know …" / "Do you have a record of …" are wrappers, not yes/no questions (an email's
        // date came back as "No — the documents give date: …").
        #expect(n("Do we know the date/time the email \"Past Due Invoice\" went out?") == "The date/time the email \"Past Due Invoice\" went out?")
        #expect(n("Do you have a record of when the email \"ENA Group Expenses\" was sent?") == "When the email \"ENA Group Expenses\" was sent?")
        #expect(EmailHeaderAnswerer.parse(n("Do we know the date/time the email \"Past Due Invoice\" went out?")) == .sentDate(subject: "Past Due Invoice"))
        // A yes/no about whether a record exists keeps its shape.
        #expect(n("Do we have any record of a meeting with Bill Rapp?") == "Do we have any record of a meeting with Bill Rapp?")
        // Record answers are stamped so the yes/no and other shape gates leave them alone.
        #expect(try ask("When was the email \"Heartland Energy Group\" sent?").intentKind == VerifiedAnswer.recordAnswerKind)
        #expect(EmailHeaderAnswerer.parse("Do you have the send date for the email \"Heartland Energy Group\"?") == .sentDate(subject: "Heartland Energy Group"))
        #expect(EmailHeaderAnswerer.parse(n("Can you tell me when navigator@nisource.com emailed Zelda Quackenbush?")) == .when(from: "navigator@nisource.com", to: "Zelda Quackenbush"))
        #expect(EmailHeaderAnswerer.parse(n("I'm looking for the date that noreply@ccomad3.uu.commissioner.com emailed Zelda Quackenbush — do you have that?")) == .when(from: "noreply@ccomad3.uu.commissioner.com", to: "Zelda Quackenbush"))
        // The subject-first actor/person doors leave these questions to the dedicated answerers.
        #expect(AppState.ownedByDedicatedAnswerer("Who's the sender listed on the email \"Azalea Trail\"?"))
        #expect(AppState.ownedByDedicatedAnswerer("Could you specify the sentence that Christi Machala received?"))
        #expect(!AppState.ownedByDedicatedAnswerer("Who filed the trademark renewal?"))
        // With no emails searched, an unknown subject is left to the normal pipeline.
        let parsed = try #require(EmailHeaderAnswerer.parse("Who sent the email \"Nothing like this\"?"))
        #expect(EmailHeaderAnswerer.answer(parsed, messages: []) == nil)
    }
}
