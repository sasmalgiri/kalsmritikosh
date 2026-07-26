//
//  SensitiveScopeRepositoryTests.swift
//  KalsmritikoshTests
//
//  OPS-003A — protection assignment CRUD + scope-decision matrix.
//

import Testing
import Foundation
@testable import Kalsmritikosh

@Suite("OPS-003A SensitiveScopeRepository")
struct SensitiveScopeRepositoryTests {

    private let t0 = Date(timeIntervalSince1970: 1_750_000_000)

    private func rig() async throws -> (Database, SensitiveScopeRepository) {
        let db = try await MigrationFixtureBuilder.database(atVersion: 0)
        try await SchemaMigrations.migrate(db)
        return (db, SensitiveScopeRepository(database: db))
    }

    // MARK: - 1: Direct assignment blocks

    @Test("A direct restricted+privileged assignment blocks all scope surfaces")
    func assignedTargetIsBlocked() async throws {
        let (_, repo) = try await rig()
        let koID = UUID()
        let a = try await repo.assign(
            targetKind: .knowledgeObject, targetID: koID,
            sensitivity: .restricted, privileged: true,
            origin: "user", reason: nil, assignedBy: "u", at: t0)
        #expect(a.isActive)
        #expect(a.targetID == koID)
        #expect(a.sensitivity == .restricted)
        #expect(a.privileged)

        let label = try await repo.effectiveLabel(forTargetKind: .knowledgeObject, id: koID)
        #expect(label.sensitivity == .restricted)
        #expect(label.privileged)

        // Blocked from all purposes — internal scope cannot see restricted+privileged.
        for purpose in SensitiveUsePurpose.allCases {
            let scope = SensitiveScope(workspaceID: UUID(), maximumSensitivity: .internalLevel,
                                       permitsPrivilegedMaterial: false, purpose: purpose)
            #expect(!SensitiveScopeRepository.scopePermits(label, scope: scope),
                    "purpose \(purpose) should block restricted+privileged")
        }
    }

    // MARK: - 2: Revocation unblocks completely

    @Test("Revoking the only assignment returns the fail-closed default")
    func revocationUnblocksCompletely() async throws {
        let (_, repo) = try await rig()
        let koID = UUID()
        let a = try await repo.assign(
            targetKind: .knowledgeObject, targetID: koID,
            sensitivity: .confidential, privileged: false,
            origin: "user", reason: nil, assignedBy: "u", at: t0)

        try await repo.revoke(assignmentID: a.id, revokedBy: "u", reason: "cleared",
                              at: t0.addingTimeInterval(1))

        let label = try await repo.effectiveLabel(forTargetKind: .knowledgeObject, id: koID)
        // Fail-closed default: internal (not public), not privileged.
        #expect(label.sensitivity == .internalLevel)
        #expect(!label.privileged)

        // A scope with internal ceiling now permits this label.
        let scope = SensitiveScope(workspaceID: UUID(), maximumSensitivity: .internalLevel,
                                   permitsPrivilegedMaterial: false, purpose: .retrieval)
        #expect(SensitiveScopeRepository.scopePermits(label, scope: scope))

        // Revoking an already-revoked assignment throws.
        await #expect(throws: (any Error).self) {
            try await repo.revoke(assignmentID: a.id, revokedBy: "u", reason: nil,
                                  at: t0.addingTimeInterval(2))
        }
    }

    // MARK: - 3: Privilege sticky under high-sensitivity scope

    @Test("Privilege blocks even when sensitivity is within scope ceiling")
    func privilegeStickyUnderHighSensitivityScope() async throws {
        let (_, repo) = try await rig()
        let koID = UUID()
        _ = try await repo.assign(
            targetKind: .knowledgeObject, targetID: koID,
            sensitivity: .publicLevel, privileged: true,
            origin: "user", reason: nil, assignedBy: "u", at: t0)

        let label = try await repo.effectiveLabel(forTargetKind: .knowledgeObject, id: koID)
        #expect(label.sensitivity == .publicLevel)
        #expect(label.privileged)

        // Scope ceiling is restricted (very permissive) but does NOT permit privileged —
        // the assignment must still be blocked.
        let scope = SensitiveScope(workspaceID: UUID(), maximumSensitivity: .restricted,
                                   permitsPrivilegedMaterial: false, purpose: .prompt)
        #expect(!SensitiveScopeRepository.scopePermits(label, scope: scope))

        // A scope that explicitly permits privileged material IS allowed.
        let permissiveScope = SensitiveScope(workspaceID: UUID(), maximumSensitivity: .restricted,
                                             permitsPrivilegedMaterial: true, purpose: .prompt)
        #expect(SensitiveScopeRepository.scopePermits(label, scope: permissiveScope))
    }

    // MARK: - 4: Batch resolution

    @Test("Batch resolution returns the correct label for each target")
    func batchResolutionReturnsBothLabels() async throws {
        let (_, repo) = try await rig()
        let restrictedID = UUID()
        let unassignedID = UUID()
        _ = try await repo.assign(
            targetKind: .knowledgeObject, targetID: restrictedID,
            sensitivity: .restricted, privileged: false,
            origin: "user", reason: nil, assignedBy: "u", at: t0)

        let labels = try await repo.batchEffectiveLabels([
            (.knowledgeObject, restrictedID),
            (.knowledgeObject, unassignedID)
        ])
        #expect(labels[restrictedID]?.sensitivity == .restricted)
        #expect(labels[unassignedID]?.sensitivity == .internalLevel,
                "Unassigned target must resolve to fail-closed internal, not public")
    }

    // MARK: - 5: Unknown target fails closed

    @Test("A target with no assignment resolves to internal, never public")
    func unknownTargetFailsClosed() async throws {
        let (_, repo) = try await rig()
        let label = try await repo.effectiveLabel(forTargetKind: .claim, id: UUID())
        #expect(label.sensitivity == .internalLevel)
        #expect(!label.privileged)
        // Ensure it is NOT publicLevel — that would be an open-by-default failure.
        #expect(label.sensitivity != .publicLevel)
    }

    // MARK: - 6: Multiple active assignments inherit highest

    @Test("Two active assignments on the same target inherit the higher sensitivity")
    func multipleActiveAssignmentsInheritHighest() async throws {
        let (_, repo) = try await rig()
        let koID = UUID()
        _ = try await repo.assign(
            targetKind: .knowledgeObject, targetID: koID,
            sensitivity: .confidential, privileged: false,
            origin: "user", reason: nil, assignedBy: "u", at: t0)
        _ = try await repo.assign(
            targetKind: .knowledgeObject, targetID: koID,
            sensitivity: .restricted, privileged: false,
            origin: "user", reason: nil, assignedBy: "u", at: t0.addingTimeInterval(1))

        let label = try await repo.effectiveLabel(forTargetKind: .knowledgeObject, id: koID)
        #expect(label.sensitivity == .restricted, "inherit() should return the max sensitivity")
    }

    // MARK: - 7: Revoke one, other remains active

    @Test("Revoking one assignment leaves the other active on the same target")
    func revokeOneAssignmentLeavesOtherActive() async throws {
        let (_, repo) = try await rig()
        let koID = UUID()
        let a1 = try await repo.assign(
            targetKind: .knowledgeObject, targetID: koID,
            sensitivity: .confidential, privileged: false,
            origin: "user", reason: nil, assignedBy: "u", at: t0)
        _ = try await repo.assign(
            targetKind: .knowledgeObject, targetID: koID,
            sensitivity: .restricted, privileged: false,
            origin: "user", reason: nil, assignedBy: "u", at: t0.addingTimeInterval(1))

        try await repo.revoke(assignmentID: a1.id, revokedBy: "u", reason: nil,
                              at: t0.addingTimeInterval(2))

        let label = try await repo.effectiveLabel(forTargetKind: .knowledgeObject, id: koID)
        // The restricted assignment (a2) survives — target still blocked.
        #expect(label.sensitivity == .restricted)

        let all = try await repo.assignments(forTargetKind: .knowledgeObject, id: koID)
        #expect(all.count == 2)
        #expect(all.filter(\.isActive).count == 1)
        #expect(all.filter { !$0.isActive }.count == 1)
    }
}
