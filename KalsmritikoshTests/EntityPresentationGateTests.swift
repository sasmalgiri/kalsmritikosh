//
//  EntityPresentationGateTests.swift
//  KalsmritikoshTests
//
//  D-13 (P0 answer-quality pack) — presentation-only hygiene for the
//  "Subjects in scope" footer. Mail/infrastructure brand names (the
//  screenshot's "Gmail, Hxcore, Google, Smtpnet") stay in the LEDGER —
//  they are real strings from real headers — but never print as subjects.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("D-13 — entity presentation gate")
struct EntityPresentationGateTests {

    private func entity(_ value: String, kind: Entity.Kind = .organization) -> Entity {
        Entity(kind: kind, value: value, sourceObjectID: UUID(), confidence: .medium)
    }

    @Test("Mail/infra brands are filtered from presentation, humans and orgs survive")
    func screenshotList() {
        let gate = EntityQualityGate(stoplist: [])
        // The screenshot's footer, plus real subjects that must survive.
        let rejected = ["Gmail", "Google", "Smtpnet", "Outlook", "Yahoo",
                        "mailer-daemon", "Noreply", "IMAP01", "MX2"]
        for value in rejected {
            #expect(!gate.keepsForPresentation(entity(value)), "\(value) printed as a subject")
        }
        let kept = ["Orchid Chemicals Ltd", "Nila Instruments", "Maria Lopez", "Supplier ABC"]
        for value in kept {
            #expect(gate.keepsForPresentation(entity(value)), "\(value) wrongly filtered")
        }
    }

    @Test("Presentation filtering is STRICTER than ledger keeping — nothing is deleted")
    func presentationOnlyNotDeletion() {
        let gate = EntityQualityGate(stoplist: [])
        let gmail = entity("Gmail")
        // The ledger KEEPS it (shouldKeep true: brand-cased, letters only)…
        #expect(gate.shouldKeep(gmail))
        // …presentation does not print it.
        #expect(!gate.keepsForPresentation(gmail))
    }

    @Test("Host-fragment prefixes match only short technical suffixes")
    func prefixScope() {
        #expect(EntityQualityGate.isMailInfraName("smtpnet"))
        #expect(EntityQualityGate.isMailInfraName("pop3srv"))
        // A multi-word name sharing the letters survives.
        #expect(!EntityQualityGate.isMailInfraName("MX Global Logistics Ltd"))
    }
}
