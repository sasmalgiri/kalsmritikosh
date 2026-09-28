//
//  PhoneContextTests.swift
//  KalsmritikoshTests
//
//  P1.6 — a bare digit run is undecidable by shape; the text around it
//  decides. Labelled → a phone; unlabelled → a record id, retired (reversibly).
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("P1.6 — a phone is decided by its label, not its shape")
struct PhoneContextTests {

    @Test("Labelled runs are phones — including list continuations after a label")
    func labelled() {
        for text in ["Mob: 9830012345", "Phone No. 9830012345", "Tel 033 24001234 or tel:9830012345",
                     "Contact - 9830012345", "M: 9830012345", "WhatsApp 9830012345",
                     "Phone: 9830067890, 9830012345"] {
            #expect(EntityQualityGate.phoneLabelPrecedes("9830012345", in: text), "\(text)")
        }
    }

    @Test("Unlabelled or embedded runs are not phones")
    func unlabelled() {
        #expect(!EntityQualityGate.phoneLabelPrecedes("785718091", in: "Ref 785718091 dated 3 May"))
        #expect(!EntityQualityGate.phoneLabelPrecedes("785718091", in: "Account 785718091 credited"))
        #expect(!EntityQualityGate.phoneLabelPrecedes("785718091", in: "Mob: 17857180912"),
                "a run inside a longer number is not that run")
        #expect(!EntityQualityGate.phoneLabelPrecedes("785718091", in: "The mobile app sent order 785718091"),
                "a label word far from the number, with words between, does not introduce it")
    }

    @Test("Only digit-only values are subject to the context rule")
    func bareShape() {
        #expect(EntityQualityGate.isBareDigitRun("785718091"))
        #expect(!EntityQualityGate.isBareDigitRun("+91 98300 12345"))
        #expect(!EntityQualityGate.isBareDigitRun("08451-287508"))
    }
}
