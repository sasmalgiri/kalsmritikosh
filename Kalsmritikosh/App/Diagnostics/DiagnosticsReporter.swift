//
//  DiagnosticsReporter.swift
//  Kalsmritikosh
//
//  U-4 — crash & hang diagnostics, ON DEVICE. The system (MetricKit) hands the app
//  reports about its own crashes, hangs, CPU and disk-write exceptions, plus a daily
//  timing/energy summary. They are saved as JSON files in the app's own Application
//  Support folder under Diagnostics/ (the newest `keep` are kept) and NOTHING is sent.
//  The only way a file leaves the Mac is the person pressing "Send diagnostics…",
//  seeing the list of files, and choosing to email them from their own Mail app.
//
//  What is in the files: app timing, memory/CPU/disk counters, call stacks of the app's
//  own code at a crash or hang, device model and OS/app versions. Nothing about the
//  person's documents, questions or ledger is ever written here — MetricKit has no
//  access to them, and this file adds nothing of its own to the payloads.
//

import Foundation
import MetricKit
import os

/// The on-disk folder of saved diagnostics. Pure file handling, no network.
nonisolated enum DiagnosticsStore {
    /// How many files are kept; older ones are removed when a new one is saved.
    static let keep = 30

    /// `~/Library/Application Support/Kalsmritikosh/Diagnostics/` (inside the sandbox container).
    static var folder: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Kalsmritikosh", isDirectory: true)
            .appendingPathComponent("Diagnostics", isDirectory: true)
    }

    /// File-name stamp that sorts in time order (UTC), e.g. `20261023-141502-123`.
    static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return f.string(from: date)
    }

    /// Save one payload as `<stamp>-<kind>-<short id>.json`, then prune to `keep`.
    @discardableResult
    static func save(_ json: Data, kind: String, date: Date, in folder: URL? = folder, keep: Int = keep) -> URL? {
        guard let folder else {
            KalsmritikoshLog.app.error("Diagnostics: no Application Support folder; payload not saved")
            return nil
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let id = UUID().uuidString.prefix(8)
            let url = folder.appendingPathComponent("\(stamp(date))-\(kind)-\(id).json")
            try json.write(to: url, options: .atomic)
            prune(folder: folder, keep: keep)
            return url
        } catch {
            KalsmritikoshLog.app.error("Diagnostics: could not save \(kind, privacy: .public) payload: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// The saved files, newest first (names start with a sortable time stamp).
    static func files(in folder: URL? = folder) -> [URL] {
        guard let folder else { return [] }
        let all: [URL]
        do {
            all = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil,
                                                              options: [.skipsHiddenFiles])
        } catch {
            // A missing folder simply means nothing has been saved yet.
            if (error as NSError).code != NSFileReadNoSuchFileError {
                KalsmritikoshLog.app.error("Diagnostics: could not list the folder: \(error.localizedDescription, privacy: .public)")
            }
            return []
        }
        return all.filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// Remove all but the newest `keep` files.
    static func prune(folder: URL, keep: Int) {
        for old in files(in: folder).dropFirst(max(0, keep)) {
            do { try FileManager.default.removeItem(at: old) } catch {
                KalsmritikoshLog.app.error("Diagnostics: could not remove an old file: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Size in bytes, for the preview list.
    static func size(of url: URL) -> Int {
        do { return try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 } catch {
            KalsmritikoshLog.app.error("Diagnostics: could not read a file size: \(error.localizedDescription, privacy: .public)")
            return 0
        }
    }
}

/// Receives MetricKit payloads and saves them. Registered once at app launch.
nonisolated final class DiagnosticsReporter: NSObject, MXMetricManagerSubscriber, Sendable {
    static let shared = DiagnosticsReporter()

    private let started = OSAllocatedUnfairLock(initialState: false)

    /// Subscribe to MetricKit. Safe to call more than once.
    func start() {
        let first = started.withLock { s -> Bool in
            defer { s = true }
            return !s
        }
        guard first else { return }
        MXMetricManager.shared.add(self)
        // Payloads delivered while the app was not running are also handed over here.
        let pending = MXMetricManager.shared.pastDiagnosticPayloads
        if !pending.isEmpty { save(diagnostics: pending) }
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        for p in payloads {
            DiagnosticsStore.save(p.jsonRepresentation(), kind: "metrics", date: p.timeStampEnd)
        }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        save(diagnostics: payloads)
    }

    private func save(diagnostics payloads: [MXDiagnosticPayload]) {
        for p in payloads {
            DiagnosticsStore.save(p.jsonRepresentation(), kind: Self.kind(of: p), date: p.timeStampEnd)
        }
    }

    /// A short label for the file name: what the payload mainly reports.
    private static func kind(of p: MXDiagnosticPayload) -> String {
        if !(p.crashDiagnostics ?? []).isEmpty { return "crash" }
        if !(p.hangDiagnostics ?? []).isEmpty { return "hang" }
        if !(p.cpuExceptionDiagnostics ?? []).isEmpty { return "cpu" }
        if !(p.diskWriteExceptionDiagnostics ?? []).isEmpty { return "diskwrite" }
        return "diagnostic"
    }
}
