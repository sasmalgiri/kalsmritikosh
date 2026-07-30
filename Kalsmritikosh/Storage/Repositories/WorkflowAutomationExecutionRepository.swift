//
//  WorkflowAutomationExecutionRepository.swift
//  Kalsmritikosh
//
//  PJE-010 — persistence for the automation execution ledger. Two-phase,
//  idempotency-guarded receipts:
//
//    begin(...)        → reserve the UNIQUE idempotency key with a 'started' row;
//                        a repeated delivery returns the PRIOR execution instead
//                        of a second output (skippedDuplicate semantics).
//    complete(...)     → mark 'succeeded' and link the proposal output.
//    markFailed(...)   → mark 'failed' with a reason (no output was produced).
//
//  request/result hashes are stored-byte SHA-256 (the PJE-006B.1 contract), so
//  tampering with a persisted request or result is detected on read.
//

import Foundation

public actor WorkflowAutomationExecutionRepository {

    private let database: Database

    public init(database: Database) { self.database = database }

    public enum BeginOutcome: Sendable, Equatable {
        case started(WorkflowAutomationExecution)
        case duplicate(WorkflowAutomationExecution)
    }

    // MARK: - Begin (reserve idempotency key)

    public func begin(
        workspaceID: UUID,
        workflowRunID: UUID?,
        stepRunID: UUID?,
        applicationDefinitionID: String,
        automationDefinitionID: String,
        automationDefinitionVersion: Int,
        triggerKind: PersonaAutomationTriggerKind,
        triggerEventKey: String,
        actionKind: PersonaAutomationActionKind,
        idempotencyKey: String,
        requestJSON: String,
        now: Date
    ) async throws -> BeginOutcome {
        // A prior execution for this idempotency key wins — never a second output.
        if let existing = try await execution(idempotencyKey: idempotencyKey) {
            return .duplicate(existing)
        }
        let id = UUID()
        let requestSHA = try WorkflowPersistedJSONIntegrity.sha256(storedJSON: requestJSON)
        do {
            try await database.exec("""
                INSERT INTO workflow_automation_executions
                    (id, workspace_id, workflow_run_id, step_run_id,
                     application_definition_id, automation_definition_id,
                     automation_definition_version, trigger_kind, trigger_event_key,
                     action_kind, idempotency_key, request_json, request_sha256,
                     status, started_at)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);
                """, [
                    .uuid(id), .uuid(workspaceID),
                    workflowRunID.map { SQLValue.uuid($0) } ?? .null,
                    stepRunID.map { SQLValue.uuid($0) } ?? .null,
                    .text(applicationDefinitionID), .text(automationDefinitionID),
                    .integer(Int64(automationDefinitionVersion)),
                    .text(triggerKind.rawValue), .text(triggerEventKey),
                    .text(actionKind.rawValue), .text(idempotencyKey),
                    .text(requestJSON), .text(requestSHA),
                    .text(WorkflowAutomationExecutionStatus.started.rawValue),
                    .date(now)
                ])
        } catch {
            // A concurrent begin won the UNIQUE key — return the prior execution.
            if let existing = try await execution(idempotencyKey: idempotencyKey) {
                return .duplicate(existing)
            }
            throw error
        }
        let started = try await execution(id: id)
        return .started(try requireExecution(started, id: id))
    }

    // MARK: - Complete / fail

    @discardableResult
    public func complete(
        id: UUID,
        outputKind: WorkflowAutomationOutputKind,
        outputID: UUID,
        resultJSON: String,
        now: Date
    ) async throws -> WorkflowAutomationExecution {
        let resultSHA = try WorkflowPersistedJSONIntegrity.sha256(storedJSON: resultJSON)
        try await database.exec("""
            UPDATE workflow_automation_executions
               SET status = ?, output_kind = ?, output_id = ?,
                   result_json = ?, result_sha256 = ?, completed_at = ?
             WHERE id = ?;
            """, [
                .text(WorkflowAutomationExecutionStatus.succeeded.rawValue),
                .text(outputKind.rawValue), .uuid(outputID),
                .text(resultJSON), .text(resultSHA), .date(now), .uuid(id)
            ])
        return try requireExecution(try await execution(id: id), id: id)
    }

    @discardableResult
    public func markFailed(
        id: UUID, reason: String, now: Date
    ) async throws -> WorkflowAutomationExecution {
        try await database.exec("""
            UPDATE workflow_automation_executions
               SET status = ?, failure_reason = ?, completed_at = ?
             WHERE id = ?;
            """, [
                .text(WorkflowAutomationExecutionStatus.failed.rawValue),
                .text(reason), .date(now), .uuid(id)
            ])
        return try requireExecution(try await execution(id: id), id: id)
    }

    // MARK: - Reads (hash-verified)

    public func execution(idempotencyKey: String) async throws -> WorkflowAutomationExecution? {
        let rows = try await database.query(
            "\(Self.selectColumns) WHERE idempotency_key = ?;", [.text(idempotencyKey)])
        guard let row = rows.first else { return nil }
        return try Self.decodeVerified(row)
    }

    public func execution(id: UUID) async throws -> WorkflowAutomationExecution? {
        let rows = try await database.query(
            "\(Self.selectColumns) WHERE id = ?;", [.uuid(id)])
        guard let row = rows.first else { return nil }
        return try Self.decodeVerified(row)
    }

    public func executions(inWorkspace workspaceID: UUID) async throws -> [WorkflowAutomationExecution] {
        let rows = try await database.query(
            "\(Self.selectColumns) WHERE workspace_id = ? ORDER BY started_at ASC;", [.uuid(workspaceID)])
        return try rows.map { try Self.decodeVerified($0) }
    }

    // MARK: - Decoding

    private static let selectColumns = """
        SELECT id, workspace_id, workflow_run_id, step_run_id,
               application_definition_id, automation_definition_id,
               automation_definition_version, trigger_kind, trigger_event_key,
               action_kind, idempotency_key, request_json, request_sha256,
               status, output_kind, output_id, result_json, result_sha256,
               started_at, completed_at, failure_reason
          FROM workflow_automation_executions
        """

    private func requireExecution(
        _ execution: WorkflowAutomationExecution?, id: UUID
    ) throws -> WorkflowAutomationExecution {
        guard let execution else { throw WorkflowAutomationExecutionError.executionNotFound(id) }
        return execution
    }

    private static func decodeVerified(_ row: SQLRow) throws -> WorkflowAutomationExecution {
        guard let id = row.uuid(0), let workspaceID = row.uuid(1),
              let appID = row.string(4), let autoID = row.string(5),
              let version = row.int(6),
              let triggerRaw = row.string(7), let trigger = PersonaAutomationTriggerKind(rawValue: triggerRaw),
              let eventKey = row.string(8),
              let actionRaw = row.string(9), let action = PersonaAutomationActionKind(rawValue: actionRaw),
              let idemKey = row.string(10),
              let requestJSON = row.string(11), let requestSHA = row.string(12),
              let statusRaw = row.string(13), let status = WorkflowAutomationExecutionStatus(rawValue: statusRaw),
              let startedAt = row.date(18)
        else { throw WorkflowAutomationExecutionError.executionNotFound(UUID()) }

        // Stored-byte hash verification (tamper detection).
        guard WorkflowPersistedJSONIntegrity.rawSHA256(of: requestJSON) == requestSHA else {
            throw WorkflowAutomationExecutionError.requestHashMismatch(id)
        }
        if let resultJSON = row.string(16), let resultSHA = row.string(17) {
            guard WorkflowPersistedJSONIntegrity.rawSHA256(of: resultJSON) == resultSHA else {
                throw WorkflowAutomationExecutionError.resultHashMismatch(id)
            }
        }

        return WorkflowAutomationExecution(
            id: id, workspaceID: workspaceID,
            workflowRunID: row.uuid(2), stepRunID: row.uuid(3),
            applicationDefinitionID: appID, automationDefinitionID: autoID,
            automationDefinitionVersion: Int(version),
            triggerKind: trigger, triggerEventKey: eventKey, actionKind: action,
            idempotencyKey: idemKey, requestJSON: requestJSON, requestSHA256: requestSHA,
            status: status,
            outputKind: row.string(14).flatMap { WorkflowAutomationOutputKind(rawValue: $0) },
            outputID: row.uuid(15),
            resultJSON: row.string(16), resultSHA256: row.string(17),
            startedAt: startedAt, completedAt: row.date(19),
            failureReason: row.string(20))
    }
}
