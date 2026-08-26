//
//  MethodRunRepository.swift
//  Kalsmritikosh
//
//  PM-002 — the ONE authoritative writer for the Stage 4 MethodRun aggregate
//  (schema v79). It provides safe PERSISTENCE PRIMITIVES only: create a run, and
//  append nodes, edges, evidence links, assumptions, findings, reviews and
//  validation results. The complete lifecycle transition service (start / pause /
//  resume / block / complete / cancel / supersede / review gates) is PM-004.
//
//  Guarantees enforced here:
//    • Optimistic concurrency — every aggregate mutation is CAS-guarded on the
//      MethodRun revision; a stale expected revision writes nothing.
//    • One mutation = one revision increase, in one SAVEPOINT (atomic; a partial
//      failure leaves no orphan child and no revision change).
//    • Same-run ownership — a child may only reference nodes/findings of its own
//      run (checked here for a clean error; also enforced by composite FKs).
//    • Canonical evidence references are validated (existence + workspace + scope)
//      through the SHARED WorkflowEvidenceReferenceGating — never a new resolver —
//      and stored as IDs only; no evidence content is copied.
//    • Reviews are HUMAN and append-only (MethodReview.validate() + a CHECK).
//    • Findings never promote a Claim; related_claim_id is a validated soft ref.
//    • Canonical tables (claims/evidence/entities/events/…) are never mutated.
//

import Foundation

