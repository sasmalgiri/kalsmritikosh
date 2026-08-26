//
//  PersonaJobKind.swift
//  Kalsmritikosh
//
//  PHASE A (seventh audit) — the phase-kind vocabulary in its OWN file so the
//  standalone verifier is generated from this exact source (see
//  scripts/generate-kalverify.sh). Split from PersonaJob.swift, whose other
//  types pull app-side dependencies the verifier must not carry.
//

import Foundation

/// The concrete, launchable capabilities a persona job can name. Each case is routed by PersonaJobService to
/// an EXISTING real service — there is no new engine behind a kind. The Investigator populates every case
/// below with its already-shipped services (INV-01…INV-20).
public nonisolated enum PersonaJobKind: String, Sendable, Codable, CaseIterable, Hashable {
    case caseIntake            // INV-01  — case intake & scope authority
    case ask                   // INV-01-C — case-scoped Ask
    case methods               // INV-01-C2 — case-scoped professional methods
    case dataLab               // INV-01-C3 — case-scoped DataLab presets
    case subjectDossier        // INV-02  — subject dossier
    case identityResolution    // INV-03  — identity resolution (reversible merge)
    case analysis              // INV-04..07 — brainstorm / 5W1H / evidence plan / hypotheses
    case sourceReliability     // INV-08  — source reliability desk
    case contradictionGap      // INV-12  — contradiction & gap desk
    case causalAnalysis        // INV-13/14/15 — Five Whys / Fishbone / Root-cause
    case linkage               // INV-09/10/11 — timeline / relationship / transaction flow
    case capaRegister          // INV-16  — CAPA register
    case effectivenessReview   // INV-17  — effectiveness review
    case evidenceCustody       // INV-18  — evidence vault & custody
    case findings              // INV-19  — findings & export
    case closure               // INV-20  — case closure & reopen
}
