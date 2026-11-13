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

/// S16 (SEC-11) — what a saved diagnostic may hold. MetricKit's crash reports can carry an exception's COMPOSED MESSAGE
/// (an Objective-C exception's reason, which may quote a string the app was handling — a file name, a key, a passage),
/// its format arguments, and file paths under the person's home folder. Every payload is passed through here before it
/// is written, and every file already saved is passed through again before it is listed for sending: free-text message
/// fields are removed (their type and class are kept), home-folder paths lose everything after the folder name, and any
/// credential-shaped text is masked. A payload that cannot be read as JSON is replaced, never kept as it was.
nonisolated enum DiagnosticsSanitizer {
    static let removed = "[removed: may carry content]"
    /// Keys whose value is free text an exception or the system composed (never needed to diagnose a crash's location).
    /// (`exceptionReason` itself is walked: its class and exception name stay, its message, format and arguments go.)
    static let freeTextKeys: Set<String> = ["composedMessage", "formatString", "arguments", "reason",
                                            "message", "userInfo", "description", "debugDescription", "localizedDescription"]
    /// The marker that a file was cleaned by this build (so an older file is cleaned once).
    static let markerKey = "imeSanitized"

    static func sanitize(_ data: Data) -> Data {
        guard let any = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return Data(#"{"imeSanitized":1,"removed":"the payload could not be read, so it was not kept"}"#.utf8)
        }
        var clean = walk(any, key: nil)
        if var d = clean as? [String: Any] { d[markerKey] = 1; clean = d }
        guard JSONSerialization.isValidJSONObject(clean),
              let out = try? JSONSerialization.data(withJSONObject: clean, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return Data(#"{"imeSanitized":1,"removed":"the payload could not be cleaned, so it was not kept"}"#.utf8)
        }
        return out
    }

    static func walk(_ value: Any, key: String?) -> Any {
        if let k = key, freeTextKeys.contains(k), !(value is NSNumber) { return removed }
        switch value {
        case let d as [String: Any]:
            var out: [String: Any] = [:]
            for (k, v) in d { out[k] = walk(v, key: k) }
            return out
        case let a as [Any]:
            return a.map { walk($0, key: nil) }
        case let s as String:
            return clean(s)
        default:
            return value
        }
    }

    /// A string value: home-folder paths cut to the folder, credentials masked.
    static func clean(_ s: String) -> String {
        var t = SecretRedactor.redact(s)
        if let re = try? NSRegularExpression(pattern: #"(/Users|/private/var/folders|/var/folders)/[^\s"',;:]+"#) {
            t = re.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: "$1/[path removed]")
        }
        return t
    }

    static func isSanitized(_ data: Data) -> Bool {
        guard let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        return d[markerKey] != nil
    }
}

/// The on-disk folder of saved diagnostics. Pure file handling, no network.
nonisolated enum DiagnosticsStore {
    /// How many files are kept; older ones are removed when a new one is saved.
    static let keep = 30

    /// `~/Library/Application Support/Kalsmritikosh/Diagnostics/` (inside the sandbox container).
    static var folder: URL? {
        // S18 (QA-14): the test host's own folder, never the owner's diagnostics.
        TestHost.applicationSupport()?
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
            // S16 (SEC-11) — nothing is written as MetricKit delivered it: free-text messages, paths and credentials go first.
            try DiagnosticsSanitizer.sanitize(json).write(to: url, options: .atomic)
            prune(folder: folder, keep: keep)
            return url
        } catch {
            KalsmritikoshLog.app.error("Diagnostics: could not save \(kind, privacy: .public) payload: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// S16 (SEC-11) — clean every saved file that an earlier build wrote as delivered (run before the files are listed
    /// for sending and at launch). A file that cannot be cleaned is removed rather than offered.
    static func sanitizeExisting(in folder: URL? = folder) {
        for url in files(in: folder) {
            do {
                let data = try Data(contentsOf: url)
                if DiagnosticsSanitizer.isSanitized(data) { continue }
                try DiagnosticsSanitizer.sanitize(data).write(to: url, options: .atomic)
            } catch {
                KalsmritikoshLog.app.error("Diagnostics: a saved file could not be cleaned; removing it: \(String(describing: type(of: error)), privacy: .public)")
                do { try FileManager.default.removeItem(at: url) } catch {
                    KalsmritikoshLog.app.error("Diagnostics: an uncleanable file could not be removed: \(String(describing: type(of: error)), privacy: .public)")
                }
            }
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
        DiagnosticsStore.sanitizeExisting()
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
