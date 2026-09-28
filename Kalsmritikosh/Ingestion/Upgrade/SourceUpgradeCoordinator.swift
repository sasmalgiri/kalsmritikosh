//
//  SourceUpgradeCoordinator.swift
//  Kalsmritikosh
//
//  USF-M3 (USF-009 §26/§27/§29) — the ONE progressive-upgrade authority. `ensure(goal:)` plans the
//  MINIMAL work from durable readiness, enqueues it (idempotent), and — in foreground — claims → executes
//  → VERIFIES the durable readiness postcondition → marks done (a handler that returns WITHOUT advancing
//  readiness fails postcondition, never silently "done"). Background execution plans + returns; the drainer
//  runs claimed jobs later and yields to interactive queries. Impossible targets become blockers, not
//  endless jobs.
//

import Foundation

public struct SourceUpgradeCoordinator: Sendable {

    private let database: Database
    private let jobs: SourceUpgradeJobRepository
    private let readiness: SourceReadinessRepository
    private let container: ContainerInspectionRepository?
    private let executor: SourceUpgradeExecutor
    private let priorityGate: QueryPriorityGate?

    public init(database: Database, jobs: SourceUpgradeJobRepository, readiness: SourceReadinessRepository,
                container: ContainerInspectionRepository?, executor: SourceUpgradeExecutor, priorityGate: QueryPriorityGate? = nil) {
        self.database = database
        self.jobs = jobs
        self.readiness = readiness
        self.container = container
        self.executor = executor
        self.priorityGate = priorityGate
    }

    /// Plan + persist the minimal work to reach `goal` for an EXACT source version. Foreground also
    /// claims + executes + verifies each job now. Throws a typed blocker when the goal is unreachable.
    @discardableResult
    public func ensure(sourceVersionID: UUID, goal: SourceUpgradeGoal, priority: SourceUpgradePriority = .userRequested,
                       execution: SourceUpgradeExecutionMode = .background, origin: SourceUpgradeOrigin = .userRequested,
                       at now: Date) async throws -> [SourceUpgradeJob] {
        guard let typeRaw = try await database.query(
            "SELECT detected_type FROM source_versions WHERE id = ? LIMIT 1;", [.uuid(sourceVersionID)]).first?.string(0) else {
            throw SourceUpgradeError.sourceVersionMissing(sourceVersionID)
        }
        let type = SourceType(rawValue: typeRaw) ?? .unknown
        try await reconcileIndexing(sourceVersionID, at: now)
        let snapshot = try await readiness.snapshot(sourceVersionID: sourceVersionID)
        let containerStatus = type.category == .archive ? (try? await container?.manifest(sourceVersionID: sourceVersionID)?.status) ?? nil : nil

        let plan = try SourceUpgradePlanner.plan(sourceVersionID: sourceVersionID, goal: goal,
                                                 detectedType: type, readiness: snapshot, containerStatus: containerStatus)
        if plan.alreadySatisfied { return [] }

        var enqueued: [SourceUpgradeJob] = []
        for kind in plan.kinds {
            enqueued.append(try await jobs.enqueue(sourceVersionID: sourceVersionID, kind: kind, goal: goal,
                                                   priority: priority, origin: origin, at: now))
        }
        if execution == .foreground {
            for job in enqueued {
                if let claimed = try await jobs.claim(jobID: job.id, at: now) {
                    try await executeClaimed(claimed, at: now)
                }
            }
        }
        return enqueued
    }

    /// F15 — readiness was trusted as recorded: a stored "indexing ready (N units)" stayed ready even
    /// after the chunks behind it were lost, so nothing ever re-planned the index. Before planning, the
    /// stored indexing claim is checked against the LIVE per-version FTS coverage; when coverage has
    /// fallen below what was recorded, the dimension is invalidated so the planner schedules a rebuild.
    private func reconcileIndexing(_ sourceVersionID: UUID, at now: Date) async throws {
        let snap = try await readiness.snapshot(sourceVersionID: sourceVersionID)
        guard let rec = snap.dimension(.indexing), rec.state == .ready || rec.state == .partial else { return }
        let recorded = rec.completedUnits ?? 0
        let live = try await readiness.ftsCoverage(sourceVersionID: sourceVersionID)
        guard recorded > 0, live.indexed < recorded else { return }
        try await readiness.apply(SourceReadinessUpdatePlan(
            sourceVersionID: sourceVersionID, expectedRevision: snap.aggregateRevision,
            updates: [SourceReadinessDimensionUpdate(
                dimension: .indexing, state: .running, action: .invalidate,
                detail: "index coverage fell to \(live.indexed)/\(recorded) — rebuild required")],
            producerID: "usf-m3.reconcile", producerVersion: "1", occurredAt: now))
    }

