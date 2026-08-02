//
//  JobRepository.swift
//  Kalsmritikosh
//
//  TBJ-FINAL. Durable persistence for the time-bounded Job planning envelope (schema v91). This is
//  NOT a second task or deadline system: it stores an objective, a time budget, and an ordered set
//  of REFERENCES to objects the canonical engine already owns (ProfessionalTask / WorkflowRun / step
//  / requirement / evidence requirement / expected artifact), plus an append-only audit ledger.
//
//  Fail-closed rules enforced here (the schema CHECKs backstop them):
//    • A budget bound to a "confirmed deadline" is resolved in `deadlines` — the CONFIRMED table.
//      A DeadlineCandidate has no row there, so it can NEVER become a job's authoritative budget.
//    • Every task/run/step reference must resolve AND belong to the job's workspace.
//    • Every mutation is atomic (SAVEPOINT), carries optimistic CAS on the job revision, and appends
//      exactly one durable event — so reopen(after relaunch) always reconstructs the true state.
//    • Closing / abandoning a job is a human-recorded lifecycle act; it is never inferred from the
//      completion of underlying tasks or workflows.
//

import Foundation

public actor JobRepository {
    private let database: Database

    public init(database: Database) { self.database = database }

    // MARK: - Create

    /// Open a new active job. Validates the workspace, title and budget, resolving a confirmed-deadline
    /// or workflow budget against its authority before binding. Emits the `created` event.
    @discardableResult
    public func createJob(workspaceID: UUID, title: String, detail: String?, budget: TimeBudget,
                          primaryWorkflowRunID: UUID?, actor: String, at date: Date) async throws -> JobRecord {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { throw JobError.blankTitle }
        try requireActor(actor)
        guard try await rowExists("workspaces", id: workspaceID) else { throw JobError.workspaceNotFound(workspaceID) }
        try await validateBudget(budget, workspaceID: workspaceID)
        if let run = primaryWorkflowRunID {
            try await requireWorkflowRun(run, inWorkspace: workspaceID)
        }

        let job = JobObjective(id: UUID(), workspaceID: workspaceID, title: cleanTitle, detail: detail,
                               budget: budget, primaryWorkflowRunID: primaryWorkflowRunID,
                               lifecycle: .active, revision: 1, createdAt: date, updatedAt: date,
                               closedAt: nil, closureReason: nil)
        let sp = savepointName("job_create", job.id)
        do {
            try await database.exec("SAVEPOINT \(sp);")
            let b = budgetColumns(budget)
            try await database.exec("""
                INSERT INTO job_objectives (id, workspace_id, title, objective_detail, budget_basis,
                    budget_seconds, budget_deadline_id, budget_workflow_run_id, primary_workflow_run_id,
                    lifecycle, revision, created_at, updated_at, closed_at, closure_reason)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);
                """, [.uuid(job.id), .uuid(workspaceID), .text(cleanTitle), .optionalText(detail),
                      .text(budget.basis.rawValue), b.seconds, b.deadline, b.workflow,
                      primaryWorkflowRunID.map { SQLValue.uuid($0) } ?? .null,
                      .text(JobLifecycle.active.rawValue), .integer(1), .date(date), .date(date), .null, .null])
            try await appendEvent(jobID: job.id, sequence: 1, revision: 1, action: .created,
                                  actor: actor, detail: nil, at: date)
            try await database.exec("RELEASE SAVEPOINT \(sp);")
        } catch {
            try? await database.exec("ROLLBACK TO SAVEPOINT \(sp);")
            try? await database.exec("RELEASE SAVEPOINT \(sp);")
            throw error
        }
        return try await require(job.id)
    }

    // MARK: - Budget

    /// Replace the job's time budget. CAS on revision; emits `budgetSet`.
    @discardableResult
    public func setBudget(jobID: UUID, budget: TimeBudget, expectedRevision: Int,
                          actor: String, at date: Date) async throws -> JobRecord {
        try requireActor(actor)
        let job = try await requireObjective(jobID)
        try requireActive(job)
        try requireRevision(job, expectedRevision)
        try await validateBudget(budget, workspaceID: job.workspaceID)
        let newRev = job.revision + 1
        let sp = savepointName("job_budget", jobID)
        do {
            try await database.exec("SAVEPOINT \(sp);")
            let b = budgetColumns(budget)
            try await database.exec("""
                UPDATE job_objectives SET budget_basis = ?, budget_seconds = ?, budget_deadline_id = ?,
                    budget_workflow_run_id = ?, revision = ?, updated_at = ? WHERE id = ?;
                """, [.text(budget.basis.rawValue), b.seconds, b.deadline, b.workflow,
                      .integer(Int64(newRev)), .date(date), .uuid(jobID)])
            try await appendEvent(jobID: jobID, sequence: try await nextSequence(jobID), revision: newRev,
                                  action: .budgetSet, actor: actor, detail: budget.basis.rawValue, at: date)
            try await database.exec("RELEASE SAVEPOINT \(sp);")
        } catch {
            try? await database.exec("ROLLBACK TO SAVEPOINT \(sp);")
            try? await database.exec("RELEASE SAVEPOINT \(sp);")
            throw error
        }
        return try await require(jobID)
    }

    // MARK: - Plan references

    /// Add a reference to an existing authority object. Validates existence + workspace for
    /// task/run/step references; requirement/artifact references validate their optional context run.
    /// CAS on revision; emits `referenceAdded`.
    @discardableResult
    public func addReference(jobID: UUID, kind: JobPlanReferenceKind, referenceID: String,
                             workflowRunID: UUID?, role: JobPlanReferenceRole,
                             isMinimumDeliverable: Bool, note: String?, expectedRevision: Int,
                             actor: String, at date: Date) async throws -> JobRecord {
        try requireActor(actor)
        let job = try await requireObjective(jobID)
        try requireActive(job)
        try requireRevision(job, expectedRevision)
        let cleanRef = referenceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanRef.isEmpty else { throw JobError.blankReference }
        try await validateReference(kind: kind, referenceID: cleanRef, workflowRunID: workflowRunID,
                                    workspaceID: job.workspaceID)
        // Reject an exact duplicate (job, kind, ref, context run) up-front for a clear error; the
        // COALESCE-unique index is the hard backstop.
        if try await referenceExists(jobID: jobID, kind: kind, referenceID: cleanRef, workflowRunID: workflowRunID) {
            throw JobError.duplicateReference
        }
        let newRev = job.revision + 1
        let refID = UUID()
        let sp = savepointName("job_ref_add", refID)
        do {
            try await database.exec("SAVEPOINT \(sp);")
            let ordinal = try await nextOrdinal(jobID)
            try await database.exec("""
                INSERT INTO job_plan_references (id, job_id, reference_kind, reference_id, workflow_run_id,
                    role, is_minimum_deliverable, ordinal, note, created_at)
                VALUES (?,?,?,?,?,?,?,?,?,?);
                """, [.uuid(refID), .uuid(jobID), .text(kind.rawValue), .text(cleanRef),
                      workflowRunID.map { SQLValue.uuid($0) } ?? .null, .text(role.rawValue),
                      .integer(isMinimumDeliverable ? 1 : 0), .integer(Int64(ordinal)),
                      .optionalText(note), .date(date)])
            try await bumpRevision(jobID: jobID, to: newRev, at: date)
            try await appendEvent(jobID: jobID, sequence: try await nextSequence(jobID), revision: newRev,
                                  action: .referenceAdded, actor: actor, detail: kind.rawValue, at: date)
            try await database.exec("RELEASE SAVEPOINT \(sp);")
        } catch {
            try? await database.exec("ROLLBACK TO SAVEPOINT \(sp);")
            try? await database.exec("RELEASE SAVEPOINT \(sp);")
            throw error
        }
        return try await require(jobID)
    }

    /// Change a reference's role and/or minimum-deliverable flag. CAS; emits `referenceUpdated`.
    @discardableResult
    public func updateReference(referenceID: UUID, role: JobPlanReferenceRole, isMinimumDeliverable: Bool,
                                expectedRevision: Int, actor: String, at date: Date) async throws -> JobRecord {
        try requireActor(actor)
        let jobID = try await requireReferenceJob(referenceID)
        let job = try await requireObjective(jobID)
        try requireActive(job)
        try requireRevision(job, expectedRevision)
        let newRev = job.revision + 1
        let sp = savepointName("job_ref_upd", referenceID)
        do {
            try await database.exec("SAVEPOINT \(sp);")
            try await database.exec("""
                UPDATE job_plan_references SET role = ?, is_minimum_deliverable = ? WHERE id = ?;
                """, [.text(role.rawValue), .integer(isMinimumDeliverable ? 1 : 0), .uuid(referenceID)])
            try await bumpRevision(jobID: jobID, to: newRev, at: date)
            try await appendEvent(jobID: jobID, sequence: try await nextSequence(jobID), revision: newRev,
                                  action: .referenceUpdated, actor: actor, detail: nil, at: date)
            try await database.exec("RELEASE SAVEPOINT \(sp);")
        } catch {
            try? await database.exec("ROLLBACK TO SAVEPOINT \(sp);")
            try? await database.exec("RELEASE SAVEPOINT \(sp);")
            throw error
        }
        return try await require(jobID)
    }

    /// Remove a plan reference. CAS; emits `referenceRemoved`.
    @discardableResult
    public func removeReference(referenceID: UUID, expectedRevision: Int, actor: String,
                                at date: Date) async throws -> JobRecord {
        try requireActor(actor)
        let jobID = try await requireReferenceJob(referenceID)
        let job = try await requireObjective(jobID)
        try requireActive(job)
        try requireRevision(job, expectedRevision)
        let newRev = job.revision + 1
        let sp = savepointName("job_ref_rm", referenceID)
        do {
            try await database.exec("SAVEPOINT \(sp);")
            try await database.exec("DELETE FROM job_plan_references WHERE id = ?;", [.uuid(referenceID)])
            try await bumpRevision(jobID: jobID, to: newRev, at: date)
            try await appendEvent(jobID: jobID, sequence: try await nextSequence(jobID), revision: newRev,
                                  action: .referenceRemoved, actor: actor, detail: nil, at: date)
            try await database.exec("RELEASE SAVEPOINT \(sp);")
        } catch {
            try? await database.exec("ROLLBACK TO SAVEPOINT \(sp);")
            try? await database.exec("RELEASE SAVEPOINT \(sp);")
            throw error
        }
        return try await require(jobID)
    }

    // MARK: - Lifecycle (human-recorded)

    /// Close a job as done — a HUMAN act, never inferred from underlying task/workflow completion.
    @discardableResult
    public func close(jobID: UUID, reason: String?, expectedRevision: Int, actor: String,
                      at date: Date) async throws -> JobRecord {
        try await transitionLifecycle(jobID: jobID, to: .closed, action: .closed, reason: reason,
                                      expectedRevision: expectedRevision, actor: actor, at: date)
    }

    /// Abandon a job — a HUMAN act. The plan and its history are preserved.
    @discardableResult
    public func abandon(jobID: UUID, reason: String?, expectedRevision: Int, actor: String,
                        at date: Date) async throws -> JobRecord {
        try await transitionLifecycle(jobID: jobID, to: .abandoned, action: .abandoned, reason: reason,
                                      expectedRevision: expectedRevision, actor: actor, at: date)
    }

    /// Reopen a closed/abandoned job back to active. Clears the closure fields; emits `reopened`.
    @discardableResult
    public func reopen(jobID: UUID, expectedRevision: Int, actor: String, at date: Date) async throws -> JobRecord {
        try requireActor(actor)
        let job = try await requireObjective(jobID)
        guard job.lifecycle != .active else {
            throw JobError.invalidLifecycleTransition(from: job.lifecycle, to: .active)
        }
        try requireRevision(job, expectedRevision)
        let newRev = job.revision + 1
        let sp = savepointName("job_reopen", jobID)
        do {
            try await database.exec("SAVEPOINT \(sp);")
            try await database.exec("""
                UPDATE job_objectives SET lifecycle = ?, closed_at = NULL, closure_reason = NULL,
                    revision = ?, updated_at = ? WHERE id = ?;
                """, [.text(JobLifecycle.active.rawValue), .integer(Int64(newRev)), .date(date), .uuid(jobID)])
            try await appendEvent(jobID: jobID, sequence: try await nextSequence(jobID), revision: newRev,
                                  action: .reopened, actor: actor, detail: nil, at: date)
            try await database.exec("RELEASE SAVEPOINT \(sp);")
        } catch {
            try? await database.exec("ROLLBACK TO SAVEPOINT \(sp);")
            try? await database.exec("RELEASE SAVEPOINT \(sp);")
            throw error
        }
        return try await require(jobID)
    }

    // MARK: - Reads (durable resume)

    public func objective(id: UUID) async throws -> JobObjective? {
        (try await database.query("\(Self.objectiveColumns) WHERE id = ? LIMIT 1;", [.uuid(id)]))
            .first.flatMap(Self.decodeObjective)
    }

    public func references(jobID: UUID) async throws -> [JobPlanReference] {
        (try await database.query(
            "\(Self.referenceColumns) WHERE job_id = ? ORDER BY ordinal ASC, created_at ASC, id ASC;",
            [.uuid(jobID)])).compactMap(Self.decodeReference)
    }

    public func events(jobID: UUID) async throws -> [JobEvent] {
        (try await database.query(
            "\(Self.eventColumns) WHERE job_id = ? ORDER BY sequence ASC;", [.uuid(jobID)]))
            .compactMap(Self.decodeEvent)
    }

    /// The durable resume anchor: reconstruct a job's full state (objective + plan + audit) from disk.
    public func fetch(jobID: UUID) async throws -> JobRecord? {
        guard let obj = try await objective(id: jobID) else { return nil }
        let refs = try await references(jobID: jobID)
        let evs = try await events(jobID: jobID)
        return JobRecord(plan: JobExecutionPlan(objective: obj, references: refs), events: evs)
    }

    public func jobIDs(workspaceID: UUID, lifecycles: Set<JobLifecycle> = []) async throws -> [UUID] {
        var sql = "SELECT id FROM job_objectives WHERE workspace_id = ?"
        var params: [SQLValue] = [.uuid(workspaceID)]
        if !lifecycles.isEmpty {
            sql += " AND lifecycle IN (\(lifecycles.map { _ in "?" }.joined(separator: ",")))"
            params += lifecycles.map { .text($0.rawValue) }
        }
        sql += " ORDER BY created_at ASC, id ASC;"
        return (try await database.query(sql, params)).compactMap { $0.uuid(0) }
    }

    // MARK: - Shared lifecycle transition

    private func transitionLifecycle(jobID: UUID, to lifecycle: JobLifecycle, action: JobEventAction,
                                     reason: String?, expectedRevision: Int, actor: String,
                                     at date: Date) async throws -> JobRecord {
        try requireActor(actor)
        let job = try await requireObjective(jobID)
        try requireActive(job)
        try requireRevision(job, expectedRevision)
        let newRev = job.revision + 1
        let sp = savepointName("job_life", jobID)
        do {
            try await database.exec("SAVEPOINT \(sp);")
            try await database.exec("""
                UPDATE job_objectives SET lifecycle = ?, closed_at = ?, closure_reason = ?,
                    revision = ?, updated_at = ? WHERE id = ?;
                """, [.text(lifecycle.rawValue), .date(date), .optionalText(reason),
                      .integer(Int64(newRev)), .date(date), .uuid(jobID)])
            try await appendEvent(jobID: jobID, sequence: try await nextSequence(jobID), revision: newRev,
                                  action: action, actor: actor, detail: reason, at: date)
            try await database.exec("RELEASE SAVEPOINT \(sp);")
        } catch {
            try? await database.exec("ROLLBACK TO SAVEPOINT \(sp);")
            try? await database.exec("RELEASE SAVEPOINT \(sp);")
            throw error
        }
        return try await require(jobID)
    }

    // MARK: - Validation helpers

    private func requireActor(_ actor: String) throws {
        guard !actor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw JobError.blankActor }
    }

    private func requireObjective(_ id: UUID) async throws -> JobObjective {
        guard let obj = try await objective(id: id) else { throw JobError.jobNotFound(id) }
        return obj
    }

    private func requireActive(_ job: JobObjective) throws {
        guard job.lifecycle == .active else { throw JobError.jobNotActive(job.lifecycle) }
    }

    private func requireRevision(_ job: JobObjective, _ expected: Int) throws {
        guard job.revision == expected else {
            throw JobError.revisionConflict(expected: expected, actual: job.revision)
        }
    }

    private func require(_ jobID: UUID) async throws -> JobRecord {
        guard let record = try await fetch(jobID: jobID) else { throw JobError.jobNotFound(jobID) }
        return record
    }

    /// Enforce the budget's well-formedness AND that a confirmed-deadline / workflow budget resolves
    /// to a real authority in the job's workspace. A candidate deadline id has no `deadlines` row and
    /// is therefore rejected here — it can never become a job budget.
    private func validateBudget(_ budget: TimeBudget, workspaceID: UUID) async throws {
        guard budget.isWellFormed else { throw JobError.malformedBudget }
        switch budget.basis {
        case .confirmedDeadline:
            guard let d = budget.deadlineID else { throw JobError.malformedBudget }
            guard try await deadlineIsConfirmed(d, inWorkspace: workspaceID) else {
                throw JobError.deadlineNotConfirmed(d)
            }
        case .workflowConstraint:
            guard let run = budget.workflowRunID else { throw JobError.malformedBudget }
            try await requireWorkflowRun(run, inWorkspace: workspaceID)
        case .explicitDuration, .none:
            break
        }
    }

    /// A confirmed deadline is a row in `deadlines` (NOT `deadline_candidates`) whose owning task is in
    /// this workspace. This is the structural "candidate can never be a budget" guarantee.
    private func deadlineIsConfirmed(_ deadlineID: UUID, inWorkspace workspaceID: UUID) async throws -> Bool {
        let rows = try await database.query("""
            SELECT t.workspace_id FROM deadlines d
            JOIN professional_tasks t ON t.id = d.task_id
            WHERE d.id = ? LIMIT 1;
            """, [.uuid(deadlineID)])
        guard let ws = rows.first?.uuid(0) else { return false }
        return ws == workspaceID
    }

    private func requireWorkflowRun(_ runID: UUID, inWorkspace workspaceID: UUID) async throws {
        let rows = try await database.query("SELECT workspace_id FROM workflow_runs WHERE id = ? LIMIT 1;", [.uuid(runID)])
        guard let ws = rows.first?.uuid(0) else { throw JobError.workflowRunNotFound(runID) }
        guard ws == workspaceID else { throw JobError.crossWorkspaceReference(kind: "workflowRun", id: runID.uuidString) }
    }

    /// Validate a plan reference resolves to a real object in the job's workspace. Task/run/step
    /// references are resolved to rows; requirement/evidence/artifact references are definition-level
    /// keys, so only their optional CONTEXT run is validated (nonblank id is checked by the caller).
    private func validateReference(kind: JobPlanReferenceKind, referenceID: String,
                                   workflowRunID: UUID?, workspaceID: UUID) async throws {
        switch kind {
        case .professionalTask:
            let ws = try await workspaceOf(table: "professional_tasks", id: referenceID)
            try requireResolved(ws, kind: kind, id: referenceID, workspaceID: workspaceID)
        case .workflowRun:
            let ws = try await workspaceOf(table: "workflow_runs", id: referenceID)
            try requireResolved(ws, kind: kind, id: referenceID, workspaceID: workspaceID)
        case .workflowStep:
            guard let stepUUID = UUID(uuidString: referenceID) else {
                throw JobError.crossWorkspaceReference(kind: kind.rawValue, id: referenceID)
            }
            let rows = try await database.query("""
                SELECT r.workspace_id FROM workflow_step_runs s
                JOIN workflow_runs r ON r.id = s.run_id WHERE s.id = ? LIMIT 1;
                """, [.uuid(stepUUID)])
            try requireResolved(rows.first?.uuid(0), kind: kind, id: referenceID, workspaceID: workspaceID)
        case .workflowRequirement, .evidenceRequirement, .expectedArtifact:
            // Definition-level id: validate the optional context run belongs to the workspace.
            if let run = workflowRunID {
                try await requireWorkflowRun(run, inWorkspace: workspaceID)
            }
        }
    }

    private func requireResolved(_ ws: UUID?, kind: JobPlanReferenceKind, id: String, workspaceID: UUID) throws {
        guard let ws else { throw JobError.crossWorkspaceReference(kind: kind.rawValue, id: id) }
        guard ws == workspaceID else { throw JobError.crossWorkspaceReference(kind: kind.rawValue, id: id) }
    }

    private func workspaceOf(table: String, id: String) async throws -> UUID? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        return try await database.query("SELECT workspace_id FROM \(table) WHERE id = ? LIMIT 1;", [.uuid(uuid)])
            .first?.uuid(0)
    }

    private func requireReferenceJob(_ referenceID: UUID) async throws -> UUID {
        guard let job = try await database.query(
            "SELECT job_id FROM job_plan_references WHERE id = ? LIMIT 1;", [.uuid(referenceID)])
            .first?.uuid(0) else { throw JobError.referenceNotFound(referenceID) }
        return job
    }

    private func referenceExists(jobID: UUID, kind: JobPlanReferenceKind, referenceID: String,
                                 workflowRunID: UUID?) async throws -> Bool {
        let run = workflowRunID?.uuidString ?? ""
        let count = try await database.query("""
            SELECT COUNT(*) FROM job_plan_references
            WHERE job_id = ? AND reference_kind = ? AND reference_id = ? AND COALESCE(workflow_run_id, '') = ?;
            """, [.uuid(jobID), .text(kind.rawValue), .text(referenceID), .text(run)]).first?.int(0) ?? 0
        return Int(count) > 0
    }

    // MARK: - Row / sequence helpers

    private func rowExists(_ table: String, id: UUID) async throws -> Bool {
        Int(try await database.query("SELECT COUNT(*) FROM \(table) WHERE id = ?;", [.uuid(id)]).first?.int(0) ?? 0) > 0
    }

    private func nextSequence(_ jobID: UUID) async throws -> Int {
        Int(try await database.query("SELECT COALESCE(MAX(sequence), 0) FROM job_events WHERE job_id = ?;",
                                     [.uuid(jobID)]).first?.int(0) ?? 0) + 1
    }

    private func nextOrdinal(_ jobID: UUID) async throws -> Int {
        Int(try await database.query("SELECT COALESCE(MAX(ordinal), -1) FROM job_plan_references WHERE job_id = ?;",
                                     [.uuid(jobID)]).first?.int(0) ?? -1) + 1
    }

    private func bumpRevision(jobID: UUID, to revision: Int, at date: Date) async throws {
        try await database.exec("UPDATE job_objectives SET revision = ?, updated_at = ? WHERE id = ?;",
                                [.integer(Int64(revision)), .date(date), .uuid(jobID)])
    }

    private func appendEvent(jobID: UUID, sequence: Int, revision: Int, action: JobEventAction,
                             actor: String, detail: String?, at date: Date) async throws {
        try await database.exec("""
            INSERT INTO job_events (id, job_id, sequence, job_revision, action, actor, detail, occurred_at)
            VALUES (?,?,?,?,?,?,?,?);
            """, [.uuid(UUID()), .uuid(jobID), .integer(Int64(sequence)), .integer(Int64(revision)),
                  .text(action.rawValue), .text(actor), .optionalText(detail), .date(date)])
    }

    private func budgetColumns(_ budget: TimeBudget) -> (seconds: SQLValue, deadline: SQLValue, workflow: SQLValue) {
        (budget.explicitDuration.map { SQLValue.real($0) } ?? .null,
         budget.deadlineID.map { SQLValue.uuid($0) } ?? .null,
         budget.workflowRunID.map { SQLValue.uuid($0) } ?? .null)
    }

    private func savepointName(_ prefix: String, _ id: UUID) -> String {
        "\(prefix)_\(id.uuidString.replacingOccurrences(of: "-", with: ""))"
    }

    // MARK: - Columns + decoders

    private nonisolated static let objectiveColumns = """
    SELECT id, workspace_id, title, objective_detail, budget_basis, budget_seconds, budget_deadline_id,
           budget_workflow_run_id, primary_workflow_run_id, lifecycle, revision, created_at, updated_at,
           closed_at, closure_reason
    FROM job_objectives
    """

    private nonisolated static func decodeObjective(_ r: SQLRow) -> JobObjective? {
        guard let id = r.uuid(0), let ws = r.uuid(1), let title = r.string(2),
              let basis = r.string(4).flatMap(JobBudgetBasis.init(rawValue:)),
              let lifecycle = r.string(9).flatMap(JobLifecycle.init(rawValue:)),
              let revision = r.int(10).map({ Int($0) }),
              let created = r.date(11), let updated = r.date(12) else { return nil }
        let budget = TimeBudget(basis: basis, explicitDuration: r.double(5),
                                deadlineID: r.uuid(6), workflowRunID: r.uuid(7))
        return JobObjective(id: id, workspaceID: ws, title: title, detail: r.string(3), budget: budget,
                            primaryWorkflowRunID: r.uuid(8), lifecycle: lifecycle, revision: revision,
                            createdAt: created, updatedAt: updated, closedAt: r.date(13),
                            closureReason: r.string(14))
    }

    private nonisolated static let referenceColumns = """
    SELECT id, job_id, reference_kind, reference_id, workflow_run_id, role, is_minimum_deliverable,
           ordinal, note, created_at
    FROM job_plan_references
    """

    private nonisolated static func decodeReference(_ r: SQLRow) -> JobPlanReference? {
        guard let id = r.uuid(0), let job = r.uuid(1),
              let kind = r.string(2).flatMap(JobPlanReferenceKind.init(rawValue:)),
              let refID = r.string(3),
              let role = r.string(5).flatMap(JobPlanReferenceRole.init(rawValue:)),
              let mad = r.int(6), let ordinal = r.int(7).map({ Int($0) }),
              let created = r.date(9) else { return nil }
        return JobPlanReference(id: id, jobID: job, kind: kind, referenceID: refID,
                                workflowRunID: r.uuid(4), role: role, isMinimumDeliverable: mad == 1,
                                ordinal: ordinal, note: r.string(8), createdAt: created)
    }

    private nonisolated static let eventColumns = """
    SELECT id, job_id, sequence, job_revision, action, actor, detail, occurred_at
    FROM job_events
    """

    private nonisolated static func decodeEvent(_ r: SQLRow) -> JobEvent? {
        guard let id = r.uuid(0), let job = r.uuid(1),
              let seq = r.int(2).map({ Int($0) }), let rev = r.int(3).map({ Int($0) }),
              let action = r.string(4).flatMap(JobEventAction.init(rawValue:)),
              let actor = r.string(5), let at = r.date(7) else { return nil }
        return JobEvent(id: id, jobID: job, sequence: seq, jobRevision: rev, action: action,
                        actor: actor, detail: r.string(6), occurredAt: at)
    }
}
