//
//  BackgroundMemoryDistiller.swift
//  Kalsmritikosh
//
//  Idle-gated background memory distillation. The ledger-first engine does
//  ZERO distillation at ingest (the minimum-LLM promise), so on a fresh corpus
//  `memory_objects` stays empty until either the user presses "Distill memory
//  now" or a question is asked about a subject. This worker is the background
//  half of that pair: while the Mac is idle AND the user has opted into
//  background maintenance, it distills the top subjects in the ledger so memory
//  is warm before the user asks.
//
//  Distillation can spend an LLM call, so — unlike EntityReconciler (pure
//  rule-based, always on) — this worker is gated behind the user's maintenance
//  choice. The injected `distill` closure returns 0 when the gate says "not
//  now" (maintenance Off), keeping the minimum-LLM release default intact.
//

import Foundation
import OSLog

public actor BackgroundMemoryDistiller: BackgroundService {
    public let id = "kalsmritikosh.memory.distiller"

    /// Returns the number of subjects distilled, or 0 when the maintenance gate
    /// declines (Off) or the distiller isn't ready. Injected by AppState so the
    /// gate + banner + the distiller all live in one place.
    private let distill: @Sendable () async -> Int
    private let idleThreshold: TimeInterval
    private let interval: TimeInterval
    private let pollInterval: TimeInterval

    private var watchTask: Task<Void, Never>?
    private var lastRunAt: Date = .distantPast

    public init(
        idleThreshold: TimeInterval = 90,
        interval: TimeInterval = 6 * 60 * 60,
        pollInterval: TimeInterval = 30,
        distill: @escaping @Sendable () async -> Int
    ) {
        self.idleThreshold = idleThreshold
        self.interval = interval
        self.pollInterval = pollInterval
        self.distill = distill
    }

    public func start() async {
        guard watchTask == nil else { return }
        KalsmritikoshLog.knowledge.info("BackgroundMemoryDistiller watching (idle memory distillation)")
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
        let count = await distill()
        if count > 0 {
            KalsmritikoshLog.knowledge.info("BackgroundMemoryDistiller distilled \(count, privacy: .public) subject(s)")
        }
    }
}
