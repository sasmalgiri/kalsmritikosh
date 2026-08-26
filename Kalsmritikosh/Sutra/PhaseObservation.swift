//
//  PhaseObservation.swift
//  Kalsmritikosh
//
//  PHASE B (seventh audit) — machine observation of SOP phase completion.
//  The conformance assessor previously recognized only four phases (intake,
//  findings, custody, closure); the other twelve could never be marked
//  reached, so protocols requiring them could never conform. This service
//  DERIVES phase completion from the EXISTING case-scoped authorities — the
//  hypotheses ledger, the reliability desk, the contradiction/gap desk, the
//  subject dossier, the identity decision log, and the v113 case↔method-run
//  linkage. No second source of truth is introduced: an observation is a
//  query over the tables the work already wrote.
//
//  A probe error reads as NOT observed — fail-closed: fewer observed phases
//  means stricter assessment, never looser.
//

import Foundation

/// One machine observation of a phase: how many artifacts the case's own
/// ledgers hold for it, and how many of those are decided/completed.
public nonisolated struct PhaseObservationRecord: Sendable, Equatable {
    public let phase: PersonaJobKind
    public let artifactCount: Int
    public let decidedCount: Int
    public init(phase: PersonaJobKind, artifactCount: Int, decidedCount: Int) {
        self.phase = phase; self.artifactCount = artifactCount; self.decidedCount = decidedCount
    }
}

public actor PhaseObservationService {
    private let analysis: InvestigationAnalysisService?
    private let reliability: InvestigationReliabilityService?
    private let contradictionGap: InvestigationContradictionGapService?
    private let dossier: InvestigationSubjectDossierService?
    private let identity: InvestigationIdentityResolutionService?
    private let methodRuns: MethodRunRepository?

    public init(analysis: InvestigationAnalysisService? = nil,
                reliability: InvestigationReliabilityService? = nil,
                contradictionGap: InvestigationContradictionGapService? = nil,
                dossier: InvestigationSubjectDossierService? = nil,
                identity: InvestigationIdentityResolutionService? = nil,
                methodRuns: MethodRunRepository? = nil) {
        self.analysis = analysis
        self.reliability = reliability
        self.contradictionGap = contradictionGap
        self.dossier = dossier
        self.identity = identity
        self.methodRuns = methodRuns
    }

    /// The phase kinds THIS build can machine-observe. A governing protocol
    /// whose required phases fall outside this set is refused at run start —
    /// it could never conform, and silence would be dishonest.
    /// `ask` and `dataLab` remain attestation-only today (their case-scoped
    /// activity is not yet persisted per case) — stated, not hidden.
    public static let observableKinds: Set<PersonaJobKind> = [
        .caseIntake, .findings, .evidenceCustody, .closure,           // snapshot-derived (the original four)
        .analysis, .sourceReliability, .contradictionGap,             // desk ledgers
        .subjectDossier, .identityResolution,                         // dossier + decision log
        .methods, .causalAnalysis, .linkage, .capaRegister,           // v113 case↔method-run linkage
        .effectivenessReview,
    ]

    /// Machine observations for one case, beyond the four snapshot-derived
    /// phases (which the handoff model derives itself).
    public func observations(caseID: UUID) async -> [PersonaJobKind: PhaseObservationRecord] {
        var out: [PersonaJobKind: PhaseObservationRecord] = [:]
        func note(_ phase: PersonaJobKind, artifacts: Int, decided: Int) {
            guard artifacts > 0 else { return }
            out[phase] = PhaseObservationRecord(phase: phase, artifactCount: artifacts, decidedCount: decided)
        }
        if let analysis, let hs = try? await analysis.hypotheses(caseID: caseID) {
            // A hypothesis moved past 'proposed' carries a human call.
            note(.analysis, artifacts: hs.count, decided: hs.filter { $0.status != .proposed }.count)
        }
        if let reliability, let entries = try? await reliability.schedule(caseID: caseID) {
            let assessed = entries.filter { $0.assessment != nil }.count
            note(.sourceReliability, artifacts: assessed, decided: assessed)
        }
        if let contradictionGap {
            let cs = (try? await contradictionGap.contradictions(caseID: caseID)) ?? []
            let gs = (try? await contradictionGap.gaps(caseID: caseID)) ?? []
            let decided = cs.filter { $0.review != nil }.count + gs.filter { $0.review != nil }.count
            note(.contradictionGap, artifacts: cs.count + gs.count, decided: decided)
        }
        if let dossier, let subjects = try? await dossier.subjects(caseID: caseID) {
            note(.subjectDossier, artifacts: subjects.count, decided: subjects.count)
        }
        if let identity, let decisions = try? await identity.decisionLog(caseID: caseID) {
            note(.identityResolution, artifacts: decisions.count, decided: decisions.count)
        }
        if let methodRuns, let activity = try? await methodRuns.casePhaseActivity(caseID: caseID) {
            for row in activity {
                note(row.phase, artifacts: row.total, decided: row.completed)
            }
        }
        return out
    }
}
