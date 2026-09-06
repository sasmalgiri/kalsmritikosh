//
//  BuildIdentity.swift
//  Kalsmritikosh
//
//  SPEC A1.5 — the build's identity: which commit produced this binary.
//  Stamped by scripts/stamp-build-identity.sh (the release recipe runs it
//  right before archiving; HOLD 2 step 0 compares About → build hash to
//  main HEAD). "development" means an unstamped local build — the witness
//  must not proceed on one. Shown in About and carried in every AI receipt
//  beside the model stamp.
//
//  (A build-phase run-script would stamp automatically; adding one is a
//  pbxproj edit — an owner-in-Xcode step, offered in the runbook.)
//

import Foundation

public enum BuildIdentity {
    /// The short git SHA this binary was built from; "development" until stamped.
    public static let gitSHA = "development"

    public static var displayLine: String { "Build \(gitSHA)" }
}
