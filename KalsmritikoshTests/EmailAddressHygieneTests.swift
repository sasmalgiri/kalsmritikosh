//
//  EmailAddressHygieneTests.swift
//  KalsmritikoshTests
//
//  Every junk value here was observed in the OWNER'S LIVE LEDGER (audit
//  2026-09-22/23), and every "must survive" value is a real correspondent from
//  the same archive — so the guard is pinned against real data, not invented
//  shapes. Innocence cases matter most: over-rejecting a genuine address would
//  be a worse bug than the noise we're removing.
//

import Testing
import Foundation
@testable import Kalsmritikosh

struct EmailAddressHygieneTests {

    // MARK: - Machine-generated (observed junk)

    @Test("Message-ID / SMTP trace / content-ID addresses are rejected")
    func machineAddressesRejected() {
        let junk = [
            "4fa27c09.5c91cc0a.7f04.7fb6@mx.google.com",
            "55df0168.0b8a420a.48ce7.ffffda74SMTPIN_ADDED_BROKEN@mx.google.com",
            "CAPuxmJrhQe7SReGWdghBunk-kD_NBHxcqyD38ansEZAgMfG8Ag@mail.gmail.com",
            "ee0dc35d0707230906x6d844c8as3557b3b7f510f8ed@mail.gmail.com",
            "image001.png@01CE304B.FCDAA",
            "d534ed66-15ba-46e3-9c95-31cf4805ea5e@gmail.com",
            "mailer-daemon@googlemail.com",
            "1743326321.10701.1512317829367.JavaMail.pin@smtpnet.hathway.com"
        ]
        for address in junk {
            #expect(EmailAddressHygiene.isMachineGenerated(address),
                    "should be rejected: \(address)")
        }
    }

    @Test("Real correspondents from the live archive all survive (innocence)")
    func realAddressesSurvive() {
        let real = [
            "sasmalgiri@gmail.com",
            "vishu_rani2821@yahoo.com",
            "vijay@khuranaandkhurana.com",
            "shirshendu.sasmal@fresenius.com",
            "debarshi.samanta@fresenius-kabi.com",
            "pankajrana.ipo@gov.in",
            "kolkata-patent@nic.in",
            "hr.apssgcare@gmail.com",
            "parupalli.srihari@piramal.com",
            "ta@vodafone.com",                       // very short local part
            "Roshani.u@sequent.in",                  // mixed case, dotted
            "noreply@travian.in"                     // role address, still real
        ]
        for address in real {
            #expect(!EmailAddressHygiene.isMachineGenerated(address),
                    "wrongly rejected a real address: \(address)")
        }
    }

    @Test("A human mailbox on an infrastructure domain is kept")
    func humanOnMachineDomainKept() {
        #expect(!EmailAddressHygiene.isMachineGenerated("shirshendu@googlemail.com"))
        #expect(EmailAddressHygiene.isMachineGenerated("Nk8aNyumTTg5toXw@mail.gmail.com"))
    }

    // MARK: - Truncated variants (the live 7-way split)

    @Test("Suffix fragments of a longer address on the same domain are dropped")
    func truncatedVariantsCollapse() {
        // Exactly what the live ledger held for ONE real address.
        let observed = [
            "sasmalgiri@gmail.com",
            "asmalgiri@gmail.com", "smalgiri@gmail.com", "malgiri@gmail.com",
            "algiri@gmail.com", "lgiri@gmail.com", "iri@gmail.com"
        ]
        let kept = EmailAddressHygiene.dropTruncatedVariants(observed)
        #expect(kept == ["sasmalgiri@gmail.com"], "got \(kept)")
    }

    @Test("Fragments only collapse WITHIN a domain, never across domains")
    func collapseIsDomainScoped() {
        // `ta@vodafone.com` must survive even though `srihari...` is longer —
        // different domain, so no suffix relationship applies.
        let kept = EmailAddressHygiene.dropTruncatedVariants([
            "parupalli.srihari@piramal.com", "ta@vodafone.com", "hari@piramal.com"
        ])
        #expect(kept.contains("ta@vodafone.com"))
        #expect(kept.contains("parupalli.srihari@piramal.com"))
        // `hari@piramal.com` IS a suffix of `...srihari@piramal.com` → dropped.
        #expect(!kept.contains("hari@piramal.com"))
    }

    @Test("Two genuinely different addresses on one domain both survive")
    func distinctSameDomainSurvive() {
        let kept = EmailAddressHygiene.dropTruncatedVariants([
            "vijay@khuranaandkhurana.com", "smita@khuranaandkhurana.com",
            "lalan@khuranaandkhurana.com"
        ])
        #expect(kept.count == 3, "got \(kept)")
    }

    // MARK: - Combined pass

    @Test("clean() removes machine noise and fragments, keeping the real pair")
    func combinedClean() {
        let raw = [
            "sasmalgiri@gmail.com",
            "algiri@gmail.com",                                  // wrap fragment
            "vishu_rani2821@yahoo.com",
            "4fa27c09.5c91cc0a.7f04.7fb6@mx.google.com",         // Message-ID
            "image001.png@01CE304B.FCDAA"                        // inline image CID
        ]
        let kept = EmailAddressHygiene.clean(raw)
        #expect(Set(kept) == ["sasmalgiri@gmail.com", "vishu_rani2821@yahoo.com"], "got \(kept)")
    }

    @Test("clean() is order-stable and idempotent")
    func stableAndIdempotent() {
        let raw = ["b@x.com", "a@x.com", "zz@y.com"]
        let once = EmailAddressHygiene.clean(raw)
        #expect(once == raw)                               // nothing to drop, order kept
        #expect(EmailAddressHygiene.clean(once) == once)   // idempotent
    }
}
