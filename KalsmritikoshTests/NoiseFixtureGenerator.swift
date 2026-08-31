//
//  NoiseFixtureGenerator.swift
//  KalsmritikoshTests
//
//  V0 (C-3) — seeded, deterministic adversarial noise generator. Every
//  noise class the real archive has produced is expressed HERE, as a
//  generator method, never only as a one-off test document — the standing
//  rule: every real-data discovery is added to the generator.
//
//  All identifiers/names below are synthetic (never the owner's real data).
//

import Foundation
@testable import Kalsmritikosh

/// Deterministic builder of adversarial document variants around one
/// gold fact set. No randomness — "seeded" means the noise inventory is
/// versioned data, so a red is reproducible byte-for-byte.
struct NoiseFixtureGenerator {

    // Gold seed (synthetic).
    let patentNumber = "700321"
    let applicationNumber = "202398012345"
    let grantDateText = "17 June 2025"
    let filingDateText = "11 March 2023"
    let orgName = "Nila Instruments Pvt Ltd"

    /// V0 noise class 1+2+3+8: the same identifier under 3+ label spellings,
    /// one mislabel block (application number in patent position), a date in
    /// identifier position + slash-date adjacent to the label, and decoy
    /// density (many label mentions, one true value per field).
    var noisyGrantLetter: String {
        """
        # Intellectual Property Office — Letter of Grant

        In the matter of the application for patent filed by \(orgName),
        the patent is hereby granted and recorded in the Register of Patents.

        Application No. \(applicationNumber)
        Patent No. \(patentNumber)
        Patent No \(patentNumber)
        Patent Number \(patentNumber)
        Patent # \(patentNumber)
        Patent No : \(patentNumber)

        The patent number was allotted upon grant. The patent number appears
        on the certificate. Refer to the patent number in all correspondence
        about the patent number.

        Patent No. \(applicationNumber)
        Patent : 22/03/2023

        Date of Filing : \(filingDateText)
        Date of Grant : \(grantDateText)
        """
    }

    /// V0 noise class 4: OCR digit substitution (5→S, 0→O, 1→l) on the
    /// patent value.
    var ocrGrantLetter: String {
        let ocrValue = patentNumber
            .replacingOccurrences(of: "5", with: "S")
            .replacingOccurrences(of: "0", with: "O")
            .replacingOccurrences(of: "1", with: "l")
        return """
        # Intellectual Property Office — Letter of Grant (scanned copy)

        In the matter of the application for patent filed by \(orgName),
        the patent is hereby granted.

        Patent No. \(ocrValue)
        Date of Grant : \(grantDateText)
        """
    }

    /// V0 noise class 5: a page break splitting label from value.
    /// (Stays red until Train 3's C-4 cross-block assembly.)
    var pageBreakSplitLetter: String {
        """
        # Intellectual Property Office — Letter of Grant

        In the matter of the application for patent filed by \(orgName),
        the following particulars are recorded. Patent No.

        --- PAGE 2 ---

        \(patentNumber)
        Date of Grant : \(grantDateText)
        """
    }

    /// V0 noise class 6: a quoted reply restating the value with different
    /// spacing, plus the same value in a table cell and in prose.
    var quotedReplyWithTable: String {
        """
        Subject: RE: RE: Grant of patent

        Thanks — confirming receipt of the grant letter.

        | Field | Value |
        | Patent No. | \(patentNumber) |
        | Date of Grant | \(grantDateText) |

        As discussed, the granted patent number \(patentNumber) is now on record.

        > On 18 June 2025, the Office wrote:
        > Patent  No.   \(patentNumber)
        > Date of Grant : \(grantDateText)
        """
    }

    /// V0 entity-noise fixture (for V3's gate). First-run lesson recorded:
    /// prose attendee lists yield no entities — the LIVE noise ("Nil Nil",
    /// leading-punctuation names, emails-as-person, system-app senders)
    /// enters through EMAIL PARTICIPANT extraction, so the fixture is an
    /// .eml with junk participants, matching the archive's shape.
    var entityNoiseEmail: String {
        """
        From: Nil Nil <nil.nil@example.com>
        To: ", Shabana Khan" <s.khan@example.com>, priya.k@example.com
        Cc: File Processing Bot <bot@example.com>
        Subject: RESPONSE_TO_HEARING_\(applicationNumber)_29.08.2024.pdf
        Date: Mon, 15 Jul 2024 10:00:00 +0530
        Message-ID: <fixture-entity-noise@example.com>
        Content-Type: text/plain; charset=utf-8

        Please find attached the response document for \(orgName).
        """
    }

    /// Binding #2 (addenda §A) — the causal-explosion seed: N near-identical
    /// dated thread events within the discovery gap window, plus ONE pair
    /// carrying a lexical trigger ("due to") that must survive as CAUSED.
    /// Titles echo the real archive's shape: an email thread re-sending the
    /// same subject line for days.
    func threadEvents(count: Int, sourceObjectID: UUID, baseDate: Date) -> [Event] {
        precondition(count >= 4)
        var events: [Event] = []
        for i in 0..<count {
            let date = baseDate.addingTimeInterval(TimeInterval(i) * 6 * 3600) // 4/day
            events.append(Event(
                kind: .emailReceived,
                date: date,
                title: "RE: Response to hearing \(applicationNumber) — circulation \(i % 3)",
                sourceObjectID: sourceObjectID,
                confidence: .medium))
        }
        // The one TRUE causal pair, lexical trigger in the effect's title.
        events.append(Event(
            kind: .meetingHeld,
            date: baseDate.addingTimeInterval(TimeInterval(count) * 6 * 3600),
            title: "Hearing rescheduled due to the office objection",
            sourceObjectID: sourceObjectID,
            confidence: .high))
        return events
    }
}
