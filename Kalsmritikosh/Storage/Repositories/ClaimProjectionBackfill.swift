//
//  ClaimProjectionBackfill.swift
//  Kalsmritikosh
//
//  PA-PROD Commit B2 — the resumable, single-flight background driver that projects the whole
//  ledger into canonical Claims and reconciles derived workspace membership. Durable via
//  ClaimProjectionProgressRepository (keyset cursor per producer version + source kind).
//
//  At-least-once semantics per source: fetch keyset page → project one source → persist its
//  Claims → advance the cursor. A crash between persistence and cursor-advance safely repeats
//  that source (Claim ids are fingerprint-idempotent, so a repeat updates, never duplicates).
//  A malformed/unsupported source is SKIPPED and the cursor advances; an INFRASTRUCTURE failure
//  (db / evidence store / page query) THROWS, halting that kind's pass with the cursor left at
//  the last successful source — so nothing is ever marked complete without its Claims saved.
//

import Foundation
import os

public actor ClaimProjectionBackfill {
    public enum Kind: String, CaseIterable, Sendable {
        case genericFact, temporalClaim, assertion, event
    }

    private let producer: ClaimProducer
    private let progress: ClaimProjectionProgressRepository
    private let membership: WorkspaceMembershipDeriver
    private let genericFacts: GenericFactRepository
    private let temporalClaims: TemporalClaimRepository
    private let assertions: AssertionsRepository
    private let events: EventsRepository
    private let pageSize: Int
    /// The producer version this backfill records progress under. A new version gets an
    /// independent progress set (a fresh pass); defaults to the current producer version.
    private let version: String
    private var active: Task<Void, Never>?
    /// Test seam (internal, not public API): awaited once before each source is projected, so a
    /// test can deterministically interleave cancellation mid-page. nil in production.
    var beforeEachProject: (@Sendable () async -> Void)?

    public init(producer: ClaimProducer, progress: ClaimProjectionProgressRepository,
                membership: WorkspaceMembershipDeriver,
                genericFacts: GenericFactRepository, temporalClaims: TemporalClaimRepository,
                assertions: AssertionsRepository, events: EventsRepository, pageSize: Int = 500,
                version: String = ClaimProducer.producerVersion) {
        self.producer = producer; self.progress = progress; self.membership = membership
        self.genericFacts = genericFacts; self.temporalClaims = temporalClaims
        self.assertions = assertions; self.events = events; self.pageSize = pageSize
        self.version = version
    }

    /// Single-flight: concurrent callers await the one active pass rather than starting a
    /// duplicate scan.
    public func run(at now: Date) async {
        if let active { await active.value; return }
        let task = Task { await self.runPass(at: now) }
        active = task
        await task.value
        active = nil
    }

    /// Cancel the in-flight pass (if any) and AWAIT its cooperative wind-down. Because the loops
    /// check `Task.isCancelled` before every kind, page, source, completion mark, and membership
    /// reconciliation, cancellation stops promptly and NEVER marks unfinished work complete — the
    /// durable cursor is left at the last successfully-projected source, so the next run resumes
    /// there. AppState calls this on the OLD projection actor before replacing it on a re-boot.
    public func cancel() async {
        active?.cancel()
        await active?.value
        active = nil
    }

    /// Cancel the active task WITHOUT awaiting it — safe to call from inside the pass itself
    /// (e.g. a test seam). Awaiting from within would deadlock on the running task.
    func requestCancel() { active?.cancel() }

    /// Test seam (internal): install the before-each-project hook.
    func setBeforeEachProject(_ hook: @escaping @Sendable () async -> Void) { beforeEachProject = hook }

    private func runPass(at now: Date) async {
        for kind in Kind.allCases {
            if Task.isCancelled { return }                       // before every source kind
            await runKind(kind, at: now)
        }
        if Task.isCancelled { return }                           // before membership reconciliation
        do { _ = try await membership.deriveAll(at: now) }
        catch { KalsmritikoshLog.storage.error("Claim membership reconciliation failed: \(String(describing: error), privacy: .public)") }
    }

    /// Incremental post-ingest projection for ONE freshly-committed source file — the
    /// IngestCoordinator hook. Runs on the SAME actor as the full backfill, so it never scans
    /// concurrently with a full pass (it first awaits any active pass to completion). Projects
    /// the file's affected subjects into Claims and reconciles derived membership for only the
    /// workspaces that hold this source. Fully idempotent (fingerprint Claim ids + derived-set
    /// replacement), so repeats and overlaps are safe. NEVER throws: a projection failure must
    /// never fail the ingest that triggered it — it is logged and swallowed.
    public func projectSource(fileID: UUID, at now: Date) async {
        // Fire-and-forget ingestion hook: failures are logged and swallowed so a projection error
        // never fails the ingest that triggered it.
        do { try await projectSourceForUserAction(fileID: fileID, at: now) }
        catch { KalsmritikoshLog.storage.error("Incremental claim projection failed for one source: \(String(describing: error), privacy: .public)") }
    }

    /// PA-UI-001 — the SAME per-source projection as `projectSource`, but for an explicit USER
    /// action (adding a source to a workspace): it PROPAGATES errors so the UI can surface an
    /// actionable failure instead of silently doing nothing. Runs on the shared actor (awaits any
    /// active full pass first), produces the source's affected subjects' Claims, and reconciles
    /// derived membership for the workspaces that hold the source.
    public func projectSourceForUserAction(fileID: UUID, at now: Date) async throws {
        if let active { await active.value }   // don't interleave a scan with a full pass
        let subjects = try await membership.subjects(inFiles: [fileID])
        for subject in subjects { _ = try await producer.produce(forSubjectID: subject, at: now) }
        _ = try await membership.reconcileWorkspaces(forSource: fileID, at: now)
    }

    private struct Item { let id: UUID; let project: () async throws -> ClaimProjectionOutcome }

    private func runKind(_ kind: Kind, at now: Date) async {
        do {
            if try await progress.cursor(version: version, kind: kind.rawValue).complete { return }
            var after = try await progress.cursor(version: version, kind: kind.rawValue).lastSourceID
            while true {
                if Task.isCancelled { return }            // before every fetched page
                let page = try await fetch(kind, afterID: after, at: now)
                if page.isEmpty {
                    if Task.isCancelled { return }         // never mark complete once cancelled
                    try await progress.markComplete(version: version, kind: kind.rawValue, at: now); break
                }
                for item in page {
                    if Task.isCancelled { return }         // before projecting each source
                    await beforeEachProject?()
                    if Task.isCancelled { return }         // the hook may have requested cancellation
                    _ = try await item.project()          // infra failure THROWS → cursor not advanced
                    after = item.id
                    try await progress.advance(version: version, kind: kind.rawValue, lastSourceID: item.id, at: now)
                }
                if page.count < pageSize {
                    if Task.isCancelled { return }         // never mark complete once cancelled
                    try await progress.markComplete(version: version, kind: kind.rawValue, at: now); break
                }
            }
        } catch {
            // Infrastructure failure: halt this kind; the cursor stays at the last successful
            // source, so the next run resumes there (nothing marked complete prematurely).
            KalsmritikoshLog.storage.error("Claim projection halted for \(kind.rawValue, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    private func fetch(_ kind: Kind, afterID: UUID?, at now: Date) async throws -> [Item] {
        switch kind {
        case .genericFact:
            return (try await genericFacts.page(afterID: afterID, pageSize: pageSize)).map { f in
                Item(id: f.id) { try await self.producer.project(genericFact: f, at: now) }
            }
        case .temporalClaim:
            return (try await temporalClaims.page(afterID: afterID, pageSize: pageSize)).map { t in
                Item(id: t.id) { try await self.producer.project(temporalClaim: t, at: now) }
            }
        case .assertion:
            return (try await assertions.page(afterID: afterID, pageSize: pageSize)).map { a in
                Item(id: a.id) { try await self.producer.project(assertion: a, at: now) }
            }
        case .event:
            // PA-EXT-001 — hydrate attributes + narrative slots + participant labels (batched) so
            // the producer renders rich statements; keyset cursor still keys on the event id.
            return (try await events.pageForClaimProjection(afterID: afterID, pageSize: pageSize)).map { source in
                Item(id: source.event.id) { try await self.producer.project(source: source, at: now) }
            }
        }
    }
}
