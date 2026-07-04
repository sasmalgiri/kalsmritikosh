//
//  EntityReconciler.swift
//  Kalsmritikosh
//
//  On-device, rule-based ledger self-healing. During idle it looks for
//  OCR / typo variants of the SAME name — a single-occurrence spelling
//  like "Thirshendus Sasmal" from a garbled signature line — and folds it
//  into the corroborated spelling ("Shirshendu Sasmal", seen cleanly
//  several times in the same corpus). Nothing is deleted; the variant is
//  aliased to the winner and demoted in trust (the "tier by confidence"
//  rule), so answers self-correct without ever losing source data.
//
//  Mode-independent: runs in all three system modes (name hygiene isn't a
//  per-architecture concern). Idle-gated so it never competes with the user.
//

import Foundation
import OSLog

public actor EntityReconciler: BackgroundService {
    public let id = "atlas.entity.reconciler"

    /// Returns the number of variants folded. Injected by AppState.
    private let reconcile: @Sendable () async -> Int
    private let idleThreshold: TimeInterval
    private let interval: TimeInterval
    private let pollInterval: TimeInterval

    private var watchTask: Task<Void, Never>?
    private var lastRunAt: Date = .distantPast

    public init(
        idleThreshold: TimeInterval = 60,
        interval: TimeInterval = 30 * 60,
        pollInterval: TimeInterval = 20,
        reconcile: @escaping @Sendable () async -> Int
    ) {
        self.idleThreshold = idleThreshold
        self.interval = interval
        self.pollInterval = pollInterval
        self.reconcile = reconcile
    }

    public func start() async {
        guard watchTask == nil else { return }
        AtlasLog.knowledge.info("EntityReconciler watching (idle name self-correction)")
        watchTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.tick()
                let ns = UInt64(self.pollInterval * 1_000_000_000)
                try? await Task.sleep(nanoseconds: ns)
            }
        }
    }

    public func stop() async {
        watchTask?.cancel()
        watchTask = nil
    }

    private func tick() async {
        guard SystemActivity.isIdle(threshold: idleThreshold) else { return }
        guard Date().timeIntervalSince(lastRunAt) >= interval else { return }
        lastRunAt = Date()
        let folded = await reconcile()
        if folded > 0 {
            AtlasLog.knowledge.info("EntityReconciler folded \(folded, privacy: .public) OCR name variant(s)")
        }
    }
}
