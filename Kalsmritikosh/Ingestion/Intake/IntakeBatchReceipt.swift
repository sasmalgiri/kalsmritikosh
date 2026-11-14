//
//  IntakeBatchReceipt.swift
//  Kalsmritikosh
//
//  Smart-map IN-12 / IN-01 (docs/IME_Full_Smart_Map_Implementation_TODO_2026-11-08.md §04) — the receipt of one intake
//  batch. A batch is the durable ingest run (PI.3, `ingest_runs` / `ingest_run_files`): every file the run selected has a
//  row before it is read. Schema v178 adds what happened to each one — received (a new document or a new version),
//  already held (unchanged, or moved), an exact duplicate of another document (same bytes elsewhere), failed or timed
//  out — with the source version it became and the channel it came through. The receipt reconciles those against what
//  was selected, so the files a run could not take in stay counted and named instead of disappearing behind a success
//  count. `IngestFailureLog` remains the in-memory banner of the current run; this is the record.
//
//  Channels (IN-01): every way an item reaches the app has one name. A team submission channel is NOT here: it needs an
//  authenticated multi-user identity and a shared submission service, which this build does not have (blocker recorded
//  in the completion matrix).
//
//  Formats die at ingestion: nothing here looks at a file's type.
//

import Foundation
import os

/// The way an item reached the archive or a case. The raw values mirror the v178 CHECKs.
public nonisolated enum IntakeChannel: String, Sendable, Codable, CaseIterable, Hashable {
    /// A document in the case's workspace whose original channel is not recorded (taken in before v178, or inside another).
    case workspace
    /// A registered folder read (again) by "Read all" or after it was added.
    case folderImport
    /// A file or folder chosen with the picker (Add sources).
    case fileImport
    /// Files or folders dropped on the window.
    case dragDrop
    /// An item shared to the app from another app (the Share menu).
    case shareInbox
    /// The Capture window or the Services menu.
    case capture
    /// An import from an iPhone or iPad (Continuity Camera).
    case deviceImport
    /// An entry typed into the case by a person.
    case manualEntry
    /// A message typed or pasted into the case (a call note, a text a witness sent).
    case message

    /// Whether the channel carries a typed entry rather than a document.
    public var isTyped: Bool { self == .manualEntry || self == .message }

    public var label: String {
        switch self {
        case .workspace: return "In the case's workspace"
        case .folderImport: return "Folder read"
        case .fileImport: return "Chosen in Add sources"
        case .dragDrop: return "Dropped on the window"
        case .shareInbox: return "Shared from another app"
        case .capture: return "Capture window or Services menu"
        case .deviceImport: return "Imported from iPhone or iPad"
        case .manualEntry: return "Typed into the case"
        case .message: return "Message entered into the case"
        }
    }
}

/// Which files of an ingest run came through which channel. A run reads every registered folder, so only the files the
/// trigger brought (exact files, or anything under the given roots) carry its channel; every other file is a folder re-read.
public nonisolated struct IntakeArrivalHint: Sendable, Equatable {
    public let channel: IntakeChannel
    public let files: Set<String>
    public let roots: [String]

    public init(channel: IntakeChannel, files: [URL] = [], roots: [URL] = []) {
        self.channel = channel
        self.files = Set(files.map { $0.standardizedFileURL.path })
        self.roots = roots.map { $0.standardizedFileURL.path }
    }

    /// A plain re-read of the registered folders.
    public static let folderReread = IntakeArrivalHint(channel: .folderImport)

    public func channel(for url: URL) -> IntakeChannel {
        let path = url.standardizedFileURL.path
        if files.contains(path) { return channel }
        if roots.contains(where: { path == $0 || path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }) { return channel }
        return .folderImport
    }
}

