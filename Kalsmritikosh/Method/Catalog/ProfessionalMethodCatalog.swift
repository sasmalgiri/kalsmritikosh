//
//  ProfessionalMethodCatalog.swift
//  Kalsmritikosh
//
//  Stage B — the ONE assembler that turns the concrete professional methods (Brainstorming, 5W1H,
//  Five Whys, Fishbone, CAPA, the analytical pack, the decision matrices …) into the two frozen
//  registries the generic PM-001..004 foundation already consumes: a ProfessionalMethodRegistry of
//  ProfessionalMethodDefinition and a ProfessionalMethodValidatorRegistry of the method-specific
//  validators. It REBUILDS nothing — every concrete method is just a definition + validators
//  registered here, executed by the ONE ProfessionalMethodLifecycleEngine over the ONE
//  MethodRunRepository. This file is the single owner of "which methods exist".
//
//  A concrete method never introduces a second run store, a second lifecycle, a second review or
//  validation authority, or a Claim-promotion path. Its findings/nodes stay proposal-layer; a method
//  result becomes a canonical fact only through the existing human-reviewed workflow, never here.
//

import Foundation

/// One concrete professional method: its immutable definition plus the deterministic validators that
/// enforce its completion criteria and prohibited conclusions. Pure value description — no I/O.
public protocol ConcreteProfessionalMethod: Sendable {
    var definition: ProfessionalMethodDefinition { get }
    var validators: [any ProfessionalMethodValidating] { get }
}

/// Errors assembling the catalog. Distinct from the registry errors so a catalog wiring mistake is
/// legible.
public nonisolated enum ProfessionalMethodCatalogError: Error, Sendable, Equatable {
    /// A method references a validation identifier that no supplied validator provides.
    case missingValidator(methodID: String, validatorID: String)
    /// Two distinct validators claim the same id (they must be identical to share).
    case conflictingValidator(validatorID: String)
}

/// The frozen catalog: the method-definition registry + the validator registry, ready for the
/// lifecycle engine and the workflow method bridge. A nonisolated value (two Sendable registries);
/// only the assembly statics are MainActor, because they drive the foundation's MainActor builders.
public nonisolated struct ProfessionalMethodCatalog: Sendable {
    public let methods: ProfessionalMethodRegistry
    public let validators: ProfessionalMethodValidatorRegistry

    nonisolated init(methods: ProfessionalMethodRegistry, validators: ProfessionalMethodValidatorRegistry) {
        self.methods = methods
        self.validators = validators
    }

    /// The standard shipping catalog — every accepted concrete method. Extended one PM unit at a time.
    @MainActor public static func standard() throws -> ProfessionalMethodCatalog {
        try assemble(standardMethods)
    }

    /// The concrete methods that make up the standard catalog. Grows as each PM unit lands.
    @MainActor public static var standardMethods: [any ConcreteProfessionalMethod] {
        [
            BrainstormingMethod(),
            FiveW1HMethod()
        ]
    }

    /// Freeze a method + validator registry from a set of concrete methods. Every validation
    /// identifier a method declares MUST be provided by one of its validators; validators shared by
    /// id across methods must be the same validator (same id + version).
    @MainActor public static func assemble(_ methods: [any ConcreteProfessionalMethod]) throws -> ProfessionalMethodCatalog {
        var methodBuilder = ProfessionalMethodRegistryBuilder()
        var validatorBuilder = ProfessionalMethodValidatorRegistryBuilder()
        var registeredValidators: [String: String] = [:]   // id → version, for shared-validator identity

        for method in methods {
            let byID = Dictionary(method.validators.map { ($0.validatorID, $0) }, uniquingKeysWith: { a, _ in a })
            // Every declared validation identifier must be backed by a supplied validator.
            for identifier in method.definition.validationIdentifiers where byID[identifier] == nil {
                throw ProfessionalMethodCatalogError.missingValidator(
                    methodID: method.definition.id.rawValue, validatorID: identifier)
            }
            // Register each validator once; a repeat id must be the identical version.
            for validator in method.validators {
                if let existingVersion = registeredValidators[validator.validatorID] {
                    guard existingVersion == validator.validatorVersion else {
                        throw ProfessionalMethodCatalogError.conflictingValidator(validatorID: validator.validatorID)
                    }
                    continue
                }
                try validatorBuilder.register(validator)
                registeredValidators[validator.validatorID] = validator.validatorVersion
            }
            try methodBuilder.register(method.definition)
        }

        return ProfessionalMethodCatalog(methods: methodBuilder.freeze(), validators: validatorBuilder.freeze())
    }
}
