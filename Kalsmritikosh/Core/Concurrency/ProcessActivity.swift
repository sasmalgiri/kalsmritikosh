//
//  ProcessActivity.swift
//  Kalsmritikosh
//
//  One unit of user-visible background work — so every long-running task shows
//  WHAT is running, WHEN it started, how far along it is, and an ETA. AppState
//  publishes the live list; the live panel + dashboard render it. Determinate
//  work carries unitsDone/unitsTotal (→ % + ETA); indeterminate work shows just
//  elapsed time.
//

import Foundation

public struct ProcessActivity: Identifiable, Sendable, Hashable {
    public let id: UUID
    public let title: String          // e.g. "Rebuilding legal milestones"
    public let startedAt: Date
    public var unitsDone: Int
    public var unitsTotal: Int?       // nil = indeterminate
    public var finishedAt: Date?

    public init(
        id: UUID = UUID(), title: String, startedAt: Date = Date(),
        unitsDone: Int = 0, unitsTotal: Int? = nil, finishedAt: Date? = nil
    ) {
        self.id = id; self.title = title; self.startedAt = startedAt
        self.unitsDone = unitsDone; self.unitsTotal = unitsTotal; self.finishedAt = finishedAt
    }

    public var isRunning: Bool { finishedAt == nil }
    public var isDeterminate: Bool { (unitsTotal ?? 0) > 0 }

    public func elapsed(now: Date = Date()) -> TimeInterval {
        (finishedAt ?? now).timeIntervalSince(startedAt)
    }

    /// 0…1 for determinate work; nil when the total is unknown.
    public var fraction: Double? {
        guard let total = unitsTotal, total > 0 else { return nil }
        return min(1.0, max(0.0, Double(unitsDone) / Double(total)))
    }

    /// Estimated seconds remaining, from the rate so far. nil until there's
    /// enough signal (>2% done) or when indeterminate/finished.
    public func etaSeconds(now: Date = Date()) -> TimeInterval? {
        guard finishedAt == nil, let f = fraction, f > 0.02 else { return nil }
        let e = elapsed(now: now)
        return max(0, e / f - e)
    }

    /// Compact human status: "312/580 · ~0:42 left" or "running 0:12".
    public func statusLine(now: Date = Date()) -> String {
        if let fin = finishedAt {
            return "done in \(Self.mmss(fin.timeIntervalSince(startedAt)))"
        }
        if let total = unitsTotal, total > 0 {
            let eta = etaSeconds(now: now).map { " · ~\(Self.mmss($0)) left" } ?? ""
            return "\(unitsDone)/\(total)\(eta)"
        }
        return "running \(Self.mmss(elapsed(now: now)))"
    }

    static func mmss(_ s: TimeInterval) -> String {
        let t = Int(s.rounded())
        return t >= 3600
            ? String(format: "%d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60)
            : String(format: "%d:%02d", t / 60, t % 60)
    }
}
