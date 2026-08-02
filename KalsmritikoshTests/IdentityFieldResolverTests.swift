//
//  IdentityFieldResolverTests.swift
//  KalsmritikoshTests
//
//  MMI-FINAL — the deterministic identity resolver: map an identity/document question to its
//  field type, then answer from located values — one dominant value → answer, several distinct
//  → candidates (never a guess), none above the floor → not found. Synthetic only.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("MMI-FINAL — identity field resolver")
struct IdentityFieldResolverTests {

    private func field(_ type: TypedFieldType, _ value: String, conf: Double) -> TypedField {
        TypedField(sourceVersionID: UUID(), evidenceBlockID: UUID(), fieldType: type, rawValue: value,
                   normalizedValue: value.lowercased(), confidence: conf, extractionMethod: .native,
                   locator: SourceLocator(page: 1), producerID: "mmi.typed-field", producerVersion: "1")
    }

    @Test("Name questions map to personName")
    func nameMapping() {
        #expect(IdentityFieldResolver.questionFieldType("What is the name in this document?") == .personName)
        #expect(IdentityFieldResolver.questionFieldType("Who is this document for?") == .personName)
        #expect(IdentityFieldResolver.questionFieldType("whose name is on this?") == .personName)
    }

    @Test("Document-number questions map to documentNumber")
    func documentNumberMapping() {
        #expect(IdentityFieldResolver.questionFieldType("What is the document number?") == .documentNumber)
        #expect(IdentityFieldResolver.questionFieldType("What is the passport number?") == .documentNumber)
    }

    @Test("Date questions map to their specific date field")
    func dateMapping() {
        #expect(IdentityFieldResolver.questionFieldType("What is the date of issue?") == .issueDate)
        #expect(IdentityFieldResolver.questionFieldType("What is the expiry date?") == .expiryDate)
        #expect(IdentityFieldResolver.questionFieldType("What is the date of birth?") == .dateOfBirth)
    }

    @Test("Email and phone questions map correctly")
    func emailPhoneMapping() {
        #expect(IdentityFieldResolver.questionFieldType("What is the email address?") == .email)
        #expect(IdentityFieldResolver.questionFieldType("What is the phone number?") == .phone)
    }

    @Test("A non-identity question maps to nil")
    func nonIdentityNil() {
        #expect(IdentityFieldResolver.questionFieldType("Why did the project fail?") == nil)
        #expect(IdentityFieldResolver.questionFieldType("Compare payments and complaints") == nil)
    }

    @Test("One dominant located value resolves to a deterministic answer")
    func singleAnswer() {
        let r = IdentityFieldResolver().resolve(fieldType: .personName, fields: [field(.personName, "Jane Roe", conf: 0.9)])
        guard case .answer(let f) = r else { Issue.record("expected answer"); return }
        #expect(f.normalizedValue == "jane roe")
    }

    @Test("Several distinct located values resolve to candidates, not a guess")
    func ambiguousCandidates() {
        let r = IdentityFieldResolver().resolve(fieldType: .personName,
            fields: [field(.personName, "Jane Roe", conf: 0.9), field(.personName, "John Roe", conf: 0.85)])
        guard case .ambiguous(let cands) = r else { Issue.record("expected ambiguous"); return }
        #expect(cands.count == 2)
    }

    @Test("Values below the confidence floor resolve to not found")
    func belowFloorNotFound() {
        let r = IdentityFieldResolver().resolve(fieldType: .personName, fields: [field(.personName, "Maybe Name", conf: 0.4)])
        #expect(r == .notFound)
    }

    @Test("Repeated identical values are a single answer, not a conflict")
    func dedupSameValue() {
        let r = IdentityFieldResolver().resolve(fieldType: .email,
            fields: [field(.email, "a@b.co", conf: 0.9), field(.email, "A@B.CO", conf: 0.8)])
        // Both normalize to the same value → one answer.
        guard case .answer = r else { Issue.record("expected answer"); return }
    }

    @Test("The highest-confidence field represents the answer")
    func highestConfidenceAnswer() {
        let r = IdentityFieldResolver().resolve(fieldType: .documentNumber,
            fields: [field(.documentNumber, "X1", conf: 0.6), field(.documentNumber, "X1", conf: 0.95)])
        guard case .answer(let f) = r else { Issue.record("expected answer"); return }
        #expect(f.confidence == 0.95)
    }

    @Test("An empty field set resolves to not found")
    func emptyNotFound() {
        #expect(IdentityFieldResolver().resolve(fieldType: .personName, fields: []) == .notFound)
    }

    @Test("Each distinct candidate value gets exactly one representative")
    func candidateRepresentatives() {
        let r = IdentityFieldResolver().resolve(fieldType: .personName, fields: [
            field(.personName, "Jane Roe", conf: 0.9), field(.personName, "Jane Roe", conf: 0.7),
            field(.personName, "John Roe", conf: 0.85)])
        guard case .ambiguous(let cands) = r else { Issue.record("expected ambiguous"); return }
        #expect(cands.count == 2)                       // two distinct values, one rep each
        #expect(cands.map(\.normalizedValue).sorted() == ["jane roe", "john roe"])
    }
}
