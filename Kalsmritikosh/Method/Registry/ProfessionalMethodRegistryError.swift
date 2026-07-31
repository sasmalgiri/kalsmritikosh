//
//  ProfessionalMethodRegistryError.swift
//  Kalsmritikosh
//
//  PM-003 — the typed error vocabulary for the professional-method registry.
//  Stage-4-specific; the generic backbone's PersonaRegistryError is never leaked
//  through the public API (it is mapped into these cases).
//

import Foundation

public nonisolated enum ProfessionalMethodRegistryError: Error, Equatable, Sendable {
    /// The definition failed its own structural contract (blank id/label, version).
    case invalidMethodContract(MethodContractError)
    /// The definition id is blank or not trim-stable.
    case invalidID(String)
    /// The definition version is below 1.
    case invalidVersion(id: String, version: Int)
    /// A duplicate (definition id, version) was registered.
    case duplicateRegistration(id: String, version: Int)
    /// The generic backbone reported a duplicate registry key (defensive backstop).
    case duplicateMethodKey(id: String, version: Int)
    /// A required-input role is duplicated within one definition.
    case duplicateInputRole(String)
    /// An allowed-node kind is duplicated within one definition.
    case duplicateNodeKind(String)
    /// An allowed-edge kind is duplicated within one definition.
    case duplicateEdgeKind(String)
    /// A required-review key is blank.
    case blankReviewKey
    /// A required-review key is duplicated within one definition.
    case duplicateReviewKey(String)
    /// A required-review label is blank.
    case blankReviewLabel
    /// A required review declared `mustBeHuman == false` — the accepted method
    /// review ledger is human-only; deterministic machine checks belong in
    /// `validationIdentifiers`.
    case nonHumanRequiredReview(String)
    /// A validator identifier is blank.
    case blankValidationIdentifier
    /// A validator identifier is duplicated within one definition.
    case duplicateValidationIdentifier(String)
    /// An allowed-finding kind raw value is blank.
    case blankFindingKind
    /// An allowed-finding kind is duplicated within one definition.
    case duplicateFindingKind(String)
}
