//
//  ProfessionalMethodRegistry.swift
//  Kalsmritikosh
//
//  PM-003 — the ONE immutable, code-backed registry for ProfessionalMethodDefinition.
//  It WRAPS the accepted generic versioned-registry backbone (VersionedDefinition
//  Registry / …Builder) — it never reimplements dictionary/latest/freeze/ordering
//  logic — and it is kept SEPARATE from PersonaJobCatalog: professional methods are
//  persona-neutral Stage-4 definitions. There is deliberately NO definition table
//  and no runtime definition mutation; the frozen snapshot is immutable.
//

import Foundation

// MARK: - Backbone conformances (declared from inside the Stage-4 subsystem)

extension ProfessionalMethodDefinitionID: StableRegistryID {}

extension ProfessionalMethodDefinition: VersionedRegistryDefinition {
    public typealias DefinitionID = ProfessionalMethodDefinitionID
}

// MARK: - Immutable frozen registry

public struct ProfessionalMethodRegistry: Sendable {
    private let backing: VersionedDefinitionRegistry<ProfessionalMethodDefinition>

    nonisolated init(backing: VersionedDefinitionRegistry<ProfessionalMethodDefinition>) {
        self.backing = backing
    }

    /// Exact lookup by (id, version) — O(1).
    public func definition(id: ProfessionalMethodDefinitionID, version: Int) -> ProfessionalMethodDefinition? {
        backing.definition(id: id, version: version)
    }

    /// Latest registered version for an id — DISCOVERY/PRESENTATION only. Anything
    /// persisted must carry the exact version, never an implicit "latest".
    public func latest(id: ProfessionalMethodDefinitionID) -> ProfessionalMethodDefinition? {
        backing.latest(id: id)
    }

    public func versions(for id: ProfessionalMethodDefinitionID) -> [Int] {
        backing.versions(for: id)
    }

    /// All definitions in deterministic (id.rawValue, version) order.
    public var all: [ProfessionalMethodDefinition] { backing.all }

    public var allKeys: [RegistryKey<ProfessionalMethodDefinitionID>] { backing.allKeys }
}

// MARK: - Builder

public struct ProfessionalMethodRegistryBuilder {
    private var backing = VersionedDefinitionRegistryBuilder<ProfessionalMethodDefinition>()
    private var keysSeen = Set<RegistryKey<ProfessionalMethodDefinitionID>>()

    public nonisolated init() {}

    /// Validate and register one definition. Order is chosen so each failure maps
    /// to its most specific error: id/version first, then the structural contract,
    /// then the within-definition list invariants, then key uniqueness.
    public mutating func register(_ definition: ProfessionalMethodDefinition) throws {
        // 1. Stable id (blank OR not trim-stable) → invalidID.
        let raw = definition.id.rawValue
        guard !raw.isEmpty, raw == raw.trimmingCharacters(in: .whitespaces),
              !raw.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ProfessionalMethodRegistryError.invalidID(raw)
        }
        // 2. Version.
        guard definition.version >= 1 else {
            throw ProfessionalMethodRegistryError.invalidVersion(id: raw, version: definition.version)
        }
        // 3. The definition's own structural contract (label, node/edge/input keys).
        do { try definition.validateStructure() }
        catch let error as MethodContractError {
            throw ProfessionalMethodRegistryError.invalidMethodContract(error)
        }
        // 4. Within-definition list invariants.
        try Self.validateInternals(definition)
        // 5. Duplicate (id, version).
        let key = RegistryKey(id: definition.id, version: definition.version)
        guard keysSeen.insert(key).inserted else {
            throw ProfessionalMethodRegistryError.duplicateRegistration(id: raw, version: definition.version)
        }
        // 6. Delegate to the generic backbone (pre-checks above guarantee no throw;
        //    map defensively regardless — the backbone stays the single source of truth).
        do { try backing.register(definition) }
        catch let error as PersonaRegistryError { throw Self.map(error) }
    }

    public func freeze() -> ProfessionalMethodRegistry {
        ProfessionalMethodRegistry(backing: backing.freeze())
    }

    // MARK: - Within-definition validation

    private static func validateInternals(_ d: ProfessionalMethodDefinition) throws {
        try requireNoDuplicate(d.requiredInputRoles.map(\.rawValue)) { .duplicateInputRole($0) }
        try requireNoDuplicate(d.allowedNodeKinds.map(\.rawValue)) { .duplicateNodeKind($0) }
        try requireNoDuplicate(d.allowedEdgeKinds.map(\.rawValue)) { .duplicateEdgeKind($0) }

        var reviewKeys = Set<String>()
        for review in d.requiredReviews {
            guard !review.reviewKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ProfessionalMethodRegistryError.blankReviewKey
            }
            guard !review.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ProfessionalMethodRegistryError.blankReviewLabel
            }
            guard review.mustBeHuman else {
                throw ProfessionalMethodRegistryError.nonHumanRequiredReview(review.reviewKey)
            }
            guard reviewKeys.insert(review.reviewKey).inserted else {
                throw ProfessionalMethodRegistryError.duplicateReviewKey(review.reviewKey)
            }
        }

        var validatorIDs = Set<String>()
        for identifier in d.validationIdentifiers {
            guard !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ProfessionalMethodRegistryError.blankValidationIdentifier
            }
            guard validatorIDs.insert(identifier).inserted else {
                throw ProfessionalMethodRegistryError.duplicateValidationIdentifier(identifier)
            }
        }

        var findingKinds = Set<String>()
        for kind in d.outputContract.allowedFindingKinds {
            guard !kind.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ProfessionalMethodRegistryError.blankFindingKind
            }
            guard findingKinds.insert(kind.rawValue).inserted else {
                throw ProfessionalMethodRegistryError.duplicateFindingKind(kind.rawValue)
            }
        }
    }

    private static func requireNoDuplicate(
        _ values: [String], _ makeError: (String) -> ProfessionalMethodRegistryError
    ) throws {
        var seen = Set<String>()
        for value in values where !seen.insert(value).inserted { throw makeError(value) }
    }

    private static func map(_ error: PersonaRegistryError) -> ProfessionalMethodRegistryError {
        switch error {
        case .invalidID(let raw):
            return .invalidID(raw)
        case .invalidVersion(let id, let version):
            return .invalidVersion(id: id, version: version)
        case .duplicateRegistration(_, let id, let version):
            return .duplicateMethodKey(id: id, version: version)
        default:
            return .invalidID(String(describing: error))
        }
    }
}
