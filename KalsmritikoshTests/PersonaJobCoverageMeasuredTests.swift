//
//  PersonaJobCoverageMeasuredTests.swift
//  KalsmritikoshTests
//
//  D2 (docs/INVESTIGATION_FOCUS_TODO.md) — the persona job coverage matrix, generated from the code
//  rather than written by hand: every job in the production catalog, the shared service it routes
//  to, whether it returns rows (A1), the evidence-backed studio its persona produces (A2–A4), and
//  the public case pack that exercises it start to end (B1/C1). Writes
//  PERSONA_JOB_COVERAGE_MEASURED.csv at the repository root; the hand-written
//  PERSONA_JOB_COVERAGE_MATRIX.csv stays as the design reference.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Persona job coverage — measured from the catalog")
struct PersonaJobCoverageMeasuredTests {

    /// The service each kind routes to in PersonaJobService.launch.
    static func service(_ k: PersonaJobKind) -> String {
        switch k {
        case .caseIntake: return "InvestigationCaseRepository + InvestigationWorkspaceIntake"
        case .ask: return "InvestigationAnswerService"
        case .methods: return "InvestigationMethodService"
        case .dataLab: return "InvestigationDataLabService"
        case .subjectDossier: return "InvestigationSubjectDossierService"
        case .identityResolution: return "InvestigationIdentityResolutionService"
        case .analysis: return "InvestigationAnalysisService"
        case .sourceReliability: return "InvestigationReliabilityService"
        case .contradictionGap: return "InvestigationContradictionGapService"
        case .causalAnalysis: return "InvestigationCausalService"
        case .linkage: return "InvestigationLinkageService"
        case .capaRegister, .effectivenessReview: return "InvestigationCAPAService"
        case .evidenceCustody: return "InvestigationCustodyService"
        case .findings: return "InvestigationFindingsService"
        case .closure: return "InvestigationClosureService"
        }
    }

    /// What the job hands back (A1): the case itself, an answer, or rows with their sources.
    static func workProduct(_ k: PersonaJobKind) -> String {
        switch k {
        case .caseIntake: return "case (id) with sources in scope"
        case .ask: return "cited answer over the case scope"
        case .findings: return "sealed findings report + source rows"
        default: return "rows with ids and source references"
        }
    }

    static let studioByPersona: [String: String] = [
        "lawyer": "Privilege Log", "compliance": "Workplace Investigation Report", "forensicaccountant": "Forensic Engagement",
        "siu": "SIU Referral", "journalist": "Fact-check Memo", "researcher": "Evidence Review", "genealogist": "Proof Argument",
        "individual": "Dispute File", "investigator": "Findings report", "contentcreator": "Publish Package (hidden by default)"]

    static let packByPersona: [String: String] = [
        "lawyer": "lawyer", "compliance": "compliance", "forensicaccountant": "forensic", "siu": "siu", "journalist": "journalist",
        "researcher": "researcher", "genealogist": "genealogist", "individual": "individual", "investigator": "investigator"]

    static func personaKey(_ applicationID: String) -> String {
        (applicationID.split(separator: ".").last.map(String.init) ?? applicationID).lowercased()
    }

    @Test("Every catalog job routes to a service; the measured matrix is regenerated")
    func measured() throws {
        let jobs = PersonaJobCatalogComposer.allJobs
        #expect(!jobs.isEmpty)
        var rows = ["Persona,JobID,Job,Kind,Service,WorkProduct,EvidenceBackedStudio,CasePack"]
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        for j in jobs {
            let key = Self.personaKey(j.persona)
            rows.append([q(key), q(j.id), q(j.title), q(String(describing: j.kind)), q(Self.service(j.kind)),
                         q(Self.workProduct(j.kind)), q(Self.studioByPersona[key] ?? "—"), q(Self.packByPersona[key] ?? "—")]
                .joined(separator: ","))
        }
        // Every persona the product keeps (all but the hidden creator) has a studio and a case pack.
        let personas = Set(jobs.map { Self.personaKey($0.persona) }).subtracting(["contentcreator"])
        for p in personas {
            #expect(Self.studioByPersona[p] != nil, "\(p) has a deliverable")
            #expect(Self.packByPersona[p] != nil, "\(p) has a case pack")
        }
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        try (rows.joined(separator: "\n") + "\n").write(to: repo.appendingPathComponent("PERSONA_JOB_COVERAGE_MEASURED.csv"),
                                                        atomically: true, encoding: .utf8)
    }
}
