//
//  ProfessionalMethodValidatorRegistry.swift
//  Kalsmritikosh
//
//  PM-004 — one immutable, code-backed validator registry. A definition's
//  validationIdentifiers resolve against validator IDs; the resolved validator's
//  version is persisted with each result. No validator database table.
//

import Foundation

public struct ProfessionalMethodValidatorRegistry: Sendable {
    private let byID: [String: any ProfessionalMethodValidating]

    init(byID: [String: any ProfessionalMethodValidating]) { self.byID = byID }

    public func validator(id: String) -> (any ProfessionalMethodValidating)? { byID[id] }
    public var registeredIDs: [String] { byID.keys.sorted() }
}

public struct ProfessionalMethodValidatorRegistryBuilder {
    private var byID: [String: any ProfessionalMethodValidating] = [:]

    public init() {}

    public mutating func register(_ validator: any ProfessionalMethodValidating) throws {
        let raw = validator.validatorID
        guard !raw.isEmpty else { throw ProfessionalMethodValidatorRegistryError.blankID }
        guard raw == raw.trimmingCharacters(in: .whitespaces),
              !raw.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ProfessionalMethodValidatorRegistryError.notTrimStableID(raw)
        }
        guard !validator.validatorVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProfessionalMethodValidatorRegistryError.blankVersion(raw)
        }
        guard byID[raw] == nil else { throw ProfessionalMethodValidatorRegistryError.duplicateID(raw) }
        byID[raw] = validator
    }

    public func freeze() -> ProfessionalMethodValidatorRegistry {
        ProfessionalMethodValidatorRegistry(byID: byID)
    }
}
