//
//  RecorderClock.swift
//  Kalsmritikosh
//
//  ALCOA ALC-11/12 (owner 2026-11-24; DATA-22) — contemporaneous. The time a log row is recorded with: the recorder's
//  time zone (an IANA identifier) and where the wall clock came from. Custody events, case actions, AI runs and access
//  events written from schema v216/v217 on carry both (older rows: not recorded).
//
//  Each app session pairs the wall clock with the Mac's monotonic clock (CLOCK_MONOTONIC keeps counting through sleep
//  and is never set). The ClockMonitor compares the two at every check: when the wall clock has moved more than two
//  minutes against the monotonic clock since the last check (someone set the clock, a time-zone-less reset, a dead
//  battery), it writes a "clock jump" event (clock_events, sealed in the audit chain), marks this session's rows
//  "system (clock jump this session)" and the data health check names it.
//

import Foundation
import os

public nonisolated enum RecorderClock {

    /// This Mac's system clock (set by macOS; network time when the person allows it in System Settings).
    public static let systemSource = "system"
    /// The clock source once a jump was seen in this session.
    public static let jumpedSource = "system (clock jump this session)"
    /// A wall-clock move against the monotonic clock larger than this is a jump.
    public static let jumpThreshold: TimeInterval = 120

    public struct Stamp: Sendable, Equatable {
        public let timeZone: String
        public let clockSource: String
    }

    private static let jumped = OSAllocatedUnfairLock(initialState: false)

    /// Whether a clock jump was seen in this app session.
    public static var jumpedThisSession: Bool { jumped.withLock { $0 } }
    static func noteJump() { jumped.withLock { $0 = true } }
    static func resetForTesting() { jumped.withLock { $0 = false } }

    /// The stamp for a row recorded now.
    public static func stamp() -> Stamp {
        Stamp(timeZone: TimeZone.current.identifier, clockSource: jumpedThisSession ? jumpedSource : systemSource)
    }

    /// Seconds on the monotonic clock (continues through sleep; never set by anyone).
    public static func monotonic() -> TimeInterval {
        TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000
    }

    /// The extra columns and values for an INSERT into `table` when it has `recorded_tz` (schema v217 on); else nothing.
    static func columns(_ db: isolated Database, table: String) throws -> (names: String, marks: String, binds: [SQLValue]) {
        guard !(try db.query("SELECT 1 FROM pragma_table_info(?) WHERE name = 'recorded_tz';", [.text(table)]).isEmpty) else { return ("", "", []) }
        let s = stamp()
        return (", recorded_tz, clock_source", ",?,?", [.text(s.timeZone), .text(s.clockSource)])
    }

    static func columns(_ database: Database, table: String) async throws -> (names: String, marks: String, binds: [SQLValue]) {
        guard !(try await database.query("SELECT 1 FROM pragma_table_info(?) WHERE name = 'recorded_tz';", [.text(table)]).isEmpty) else { return ("", "", []) }
        let s = stamp()
        return (", recorded_tz, clock_source", ",?,?", [.text(s.timeZone), .text(s.clockSource)])
    }

    // MARK: - Pairing

    /// Wall time paired with monotonic time at one moment.
    public struct Pairing: Sendable, Equatable {
        public let wall: Date
        public let monotonic: TimeInterval
        /// The wall time this pairing predicts for a later monotonic reading.
        public func expectedWall(atMonotonic m: TimeInterval) -> Date { wall.addingTimeInterval(m - monotonic) }
    }

    /// The jump between two pairings: how far the wall clock moved beyond the monotonic clock (positive: forward).
    public static func drift(from a: Pairing, to b: Pairing) -> TimeInterval {
        b.wall.timeIntervalSince(a.expectedWall(atMonotonic: b.monotonic))
    }
}

