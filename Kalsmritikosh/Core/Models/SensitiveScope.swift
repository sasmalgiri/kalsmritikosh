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
//  OPS-003A.1 adds: SensitiveScopeTarget (polymorphic hashable key), AssignmentAuthority
//  (structural enforcement preventing automation from setting privileged=true),
//  ProtectionResolution (explicit brokenLineage vs. resolved), new SensitiveScopeError cases.
//
//  OPS-003A.2 hardens: userDirect renamed to userConfirmed (requires actorID + confirmationID
//  — forgery now requires the caller to supply an auditable identity + event UUID); whitespace-
//  only actorID rejected; Claim lineage gains 7th branch (EB→EBO→KO→File); File privileged
//  assignments propagate to child KOs in the legacy column.
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

/// Polymorphic, hashable identity for any assignable ledger target.
///
/// `kind + id` is the canonical key — using UUID alone is ambiguous because two different
/// target tables can coincidentally hold the same UUID.
public nonisolated struct SensitiveScopeTarget: Hashable, Equatable, Sendable {
    public let kind: SensitiveScopeTargetKind
    public let id: UUID

    public nonisolated init(kind: SensitiveScopeTargetKind, id: UUID) {
        self.kind = kind
        self.id = id
    }
}

/// Structured authority for creating a protection assignment.
///
/// The enum structure makes it impossible for automation to autonomously set
/// `privileged = true`: only `.userConfirmed` carries a privilege flag; `.migration` and
/// `.systemRule` are structurally non-privileged. The `actorID` and `confirmationID` fields
/// prove that a specific human identity confirmed the privilege classification.
public enum AssignmentAuthority: Sendable {
    /// A human-confirmed assignment. `actorID` identifies the confirming actor and is stored
    /// as `assigned_by` (must be non-blank after whitespace trimming). `confirmationID` is a
    /// caller-supplied UUID that uniquely identifies this confirmation event; it is embedded
    /// in the stored `origin` string so the human-confirmed provenance is auditable without a
    /// schema change. Only this case may carry `privileged: true`.
    case userConfirmed(actorID: String, confirmationID: UUID, privileged: Bool)
    /// A migration or backfill script. Always non-privileged.
    case migration(tag: String)
    /// A deterministic rule or automated system. Always non-privileged.
    case systemRule(tag: String)

    /// Whether this authority carries a privilege flag.
    public nonisolated var isPrivileged: Bool {
        guard case .userConfirmed(_, _, let p) = self else { return false }
        return p
    }

    /// Stable string stored in `sensitive_scope_assignments.origin`.
    /// For userConfirmed: `"user_confirmed:<confirmationID.uuidString>"`.
    public nonisolated var originString: String {
        switch self {
        case .userConfirmed(_, let cid, _): return "user_confirmed:\(cid.uuidString)"
        case .migration(let t):             return "migration:\(t)"
        case .systemRule(let t):            return "system_rule:\(t)"
        }
    }

    /// Non-blank (after trimming) string stored in `sensitive_scope_assignments.assigned_by`.
    /// For userConfirmed: `actorID`. For migration/systemRule: the tag.
    public nonisolated var actorString: String {
        switch self {
        case .userConfirmed(let aid, _, _): return aid
        case .migration(let t):             return t
        case .systemRule(let t):            return t
        }
    }
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
    public let origin: String
    public let reason: String?
    public let assignedBy: String
    public let createdAt: Date
    public let revokedAt: Date?
    public let revokedBy: String?
    public let revokedReason: String?

    public nonisolated var isActive: Bool { revokedAt == nil }

    /// Polymorphic identity for this assignment's target.
    public nonisolated var target: SensitiveScopeTarget {
        SensitiveScopeTarget(kind: targetKind, id: targetID)
    }

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

/// Resolution outcome from the lineage-aware effective-label resolver.
///
/// Callers MUST treat `.brokenLineage` as a denial — it means the target UUID was not
/// found in any known table and access cannot be granted.
public enum ProtectionResolution: Sendable, Equatable {
    /// The target exists. Label is the maximum of all direct and lineage-inherited active
    /// assignments, or the fail-closed default (.internalLevel, not privileged) when no
    /// active assignment exists anywhere in the lineage.
    case resolved(ProtectionLabel)
    /// The target UUID is not found in any known table. Access must be denied.
    case brokenLineage

    /// The computed label, or nil when lineage is broken.
    public nonisolated var label: ProtectionLabel? {
        guard case .resolved(let l) = self else { return nil }
        return l
    }

    public nonisolated var isBroken: Bool {
        if case .brokenLineage = self { return true }
        return false
    }
}

/// Errors surfaced by SensitiveScopeRepository.
public enum SensitiveScopeError: Error, Sendable {
    case assignmentNotFound(UUID)
    case assignmentAlreadyRevoked(UUID)
    /// The target UUID is not present in its canonical table — assignment refused.
    case targetNotFound(SensitiveScopeTarget)
    /// A row in sensitive_scope_assignments could not be decoded (invalid sensitivity or kind).
    case malformedAssignmentRow(UUID)
    /// The actor string for an assignment or revocation must not be blank.
    case nonblankActorRequired
}