/// What happened to one selected file in a batch. Mirrors the v178 CHECK on `ingest_run_files.outcome`.
public nonisolated enum IntakeItemOutcome: String, Sendable, Codable, CaseIterable, Hashable {
    /// A new document, or a new version of one already held.
    case received
    /// Already held with these exact bytes (unchanged, or the same file at a new path).
    case alreadyHeld
    /// The exact bytes of another document already held, at another location (kept as an occurrence, not a new document).
    case duplicate
    case failed
    case timedOut

    public static func from(_ outcome: SourceIntakeOutcome) -> IntakeItemOutcome {
        switch outcome {
        case .newLogicalSource, .newVersion: return .received
        case .unchanged, .moved: return .alreadyHeld
        case .aliased: return .duplicate
        }
    }
}

/// One selected file of a batch, as recorded.
public nonisolated struct IntakeBatchLine: Sendable, Equatable, Hashable {
    public let path: String
    public var name: String { (path as NSString).lastPathComponent }
    /// The run's own file state (pending / running / done / failed).
    public let state: String
    /// Nil while the file has not been settled (still running, or the run was interrupted on it).
    public let outcome: IntakeItemOutcome?
    public let channel: IntakeChannel?
    public let sourceVersionID: UUID?
    public let intakeOutcome: SourceIntakeOutcome?
    public let error: String?
}

/// The reconciled receipt of one batch: every selected file is in exactly one bucket.
public nonisolated struct IntakeBatchReceipt: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let channel: IntakeChannel?
    public let startedAt: Date
    public let status: String
    /// Files the run planned to read (its scan count); some may not have been reached if it was stopped.
    public let planned: Int
    public let lines: [IntakeBatchLine]

    public var selected: Int { lines.count }
    public var received: Int { lines.filter { $0.outcome == .received }.count }
    public var alreadyHeld: Int { lines.filter { $0.outcome == .alreadyHeld }.count }
    public var duplicates: Int { lines.filter { $0.outcome == .duplicate }.count }
    public var failed: Int { lines.filter { $0.outcome == .failed || ($0.outcome == nil && $0.state == "failed") }.count }
    public var timedOut: Int { lines.filter { $0.outcome == .timedOut }.count }
    /// Selected but not settled: still being read, or the run stopped on it (resumable).
    public var pending: Int { lines.filter { $0.outcome == nil && $0.state != "failed" }.count }
    /// Planned but never selected (the run was stopped before reaching them).
    public var notReached: Int { max(0, planned - selected) }
    /// Every selected file is accounted for exactly once.
    public var reconciles: Bool { received + alreadyHeld + duplicates + failed + timedOut + pending == selected }
    /// The files that could not be taken in, by name, with why.
    public var failures: [(name: String, reason: String)] {
        lines.filter { $0.outcome == .failed || $0.outcome == .timedOut || ($0.outcome == nil && $0.state == "failed") }
            .map { ($0.name, $0.outcome == .timedOut ? "took longer than the time allowed" : ($0.error ?? "could not be read")) }
    }

    public var summaryLine: String {
        var s = "Selected \(selected): received \(received), already held \(alreadyHeld), duplicates \(duplicates), failed \(failed + timedOut)"
        if pending > 0 { s += ", not finished \(pending)" }
        if notReached > 0 { s += ", not reached \(notReached)" }
        return s
    }
}

