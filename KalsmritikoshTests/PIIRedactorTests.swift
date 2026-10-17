//
//  PIIRedactorTests.swift
//  KalsmritikoshTests
//
//  RED-001 — protected values are REMOVED from the underlying text (not just masked), so
//  they cannot be recovered by re-reading the output.
//

import Testing
@testable import Kalsmritikosh

@Suite("RED-001 PIIRedactor")
struct PIIRedactorTests {

    private let redactor = PIIRedactor()

    @Test("Emails, phones and custom terms are removed from the text")
    func removesPII() {
        let policy = RedactionPolicy(customTerms: ["Shirshendu Sasmal"])
        let res = redactor.redact("Contact Shirshendu Sasmal at sasmalgiri@gmail.com or 9960270472.", policy: policy)
        #expect(res.redactionCount == 3)
        #expect(res.isClean(of: ["Shirshendu Sasmal", "sasmalgiri@gmail.com", "9960270472"]))
        #expect(!res.redactedText.contains("@gmail.com"))
    }

    @Test("Disabled categories are not redacted")
    func respectsPolicy() {
        let policy = RedactionPolicy(redactEmails: false, redactPhones: false, customTerms: [])
        let res = redactor.redact("mail me at a@b.com", policy: policy)
        #expect(res.redactionCount == 0)
        #expect(res.redactedText.contains("a@b.com"))
    }

    @Test("Custom-term redaction is case-insensitive")
    func caseInsensitiveTerms() {
        let res = redactor.redact("SASMAL and sasmal and Sasmal", policy: RedactionPolicy(redactEmails: false, redactPhones: false, customTerms: ["sasmal"]))
        #expect(res.redactionCount == 3)
        #expect(!res.redactedText.lowercased().contains("sasmal"))
    }

    @Test("N1 — dates and year ranges are not phone numbers; the phone beside them still goes")
    func datesSurvivePhoneRedaction() {
        let phonesOnly = RedactionPolicy(redactEmails: false, redactPhones: true)
        let res = redactor.redact("Hearing on 2024-08-06, call +91 98765 43210.", policy: phonesOnly)
        #expect(res.redactedText.contains("2024-08-06"))
        #expect(!res.redactedText.contains("98765"))
        #expect(res.redactionCount == 1)
        for kept in ["06-08-2024", "2019 - 2024", "2019-2024", "2024-08-06 2024-08-07"] {
            let r = redactor.redact("Period \(kept) noted", policy: phonesOnly)
            #expect(r.redactedText.contains(kept), "\(kept) was treated as a phone")
            #expect(r.redactionCount == 0)
        }
        // A hyphenated phone is still a phone.
        #expect(redactor.redact("Ring 020-7946-0958 now", policy: phonesOnly).redactionCount == 1)
    }

    @Test("isClean detects a surviving protected value")
    func detectsLeak() {
        let res = PIIRedactor.Result(redactedText: "still has secret@x.com", redactionCount: 0, categories: [])
        #expect(!res.isClean(of: ["secret@x.com"]))
    }
}
