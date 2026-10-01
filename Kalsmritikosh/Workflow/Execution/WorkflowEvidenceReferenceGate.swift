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
/// (claim / evidenceBlock / sourceVersion / entity / event). Issues, gaps and contradictions
/// (F29) are checked through the evidence they are built from: every linked / cited object
/// must pass the same workspace + sensitivity checks, and under an explicit scope an object
/// with no resolvable evidence is denied.
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
        if let scopeTargetKind = Self.scopeTargetKind(for: kind) {
            return await sensitivityVerdict(
                SensitiveScopeTarget(kind: scopeTargetKind, id: canonicalObjectID), kindName: kind.rawValue)
        }

        // 3. F29 — issue / gap / contradiction carry no label of their own, but their text is
        //    drawn from evidence that does. Every piece of that evidence must pass the same
        //    workspace + sensitivity checks; one failing piece denies the whole reference.
        let lineage: [LineageMember]
        do {
            lineage = try await lineageMembers(of: kind, id: canonicalObjectID)
        } catch {
            return .denied(reason: "Lineage resolution failed for referenced \(kind.rawValue): \(error)")
        }
        // A restricted workflow (explicit scope) cannot vouch for an object whose evidence is
        // unknown; the unscoped default keeps the existing global-object behaviour.
        if lineage.isEmpty, scope != nil {
            return .denied(reason: "Referenced \(kind.rawValue) has no resolvable evidence lineage")
        }
        for member in lineage {
            let memberVerdict = await leafVerdict(member, workspaceID: workspaceID)
            if case .denied(let reason) = memberVerdict {
                return .denied(reason: "Referenced \(kind.rawValue) draws on evidence that is not permitted: \(reason)")
            }
        }
        return .permitted
    }

    // MARK: - Private

    /// One piece of evidence a composite object (issue / gap / contradiction) is built from.
    private struct LineageMember {
        let validatorKind: String
        let scopeKind: SensitiveScopeTargetKind
        let id: UUID
    }

    private enum LineageError: Error {
        case malformedReference(String)
        case unsupportedLinkKind(String)
    }

    /// Existence + workspace boundary + sensitivity for one leaf evidence object.
    private func leafVerdict(_ member: LineageMember, workspaceID: UUID) async -> WorkflowEvidenceGateVerdict {
        do {
            try await WorkflowTargetValidator.validate(
                kind: member.validatorKind, targetID: member.id,
                workspaceID: workspaceID, database: database)
        } catch WorkflowTargetValidationError.targetNotFound {
            return .denied(reason: "\(member.validatorKind) does not exist")
        } catch WorkflowTargetValidationError.crossWorkspace {
            return .denied(reason: "\(member.validatorKind) belongs to a different workspace")
        } catch {
            return .denied(reason: "\(member.validatorKind) verification failed: \(error)")
        }
        return await sensitivityVerdict(
            SensitiveScopeTarget(kind: member.scopeKind, id: member.id), kindName: member.validatorKind)
    }

    private func sensitivityVerdict(_ target: SensitiveScopeTarget, kindName: String) async -> WorkflowEvidenceGateVerdict {
        let resolution: ProtectionResolution
        do {
            resolution = try await scopeRepository.effectiveLabel(for: target)
        } catch {
            return .denied(reason: "Sensitivity resolution failed: \(error)")
        }
        switch resolution {
        case .brokenLineage:
            return .denied(reason: "Sensitivity lineage is broken for referenced \(kindName)")
        case .resolved(let label):
            if let scope = scope {
                guard scope.permits(label) else {
                    return .denied(reason: "Active sensitive scope does not permit this \(kindName)")
                }
                return .permitted
            }
            // Fail-closed default: no privileged material, nothing above the
            // unassigned-object default level.
            guard !label.privileged, label.sensitivity <= .internalLevel else {
                return .denied(reason: "No active sensitive scope permits this protected \(kindName)")
            }
            return .permitted
        }
    }

    /// The leaf evidence behind a composite object. Issues expand their links one level
    /// (a linked gap / contradiction expands to ITS evidence); an unknown link kind or a
    /// non-UUID reference is an error, never skipped.
    private func lineageMembers(of kind: WorkflowEvidenceObjectKind, id: UUID) async throws -> [LineageMember] {
        switch kind {
        case .contradiction:
            let rows = try await database.query(
                "SELECT evidence_a, evidence_b FROM contradictions WHERE id = ?;", [.uuid(id)])
            guard let row = rows.first else { return [] }
            return try [0, 1].compactMap { try Self.member(row.string($0), validatorKind: "knowledgeObject", scopeKind: .knowledgeObject) }
        case .gap:
            let rows = try await database.query(
                "SELECT evidence_object_id, before_event, after_event FROM gap_nodes WHERE id = ?;", [.uuid(id)])
            guard let row = rows.first else { return [] }
            return try [
                Self.member(row.string(0), validatorKind: "knowledgeObject", scopeKind: .knowledgeObject),
                Self.member(row.string(1), validatorKind: "event", scopeKind: .event),
                Self.member(row.string(2), validatorKind: "event", scopeKind: .event),
            ].compactMap { $0 }
        case .issue:
            let rows = try await database.query(
                "SELECT target_kind, target_id FROM professional_issue_links WHERE issue_id = ?;", [.uuid(id)])
            var members: [LineageMember] = []
            for row in rows {
                let linkKind = row.string(0) ?? ""
                guard let targetID = row.string(1).flatMap(UUID.init(uuidString:)) else {
                    throw LineageError.malformedReference("issue link \(linkKind)")
                }
                switch linkKind {
                case "contradiction": members += try await lineageMembers(of: .contradiction, id: targetID)
                case "gap":           members += try await lineageMembers(of: .gap, id: targetID)
                default:
                    guard let scopeKind = SensitiveScopeTargetKind(rawValue: linkKind),
                          IssueLinkTarget(kind: linkKind, targetID: targetID) != nil else {
                        throw LineageError.unsupportedLinkKind(linkKind)
                    }
                    members.append(LineageMember(validatorKind: linkKind, scopeKind: scopeKind, id: targetID))
                }
            }
            return members
        case .claim, .evidenceBlock, .sourceVersion, .entity, .event:
            return []
        }
    }

    /// nil column → no member; a present value that isn't a UUID → error (fail closed).
    private static nonisolated func member(
        _ raw: String?, validatorKind: String, scopeKind: SensitiveScopeTargetKind
    ) throws -> LineageMember? {
        guard let raw, !raw.isEmpty else { return nil }
        guard let id = UUID(uuidString: raw) else {
            throw LineageError.malformedReference(validatorKind)
        }
        return LineageMember(validatorKind: validatorKind, scopeKind: scopeKind, id: id)
    }

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
