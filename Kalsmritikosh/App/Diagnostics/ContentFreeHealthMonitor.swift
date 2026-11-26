//
//  ContentFreeHealthMonitor.swift
//  Kalsmritikosh
//
//  Unified path R2-E (PERF-12, owner 2026-11-22 round 2) — not tested yet. Health monitoring for a deployed service
//  (the simulated team service today; the relay or a real team service later) that never collects case content:
//  every key is a short machine token (route / error class), every value is a number. A free-text key — a name, an
//  e-mail address, a passage — is refused, not stored, so an operator can diagnose outages (health, queue lag, error
//  classes, resource use) while the declared privacy model holds. In this build it runs only inside the simulations
//  (SimulatedTeamJourneys, scripts/sim/); a real deployment needs an operator account and the deployed service.
//

import Foundation
import os

public nonisolated enum HealthOutcome: String, Sendable, Codable, CaseIterable {
    case ok, refused, failed
}

/// What went wrong, as a class — never the message, the input or the person.
public nonisolated enum HealthErrorClass: String, Sendable, Codable, CaseIterable {
    case authentication, permission, expired, notFound, conflict, storage, network, timeout, rateLimited, invalidInput, `internal`
}

public nonisolated struct HealthSnapshot: Sendable, Codable, Equatable {
    public struct RouteStats: Sendable, Codable, Equatable {
        public var count = 0
        public var outcomes: [String: Int] = [:]
        public var errorClasses: [String: Int] = [:]
        /// Latency buckets in milliseconds: "<50", "<250", "<1000", "<5000", ">=5000".
        public var latencyBuckets: [String: Int] = [:]
    }
    public var label = "SIMULATED content-free health snapshot"
    public var takenAt: Double
    public var uptimeSeconds: Double
    public var routes: [String: RouteStats]
    public var queueDepth: [String: Int]
    public var oldestQueuedSeconds: [String: Double]
    public var maxResidentBytes: Int64
    public var userCPUSeconds: Double
    public var refusedKeys: Int
    /// Healthy: no route's failures exceed 5 % of its requests and no queue is older than 15 minutes.
    public var healthy: Bool
}

public actor ContentFreeHealthMonitor {
    private let started: Date
    private var routes: [String: HealthSnapshot.RouteStats] = [:]
    private var queueDepth: [String: Int] = [:]
    private var oldestQueued: [String: Double] = [:]
    private var refusedKeys = 0

    public nonisolated init(now: Date = Date()) { started = now }

    /// A key is a machine token: lowercase letters, digits, '.', '_' or '-', 1…40 characters. Anything else (spaces,
    /// '@', capitals, punctuation of prose) could be content and is refused.
    public nonisolated static func isMachineKey(_ key: String) -> Bool {
        guard (1...40).contains(key.count) else { return false }
        return key.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "." || $0 == "_" || $0 == "-" }
    }

    @discardableResult
    public func record(route: String, outcome: HealthOutcome, errorClass: HealthErrorClass? = nil, latencyMs: Double) -> Bool {
        guard Self.isMachineKey(route) else {
            refusedKeys += 1
            KalsmritikoshLog.app.notice("Health monitor: a non-machine route key was refused (not stored)")
            return false
        }
        var s = routes[route] ?? HealthSnapshot.RouteStats()
        s.count += 1
        s.outcomes[outcome.rawValue, default: 0] += 1
        if let e = errorClass { s.errorClasses[e.rawValue, default: 0] += 1 }
        let bucket = latencyMs < 50 ? "<50" : latencyMs < 250 ? "<250" : latencyMs < 1000 ? "<1000" : latencyMs < 5000 ? "<5000" : ">=5000"
        s.latencyBuckets[bucket, default: 0] += 1
        routes[route] = s
        return true
    }

    @discardableResult
    public func recordQueue(_ queue: String, depth: Int, oldestAgeSeconds: Double) -> Bool {
        guard Self.isMachineKey(queue) else { refusedKeys += 1; return false }
        queueDepth[queue] = max(0, depth)
        oldestQueued[queue] = max(0, oldestAgeSeconds)
        return true
    }

    public func snapshot(now: Date = Date()) -> HealthSnapshot {
        var usage = rusage()
        let ok = getrusage(RUSAGE_SELF, &usage) == 0
        let maxRSS = ok ? Int64(usage.ru_maxrss) : 0                       // bytes on macOS
        let cpu = ok ? Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000 : 0
        let failing = routes.values.contains { s in
            let bad = (s.outcomes[HealthOutcome.failed.rawValue] ?? 0)
            return s.count >= 20 && Double(bad) / Double(s.count) > 0.05
        }
        let stale = oldestQueued.values.contains { $0 > 15 * 60 }
        return HealthSnapshot(takenAt: now.timeIntervalSince1970, uptimeSeconds: now.timeIntervalSince(started), routes: routes,
                              queueDepth: queueDepth, oldestQueuedSeconds: oldestQueued, maxResidentBytes: maxRSS,
                              userCPUSeconds: cpu, refusedKeys: refusedKeys, healthy: !failing && !stale)
    }

    /// The snapshot as JSON for an operator (or the simulation's report).
    public func snapshotJSON(now: Date = Date()) -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .prettyPrinted]
        do { return try enc.encode(snapshot(now: now)) } catch {
            KalsmritikoshLog.app.error("Health monitor: snapshot encoding failed: \(error.localizedDescription, privacy: .public)")
            return Data()
        }
    }

    /// True when none of `forbidden` (names, e-mail addresses, passages known to the caller) appears in `json`.
    public nonisolated static func isContentFree(_ json: Data, forbidden: [String]) -> Bool {
        let text = String(decoding: json, as: UTF8.self).lowercased()
        return !forbidden.contains { !$0.isEmpty && text.contains($0.lowercased()) }
    }
}
