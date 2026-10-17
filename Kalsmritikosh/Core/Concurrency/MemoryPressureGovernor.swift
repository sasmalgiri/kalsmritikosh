//
//  MemoryPressureGovernor.swift
//  Kalsmritikosh
//
//  F12 — memory-aware resource control. Worker caps and caches were sized once from boot-time
//  RAM and never reacted to the machine running short. The governor listens to the kernel's
//  memory-pressure signal (DispatchSource) and fans each level CHANGE out to its responders:
//
//    warning  → background drains (embedding backfill, source upgrades) idle between batches,
//               and the ingest lanes narrow to their floor.
//    critical → the same, and the corpus-wide retrieval caches shed (retrieval reads SQL).
//    normal   → drains resume, lanes widen back to their boot-time caps, and caches shed BY
//               PRESSURE re-warm from SQL (one at a time). SQL serves until each is warm.
//
//  Nothing is dropped: every drain's pending set is durable, and a shed cache is only a copy.
//  `report(_:)` is the single entry point, so tests drive it directly without the kernel.
//

import Foundation
import OSLog

public enum MemoryPressureLevel: Int, Sendable, Comparable, CustomStringConvertible {
    case normal, warning, critical

    public nonisolated static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    public nonisolated var description: String {
        switch self {
        case .normal: return "normal"
        case .warning: return "warning"
        case .critical: return "critical"
        }
    }

    /// The most severe level a kernel memory-pressure event carries.
    public nonisolated init(event: DispatchSource.MemoryPressureEvent) {
        if event.contains(.critical) { self = .critical }
        else if event.contains(.warning) { self = .warning }
        else { self = .normal }
    }
}

public actor MemoryPressureGovernor {
    public typealias Responder = @Sendable (MemoryPressureLevel) async -> Void

    private var level: MemoryPressureLevel = .normal
    private var responders: [Responder] = []
    private var source: DispatchSourceMemoryPressure?
    /// F12 — the newest level reported but not yet applied, and whether a drain is running. A
    /// responder suspends (it awaits caches / lanes), and actor reentrancy used to let the NEXT report
    /// start its responders mid-way — a relief re-warm could run before the critical shed finished.
    private var pending: MemoryPressureLevel?
    private var draining = false

    public init() {}

    public func currentLevel() -> MemoryPressureLevel { level }

    /// The newest level the system has reported (pending, or else applied). Relief work checks this
    /// between steps so it stops the moment pressure returns.
    public func latestReportedLevel() -> MemoryPressureLevel { pending ?? level }

    /// Register a responder. It is called on every level change, in registration order.
    public func addResponder(_ responder: @escaping Responder) { responders.append(responder) }

    /// Apply a new pressure level. Levels are applied ONE AT A TIME, in report order: a report that
    /// arrives while responders are running is queued, and only the newest queued level is applied
    /// next (intermediate levels superseded by a newer report are skipped). Repeats are ignored.
    public func report(_ new: MemoryPressureLevel) async {
        pending = new
        guard !draining else { return }
        draining = true
        defer { draining = false }
        while let next = pending {
            pending = nil
            guard next != level else { continue }
            let old = level
            level = next
            KalsmritikoshLog.app.notice("Memory pressure \(old.description, privacy: .public) → \(next.description, privacy: .public)")
            for responder in responders { await responder(next) }
        }
    }

    /// Start listening to the kernel's memory-pressure events. Idempotent.
    public func startMonitoring() {
        guard source == nil else { return }
        let src = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical],
                                                          queue: .global(qos: .utility))
        src.setEventHandler { [weak self, weak src] in
            guard let self, let event = src?.data else { return }
            let reported = MemoryPressureLevel(event: event)
            Task { await self.report(reported) }
        }
        src.resume()
        source = src
    }

    public func stopMonitoring() {
        source?.cancel()
        source = nil
    }
}

/// F12 — the standard responses, kept apart from the kernel wiring so they are testable.
public enum MemoryPressureResponse {
    /// The shed reason pressure writes; relief re-warms exactly the caches carrying it (a cache
    /// shed for exceeding its own byte budget would only exceed it again, so it stays cold).
    public static let pressureShedReason = "system memory pressure critical"

    /// Re-warm hooks, one per cache; each re-reads its cache's source of truth.
    public struct Rewarm: Sendable {
        public var memory: (@Sendable () async -> Void)?
        public var timeline: (@Sendable () async -> Void)?
        public var trie: (@Sendable () async -> Void)?
        public init(memory: (@Sendable () async -> Void)? = nil, timeline: (@Sendable () async -> Void)? = nil,
                    trie: (@Sendable () async -> Void)? = nil) {
            self.memory = memory; self.timeline = timeline; self.trie = trie
        }
    }

    /// Wire the ingest coordinator, lane scheduler and retrieval caches to `governor`.
    public static func install(on governor: MemoryPressureGovernor, ingest: IngestCoordinator?,
                               lanes: LaneScheduler? = nil, memory: MemoryHashCache?,
                               timeline: EntityTimeline?, trie: EntityTrie?, rewarm: Rewarm = Rewarm()) async {
        await governor.addResponder { level in
            await apply(level, ingest: ingest, lanes: lanes, memory: memory, timeline: timeline, trie: trie, rewarm: rewarm,
                        stillRelieved: { await governor.latestReportedLevel() == .normal })
        }
    }

    public static func apply(_ level: MemoryPressureLevel, ingest: IngestCoordinator?, lanes: LaneScheduler?,
                             memory: MemoryHashCache?, timeline: EntityTimeline?, trie: EntityTrie?,
                             rewarm: Rewarm = Rewarm(),
                             stillRelieved: @Sendable () async -> Bool = { true }) async {
        await ingest?.setPressurePaused(level != .normal)
        await lanes?.setPressure(level)
        switch level {
        case .critical:
            await memory?.shed(reason: pressureShedReason)
            await timeline?.shed(reason: pressureShedReason)
            await trie?.shed(reason: pressureShedReason)
        case .normal:
            // Relief: rebuild only what pressure took away. Warms run one after another so the
            // recovery itself does not spike memory, and each re-checks that pressure has not
            // returned — a critical report arriving mid-recovery stops the remaining warms.
            if await stillRelieved(), await memory?.lastShedReason() == pressureShedReason { await rewarm.memory?() }
            if await stillRelieved(), await timeline?.lastShedReason() == pressureShedReason { await rewarm.timeline?() }
            if await stillRelieved(), await trie?.lastShedReason() == pressureShedReason { await rewarm.trie?() }
        case .warning:
            break
        }
    }
}
