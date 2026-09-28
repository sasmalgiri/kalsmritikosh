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

    public init() {}

    public func currentLevel() -> MemoryPressureLevel { level }

    /// Register a responder. It is called on every level change, in registration order.
    public func addResponder(_ responder: @escaping Responder) { responders.append(responder) }

    /// Apply a new pressure level. Repeats of the current level are ignored.
    public func report(_ new: MemoryPressureLevel) async {
        guard new != level else { return }
        let old = level
        level = new
        KalsmritikoshLog.app.notice("Memory pressure \(old.description, privacy: .public) → \(new.description, privacy: .public)")
        for responder in responders { await responder(new) }
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
            await apply(level, ingest: ingest, lanes: lanes, memory: memory, timeline: timeline, trie: trie, rewarm: rewarm)
        }
    }

    public static func apply(_ level: MemoryPressureLevel, ingest: IngestCoordinator?, lanes: LaneScheduler?,
                             memory: MemoryHashCache?, timeline: EntityTimeline?, trie: EntityTrie?,
                             rewarm: Rewarm = Rewarm()) async {
        await ingest?.setPressurePaused(level != .normal)
        await lanes?.setPressure(level)
        switch level {
        case .critical:
            await memory?.shed(reason: pressureShedReason)
            await timeline?.shed(reason: pressureShedReason)
            await trie?.shed(reason: pressureShedReason)
        case .normal:
            // Relief: rebuild only what pressure took away. Warms run one after another so the
            // recovery itself does not spike memory.
            if await memory?.lastShedReason() == pressureShedReason { await rewarm.memory?() }
            if await timeline?.lastShedReason() == pressureShedReason { await rewarm.timeline?() }
            if await trie?.lastShedReason() == pressureShedReason { await rewarm.trie?() }
        case .warning:
            break
        }
    }
}
