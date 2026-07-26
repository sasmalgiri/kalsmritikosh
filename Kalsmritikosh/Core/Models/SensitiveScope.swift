//
//  SensitiveScope.swift
//  Kalsmritikosh
//
//  OPS-003A — the shared policy that controls whether a piece of evidence may appear in
//  any surface (screen, retrieval, prompt, report, receipt, export). ONE policy per
//  operation, no per-persona forks. Reuses the SensitivityLevel / ProtectionLabel /
//  SensitivityInheritance vocabulary from SensitivityInheritance.swift (SEC-001).
//  Never introduces a second sensitivity or privilege enum.
//

import Foundation

/// The six surfaces a SensitiveScope can gate. A single SensitiveScope instance applies
/// to ONE surface; the assignment ledger holds the protection assignments.
public enum SensitiveUsePurpose: String, Codable, Sendable, CaseIterable {
    case screen
    case retrieval
    case prompt
    case report
    case receipt
    case export
}

/// The kinds of ledger objects that can receive a direct protection assignment.
/// Derived objects (summaries, memory, GenericFacts, walk steps, dataset cells) inherit
/// through lineage — they do not hold direct assignments.
public enum SensitiveScopeTargetKind: String, Codable, Sendable, CaseIterable {
    case file
    case sourceVersion
    case knowledgeObject
    case chunk
    case evidenceBlock
    case entity
    case event
    case claim
}

/// The ceiling for a given operation. Constructed per-operation, never stored — the
/// assignment ledger stores what protection objects carry; this carries what the
/// current operation is permitted to see.
///
/// Fail-closed: `permits(_:)` returns false for any label that exceeds the ceiling or
/// is privileged when this scope does not permit privileged material.
public nonisolated struct SensitiveScope: Sendable, Equatable {
    public let workspaceID: UUID
    public let maximumSensitivity: SensitivityLevel
    public let permitsPrivilegedMaterial: Bool
    public let purpose: SensitiveUsePurpose

    public nonisolated init(
        workspaceID: UUID,
        maximumSensitivity: SensitivityLevel,
        permitsPrivilegedMaterial: Bool,
        purpose: SensitiveUsePurpose
    ) {
        self.workspaceID = workspaceID
        self.maximumSensitivity = maximumSensitivity
        self.permitsPrivilegedMaterial = permitsPrivilegedMaterial
        self.purpose = purpose
    }

    /// Whether a target carrying `label` is accessible in this scope.
    /// Denied when sensitivity exceeds the ceiling, or target is privileged and
    /// this scope does not permit privileged material.
    public nonisolated func permits(_ label: ProtectionLabel) -> Bool {
        label.sensitivity <= maximumSensitivity
            && (!label.privileged || permitsPrivilegedMaterial)
    }
}

/// A single protection assignment on one ledger object. Append-only — revocation sets
/// `revokedAt` rather than deleting the row. The effective ProtectionLabel for a target
/// is SensitivityInheritance.inherit(from:) applied to all active assignments.
public nonisolated struct SensitiveScopeAssignment: Sendable {
    public let id: UUID
    public let targetKind: SensitiveScopeTargetKind
    public let targetID: UUID
    public let sensitivity: SensitivityLevel
    public let privileged: Bool
    /// Provenance: "user", "legacy_privileged_column", "deterministic_rule", etc.
    public let origin: String
    public let reason: String?
    /// Actor who created the assignment (user ID, "migration_v71", rule ID, etc.).
    public let assignedBy: String
    public let createdAt: Date
    public let revokedAt: Date?
    public let revokedBy: String?
    public let revokedReason: String?

    public nonisolated var isActive: Bool { revokedAt == nil }

    public nonisolated var protectionLabel: ProtectionLabel {
        ProtectionLabel(sensitivity: sensitivity, privileged: privileged)
    }
}

/// Action recorded on the `sensitive_scope_reviews` audit ledger.
public enum SensitiveScopeAction: String, Codable, Sendable {
    case assigned
    case revoked
}

/// Immutable audit record for one assign/revoke on an assignment.
public nonisolated struct SensitiveScopeReview: Sendable {
    public let id: UUID
    public let assignmentID: UUID
    public let action: SensitiveScopeAction
    public let actorNote: String?
    public let createdAt: Date
}

/// Errors surfaced by SensitiveScopeRepository.
public enum SensitiveScopeError: Error, Sendable {
    case assignmentNotFound(UUID)
    case assignmentAlreadyRevoked(UUID)
}