    /// Background drainer step: claim the next eligible job, run + verify it, return whether one ran.
    @discardableResult
    public func runNext(at now: Date) async -> Bool {
        await priorityGate?.awaitClearance()
        guard let claimed = (try? await jobs.claimNext(at: now)) ?? nil else { return false }
        try? await executeClaimed(claimed, at: now)
        return true
    }

    /// Drain up to `max` eligible jobs (background). Yields to interactive queries between jobs.
    @discardableResult
    public func drain(max: Int = .max, at now: Date) async -> Int {
        var ran = 0
        // F21 — each job gets a FRESH time (the caller's `now` advanced by real elapsed time): reusing
        // one timestamp for a long drain issues late jobs leases that are already expired in wall time,
        // so recovery could reclaim a job its worker is still running.
        let wallStart = Date()
        while ran < max, await runNext(at: now.addingTimeInterval(Date().timeIntervalSince(wallStart))) { ran += 1 }
        return ran
    }

    // MARK: - Execute a claimed (running) job + verify its postcondition

    private func executeClaimed(_ claimed: SourceUpgradeJob, at now: Date) async throws {
        guard let svid = claimed.sourceVersionID else { return }
        // F21 — every outcome below is written under THIS claim's lease token, so a worker whose job
        // was reclaimed or cancelled meanwhile cannot overwrite the newer state (`staleLease`).
        guard executor.handles(claimed.kind) else {
            try await jobs.block(claimed.id, reason: "no handler for \(claimed.kind.rawValue)", lease: claimed.leaseToken, at: now)
            throw SourceUpgradeError.unsupportedCapability(claimed.kind)
        }
        do {
            try await executor.execute(kind: claimed.kind, sourceVersionID: svid)
        } catch let e as SourceUpgradeError {
            // Permanent blockers (bytes changed/missing, unsupported, policy) block; transient errors retry.
            if Self.isPermanent(e) { try await jobs.block(claimed.id, reason: "\(e)", lease: claimed.leaseToken, at: now) }
            else { try await jobs.fail(claimed, error: "\(e)", at: now) }
            throw e
        } catch {
            try await jobs.fail(claimed, error: "\(error)", at: now)   // bounded auto-retry
            throw error
        }
        // §27 — the job is done ONLY when the durable readiness postcondition is actually met.
        if try await postconditionMet(kind: claimed.kind, sourceVersionID: svid) {
            try await jobs.succeed(claimed, at: now)
        } else {
            // §27 — a handler that ran but did not advance readiness fails TERMINALLY (re-running the
            // same work would not change the durable state), never silently "done", never endless retry.
            try await jobs.failTerminal(claimed, error: "postconditionNotSatisfied", at: now)
            throw SourceUpgradeError.postconditionNotSatisfied(kind: claimed.kind, sourceVersionID: svid)
        }
    }

    private func postconditionMet(kind: SourceUpgradeKind, sourceVersionID: UUID) async throws -> Bool {
        if kind == .containerInspection {
            return try await container?.manifest(sourceVersionID: sourceVersionID) != nil
        }
        let after = try await readiness.snapshot(sourceVersionID: sourceVersionID)
        if let dim = kind.targetDimension {
            let rec = after.dimension(dim)
            return rec?.state == .ready || (rec?.hasPresentContent ?? false)
        }
        // Analytical sub-kinds (embedding/entity/etc.) have no single readiness dimension — the handler's
        // successful, durable return is the postcondition.
        return true
    }

    private static func isPermanent(_ e: SourceUpgradeError) -> Bool {
        switch e {
        case .unsupportedCapability, .missingDependency, .sourceUnavailable, .policyBlocked,
             .sourceBytesChanged, .vaultBlobMissing, .hashMismatch, .sourceVersionMissing:
            return true
        default:
            return false
        }
    }
}