/// Writes and reads the per-file outcome of an ingest run (v178 columns). Writes never throw into the ingest loop: a
/// receipt that cannot be written is logged and the file's ingest is unaffected.
public actor IntakeReceiptRepository {
    private let database: Database
    public init(database: Database) { self.database = database }

    /// The channel that triggered the run.
    public func setChannel(run: UUID, channel: IntakeChannel) async {
        do {
            try await database.exec("UPDATE ingest_runs SET channel = ? WHERE id = ?;", [.text(channel.rawValue), .uuid(run)])
        } catch {
            KalsmritikoshLog.ingestion.error("Intake receipt: channel not recorded: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Record a settled file (after the run's own `setFileState`, so the line exists).
    public func recordReceived(run: UUID, path: String, channel: IntakeChannel, sourceVersionID: UUID?, intakeOutcome: SourceIntakeOutcome?) async {
        // A file read without an intake outcome (an older pipeline path) is received; a version without an outcome cannot be classed.
        let outcome = intakeOutcome.map(IntakeItemOutcome.from) ?? .received
        await settle(run: run, path: path, channel: channel, outcome: outcome, sourceVersionID: sourceVersionID, intakeOutcome: intakeOutcome)
    }

    public func recordFailed(run: UUID, path: String, channel: IntakeChannel, timedOut: Bool) async {
        await settle(run: run, path: path, channel: channel, outcome: timedOut ? .timedOut : .failed, sourceVersionID: nil, intakeOutcome: nil)
    }

    /// A file of an interrupted run read again on a later launch: its outcome, keeping the channel recorded for it.
    public func recordResumed(run: UUID, path: String, sourceVersionID: UUID?, intakeOutcome: SourceIntakeOutcome?) async {
        await settle(run: run, path: path, channel: nil, outcome: intakeOutcome.map(IntakeItemOutcome.from) ?? .received,
                     sourceVersionID: sourceVersionID, intakeOutcome: intakeOutcome)
    }

    public func recordResumeFailed(run: UUID, path: String) async {
        await settle(run: run, path: path, channel: nil, outcome: .failed, sourceVersionID: nil, intakeOutcome: nil)
    }

    /// `channel` nil keeps the one already recorded for the line (a folder re-read when none was).
    private func settle(run: UUID, path: String, channel: IntakeChannel?, outcome: IntakeItemOutcome,
                        sourceVersionID: UUID?, intakeOutcome: SourceIntakeOutcome?) async {
        do {
            try await database.exec("""
                UPDATE ingest_run_files SET outcome = ?, channel = coalesce(?, channel, 'folderImport'), source_version_id = ?, intake_outcome = ?
                WHERE run_id = ? AND path_hash = ?;
                """, [.text(outcome.rawValue), channel.map { SQLValue.text($0.rawValue) } ?? .null, sourceVersionID.map { SQLValue.uuid($0) } ?? .null,
                      intakeOutcome.map { SQLValue.text($0.rawValue) } ?? .null,
                      .uuid(run), .text(IngestRunRepository.pathHash(path))])
        } catch {
            KalsmritikoshLog.ingestion.error("Intake receipt: outcome not recorded: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The reconciled receipt of one run (nil when there is no such run).
    public func receipt(run: UUID) async throws -> IntakeBatchReceipt? {
        guard let head = try await database.query("SELECT status, total_files, started_at, channel FROM ingest_runs WHERE id = ?;", [.uuid(run)]).first else {
            return nil
        }
        let lines = try await database.query("""
            SELECT path, state, outcome, channel, source_version_id, intake_outcome, error FROM ingest_run_files WHERE run_id = ? ORDER BY path;
            """, [.uuid(run)]).compactMap { r -> IntakeBatchLine? in
            guard let path = r.string(0), let state = r.string(1) else { return nil }
            return IntakeBatchLine(path: path, state: state, outcome: r.string(2).flatMap(IntakeItemOutcome.init(rawValue:)),
                                   channel: r.string(3).flatMap(IntakeChannel.init(rawValue:)), sourceVersionID: r.uuid(4),
                                   intakeOutcome: r.string(5).flatMap(SourceIntakeOutcome.init(rawValue:)), error: r.string(6))
        }
        // ingest_runs stores milliseconds (IngestRunRepository).
        return IntakeBatchReceipt(id: run, channel: head.string(3).flatMap(IntakeChannel.init(rawValue:)),
                                  startedAt: Date(timeIntervalSince1970: (head.double(2) ?? 0) / 1000),
                                  status: head.string(0) ?? "unknown", planned: Int(head.int(1) ?? 0), lines: lines)
    }

    /// The most recent runs, newest first.
    public func recentRuns(limit: Int = 20) async throws -> [UUID] {
        try await database.query("SELECT id FROM ingest_runs ORDER BY started_at DESC LIMIT ?;", [.integer(Int64(max(1, limit)))]).compactMap { $0.uuid(0) }
    }

    /// How each version first ARRIVED (the run that received it as a new document or version): version → (run, channel, when).
    public func arrivals(of versions: Set<UUID>) async throws -> [UUID: IntakeArrival] {
        guard !versions.isEmpty else { return [:] }
        var out: [UUID: IntakeArrival] = [:]
        let ids = Array(versions)
        for start in stride(from: 0, to: ids.count, by: 400) {
            let chunk = Array(ids[start..<min(start + 400, ids.count)])
            let rows = try await database.query("""
                SELECT f.source_version_id, f.run_id, f.channel, f.updated_at FROM ingest_run_files f
                WHERE f.outcome = 'received' AND f.source_version_id IN (\(chunk.map { _ in "?" }.joined(separator: ",")))
                ORDER BY f.updated_at ASC;
                """, chunk.map { .uuid($0) })
            for r in rows {
                guard let v = r.uuid(0), let run = r.uuid(1), out[v] == nil else { continue }
                out[v] = IntakeArrival(sourceVersionID: v, channel: r.string(2).flatMap(IntakeChannel.init(rawValue:)) ?? .folderImport,
                                       runID: run, at: Date(timeIntervalSince1970: (r.double(3) ?? 0) / 1000))
            }
        }
        return out
    }

    /// Every run that settled one of these versions (received, already held or duplicate) — the batches a case's documents
    /// can be traced to. version → run ids, oldest first.
    public func runs(settling versions: Set<UUID>) async throws -> [UUID: [UUID]] {
        guard !versions.isEmpty else { return [:] }
        var out: [UUID: [UUID]] = [:]
        let ids = Array(versions)
        for start in stride(from: 0, to: ids.count, by: 400) {
            let chunk = Array(ids[start..<min(start + 400, ids.count)])
            let rows = try await database.query("""
                SELECT source_version_id, run_id FROM ingest_run_files
                WHERE outcome IN ('received','alreadyHeld','duplicate') AND source_version_id IN (\(chunk.map { _ in "?" }.joined(separator: ",")))
                ORDER BY updated_at ASC;
                """, chunk.map { .uuid($0) })
            for r in rows {
                guard let v = r.uuid(0), let run = r.uuid(1) else { continue }
                if !(out[v]?.contains(run) ?? false) { out[v, default: []].append(run) }
            }
        }
        return out
    }

    /// Versions that ARRIVED (were received as a new document or version) through one of `channels`, at or after `since`,
    /// and are still the current version of their document. Newest first. The Share inbox, capture and device imports feed
    /// a case's review through this; a channel-arrival policy reads it too.
    public func channelArrivals(channels: Set<IntakeChannel>, since: Date?) async throws -> [IntakeArrival] {
        guard !channels.isEmpty else { return [] }
        let list = Array(channels).map(\.rawValue).sorted()
        let rows = try await database.query("""
            SELECT f.source_version_id, f.channel, f.run_id, MIN(f.updated_at) AS first_at FROM ingest_run_files f
            JOIN source_versions sv ON sv.id = f.source_version_id AND sv.is_current = 1
            WHERE f.outcome = 'received' AND f.channel IN (\(list.map { _ in "?" }.joined(separator: ",")))
            GROUP BY f.source_version_id HAVING first_at >= ? ORDER BY first_at DESC;
            """, list.map { .text($0) } + [.real((since?.timeIntervalSince1970 ?? 0) * 1000)])
        return rows.compactMap { r in
            guard let v = r.uuid(0), let c = r.string(1).flatMap(IntakeChannel.init(rawValue:)), let run = r.uuid(2) else { return nil }
            return IntakeArrival(sourceVersionID: v, channel: c, runID: run, at: Date(timeIntervalSince1970: (r.double(3) ?? 0) / 1000))
        }
    }

    /// The capture-type channels: items sent to the app itself rather than read from a folder.
    public nonisolated static let capturedChannels: Set<IntakeChannel> = [.shareInbox, .capture, .deviceImport]
}

/// A document version as it arrived: through which channel, in which batch, when.
public nonisolated struct IntakeArrival: Sendable, Equatable, Hashable {
    public let sourceVersionID: UUID
    public let channel: IntakeChannel
    public let runID: UUID
    public let at: Date
}
