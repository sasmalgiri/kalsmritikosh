//
//  BuyerPersonaCatalogTests.swift
//  KalsmritikoshTests
//
//  The buyer-research personas (SIU, Forensic Accountant, Compliance/HR,
//  Genealogist) plus the Content Creator (2026-08-20) — vocabulary lenses over
//  the shared engines. Locks the same contract PJOB-MAX locks for the core
//  five: discoverable, resolvable, unique job ids, an intake path, and full
//  16-kind capability coverage — without touching the pinned five-persona
//  coverage matrix.
//

import Testing
@testable import Kalsmritikosh

@Suite("BUYER-PERSONAS — SIU / Forensic Accountant / Compliance / Genealogist / Content Creator")
struct BuyerPersonaCatalogTests {

    private static let expected: [(id: ApplicationDefinitionID, label: String, jobs: [PersonaJob])] = [
        (SIUPersonaPackage.applicationID, "Insurance Fraud (SIU)", SIUPersonaPackage.jobs),
        (ForensicAccountantPersonaPackage.applicationID, "Forensic Accountant", ForensicAccountantPersonaPackage.jobs),
        (CompliancePersonaPackage.applicationID, "Compliance / HR Investigator", CompliancePersonaPackage.jobs),
        (GenealogistPersonaPackage.applicationID, "Genealogist / Family Historian", GenealogistPersonaPackage.jobs),
        (ContentCreatorPersonaPackage.applicationID, "Content Creator", ContentCreatorPersonaPackage.jobs),
    ]

    @Test("All register, resolve, and cover every capability kind with 16 unique jobs")
    func catalogContract() throws {
        let catalog = try PersonaJobCatalogComposer.composeProduction()
        for persona in Self.expected {
            let app = catalog.latestApplication(id: persona.id)
            #expect(app != nil, "\(persona.label) not discoverable")
            #expect(app?.label == persona.label)
            #expect(catalog.resolvedPackage(applicationID: persona.id) != nil, "\(persona.label) not resolvable")

            let jobs = PersonaJobCatalogComposer.jobs(forPersona: persona.id)
            #expect(jobs.count == 16, "\(persona.label): \(jobs.count) jobs")
            #expect(Set(jobs.map(\.id)).count == jobs.count, "\(persona.label): duplicate job ids")
            #expect(jobs.map(\.id) == persona.jobs.map(\.id), "\(persona.label): composer/package drift")
            #expect(jobs.allSatisfy { $0.persona == persona.id.rawValue })
            #expect(jobs.contains { $0.kind == .caseIntake }, "\(persona.label): no intake job")
            #expect(Set(jobs.map(\.kind)).count == PersonaJobKind.allCases.count,
                    "\(persona.label): does not cover all 16 job kinds")
        }
    }

    @Test("The core five personas are untouched — same ids, same counts")
    func coreFiveUnchanged() throws {
        let catalog = try PersonaJobCatalogComposer.composeProduction()
        for (id, count) in [(InvestigatorPersonaPackage.applicationID, 16),
                            (ResearcherPersonaPackage.applicationID, 20),
                            (JournalistPersonaPackage.applicationID, 22),
                            (IndividualPersonaPackage.applicationID, 23),
                            (LawyerPersonaPackage.applicationID, 22)] {
            #expect(catalog.latestApplication(id: id) != nil)
            #expect(PersonaJobCatalogComposer.jobs(forPersona: id).count == count)
        }
    }
}
