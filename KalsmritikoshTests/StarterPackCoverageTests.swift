//
//  StarterPackCoverageTests.swift
//  KalsmritikoshTests
//
//  Starter packs — persona coverage. Two guarantees:
//   1. Each new pack EXTRACTS its domain's headline fields from a
//      representative document.
//   2. Each new pack stays SILENT on out-of-domain text (the marker gate),
//      so it can never perturb another domain's answers or the seal.
//   3. Every named persona's document type has at least one pack.
//  All pure, fast tier.
//

import Testing
import Foundation
@testable import Kalsmritikosh

@Suite("Starter packs — persona coverage")
struct StarterPackCoverageTests {

    private func fields(_ facts: [GenericFact]) -> Set<String> {
        Set(facts.map { FactSchemaRegistry.normalizeField($0.field) })
    }

    // — 1. each pack extracts its headline fields —

    @Test func medicalExtractsFromAHealthRecord() {
        let text = """
        Discharge Summary
        Patient: Ananya Gupta
        Physician: Dr. Rajesh Menon
        Diagnosis: Type 2 diabetes mellitus
        Medication: Metformin 500 mg twice daily
        Date of visit: 12/03/2024
        """
        let f = fields(MedicalDomainPack.extractFacts(fromText: text, subjectLabel: "s", blockID: UUID()))
        #expect(f.contains("patient"))
        #expect(f.contains("diagnosis"))
        #expect(f.contains("visitdate"))
    }

    @Test func legalCaseExtractsFromACourtDocument() {
        let text = """
        In the Court of the District Judge
        Case No: CS/1234/2023
        Plaintiff: Ramesh Chandra
        Defendant: Acme Industries
        The matter is listed for hearing on 05/06/2024.
        """
        let f = fields(LegalCaseDomainPack.extractFacts(fromText: text, subjectLabel: "s", blockID: UUID()))
        #expect(f.contains("casenumber"))
        #expect(f.contains("plaintiff"))
        #expect(f.contains("hearingdate"))
    }

    @Test func vitalRecordsExtractsFromABirthCertificate() {
        let text = """
        Certificate of Birth
        Name: Meera Nair
        Date of birth: 14/08/1990
        Place of birth: Kochi
        Father's name: Suresh Nair
        Mother's name: Lakshmi Nair
        """
        let f = fields(VitalRecordsDomainPack.extractFacts(fromText: text, subjectLabel: "s", blockID: UUID()))
        #expect(f.contains("birthdate"))
        #expect(f.contains("father"))
        #expect(f.contains("mother"))
    }

    @Test func financialStatementExtractsFromABankStatement() {
        let text = """
        Account Statement
        Account holder: Vikram Singh
        Account number: 001234567890
        Statement period: 01/04/2024 to 30/04/2024
        Closing balance: ₹1,45,320.50
        """
        let f = fields(FinancialStatementDomainPack.extractFacts(fromText: text, subjectLabel: "s", blockID: UUID()))
        #expect(f.contains("accountnumber"))
        #expect(f.contains("balance"))
    }

    @Test func propertyExtractsFromASaleDeed() {
        let text = """
        Sale Deed
        Property situated at: 42 MG Road, Bengaluru
        Vendor: Prakash Rao
        Purchaser: Sunita Desai
        Consideration: ₹85,00,000
        Executed on 20/01/2023.
        """
        let f = fields(PropertyDomainPack.extractFacts(fromText: text, subjectLabel: "s", blockID: UUID()))
        #expect(f.contains("seller"))
        #expect(f.contains("buyer"))
        #expect(f.contains("consideration"))
    }

    @Test func identityExtractsFromAPassport() {
        let text = """
        Republic of India — Passport
        Passport No: M1234567
        Name: Arjun Kapoor
        Date of issue: 10/02/2019
        Date of expiry: 09/02/2029
        Issuing Authority: Ministry of External Affairs
        """
        let f = fields(IdentityDocumentDomainPack.extractFacts(fromText: text, subjectLabel: "s", blockID: UUID()))
        #expect(f.contains("documenttype"))
        #expect(f.contains("idnumber"))
        #expect(f.contains("expirydate"))
    }

    // — 2. silence on out-of-domain text (protects the seal) —

    @Test func newPacksStaySilentOnPatentText() {
        let patent = "Patent No. 202331019665 granted to Shirshendu Sasmal on 28 November 2024."
        for facts in [
            MedicalDomainPack.extractFacts(fromText: patent, subjectLabel: "s", blockID: UUID()),
            LegalCaseDomainPack.extractFacts(fromText: patent, subjectLabel: "s", blockID: UUID()),
            VitalRecordsDomainPack.extractFacts(fromText: patent, subjectLabel: "s", blockID: UUID()),
            FinancialStatementDomainPack.extractFacts(fromText: patent, subjectLabel: "s", blockID: UUID()),
            PropertyDomainPack.extractFacts(fromText: patent, subjectLabel: "s", blockID: UUID()),
            IdentityDocumentDomainPack.extractFacts(fromText: patent, subjectLabel: "s", blockID: UUID()),
        ] {
            #expect(facts.isEmpty, "a starter pack fired on patent text — seal risk")
        }
    }

    @Test func newPacksStaySilentOnPlainEmail() {
        let email = "Hi, please find attached the minutes from Tuesday's meeting. Regards, Sam."
        for facts in [
            MedicalDomainPack.extractFacts(fromText: email, subjectLabel: "s", blockID: UUID()),
            LegalCaseDomainPack.extractFacts(fromText: email, subjectLabel: "s", blockID: UUID()),
            VitalRecordsDomainPack.extractFacts(fromText: email, subjectLabel: "s", blockID: UUID()),
            FinancialStatementDomainPack.extractFacts(fromText: email, subjectLabel: "s", blockID: UUID()),
            PropertyDomainPack.extractFacts(fromText: email, subjectLabel: "s", blockID: UUID()),
            IdentityDocumentDomainPack.extractFacts(fromText: email, subjectLabel: "s", blockID: UUID()),
        ] {
            #expect(facts.isEmpty, "a starter pack fired on a plain email")
        }
    }

    // — 3. every field the new packs emit is a known field —

    @Test func everyStarterFieldIsRegistered() {
        let all = MedicalDomainPack.emittedFields + LegalCaseDomainPack.emittedFields
            + VitalRecordsDomainPack.emittedFields + FinancialStatementDomainPack.emittedFields
            + PropertyDomainPack.emittedFields + IdentityDocumentDomainPack.emittedFields
        for f in all {
            #expect(FieldRegistry.isKnown(f), "starter field '\(f)' is not in the FieldRegistry")
        }
    }

    // — the additive dispatcher routes them all —

    @Test func dispatcherRunsEveryStarterPack() {
        let medical = "Patient: A. Sample. Diagnosis: influenza. Prescribed rest."
        let facts = DomainFactExtractor().extract(fromText: medical, subjectLabel: "s", blockID: UUID())
        #expect(facts.contains { FactSchemaRegistry.normalizeField($0.field) == "diagnosis" })
    }
}
