//
//  JobTooling.swift
//  Kalsmritikosh
//
//  Sūtra Engine — roadmap step 1 (see VISION_SUTRA_ENGINE.md).
//
//  The machine-readable encoding of PERSONA_JOB_DEPTH_MAP.md: for every shared
//  PersonaJobKind, the TIER (the cognitive shape of the job) and the METHOD it
//  uses determine which surface the job earns. Today the map lives in prose and
//  the surface choices are scattered; this makes them a single, queryable source
//  of truth — the first piece of the constitution the app can actually read.
//
//  Pure value + a static catalog; no behavior change. A later step has Work
//  Center / the persona hub read `JobToolingCatalog.profile(for:)` to launch the
//  matching canvas instead of a hard-coded mapping.
//

import Foundation

/// The cognitive shape of a job — decides how much tooling it earns.
public nonisolated enum PhaseTier: String, Codable, Sendable, CaseIterable, Equatable {
    case capture          // fill a register / log / matrix of facts        → table / form
    case analyze          // the work IS structured reasoning over evidence → interactive canvas / studio
    case readDerive       // assemble evidence → display → judge            → dedicated view
    case decideProduce    // a gated human decision + sealed output         → gated form + receipt

    public var label: String {
        switch self {
        case .capture: return "Capture"
        case .analyze: return "Analyze"
        case .readDerive: return "Read / derive"
        case .decideProduce: return "Decide / produce"
        }
    }
    /// Only `analyze` jobs warrant a bespoke studio/canvas.
    public var warrantsStudio: Bool { self == .analyze }
}

/// The recognized analytic method a job applies (drives which canvas fits).
public nonisolated enum AnalyticMethod: String, Codable, Sendable, CaseIterable, Equatable {
    case none
    case table            // a cited register / matrix (DataLab)
    case ach              // Analysis of Competing Hypotheses (matrix studio)
    case fishbone         // Ishikawa cause-and-effect
    case fiveWhys         // 5 Whys
    case linkAnalysis     // association / network
    case timeline         // chronology
    case fundFlow         // payer → payee flow
    case custodyLedger    // append-only chain of custody

    public var label: String {
        switch self {
        case .none: return "—"
        case .table: return "Cited table"
        case .ach: return "Analysis of Competing Hypotheses"
        case .fishbone: return "Fishbone (Ishikawa)"
        case .fiveWhys: return "5 Whys"
        case .linkAnalysis: return "Link / network analysis"
        case .timeline: return "Timeline"
        case .fundFlow: return "Fund flow"
        case .custodyLedger: return "Chain of custody"
        }
    }
}

/// The tooling doctrine for one job-kind: its tier, its method, and the surface
/// that best fits (a RootView `Destination.rawValue`, or nil when a Work Center
/// form / headless service is correct). `rationale` cites the map's reasoning.
public nonisolated struct JobToolingProfile: Sendable, Equatable {
    public let kind: PersonaJobKind
    public let tier: PhaseTier
    public let method: AnalyticMethod
    public let surface: String?          // Destination rawValue, or nil (form/service)
    public let rationale: String
    public init(_ kind: PersonaJobKind, _ tier: PhaseTier, _ method: AnalyticMethod,
                surface: String?, rationale: String) {
        self.kind = kind; self.tier = tier; self.method = method
        self.surface = surface; self.rationale = rationale
    }
}

public nonisolated enum JobToolingCatalog {

    /// One profile per shared PersonaJobKind — the machine-readable job-depth map.
    public static let profiles: [JobToolingProfile] = [
        .init(.caseIntake, .decideProduce, .none, surface: nil,
              rationale: "Intake sets scope + written authorization — a gated setup form."),
        .init(.ask, .readDerive, .none, surface: "ask",
              rationale: "Cited Q&A over the evidence."),
        .init(.methods, .analyze, .none, surface: nil,
              rationale: "Structured analytic techniques; a checklist today, canvas-hostable later."),
        .init(.dataLab, .capture, .table, surface: "dataLab",
              rationale: "Registers / logs / matrices — a cited table is correct."),
        .init(.subjectDossier, .readDerive, .none, surface: "dossier",
              rationale: "Assemble everything known about a subject, cited."),
        .init(.identityResolution, .readDerive, .none, surface: nil,
              rationale: "Reversible, human-gated merge; a decision view."),
        // The fix from the map: ACH is a matrix technique → the Competing Hypotheses studio.
        .init(.analysis, .analyze, .ach, surface: "hypotheses",
              rationale: "Analysis of Competing Hypotheses (Heuer) — a matrix, not a flat form."),
        .init(.sourceReliability, .readDerive, .none, surface: nil,
              rationale: "Rate sources on the Admiralty scale; a schedule view (a grid could improve it)."),
        .init(.contradictionGap, .readDerive, .none, surface: "review",
              rationale: "Surface conflicts/gaps and record a disposition; both sides preserved."),
        .init(.causalAnalysis, .analyze, .fishbone, surface: "reasoning",
              rationale: "5 Whys / fishbone — the Reasoning Studio canvas."),
        .init(.linkage, .analyze, .linkAnalysis, surface: "connections",
              rationale: "Timeline / relationship / transaction flow — canvas surfaces (also timeline, fundFlow)."),
        .init(.capaRegister, .capture, .table, surface: nil,
              rationale: "Corrective/preventive actions — a tracked register."),
        .init(.effectivenessReview, .decideProduce, .none, surface: nil,
              rationale: "Verify an action resolved the exposure — a gated check."),
        .init(.evidenceCustody, .capture, .custodyLedger, surface: nil,
              rationale: "Append-only custody ledger with integrity hashes (SWGDE/NIST)."),
        .init(.findings, .decideProduce, .none, surface: "handoff",
              rationale: "Gated findings with standard-of-proof + open-items gates, sealed receipt."),
        .init(.closure, .decideProduce, .none, surface: "handoff",
              rationale: "Explicit human close/reopen; retains unresolved items.")
    ]

    private static let byKind: [PersonaJobKind: JobToolingProfile] =
        Dictionary(uniqueKeysWithValues: profiles.map { ($0.kind, $0) })

    public static func profile(for kind: PersonaJobKind) -> JobToolingProfile? { byKind[kind] }

    /// The analyze-tier jobs — the ones that warrant a bespoke canvas/studio.
    public static var analyticKinds: [PersonaJobKind] {
        profiles.filter { $0.tier == .analyze }.map(\.kind)
    }
}
