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

    @Test("isClean detects a surviving protected value")
    func detectsLeak() {
        let res = PIIRedactor.Result(redactedText: "still has secret@x.com", redactionCount: 0, categories: [])
        #expect(!res.isClean(of: ["secret@x.com"]))
    }
}
