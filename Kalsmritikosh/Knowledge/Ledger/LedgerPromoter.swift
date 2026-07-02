//
//  LedgerPromoter.swift
//  Kalsmritikosh
//
//  System 3 (Ledger event-driven) — the PROACTIVE engine. Where the
//  Full-LLM system eagerly extracts everything up front and the
//  Hot/Warm/Cold system tiers by importance, System 3 stays near-zero
//  LLM but *proactively maintains the structured ledger during idle*:
//  it re-derives the "missing links" (gap) layer as the corpus grows,
//  so findings surface before the user asks — without spending LLM
//  budget. This is the "the system tells you what happened" direction,
//  done with deterministic rules.
//
//  Self-gating: only runs when the active SystemMode is
//  `.ledgerEventDriven` AND the machine is idle, so it never competes
//  with the user or the other modes.
//

import Foundation
import OSLog

public actor LedgerPromoter: BackgroundService {
    public let id = "atlas.ledger.promoter"

    /// Rule-based gap scan (no LLM). Returns the count found.
    private let scan: @Sendable () async -> Int
    /// True only when System 3 is the active mode.
    private let isActive: @Sendable () -> Bool
    /// Seconds of idle before a proactive pass runs.
    private let idleThreshold: TimeInterval
    /// Minimum spacing between proactive passes.
    private let interval: TimeInterval
    /// How often the watch loop samples.
    private let pollInterval: TimeInterval
    /// Reports each pass so the UI can show "ledger maintained just now".
    private let onScan: @Sendable (Int) -> Void

    private var watchTask: Task<Void, Never>?
    private var lastRunAt: Date = .distantPast

    public init(
        idleThreshold: TimeInterval = 90,
        interval: TimeInterval = 20 * 60,
        pollInterval: TimeInterval = 15,
        isActive: @escaping @Sendable () -> Bool,
        scan: @escaping @Sendable () async -> Int,
        onScan: @escaping @Sendable (Int) -> Void = { _ in }
    ) {
        self.idleThreshold = idleThreshold
        self.interval = interval
        self.pollInterval = pollInterval
        self.isActive = isActive
        self.scan = scan
        self.onScan = onScan
    }

    public func start() async {
        guard watchTask == nil else { return }
        AtlasLog.knowledge.info("LedgerPromoter watching (System 3 proactive gap maintenance)")
        watchTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.tick()
                let ns = await UInt64(self.pollInterval * 1_000_000_000)
                try? await Task.sleep(nanoseconds: ns)
            }
        }
    }

    public func stop() async {
        watchTask?.cancel()
        watchTask = nil
    }

    private func tick() async {
        guard isActive() else { return }                                  // only in ledger mode
        guard SystemActivity.isIdle(threshold: idleThreshold) else { return }
        guard Date().timeIntervalSince(lastRunAt) >= interval else { return }
        lastRunAt = Date()
        let found = await scan()
        onScan(found)
        AtlasLog.knowledge.info("LedgerPromoter proactive pass — \(found, privacy: .public) gaps in the ledger")
    }
}
