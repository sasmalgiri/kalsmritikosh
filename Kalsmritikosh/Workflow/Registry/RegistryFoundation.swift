//
//  RegistryFoundation.swift
//  Kalsmritikosh
//
//  PJE-002 — Registry backbone: stable IDs, versioned keys, generic immutable
//  registry, and its mutable builder boundary.
//
//  All enumeration is sorted deterministically by (id.rawValue, version) ascending,
//  regardless of registration order.
//
//  Validation rules (enforced at registration time, not at ID construction):
//    - rawValue must be non-empty, non-whitespace-only, and trim-stable.
//    - version must be >= 1.
//    - Duplicate (ID, version) registration is rejected.
//

import Foundation

// MARK: - StableRegistryID

/// Common contract for all stable definition IDs.
/// Ordering is done using rawValue string comparison at all call sites.
/// `Comparable` is intentionally absent: retroactive conformances in a
/// `SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor` module would be MainActor-isolated,
/// which conflicts with the `Sendable` constraint in Swift 6 strict concurrency.
public protocol StableRegistryID:
    RawRepresentable,
    Hashable,
    Codable,
    Sendable
where RawValue == String {}

// MARK: - PJE-001 ID conformances

extension ApplicationDefinitionID: StableRegistryID {}
extension ToolDefinitionID: StableRegistryID {}
extension WorkflowDefinitionID: StableRegistryID {}

// MARK: - New registry ID types

public nonisolated struct ObjectSchemaDefinitionID: RawRepresentable, Hashable, Codable, Sendable, StableRegistryID {
    public let rawValue: String
    public nonisolated init(rawValue: String) { self.rawValue = rawValue }
}

public nonisolated struct WorkProductDefinitionID: RawRepresentable, Hashable, Codable, Sendable, StableRegistryID {
    public let rawValue: String
    public nonisolated init(rawValue: String) { self.rawValue = rawValue }
}

public nonisolated struct ValidatorDefinitionID: RawRepresentable, Hashable, Codable, Sendable, StableRegistryID {
    public let rawValue: String
    public nonisolated init(rawValue: String) { self.rawValue = rawValue }
}

public nonisolated struct TerminologyDefinitionID: RawRepresentable, Hashable, Codable, Sendable, StableRegistryID {
    public let rawValue: String
    public nonisolated init(rawValue: String) { self.rawValue = rawValue }
}

public nonisolated struct AutomationDefinitionID: RawRepresentable, Hashable, Codable, Sendable, StableRegistryID {
    public let rawValue: String
    public nonisolated init(rawValue: String) { self.rawValue = rawValue }
}

// MARK: - RegistryKey

/// Versioned identity key. Order: id.rawValue ascending, then version ascending.
public nonisolated struct RegistryKey<ID: StableRegistryID>: Hashable, Codable, Sendable {
    public let id: ID
    public let version: Int

    public nonisolated init(id: ID, version: Int) {
        self.id = id
        self.version = version
    }
}

// MARK: - VersionedRegistryDefinition

/// Any definition that carries a stable ID and a version number.
public protocol VersionedRegistryDefinition: Sendable {
    associatedtype DefinitionID: StableRegistryID
    var id: DefinitionID { get }
    var version: Int { get }
}

// MARK: - PJE-001 type conformances

extension PersonaApplicationDefinition: VersionedRegistryDefinition {
    public typealias DefinitionID = ApplicationDefinitionID
}
extension PersonaToolDefinition: VersionedRegistryDefinition {
    public typealias DefinitionID = ToolDefinitionID
}

// ValidatedWorkflowDefinition proxies id/version from its wrapped definition.
extension ValidatedWorkflowDefinition: VersionedRegistryDefinition {
    public typealias DefinitionID = WorkflowDefinitionID
    public var id: WorkflowDefinitionID { definition.id }
    public var version: Int { definition.version }
}

// MARK: - Immutable generic registry

/// An immutable, value-semantic registry snapshot.
/// `all` and `allKeys` are always sorted by (id.rawValue, version).
/// All reads are O(1) via internal dictionary; `versions(for:)` is O(n).
public nonisolated struct VersionedDefinitionRegistry<Definition: VersionedRegistryDefinition>: Sendable {

    private let _sorted: [Definition]
    private let _byKey: [RegistryKey<Definition.DefinitionID>: Definition]
    private let _latestVersion: [Definition.DefinitionID: Int]

    fileprivate nonisolated init(
        sorted: [Definition],
        byKey: [RegistryKey<Definition.DefinitionID>: Definition],
        latestVersion: [Definition.DefinitionID: Int]
    ) {
        self._sorted = sorted
        self._byKey = byKey
        self._latestVersion = latestVersion
    }

    public func definition(id: Definition.DefinitionID, version: Int) -> Definition? {
        _byKey[RegistryKey(id: id, version: version)]
    }

    public func latest(id: Definition.DefinitionID) -> Definition? {
        guard let v = _latestVersion[id] else { return nil }
        return _byKey[RegistryKey(id: id, version: v)]
    }

    public func versions(for id: Definition.DefinitionID) -> [Int] {
        _sorted.filter { $0.id == id }.map { $0.version }
    }

    public var all: [Definition] { _sorted }

    public var allKeys: [RegistryKey<Definition.DefinitionID>] {
        _sorted.map { RegistryKey(id: $0.id, version: $0.version) }
    }
}

