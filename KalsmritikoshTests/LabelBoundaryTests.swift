//
//  LabelBoundaryTests.swift
//  KalsmritikoshTests
//
//  THE PLURAL BUG. Found 2026-09-25 by asking the owner's real archive "How
//  many emails involve the data subject patent?" and reading the answer:
//
//    "The email is ambiguous across the evidence — the sources give different
//     values: • Timeline • sasmalgiri@gmail.com • s, indicating a significant
//     level of • s, indicating a high risk of phishing attacks. • s) • s that
//     would need to be addressed in an erasure request. • s (89.0%) • s …"
//
//  53 citations, confidence 0.33, not refused. Unreadable, and it did not
//  answer the question that was asked.
//
//  THREE compounding defects, each fixed and pinned here:
//
//   1. LABEL BOUNDARY (TypedFieldExtractor.labeledValue). The label "email"
//      matched inside the word "emailS" — the leading-boundary check passed
//      because a space preceded it, and there was NO trailing check — so the
//      remainder of the word plus the rest of the sentence became the value:
//      "s, indicating a significant level of". The same hole sat under every
//      label: "pan" in "panel", "name" in "names", "address" in "addresses".
//
//   2. SILENT FALLBACK (TypedFieldExtractor.refine). `firstMatch(...) ?? value`
//      meant a value containing NO email address was still stored AS an email
//      address. A typed field whose type cannot be verified is worse than a
//      missing one, because every reader downstream trusts the type.
//
//   3. AGGREGATE MISROUTE (IdentityFieldResolver.questionFieldType). A COUNT
//      question took the identity fast path, which exists to answer "what IS
//      the <field>". It then found several values and rendered them as
//      candidates — for a question that asked for a number.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Label boundaries, strict typed values, and aggregate routing")
struct LabelBoundaryTests {

    // MARK: - 1. The label must be a whole word

    @Test("A label must not match the prefix of a longer word")
    func labelNeedsATrailingBoundary() {
        // THE EXACT LINE from the owner's GDPR report that produced "• s".
        let real = "Total emails, indicating a significant level of exposure"
        #expect(TypedFieldExtractor.labeledValue(in: real, labels: ["email", "e-mail"]) == nil,
                "“emails” must not satisfy the label “email”")

        // Other plurals and embeddings that were equally exposed.
        #expect(TypedFieldExtractor.labeledValue(in: "The panel met on Tuesday", labels: ["pan"]) == nil)
        #expect(TypedFieldExtractor.labeledValue(in: "Their names are listed below", labels: ["name"]) == nil)
        #expect(TypedFieldExtractor.labeledValue(in: "Two addresses were found", labels: ["address"]) == nil)
        #expect(TypedFieldExtractor.labeledValue(in: "a tinted window", labels: ["tin"]) == nil)
    }

    @Test("A genuine labelled field still reads — the fix must not cost extraction")
    func genuineLabelsStillRead() {
        // Colon, the common case.
        #expect(TypedFieldExtractor.labeledValue(
            in: "Email: sasmalgiri@gmail.com", labels: ["email"]) == "sasmalgiri@gmail.com")
        // Space-separated, no colon.
        #expect(TypedFieldExtractor.labeledValue(
            in: "Email  sasmalgiri@gmail.com", labels: ["email"]) == "sasmalgiri@gmail.com")
        // Label on its own line, value on the next.
        #expect(TypedFieldExtractor.labeledValue(
            in: "Email\nsasmalgiri@gmail.com", labels: ["email"]) == "sasmalgiri@gmail.com")
        // Hyphenated label form.
        #expect(TypedFieldExtractor.labeledValue(
            in: "E-mail: a@b.com", labels: ["email", "e-mail"]) == "a@b.com")
        // A label ending in punctuation must survive the boundary rule.
        #expect(TypedFieldExtractor.labeledValue(
            in: "Passport No.: Z1234567", labels: ["passport no"]) == "Z1234567")
        #expect(TypedFieldExtractor.labeledValue(
            in: "Name: Shirshendu Sasmal", labels: ["name"]) == "Shirshendu Sasmal")
    }

    // MARK: - 2. A typed value must match its type, or be dropped

    @Test("An email field rejects text that is not an address")
    func emailRefinementIsStrict() {
        #expect(TypedFieldExtractor.refine(.email, "s, indicating a significant level of") == nil,
                "prose must NOT be storable as an email address")
        #expect(TypedFieldExtractor.refine(.email, "see attached") == nil)
        #expect(TypedFieldExtractor.refine(.email, "n/a") == nil)
        // A real address is still extracted, including out of surrounding text.
        #expect(TypedFieldExtractor.refine(.email, "sasmalgiri@gmail.com") == "sasmalgiri@gmail.com")
        #expect(TypedFieldExtractor.refine(.email, "write to a@b.com today") == "a@b.com")
    }

    @Test("A phone field rejects text that is not a number")
    func phoneRefinementIsStrict() {
        #expect(TypedFieldExtractor.refine(.phone, "call the front desk") == nil)
        #expect(TypedFieldExtractor.refine(.phone, "+91 98300 12345") != nil)
    }

    // MARK: - 3. A counting question is not a field lookup

    @Test("Aggregate questions do not take the identity fast path")
    func aggregateQuestionsDoNotRoute() {
        #expect(IdentityFieldResolver.questionFieldType(
            "How many emails involve the data subject patent?") == nil,
                "the measured misroute — a count question answered with field candidates")
        #expect(IdentityFieldResolver.questionFieldType("How many invoices are there?") == nil)
        #expect(IdentityFieldResolver.questionFieldType("List all phone numbers") == nil)
    }

    @Test("“emails” is not the email-address field, but “email” still is")
    func emailKeywordIsAWholeWord() {
        #expect(IdentityFieldResolver.questionFieldType("Which emails mention the roof?") == nil,
                "asking about messages is not asking for an address")
        // The legitimate phrasings must keep working.
        #expect(IdentityFieldResolver.questionFieldType("What is his email?") == .email)
        #expect(IdentityFieldResolver.questionFieldType("What is the email address?") == .email)
        #expect(IdentityFieldResolver.questionFieldType("Give me the e-mail on this form") == .email)
    }

    @Test("Other field routes are unaffected")
    func otherRoutesUnchanged() {
        #expect(IdentityFieldResolver.questionFieldType("What is the date of birth?") == .dateOfBirth)
        #expect(IdentityFieldResolver.questionFieldType("What is the passport number?") == .documentNumber)
        #expect(IdentityFieldResolver.questionFieldType("When does it expire?") == .expiryDate)
        #expect(IdentityFieldResolver.questionFieldType("What was the weather like?") == nil)
    }
}