public actor MethodRunRepository {

    let database: Database

    public init(database: Database) { self.database = database }

    // MARK: - Column lists (decoder order must match)

    static let runColumns =
        "id, workspace_id, method_definition_id, method_definition_version, workflow_run_id, "
        + "workflow_step_run_id, status, title, revision, created_by, created_at, updated_at, "
        + "completed_at, superseded_by_run_id, content_revision"
    static let nodeColumns =
        "id, method_run_id, node_definition_key, node_kind, label, body, working_state, ordinal, "
        + "parent_node_id, created_at, updated_at"
    static let edgeColumns =
        "id, method_run_id, from_node_id, to_node_id, edge_kind, label, ordinal"
    static let linkColumns =
        "id, method_run_id, node_id, target_kind, target_id, role, ordinal, added_by, added_at, input_role"
    static let assumptionColumns =
        "id, method_run_id, node_id, statement, status, rationale, created_by, reviewed_by, reviewed_at"
    static let findingColumns =
        "id, method_run_id, node_id, statement, finding_kind, support_status, review_status, "
        + "related_claim_id, created_at"
    static let reviewColumns =
        "id, method_run_id, node_id, finding_id, action, actor_kind, actor_identifier, comment, reviewed_at, "
        + "review_key, reviewed_content_revision"
    static let validationColumns =
        "id, method_run_id, validator_id, validator_version, severity, code, message, subject_kind, "
        + "subject_id, created_at, validation_batch_id, evaluated_content_revision"
    static let eventColumns =
        "id, method_run_id, sequence, run_revision, content_revision, action, from_status, to_status, "
        + "actor_kind, actor_identifier, reason, occurred_at"

    // MARK: - Reads

    public func run(id: UUID) async throws -> MethodRun? {
        try await database.query("SELECT \(Self.runColumns) FROM method_runs WHERE id = ?;", [.uuid(id)])
            .first.flatMap(Self.decodeRun)
    }

    public func runs(inWorkspace workspaceID: UUID) async throws -> [MethodRun] {
        try await database.query(
            "SELECT \(Self.runColumns) FROM method_runs WHERE workspace_id = ? ORDER BY created_at, id;",
            [.uuid(workspaceID)]).compactMap(Self.decodeRun)
    }

    public func runs(definitionID: ProfessionalMethodDefinitionID, version: Int) async throws -> [MethodRun] {
        try await database.query(
            "SELECT \(Self.runColumns) FROM method_runs WHERE method_definition_id = ? "
            + "AND method_definition_version = ? ORDER BY created_at, id;",
            [.text(definitionID.rawValue), .integer(Int64(version))]).compactMap(Self.decodeRun)
    }

    public func nodes(runID: UUID) async throws -> [MethodNode] {
        try await database.query(
            "SELECT \(Self.nodeColumns) FROM method_nodes WHERE method_run_id = ? ORDER BY ordinal, id;",
            [.uuid(runID)]).compactMap(Self.decodeNode)
    }

    public func edges(runID: UUID) async throws -> [MethodEdge] {
        try await database.query(
            "SELECT \(Self.edgeColumns) FROM method_edges WHERE method_run_id = ? ORDER BY ordinal, id;",
            [.uuid(runID)]).compactMap(Self.decodeEdge)
    }

    public func evidenceLinks(runID: UUID) async throws -> [MethodEvidenceLink] {
        try await database.query(
            "SELECT \(Self.linkColumns) FROM method_evidence_links WHERE method_run_id = ? ORDER BY ordinal, id;",
            [.uuid(runID)]).compactMap(Self.decodeLink)
    }

    public func assumptions(runID: UUID) async throws -> [MethodAssumption] {
        // MethodAssumption carries no timestamp; rowid gives deterministic insertion order.
        try await database.query(
            "SELECT \(Self.assumptionColumns) FROM method_assumptions WHERE method_run_id = ? ORDER BY rowid;",
            [.uuid(runID)]).compactMap(Self.decodeAssumption)
    }

    public func findings(runID: UUID) async throws -> [MethodFinding] {
        try await database.query(
            "SELECT \(Self.findingColumns) FROM method_findings WHERE method_run_id = ? ORDER BY created_at, id;",
            [.uuid(runID)]).compactMap(Self.decodeFinding)
    }

    public func reviews(runID: UUID) async throws -> [MethodReview] {
        try await database.query(
            "SELECT \(Self.reviewColumns) FROM method_reviews WHERE method_run_id = ? ORDER BY reviewed_at, id;",
            [.uuid(runID)]).compactMap(Self.decodeReview)
    }

    public func validationResults(runID: UUID) async throws -> [MethodValidationResult] {
        try await database.query(
            "SELECT \(Self.validationColumns) FROM method_validation_results WHERE method_run_id = ? ORDER BY created_at, id;",
            [.uuid(runID)]).compactMap(Self.decodeValidation)
    }

    /// The run plus all seven child collections read in ONE non-interleavable
    /// database operation, so the aggregate is a single consistent snapshot (never
    /// a run at revision N with children from revision N+1). A mutation cannot
    /// interleave between the reads because they all run inside one savepoint on
    /// the isolated Database.
    /// The run plus all child collections + lifecycle events read in ONE
    /// non-interleavable database operation — a single consistent snapshot.
    public func aggregate(runID: UUID) async throws -> MethodRunAggregate? {
        try await database.withSavepoint("mrr_agg_\(Self.spSuffix(runID))") { db in
            try Self.reconstruct(db, runID: runID)
        }
    }

    public func lifecycleEvents(runID: UUID) async throws -> [MethodLifecycleEvent] {
        try await database.query(
            "SELECT \(Self.eventColumns) FROM method_run_events WHERE method_run_id = ? ORDER BY sequence;",
            [.uuid(runID)]).compactMap(Self.decodeEvent)
    }

    // MARK: - Create

    public func createRun(
        workspaceID: UUID,
        methodDefinitionID: ProfessionalMethodDefinitionID,
        methodDefinitionVersion: Int,
        workflowRunID: UUID? = nil,
        workflowStepRunID: UUID? = nil,
        title: String? = nil,
        createdBy: String,
        now: Date
    ) async throws -> MethodRun {
        guard methodDefinitionVersion >= 1 else { throw MethodPersistenceError.invalidRun("version must be >= 1") }
        guard !createdBy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MethodPersistenceError.invalidRun("createdBy is blank")
        }
        guard !methodDefinitionID.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MethodPersistenceError.invalidRun("methodDefinitionID is blank")
        }
        guard try await database.query("SELECT 1 FROM workspaces WHERE id = ?;", [.uuid(workspaceID)]).first != nil else {
            throw MethodPersistenceError.workspaceNotFound(workspaceID)
        }
        // Soft workflow invocation references — validated at creation time only.
        if let wfRun = workflowRunID {
            let rows = try await database.query("SELECT workspace_id FROM workflow_runs WHERE id = ?;", [.uuid(wfRun)])
            guard let wsOfRun = rows.first?.uuid(0) else {
                throw MethodPersistenceError.unresolvedWorkflowReference("workflow run \(wfRun) not found")
            }
            guard wsOfRun == workspaceID else {
                throw MethodPersistenceError.unresolvedWorkflowReference("workflow run in a different workspace")
            }
            if let step = workflowStepRunID {
                let srows = try await database.query("SELECT run_id FROM workflow_step_runs WHERE id = ?;", [.uuid(step)])
                guard let runOfStep = srows.first?.uuid(0) else {
                    throw MethodPersistenceError.unresolvedWorkflowReference("workflow step \(step) not found")
                }
                guard runOfStep == wfRun else {
                    throw MethodPersistenceError.unresolvedWorkflowReference("workflow step does not belong to the run")
                }
            }
        } else if workflowStepRunID != nil {
            throw MethodPersistenceError.unresolvedWorkflowReference("a workflow step reference requires a workflow run reference")
        }

        let run = MethodRun(
            workspaceID: workspaceID, methodDefinitionID: methodDefinitionID,
            methodDefinitionVersion: methodDefinitionVersion,
            workflowRunID: workflowRunID, workflowStepRunID: workflowStepRunID,
            status: .draft, title: title, revision: 1, createdBy: createdBy,
            createdAt: now, updatedAt: now)
        let sp = "mrr_create_\(Self.spSuffix(run.id))"
        try await database.withSavepoint(sp) { db in
            try db.exec("""
                INSERT INTO method_runs
                    (id, workspace_id, method_definition_id, method_definition_version,
                     workflow_run_id, workflow_step_run_id, status, title, revision, content_revision,
                     created_by, created_at, updated_at, completed_at, superseded_by_run_id)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);
                """, [
                    .uuid(run.id), .uuid(run.workspaceID), .text(run.methodDefinitionID.rawValue),
                    .integer(Int64(run.methodDefinitionVersion)),
                    run.workflowRunID.map(SQLValue.uuid) ?? .null,
                    run.workflowStepRunID.map(SQLValue.uuid) ?? .null,
                    .text(run.status.rawValue), .optionalText(run.title),
                    .integer(Int64(run.revision)), .integer(Int64(run.contentRevision)), .text(run.createdBy),
                    .date(run.createdAt), .date(run.updatedAt),
                    .optionalDate(run.completedAt),
                    run.supersededByRunID.map(SQLValue.uuid) ?? .null
                ])
        }
        return run
    }

    // MARK: - Append mutations (each: one SAVEPOINT, one revision increase)

    @discardableResult
    public func addNode(_ node: MethodNode, expectedRevision: Int, now: Date) async throws -> MethodRun {
        guard node.ordinal >= 0 else { throw MethodPersistenceError.invalidOrdinal(node.ordinal) }
        return try await database.withSavepoint("mrr_node_\(Self.spSuffix(node.id))\(expectedRevision)") { db in
            try Self.casBump(db, runID: node.methodRunID, expected: expectedRevision, now: now, contentChanged: true)
            if let parent = node.parentNodeID {
                try Self.requireOwned(db, table: "method_nodes", id: parent, runID: node.methodRunID, what: "parent node")
            }
            try db.exec("""
                INSERT INTO method_nodes
                    (id, method_run_id, node_definition_key, node_kind, label, body,
                     working_state, ordinal, parent_node_id, created_at, updated_at)
                VALUES (?,?,?,?,?,?,?,?,?,?,?);
                """, [
                    .uuid(node.id), .uuid(node.methodRunID), .text(node.nodeDefinitionKey),
                    .text(node.nodeKind.rawValue), .text(node.label), .optionalText(node.body),
                    .text(node.workingState.rawValue), .integer(Int64(node.ordinal)),
                    node.parentNodeID.map(SQLValue.uuid) ?? .null,
                    .date(node.createdAt), .date(node.updatedAt)
                ])
            return try Self.requireRun(db, id: node.methodRunID)
        }
    }

    @discardableResult
    public func addEdge(_ edge: MethodEdge, expectedRevision: Int, now: Date) async throws -> MethodRun {
        guard edge.ordinal >= 0 else { throw MethodPersistenceError.invalidOrdinal(edge.ordinal) }
        return try await database.withSavepoint("mrr_edge_\(Self.spSuffix(edge.id))\(expectedRevision)") { db in
            try Self.casBump(db, runID: edge.methodRunID, expected: expectedRevision, now: now, contentChanged: true)
            try Self.requireOwned(db, table: "method_nodes", id: edge.fromNodeID, runID: edge.methodRunID, what: "edge from-node")
            try Self.requireOwned(db, table: "method_nodes", id: edge.toNodeID, runID: edge.methodRunID, what: "edge to-node")
            try db.exec("""
                INSERT INTO method_edges
                    (id, method_run_id, from_node_id, to_node_id, edge_kind, label, ordinal)
                VALUES (?,?,?,?,?,?,?);
                """, [
                    .uuid(edge.id), .uuid(edge.methodRunID), .uuid(edge.fromNodeID),
                    .uuid(edge.toNodeID), .text(edge.edgeKind.rawValue),
                    .optionalText(edge.label), .integer(Int64(edge.ordinal))
                ])
            return try Self.requireRun(db, id: edge.methodRunID)
        }
    }

    @discardableResult
    public func addEvidenceLink(
        _ link: MethodEvidenceLink, expectedRevision: Int,
        gate: any WorkflowEvidenceReferenceGating, now: Date
    ) async throws -> MethodRun {
        guard link.ordinal >= 0 else { throw MethodPersistenceError.invalidOrdinal(link.ordinal) }
        // Only canonical evidence kinds are linkable — workflow-output kinds are not evidence.
        guard let gateKind = link.targetKind.evidenceGateKind else {
            throw MethodPersistenceError.unsupportedEvidenceTargetKind(link.targetKind.rawValue)
        }
        guard let run = try await run(id: link.methodRunID) else {
            throw MethodPersistenceError.runNotFound(link.methodRunID)
        }
        // Shared canonical gate: existence + workspace boundary + SensitiveScope.
        let verdict = await gate.verdict(kind: gateKind, canonicalObjectID: link.targetID, workspaceID: run.workspaceID)
        if case .denied(let reason) = verdict {
            throw MethodPersistenceError.evidenceReferenceDenied(reason: reason)
        }
        return try await database.withSavepoint("mrr_evlink_\(Self.spSuffix(link.id))\(expectedRevision)") { db in
            try Self.casBump(db, runID: link.methodRunID, expected: expectedRevision, now: now, contentChanged: true)
            if let nodeID = link.nodeID {
                try Self.requireOwned(db, table: "method_nodes", id: nodeID, runID: link.methodRunID, what: "evidence-link node")
            }
            try db.exec("""
                INSERT INTO method_evidence_links
                    (id, method_run_id, node_id, target_kind, target_id, role, ordinal, added_by, added_at, input_role)
                VALUES (?,?,?,?,?,?,?,?,?,?);
                """, [
                    .uuid(link.id), .uuid(link.methodRunID), link.nodeID.map(SQLValue.uuid) ?? .null,
                    .text(link.targetKind.rawValue), .uuid(link.targetID), .text(link.role.rawValue),
                    .integer(Int64(link.ordinal)), .text(link.addedBy), .date(link.addedAt),
                    .optionalText(link.inputRole?.rawValue)
                ])
            return try Self.requireRun(db, id: link.methodRunID)
        }
    }

    @discardableResult
    public func addAssumption(_ a: MethodAssumption, expectedRevision: Int, now: Date) async throws -> MethodRun {
        return try await database.withSavepoint("mrr_assume_\(Self.spSuffix(a.id))\(expectedRevision)") { db in
            try Self.casBump(db, runID: a.methodRunID, expected: expectedRevision, now: now, contentChanged: true)
            if let nodeID = a.nodeID {
                try Self.requireOwned(db, table: "method_nodes", id: nodeID, runID: a.methodRunID, what: "assumption node")
            }
            try db.exec("""
                INSERT INTO method_assumptions
                    (id, method_run_id, node_id, statement, status, rationale, created_by, reviewed_by, reviewed_at)
                VALUES (?,?,?,?,?,?,?,?,?);
                """, [
                    .uuid(a.id), .uuid(a.methodRunID), a.nodeID.map(SQLValue.uuid) ?? .null,
                    .text(a.statement), .text(a.status.rawValue), .optionalText(a.rationale),
                    .text(a.createdBy), .optionalText(a.reviewedBy), .optionalDate(a.reviewedAt)
                ])
            return try Self.requireRun(db, id: a.methodRunID)
        }
    }

    @discardableResult
    public func addFinding(_ f: MethodFinding, expectedRevision: Int, now: Date) async throws -> MethodRun {
        // A related Claim must exist and be valid for the run's workspace — but
        // carrying the reference never confirms or mutates that Claim.
        if let claimID = f.relatedClaimID {
            guard let run = try await run(id: f.methodRunID) else {
                throw MethodPersistenceError.runNotFound(f.methodRunID)
            }
            do {
                try await WorkflowTargetValidator.validate(
                    kind: "claim", targetID: claimID, workspaceID: run.workspaceID, database: database)
            } catch {
                throw MethodPersistenceError.relatedClaimInvalid(claimID)
            }
        }
        return try await database.withSavepoint("mrr_find_\(Self.spSuffix(f.id))\(expectedRevision)") { db in
            try Self.casBump(db, runID: f.methodRunID, expected: expectedRevision, now: now, contentChanged: true)
            if let nodeID = f.nodeID {
                try Self.requireOwned(db, table: "method_nodes", id: nodeID, runID: f.methodRunID, what: "finding node")
            }
            try db.exec("""
                INSERT INTO method_findings
                    (id, method_run_id, node_id, statement, finding_kind, support_status,
                     review_status, related_claim_id, created_at)
                VALUES (?,?,?,?,?,?,?,?,?);
                """, [
                    .uuid(f.id), .uuid(f.methodRunID), f.nodeID.map(SQLValue.uuid) ?? .null,
                    .text(f.statement), .text(f.findingKind.rawValue), .text(f.supportStatus.rawValue),
                    .text(f.reviewStatus.rawValue), f.relatedClaimID.map(SQLValue.uuid) ?? .null,
                    .date(f.createdAt)
                ])
            return try Self.requireRun(db, id: f.methodRunID)
        }
    }

    @discardableResult
    public func appendReview(_ r: MethodReview, expectedRevision: Int, now: Date) async throws -> MethodRun {
        // A review is a HUMAN act — enforced by the model contract before persistence.
        try r.validate()
        return try await database.withSavepoint("mrr_review_\(Self.spSuffix(r.id))\(expectedRevision)") { db in
            try Self.casBump(db, runID: r.methodRunID, expected: expectedRevision, now: now)
            if let nodeID = r.nodeID {
                try Self.requireOwned(db, table: "method_nodes", id: nodeID, runID: r.methodRunID, what: "review node")
            }
            if let findingID = r.findingID {
                try Self.requireOwned(db, table: "method_findings", id: findingID, runID: r.methodRunID, what: "review finding")
            }
            try db.exec("""
                INSERT INTO method_reviews
                    (id, method_run_id, node_id, finding_id, action, actor_kind, actor_identifier, comment, reviewed_at,
                     review_key, reviewed_content_revision)
                VALUES (?,?,?,?,?,?,?,?,?,?,?);
                """, [
                    .uuid(r.id), .uuid(r.methodRunID), r.nodeID.map(SQLValue.uuid) ?? .null,
                    r.findingID.map(SQLValue.uuid) ?? .null, .text(r.action.rawValue),
                    .text(r.actorKind.rawValue), .text(r.actorIdentifier),
                    .optionalText(r.comment), .date(r.reviewedAt),
                    .text(r.reviewKey), .integer(Int64(r.reviewedContentRevision))
                ])
            return try Self.requireRun(db, id: r.methodRunID)
        }
    }

    @discardableResult
    public func appendValidationResult(_ v: MethodValidationResult, expectedRevision: Int, now: Date) async throws -> MethodRun {
        return try await database.withSavepoint("mrr_valid_\(Self.spSuffix(v.id))\(expectedRevision)") { db in
            try Self.casBump(db, runID: v.methodRunID, expected: expectedRevision, now: now)
            switch v.subjectKind {
            case .run:
                // A run subject id is optional, but when present must be the run itself.
                if let subjectID = v.subjectID, subjectID != v.methodRunID {
                    throw MethodPersistenceError.invalidValidationSubject("run subject id must equal the run id")
                }
            case .node, .edge, .assumption, .finding, .evidenceLink:
                // Every non-run subject is MANDATORY and must belong to the same run.
                guard let subjectID = v.subjectID else {
                    throw MethodPersistenceError.invalidValidationSubject("\(v.subjectKind.rawValue) subject requires a subject id")
                }
                let table: String
                switch v.subjectKind {
                case .node:         table = "method_nodes"
                case .edge:         table = "method_edges"
                case .assumption:   table = "method_assumptions"
                case .finding:      table = "method_findings"
                case .evidenceLink: table = "method_evidence_links"
                case .run:          table = ""   // unreachable — handled above
                }
                try Self.requireOwned(db, table: table, id: subjectID, runID: v.methodRunID, what: "validation \(v.subjectKind.rawValue)")
            }
            try db.exec("""
                INSERT INTO method_validation_results
                    (id, method_run_id, validator_id, validator_version, severity, code, message,
                     subject_kind, subject_id, created_at, validation_batch_id, evaluated_content_revision)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?);
                """, [
                    .uuid(v.id), .uuid(v.methodRunID), .text(v.validatorID), .text(v.validatorVersion),
                    .text(v.severity.rawValue), .text(v.code), .text(v.message),
                    .text(v.subjectKind.rawValue), v.subjectID.map(SQLValue.uuid) ?? .null,
                    .date(v.createdAt), .uuid(v.validationBatchID), .integer(Int64(v.evaluatedContentRevision))
                ])
            return try Self.requireRun(db, id: v.methodRunID)
        }
    }

    // MARK: - In-savepoint helpers (isolated to the passed Database)

    static func casBump(
        _ db: isolated Database, runID: UUID, expected: Int, now: Date, contentChanged: Bool = false
    ) throws {
        // A content write is permitted only while the run is draft or active; a
        // paused/waiting/blocked/terminal run must be transitioned first (PM-004).
        if contentChanged {
            let rows = try db.query("SELECT status FROM method_runs WHERE id = ?;", [.uuid(runID)])
            guard let statusRaw = rows.first?.string(0) else { throw MethodPersistenceError.runNotFound(runID) }
            guard statusRaw == "draft" || statusRaw == "active" else {
                throw MethodPersistenceError.contentMutationNotAllowed(runID, status: statusRaw)
            }
        }
        let sql = contentChanged
            ? "UPDATE method_runs SET revision = revision + 1, content_revision = content_revision + 1, updated_at = ? WHERE id = ? AND revision = ?;"
            : "UPDATE method_runs SET revision = revision + 1, updated_at = ? WHERE id = ? AND revision = ?;"
        try db.exec(sql, [.date(now), .uuid(runID), .integer(Int64(expected))])
        let changed = Int(try db.query("SELECT changes();").first?.int(0) ?? 0)
        guard changed == 1 else {
            let exists = try db.query("SELECT 1 FROM method_runs WHERE id = ?;", [.uuid(runID)])
            throw exists.isEmpty
                ? MethodPersistenceError.runNotFound(runID)
                : MethodPersistenceError.revisionConflict(runID: runID, expected: expected)
        }
    }

    static func requireOwned(_ db: isolated Database, table: String, id: UUID, runID: UUID, what: String) throws {
        let rows = try db.query("SELECT 1 FROM \(table) WHERE id = ? AND method_run_id = ?;", [.uuid(id), .uuid(runID)])
        if rows.isEmpty {
            throw MethodPersistenceError.ownershipViolation("\(what) \(id) does not belong to run \(runID)")
        }
    }

    static func requireRun(_ db: isolated Database, id: UUID) throws -> MethodRun {
        guard let run = try db.query("SELECT \(runColumns) FROM method_runs WHERE id = ?;", [.uuid(id)])
            .first.flatMap(decodeRun) else { throw MethodPersistenceError.runNotFound(id) }
        return run
    }

    static func spSuffix(_ id: UUID) -> String {
        id.uuidString.replacingOccurrences(of: "-", with: "")
    }

    // MARK: - Decoders (index-based; order matches the column-list constants)

    nonisolated static func decodeRun(_ r: SQLRow) -> MethodRun? {
        guard let id = r.uuid(0), let ws = r.uuid(1), let defID = r.string(2),
              let defVer = r.int(3), let statusRaw = r.string(6),
              let status = MethodRunStatus(rawValue: statusRaw),
              let revision = r.int(8), let createdBy = r.string(9),
              let createdAt = r.date(10), let updatedAt = r.date(11) else { return nil }
        return MethodRun(
            id: id, workspaceID: ws,
            methodDefinitionID: ProfessionalMethodDefinitionID(rawValue: defID),
            methodDefinitionVersion: Int(defVer),
            workflowRunID: r.uuid(4), workflowStepRunID: r.uuid(5),
            status: status, title: r.string(7), revision: Int(revision),
            contentRevision: Int(r.int(14) ?? 1),
            createdBy: createdBy, createdAt: createdAt, updatedAt: updatedAt,
            completedAt: r.date(12), supersededByRunID: r.uuid(13))
    }

    nonisolated static func decodeNode(_ r: SQLRow) -> MethodNode? {
        guard let id = r.uuid(0), let runID = r.uuid(1), let key = r.string(2),
              let kind = r.string(3), let label = r.string(4), let stateRaw = r.string(6),
              let state = MethodWorkingState(rawValue: stateRaw), let ordinal = r.int(7),
              let createdAt = r.date(9), let updatedAt = r.date(10) else { return nil }
        return MethodNode(
            id: id, methodRunID: runID, nodeDefinitionKey: key,
            nodeKind: MethodNodeKind(rawValue: kind), label: label, body: r.string(5),
            workingState: state, ordinal: Int(ordinal), parentNodeID: r.uuid(8),
            createdAt: createdAt, updatedAt: updatedAt)
    }

    nonisolated static func decodeEdge(_ r: SQLRow) -> MethodEdge? {
        guard let id = r.uuid(0), let runID = r.uuid(1), let from = r.uuid(2),
              let to = r.uuid(3), let kind = r.string(4), let ordinal = r.int(6) else { return nil }
        return MethodEdge(
            id: id, methodRunID: runID, fromNodeID: from, toNodeID: to,
            edgeKind: MethodEdgeKind(rawValue: kind), label: r.string(5), ordinal: Int(ordinal))
    }

    nonisolated static func decodeLink(_ r: SQLRow) -> MethodEvidenceLink? {
        guard let id = r.uuid(0), let runID = r.uuid(1), let kindRaw = r.string(3),
              let targetKind = WorkflowProvenanceReferenceKind(rawValue: kindRaw),
              let targetID = r.uuid(4), let roleRaw = r.string(5),
              let role = MethodEvidenceLinkRole(rawValue: roleRaw), let ordinal = r.int(6),
              let addedBy = r.string(7), let addedAt = r.date(8) else { return nil }
        return MethodEvidenceLink(
            id: id, methodRunID: runID, nodeID: r.uuid(2), targetKind: targetKind, targetID: targetID,
            role: role, inputRole: r.string(9).map(MethodInputRole.init(rawValue:)),
            ordinal: Int(ordinal), addedBy: addedBy, addedAt: addedAt)
    }

    nonisolated static func decodeAssumption(_ r: SQLRow) -> MethodAssumption? {
        guard let id = r.uuid(0), let runID = r.uuid(1), let statement = r.string(3),
              let statusRaw = r.string(4), let status = MethodAssumptionStatus(rawValue: statusRaw),
              let createdBy = r.string(6) else { return nil }
        return MethodAssumption(
            id: id, methodRunID: runID, nodeID: r.uuid(2), statement: statement, status: status,
            rationale: r.string(5), createdBy: createdBy, reviewedBy: r.string(7), reviewedAt: r.date(8))
    }

    nonisolated static func decodeFinding(_ r: SQLRow) -> MethodFinding? {
        guard let id = r.uuid(0), let runID = r.uuid(1), let statement = r.string(3),
              let kind = r.string(4), let supportRaw = r.string(5),
              let support = MethodFindingSupportStatus(rawValue: supportRaw),
              let reviewRaw = r.string(6), let review = MethodReviewStatus(rawValue: reviewRaw),
              let createdAt = r.date(8) else { return nil }
        return MethodFinding(
            id: id, methodRunID: runID, nodeID: r.uuid(2), statement: statement,
            findingKind: MethodFindingKind(rawValue: kind), supportStatus: support,
            reviewStatus: review, relatedClaimID: r.uuid(7), createdAt: createdAt)
    }

    nonisolated static func decodeReview(_ r: SQLRow) -> MethodReview? {
        guard let id = r.uuid(0), let runID = r.uuid(1), let actionRaw = r.string(4),
              let action = MethodReviewAction(rawValue: actionRaw), let actorRaw = r.string(5),
              let actorKind = WorkflowDecisionActorKind(rawValue: actorRaw),
              let actorID = r.string(6), let reviewedAt = r.date(8) else { return nil }
        return MethodReview(
            id: id, methodRunID: runID, nodeID: r.uuid(2), findingID: r.uuid(3),
            reviewKey: r.string(9) ?? MethodReview.legacyUnkeyedKey,
            reviewedContentRevision: Int(r.int(10) ?? 0),
            action: action, actorKind: actorKind, actorIdentifier: actorID,
            comment: r.string(7), reviewedAt: reviewedAt)
    }

    nonisolated static func decodeValidation(_ r: SQLRow) -> MethodValidationResult? {
        guard let id = r.uuid(0), let runID = r.uuid(1), let vID = r.string(2),
              let vVer = r.string(3), let sevRaw = r.string(4),
              let severity = MethodValidationSeverity(rawValue: sevRaw), let code = r.string(5),
              let message = r.string(6), let subjRaw = r.string(7),
              let subjectKind = MethodValidationSubjectKind(rawValue: subjRaw),
              let createdAt = r.date(9) else { return nil }
        return MethodValidationResult(
            id: id, methodRunID: runID, validatorID: vID, validatorVersion: vVer, severity: severity,
            code: code, message: message, subjectKind: subjectKind, subjectID: r.uuid(8),
            validationBatchID: r.uuid(10) ?? MethodValidationResult.legacyBatchID,
            evaluatedContentRevision: Int(r.int(11) ?? 0), createdAt: createdAt)
    }

    nonisolated static func decodeEvent(_ r: SQLRow) -> MethodLifecycleEvent? {
        guard let id = r.uuid(0), let runID = r.uuid(1), let sequence = r.int(2),
              let runRevision = r.int(3), let contentRevision = r.int(4),
              let actionRaw = r.string(5), let action = MethodLifecycleAction(rawValue: actionRaw),
              let fromRaw = r.string(6), let fromStatus = MethodRunStatus(rawValue: fromRaw),
              let toRaw = r.string(7), let toStatus = MethodRunStatus(rawValue: toRaw),
              let actorRaw = r.string(8), let actorKind = WorkflowDecisionActorKind(rawValue: actorRaw),
              let occurredAt = r.date(11) else { return nil }
        return MethodLifecycleEvent(
            id: id, methodRunID: runID, sequence: Int(sequence), runRevision: Int(runRevision),
            contentRevision: Int(contentRevision), action: action, fromStatus: fromStatus, toStatus: toStatus,
            actorKind: actorKind, actorIdentifier: r.string(9), reason: r.string(10), occurredAt: occurredAt)
    }
}

