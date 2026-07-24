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

    private func runPass(at now: Date) async {
        for kind in Kind.allCases { await runKind(kind, at: now) }
        do { _ = try await membership.deriveAll(at: now) }
        catch { KalsmritikoshLog.storage.error("Claim membership reconciliation failed: \(String(describing: error), privacy: .public)") }
    }

    private struct Item { let id: UUID; let project: () async throws -> ClaimProjectionOutcome }

    private func runKind(_ kind: Kind, at now: Date) async {
        do {
            if try await progress.cursor(version: version, kind: kind.rawValue).complete { return }
            var after = try await progress.cursor(version: version, kind: kind.rawValue).lastSourceID
            while true {
                let page = try await fetch(kind, afterID: after, at: now)
                if page.isEmpty {
                    try await progress.markComplete(version: version, kind: kind.rawValue, at: now); break
                }
                for item in page {
                    _ = try await item.project()          // infra failure THROWS → cursor not advanced
                    after = item.id
                    try await progress.advance(version: version, kind: kind.rawValue, lastSourceID: item.id, at: now)
                }
                if page.count < pageSize {
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
            return (try await events.pageWithParticipants(afterID: afterID, pageSize: pageSize)).map { pair in
                Item(id: pair.0.id) { try await self.producer.project(event: pair.0, participants: pair.1, at: now) }
            }
        }
    }
}