// MARK: - Mutable builder

/// Accumulates definitions and produces an immutable frozen snapshot.
/// `freeze()` is value-safe: subsequent builder mutations do not affect a frozen registry.
public nonisolated struct VersionedDefinitionRegistryBuilder<Definition: VersionedRegistryDefinition> {

    private var _byKey: [RegistryKey<Definition.DefinitionID>: Definition] = [:]

    public nonisolated init() {}

    /// Registers a definition. Throws on invalid ID/version or duplicate (ID, version).
    public mutating func register(_ definition: Definition) throws {
        let raw = definition.id.rawValue
        guard !raw.isEmpty,
              raw == raw.trimmingCharacters(in: .whitespaces),
              !raw.trimmingCharacters(in: .whitespaces).isEmpty
        else { throw PersonaRegistryError.invalidID(raw) }
        guard definition.version >= 1 else {
            throw PersonaRegistryError.invalidVersion(id: raw, version: definition.version)
        }
        let key = RegistryKey(id: definition.id, version: definition.version)
        guard _byKey[key] == nil else {
            throw PersonaRegistryError.duplicateRegistration(
                registry: "\(Definition.self)",
                id: raw,
                version: definition.version
            )
        }
        _byKey[key] = definition
    }

    /// Freezes the current state into an immutable registry.
    /// Safe to call multiple times; each call produces an independent snapshot.
    public func freeze() -> VersionedDefinitionRegistry<Definition> {
        let sorted = _byKey.values.sorted {
            if $0.id.rawValue != $1.id.rawValue { return $0.id.rawValue < $1.id.rawValue }
            return $0.version < $1.version
        }
        var latestVersion: [Definition.DefinitionID: Int] = [:]
        for def in _byKey.values {
            latestVersion[def.id] = max(latestVersion[def.id, default: 0], def.version)
        }
        return VersionedDefinitionRegistry(
            sorted: sorted,
            byKey: _byKey,
            latestVersion: latestVersion
        )
    }
}

// MARK: - PersonaRegistryError

/// Typed diagnostics for all registry and catalog operations.
public enum PersonaRegistryError: Error, Equatable, Sendable {
    case invalidID(String)
    case invalidVersion(id: String, version: Int)
    case duplicateRegistration(registry: String, id: String, version: Int)

    case workflowCompilationFailed(
        id: WorkflowDefinitionID,
        version: Int,
        error: WorkflowDefinitionError
    )

    case missingTool(
        applicationID: ApplicationDefinitionID,
        toolID: ToolDefinitionID
    )
    case missingWorkflow(ownerID: String, workflowID: WorkflowDefinitionID)
    case missingObjectSchema(
        applicationID: ApplicationDefinitionID,
        schemaID: ObjectSchemaDefinitionID
    )
    case missingWorkProduct(
        workflowID: WorkflowDefinitionID,
        workProductID: WorkProductDefinitionID
    )
    case missingComposer(
        workProductID: WorkProductDefinitionID,
        composerID: WorkProductComposerID
    )
    case missingValidator(
        workflowID: WorkflowDefinitionID,
        stepID: StepDefinitionID,
        validatorID: ValidatorDefinitionID
    )
    case validatorDoesNotSupportStep(
        validatorID: ValidatorDefinitionID,
        stepKind: WorkflowStepKind
    )
    case missingTerminology(
        applicationID: ApplicationDefinitionID,
        terminologyID: TerminologyDefinitionID
    )
    case terminologyApplicationMismatch(
        terminologyID: TerminologyDefinitionID,
        expected: ApplicationDefinitionID,
        actual: ApplicationDefinitionID
    )
    case missingAutomation(
        applicationID: ApplicationDefinitionID,
        automationID: AutomationDefinitionID
    )
    case missingRequiredCapability(ownerID: String, capability: String)
    case illegalObjectSchemaOwnership(
        representedTypeName: String,
        ownership: PersonaObjectSchemaOwnership
    )
    case blankTerminologyLabel(
        terminologyID: TerminologyDefinitionID,
        token: PersonaTerminologyToken
    )
}