/// ALCOA ALC-12 — one app session's clock: its pairing, written once (clock_sessions), and a check that records jumps.
public actor ClockMonitor {
    public struct Jump: Sendable, Equatable {
        public let id: UUID
        public let expected: Date
        public let observed: Date
        public let delta: TimeInterval
    }

    private let database: Database
    private let wall: @Sendable () -> Date
    private let mono: @Sendable () -> TimeInterval
    public let sessionID = UUID()
    private var last: RecorderClock.Pairing?
    public private(set) var jumps: [Jump] = []

    public init(database: Database, wall: @escaping @Sendable () -> Date = { Date() },
                monotonic: @escaping @Sendable () -> TimeInterval = { RecorderClock.monotonic() }) {
        self.database = database
        self.wall = wall
        self.mono = monotonic
    }

    /// Record this session's pairing (once).
    public func start() async {
        guard last == nil else { return }
        let p = RecorderClock.Pairing(wall: wall(), monotonic: mono())
        last = p
        do {
            guard try await Self.available(database) else { return }
            try await database.exec("""
                INSERT OR IGNORE INTO clock_sessions (id, started_at, started_monotonic, recorded_tz, app_build) VALUES (?,?,?,?,?);
                """, [.uuid(sessionID), .date(p.wall), .real(p.monotonic), .text(TimeZone.current.identifier),
                      .optionalText(Bundle.main.infoDictionary?["CFBundleVersion"] as? String)])
        } catch {
            KalsmritikoshLog.app.error("Clock session not recorded: \(error.localizedDescription, privacy: .private)")
        }
    }

    /// Compare the wall clock with the monotonic clock since the last check; a move over two minutes is a jump.
    @discardableResult
    public func check() async -> Jump? {
        if last == nil { await start() }
        guard let previous = last else { return nil }
        let now = RecorderClock.Pairing(wall: wall(), monotonic: mono())
        last = now
        let delta = RecorderClock.drift(from: previous, to: now)
        guard abs(delta) > RecorderClock.jumpThreshold else { return nil }
        let jump = Jump(id: UUID(), expected: previous.expectedWall(atMonotonic: now.monotonic), observed: now.wall, delta: delta)
        jumps.append(jump)
        RecorderClock.noteJump()
        KalsmritikoshLog.app.notice("Clock jump of \(Int(delta), privacy: .public) s against the monotonic clock")
        do {
            if try await Self.available(database) {
                try await database.exec("""
                    INSERT INTO clock_events (id, session_id, kind, expected_at, observed_at, delta_seconds, recorded_tz) VALUES (?,?,'jump',?,?,?,?);
                    """, [.uuid(jump.id), .uuid(sessionID), .date(jump.expected), .date(jump.observed), .real(delta), .text(TimeZone.current.identifier)])
            }
        } catch {
            KalsmritikoshLog.app.error("Clock jump not recorded: \(error.localizedDescription, privacy: .private)")
        }
        return jump
    }

    static func available(_ db: Database) async throws -> Bool {
        !(try await db.query("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'clock_events';", []).isEmpty)
    }

    /// The health-check line for this session.
    public func healthLine() -> String {
        guard !jumps.isEmpty else {
            return "Clock: no jump over \(Int(RecorderClock.jumpThreshold / 60)) minutes against the monotonic clock this session (zone \(TimeZone.current.identifier))."
        }
        let biggest = jumps.map(\.delta).max { abs($0) < abs($1) } ?? 0
        return "Clock: \(jumps.count) jump\(jumps.count == 1 ? "" : "s") this session (largest \(Int(biggest)) s). Times recorded since are marked “\(RecorderClock.jumpedSource)”; check this Mac's date and time settings."
    }

    /// Sealed events of every recorded clock jump.
    public static func auditChainEvents(_ database: Database) async throws -> [AuditChainEvent] {
        guard try await available(database) else { return [] }
        return try await database.query("SELECT id, session_id, expected_at, observed_at, delta_seconds, recorded_tz FROM clock_events;", []).compactMap { r in
            guard let id = r.uuid(0), let s = r.string(1), let e = r.date(2), let o = r.date(3), let d = r.double(4), let tz = r.string(5) else { return nil }
            return AuditChainEvent(source: .clockEvent, eventID: id, occurredAt: o,
                                   canonicalPayload: "delta=\(d);expected=\(e.timeIntervalSince1970);kind=jump;observed=\(o.timeIntervalSince1970);session=\(s.lowercased());tz=\(tz)")
        }
    }
}
