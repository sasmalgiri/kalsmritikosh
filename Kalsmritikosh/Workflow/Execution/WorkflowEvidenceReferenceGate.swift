//
//  WorkflowEvidenceReferenceGate.swift
//  Kalsmritikosh
//
//  PJE-006B — Evidence and Analytical Step Executors.
//  The reference gate that evidence/analytical executors consult BEFORE accepting
//  a canonical reference into workflow-owned state:
//    1. the referenced object must exist in its canonical table;
//    2. it must not belong exclusively outside the run's workspace;
//    3. where a sensitivity lineage is resolvable, the effective ProtectionLabel
//       must be permitted (by the active SensitiveScope, or by the fail-closed
//       default when no scope is provided).
//
//  Executors depend only on the protocol — never on Database or repository types.
//  The production adapter lives here because it is workflow-plumbing, not an executor.
//

import Foundation

// MARK: - Selectable canonical object kinds

/// Closed vocabulary of canonical object kinds a workflow evidence step may reference.
public enum WorkflowEvidenceObjectKind: String, Codable, Sendable, CaseIterable, Equatable {
    case claim
    case evidenceBlock
    case sourceVersion
    case entity
    case event
    case issue
    case gap
    case contradiction
}

// MARK: - Verdict

/// Outcome of gate verification for one canonical reference.
public enum WorkflowEvidenceGateVerdict: Sendable, Equatable {
    case permitted
    case denied(reason: String)

    public var isPermitted: Bool {
        if case .permitted = self { return true }
        return false
    }
}

// MARK: - Gate protocol

/// Verifies a single canonical reference against existence, workspace boundary,
/// and sensitive-scope policy. Implementations must be fail-closed: any error or
/// unresolvable state is a denial, never a pass-through.
public protocol WorkflowEvidenceReferenceGating: Sendable {
    func verdict(
        kind: WorkflowEvidenceObjectKind,
        canonicalObjectID: UUID,
        workspaceID: UUID
    ) async -> WorkflowEvidenceGateVerdict
}

// MARK: - Production adapter

/// Production gate backed by the canonical ledger.
///
/// Existence + workspace boundary go through the shared `WorkflowTargetValidator`
/// (issues are workspace-owned rows checked directly). Sensitivity is resolved via
/// `SensitiveScopeRepository.effectiveLabel` for the kinds that carry a lineage
/// (claim / evidenceBlock / sourceVersion / entity / event).
///
/// Scope policy:
///  • an explicit `SensitiveScope` is applied via `scope.permits(label)`;
///  • with NO scope the fail-closed default applies — nothing privileged and
///    nothing above `.internalLevel` (the unassigned-object default) is permitted.
public nonisolated struct CanonicalWorkflowEvidenceReferenceGate: WorkflowEvidenceReferenceGating {

    private let database: Database
    private let scopeRepository: SensitiveScopeRepository
    private let scope: SensitiveScope?

    public nonisolated init(
        database: Database,
        scopeRepository: SensitiveScopeRepository,
        scope: SensitiveScope? = nil
    ) {
        self.database = database
        self.scopeRepository = scopeRepository
        self.scope = scope
    }

    public func verdict(
        kind: WorkflowEvidenceObjectKind,
        canonicalObjectID: UUID,
        workspaceID: UUID
    ) async -> WorkflowEvidenceGateVerdict {
        // 1. Existence + workspace boundary (fail closed on any error)
        do {
            switch kind {
            case .issue:
                try await validateIssue(canonicalObjectID, workspaceID: workspaceID)
            case .claim, .evidenceBlock, .sourceVersion, .entity, .event, .gap, .contradiction:
                try await WorkflowTargetValidator.validate(
                    kind: Self.validatorKind(for: kind),
                    targetID: canonicalObjectID,
                    workspaceID: workspaceID,
                    database: database
                )
            }
        } catch WorkflowTargetValidationError.targetNotFound {
            return .denied(reason: "Referenced \(kind.rawValue) does not exist")
        } catch WorkflowTargetValidationError.crossWorkspace {
            return .denied(reason: "Referenced \(kind.rawValue) belongs to a different workspace")
        } catch {
            return .denied(reason: "Reference verification failed: \(error)")
        }

        // 2. Sensitive-scope enforcement where a lineage is resolvable
        guard let scopeTargetKind = Self.scopeTargetKind(for: kind) else {
            // issue / gap / contradiction carry no sensitivity lineage — boundary check is final
            return .permitted
        }
        let target = SensitiveScopeTarget(kind: scopeTargetKind, id: canonicalObjectID)
        let resolution: ProtectionResolution
        do {
            resolution = try await scopeRepository.effectiveLabel(for: target)
        } catch {
            return .denied(reason: "Sensitivity resolution failed: \(error)")
        }
        switch resolution {
        case .brokenLineage:
            return .denied(reason: "Sensitivity lineage is broken for referenced \(kind.rawValue)")
        case .resolved(let label):
            if let scope = scope {
                guard scope.permits(label) else {
                    return .denied(reason: "Active sensitive scope does not permit this \(kind.rawValue)")
                }
                return .permitted
            }
            // Fail-closed default: no privileged material, nothing above the
            // unassigned-object default level.
            guard !label.privileged, label.sensitivity <= .internalLevel else {
                return .denied(reason: "No active sensitive scope permits this protected \(kind.rawValue)")
            }
            return .permitted
        }
    }

    // MARK: - Private

    private func validateIssue(_ issueID: UUID, workspaceID: UUID) async throws {
        let rows = try await database.query(
            "SELECT workspace_id FROM professional_issues WHERE id = ?;",
            [.uuid(issueID)]
        )
        guard let owner = rows.first?.uuid(0) else {
            throw WorkflowTargetValidationError.targetNotFound(kind: "issue", id: issueID)
        }
        guard owner == workspaceID else {
            throw WorkflowTargetValidationError.crossWorkspace(kind: "issue", id: issueID)
        }
    }

    private static nonisolated func validatorKind(for kind: WorkflowEvidenceObjectKind) -> String {
        switch kind {
        case .claim:         return "claim"
        case .evidenceBlock: return "evidenceBlock"
        case .sourceVersion: return "sourceVersion"
        case .entity:        return "entity"
        case .event:         return "event"
        case .gap:           return "gap"
        case .contradiction: return "contradiction"
        case .issue:         return "issue" // handled separately; never reaches the validator
        }
    }

    private static nonisolated func scopeTargetKind(
        for kind: WorkflowEvidenceObjectKind
    ) -> SensitiveScopeTargetKind? {
        switch kind {
        case .claim:         return .claim
        case .evidenceBlock: return .evidenceBlock
        case .sourceVersion: return .sourceVersion
        case .entity:        return .entity
        case .event:         return .event
        case .issue, .gap, .contradiction: return nil
        }
    }
}