// MARK: - Case ↔ method-run linkage (PHASE B, v113)

/// The persisted case linkage the seventh audit found missing: method runs
/// were workspace-scoped only, so no case-scoped phase (methods, causal
/// analysis, linkage, CAPA) could ever be OBSERVED by the conformance
/// assessor. `startMethod` records the link at creation; the observation
/// service derives phase completion from it — the runs table stays the one
/// source of truth for run state.
extension MethodRunRepository {

    public func linkCase(_ caseID: UUID, methodRunID: UUID,
                         phaseKind: PersonaJobKind, at date: Date) async throws {
        try await database.exec("""
        INSERT OR IGNORE INTO case_method_runs (case_id, method_run_id, phase_kind, created_at)
        VALUES (?, ?, ?, ?);
        """, [.uuid(caseID), .uuid(methodRunID), .text(phaseKind.rawValue),
              .real(date.timeIntervalSince1970)])
    }

    /// Per-phase method activity for a case: (phase, total runs, completed runs).
    public func casePhaseActivity(caseID: UUID) async throws -> [(phase: PersonaJobKind, total: Int, completed: Int)] {
        let rows = try await database.query("""
        SELECT l.phase_kind,
               COUNT(*),
               SUM(CASE WHEN r.status = 'completed' THEN 1 ELSE 0 END)
        FROM case_method_runs l
        JOIN method_runs r ON r.id = l.method_run_id
        WHERE l.case_id = ?
        GROUP BY l.phase_kind;
        """, [.uuid(caseID)])
        return rows.compactMap { r in
            guard let raw = r.string(0), let phase = PersonaJobKind(rawValue: raw),
                  let total = r.int(1) else { return nil }
            return (phase, Int(total), Int(r.int(2) ?? 0))
        }
    }
}
