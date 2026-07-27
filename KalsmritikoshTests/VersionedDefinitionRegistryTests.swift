//
//  VersionedDefinitionRegistryTests.swift
//  KalsmritikoshTests
//
//  PJE-002 — Generic VersionedDefinitionRegistry and its builder.
//  Uses PersonaObjectSchemaDefinition as a concrete VersionedRegistryDefinition
//  for all structural tests.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PJE-002 — VersionedDefinitionRegistry")
struct VersionedDefinitionRegistryTests {

    // MARK: Helpers

    private func schema(
        _ rawID: String,
        version: Int = 1
    ) -> PersonaObjectSchemaDefinition {
        PersonaObjectSchemaDefinition(
            id: ObjectSchemaDefinitionID(rawValue: rawID),
            version: version,
            label: rawID,
            representedTypeName: "TestObject",
            ownership: .workflowOwned
        )
    }

    private func makeRegistry(
        _ defs: [PersonaObjectSchemaDefinition]
    ) throws -> VersionedDefinitionRegistry<PersonaObjectSchemaDefinition> {
        var b = VersionedDefinitionRegistryBuilder<PersonaObjectSchemaDefinition>()
        for d in defs { try b.register(d) }
        return b.freeze()
    }

    // MARK: - Case 1: Register and exact lookup

    @Test("Registered definition is found by exact (ID, version)")
    func registerAndExactLookup() throws {
        let reg = try makeRegistry([schema("com.schema.a", version: 2)])
        let id = ObjectSchemaDefinitionID(rawValue: "com.schema.a")
        #expect(reg.definition(id: id, version: 2) != nil)
        #expect(reg.definition(id: id, version: 2)?.version == 2)
    }

    // MARK: - Case 2: Latest-version lookup

    @Test("latest(id:) returns the highest registered version")
    func latestVersionLookup() throws {
        let reg = try makeRegistry([
            schema("com.schema.b", version: 1),
            schema("com.schema.b", version: 3),
            schema("com.schema.b", version: 2),
        ])
        let id = ObjectSchemaDefinitionID(rawValue: "com.schema.b")
        #expect(reg.latest(id: id)?.version == 3)
    }

    // MARK: - Case 3: Multiple versions of one ID coexist

    @Test("Multiple versions of the same ID coexist in the registry")
    func multipleVersionsCoexist() throws {
        let reg = try makeRegistry([
            schema("com.schema.c", version: 1),
            schema("com.schema.c", version: 2),
        ])
        let id = ObjectSchemaDefinitionID(rawValue: "com.schema.c")
        #expect(reg.versions(for: id) == [1, 2])
        #expect(reg.definition(id: id, version: 1) != nil)
        #expect(reg.definition(id: id, version: 2) != nil)
    }

    // MARK: - Case 4: Duplicate exact version rejected

    @Test("Registering the same (ID, version) twice throws duplicateRegistration")
    func duplicateExactVersionRejected() throws {
        var b = VersionedDefinitionRegistryBuilder<PersonaObjectSchemaDefinition>()
        try b.register(schema("com.schema.d", version: 1))
        #expect(throws: PersonaRegistryError.duplicateRegistration(
            registry: "PersonaObjectSchemaDefinition",
            id: "com.schema.d",
            version: 1
        )) {
            try b.register(schema("com.schema.d", version: 1))
        }
    }

    // MARK: - Case 5: Invalid zero version rejected

    @Test("Version 0 is rejected with invalidVersion")
    func invalidZeroVersionRejected() throws {
        var b = VersionedDefinitionRegistryBuilder<PersonaObjectSchemaDefinition>()
        #expect(throws: PersonaRegistryError.invalidVersion(id: "com.schema.e", version: 0)) {
            try b.register(schema("com.schema.e", version: 0))
        }
    }

    // MARK: - Case 6: Invalid negative version rejected

    @Test("Negative version is rejected with invalidVersion")
    func invalidNegativeVersionRejected() throws {
        var b = VersionedDefinitionRegistryBuilder<PersonaObjectSchemaDefinition>()
        #expect(throws: PersonaRegistryError.invalidVersion(id: "com.schema.f", version: -1)) {
            try b.register(schema("com.schema.f", version: -1))
        }
    }

    // MARK: - Case 7: Blank ID rejected

    @Test("Empty or whitespace-only ID is rejected with invalidID")
    func blankIDRejected() throws {
        var b = VersionedDefinitionRegistryBuilder<PersonaObjectSchemaDefinition>()
        #expect(throws: PersonaRegistryError.invalidID("")) {
            try b.register(schema("", version: 1))
        }
        #expect(throws: PersonaRegistryError.invalidID("   ")) {
            try b.register(schema("   ", version: 1))
        }
    }

    // MARK: - Case 8: Deterministic enumeration

    @Test("all returns definitions sorted by (id.rawValue, version)")
    func deterministicEnumeration() throws {
        let reg = try makeRegistry([
            schema("com.z", version: 1),
            schema("com.a", version: 2),
            schema("com.a", version: 1),
            schema("com.m", version: 1),
        ])
        let keys = reg.all.map { ($0.id.rawValue, $0.version) }
        #expect(keys.map { $0.0 } == ["com.a", "com.a", "com.m", "com.z"])
        #expect(keys.map { $0.1 } == [1, 2, 1, 1])
    }

    // MARK: - Case 9: Registration order independence

    @Test("Registering in reverse order produces the same all array")
    func registrationOrderIndependence() throws {
        let defs: [PersonaObjectSchemaDefinition] = [
            schema("com.schema.x", version: 1),
            schema("com.schema.y", version: 1),
            schema("com.schema.z", version: 1),
        ]
        let reg1 = try makeRegistry(defs)
        let reg2 = try makeRegistry(defs.reversed())
        let ids1 = reg1.all.map { $0.id.rawValue }
        let ids2 = reg2.all.map { $0.id.rawValue }
        #expect(ids1 == ids2)
    }

    // MARK: - Case 10: Frozen registry unaffected by later builder mutation

    @Test("Mutating the builder after freeze does not change the frozen registry")
    func frozenRegistryUnaffectedByLaterMutation() throws {
        var b = VersionedDefinitionRegistryBuilder<PersonaObjectSchemaDefinition>()
        try b.register(schema("com.schema.before", version: 1))
        let frozen = b.freeze()
        try b.register(schema("com.schema.after", version: 1))

        let idBefore = ObjectSchemaDefinitionID(rawValue: "com.schema.before")
        let idAfter  = ObjectSchemaDefinitionID(rawValue: "com.schema.after")

        // Frozen registry must contain the pre-freeze state only.
        #expect(frozen.definition(id: idBefore, version: 1) != nil)
        #expect(frozen.definition(id: idAfter,  version: 1) == nil)
        #expect(frozen.all.count == 1)
    }

    // MARK: - Case 11: Missing lookup returns nil

    @Test("definition(id:version:) and latest(id:) return nil for unknown IDs")
    func missingLookupReturnsNil() throws {
        let reg = try makeRegistry([schema("com.schema.known", version: 1)])
        let unknownID = ObjectSchemaDefinitionID(rawValue: "com.schema.unknown")
        #expect(reg.definition(id: unknownID, version: 1) == nil)
        #expect(reg.latest(id: unknownID) == nil)
    }
}
