//
//  WorkflowTargetValidator.swift
//  Kalsmritikosh
//
//  OPS-002 — the SHARED fail-closed target validator for workflow-object links (Issues, Tasks,
//  and future Stage-2/3 objects). Extracted from OPS-001's ProfessionalIssueRepository so the
//  existence + workspace-boundary rules live in ONE place instead of duplicated SQL:
//
//   • the target must EXIST in its canonical table (an unresolvable target is never silently
//     accepted);
//   • where the target's workspace/source boundary is DETERMINABLE (claim via evidence→KO→file,
//     event via source KO, evidenceBlock via ownership, KO/sourceVersion via file, entity via
//     manual∪derived membership) it must not belong EXCLUSIVELY outside the linking workspace;
//   • contradictions and gaps are global (existence only);
//   • an indeterminable boundary (claim with no evidence, file in no workspace, entity in no
//     workspace) is accepted on existence alone.
//

import Foundation

/// Shared validation failure — callers map it onto their own error vocabulary.
enum WorkflowTargetValidationError: Error, Equatable {
    case targetNotFound(kind: String, id: UUID)
    case crossWorkspace(kind: String, id: UUID)
}

enum WorkflowTargetValidator {

    /// Validate a canonical link target (by its stable kind discriminator + id) against the
    /// linking workspace. Kinds: claim / event / entity / evidenceBlock / knowledgeObject /
    /// sourceVersion / contradiction / gap.
    static func validate(kind: String, targetID: UUID, workspaceID: UUID,
                         database: Database) async throws {
        let table: String
        switch kind {
        case "claim":           table = "claims"
        case "event":           table = "events"
        case "entity":          table = "entities"
        case "evidenceBlock":   table = "evidence_blocks"
        case "knowledgeObject": table = "knowledge_objects"
        case "sourceVersion":   table = "source_versions"
        case "contradiction":   table = "contradictions"
        case "gap":             table = "gap_nodes"
        default:
            throw WorkflowTargetValidationError.targetNotFound(kind: kind, id: targetID)
        }
        guard try await exists(database, table: table, id: targetID) else {
            throw WorkflowTargetValidationError.targetNotFound(kind: kind, id: targetID)
        }

        // Boundary derivation → the set of FILE ids anchoring the target (empty = indeterminable).
        var fileIDs: [UUID] = []
        switch kind {
        case "claim":
            fileIDs = try await uuids(database, """
            SELECT DISTINCT k.file_id FROM claim_evidence_ref r
            JOIN knowledge_objects k ON k.id = r.knowledge_object_id
            WHERE r.claim_id = ?;
            """, [.uuid(targetID)])
        case "event":
            fileIDs = try await uuids(database, """
            SELECT DISTINCT k.file_id FROM events e
            JOIN knowledge_objects k ON k.id = e.source_object_id
            WHERE e.id = ?;
            """, [.uuid(targetID)])
        case "evidenceBlock":
            fileIDs = try await uuids(database, """
            SELECT DISTINCT k.file_id FROM evidence_block_objects o
            JOIN knowledge_objects k ON k.id = o.knowledge_object_id
            WHERE o.evidence_block_id = ?;
            """, [.uuid(targetID)])
        case "knowledgeObject":
            fileIDs = try await uuids(database, "SELECT file_id FROM knowledge_objects WHERE id = ?;", [.uuid(targetID)])
        case "sourceVersion":
            fileIDs = try await uuids(database, "SELECT logical_source_id FROM source_versions WHERE id = ?;", [.uuid(targetID)])
        case "entity":
            // Entities are bound by workspace MEMBERSHIP (manual ∪ derived), not files.
            let workspaces = try await uuids(database, """
            SELECT workspace_id FROM workspace_entities WHERE entity_id = ?
            UNION SELECT workspace_id FROM workspace_derived_entities WHERE entity_id = ?;
            """, [.uuid(targetID), .uuid(targetID)])
            if !workspaces.isEmpty, !workspaces.contains(workspaceID) {
                throw WorkflowTargetValidationError.crossWorkspace(kind: kind, id: targetID)
            }
            return
        case "contradiction", "gap":
            return   // global objects — no determinable per-workspace boundary
        default:
            return
        }
        guard !fileIDs.isEmpty else { return }   // indeterminable boundary → existence is enough
        let ph = fileIDs.map { _ in "?" }.joined(separator: ",")
        let holders = try await uuids(database,
            "SELECT DISTINCT workspace_id FROM workspace_sources WHERE file_id IN (\(ph));",
            fileIDs.map { .uuid($0) })
        if !holders.isEmpty, !holders.contains(workspaceID) {
            throw WorkflowTargetValidationError.crossWorkspace(kind: kind, id: targetID)
        }
    }

    private static func exists(_ db: Database, table: String, id: UUID) async throws -> Bool {
        Int(try await db.query("SELECT COUNT(*) FROM \(table) WHERE id = ?;", [.uuid(id)]).first?.int(0) ?? 0) > 0
    }

    private static func uuids(_ db: Database, _ sql: String, _ params: [SQLValue]) async throws -> [UUID] {
        (try await db.query(sql, params)).compactMap { $0.uuid(0) }
    }
}
