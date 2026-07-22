//
//  DocumentRoleTests.swift
//  KalsmritikoshTests
//
//  SEM-001 — a document's semantic role is independent of its file type, and the coarse
//  retrieval bucket is derived from it.
//

import Testing
@testable import Kalsmritikosh

@Suite("SEM-001 DocumentRole")
struct DocumentRoleTests {

    @Test("An image can be a payment receipt (role != file type)")
    func imageCanBeReceipt() {
        let roles = DocumentRoleClassifier.classify(
            fileName: "TransactionReceipt.jpeg", sourceType: .jpg,
            presentFields: [.monetaryAmount, .counterparty])
        #expect(roles.contains(.paymentReceipt))
        #expect(roles.first?.preferredSourceRole == .transactional)
    }

    @Test("A .doc résumé classifies as resume → biographical")
    func docResume() {
        let roles = DocumentRoleClassifier.classify(fileName: "Resume.doc", sourceType: .doc, presentFields: [.employment])
        #expect(roles.contains(.resume))
        #expect(roles.first?.preferredSourceRole == .biographical)
    }

    @Test("Email family is always correspondence regardless of quoted content")
    func emailCorrespondence() {
        let roles = DocumentRoleClassifier.classify(fileName: "Resume forwarded.eml", sourceType: .eml, presentFields: [.employment])
        #expect(roles == [.correspondence])
    }

    @Test("Every DocumentRole maps to a coarse retrieval bucket")
    func mappingTotal() {
        for role in DocumentRole.allCases {
            _ = role.preferredSourceRole // must not trap
        }
        #expect(DocumentRole.patentGrant.preferredSourceRole == .official)
        #expect(DocumentRole.contract.preferredSourceRole == .contractual)
    }
}
