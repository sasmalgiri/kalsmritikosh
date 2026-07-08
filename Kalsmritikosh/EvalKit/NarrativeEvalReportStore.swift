//
//  NarrativeEvalReportStore.swift
//  Kalsmritikosh
//
//  HISTORY Phase F.4 — persistence + history for NarrativeEvalKit
//  reports so a developer can diff "did the numbers move" between
//  runs without piping markdown to a file by hand.
//
//  Reports are written as one JSON file per run under:
//      Application Support/Kalsmritikosh/eval/narrative/<iso8601>.json
//
//  The directory is created lazily; failures are non-fatal — the
//  report still prints to stdout via SmokeTest's existing path. The
//  dashboard view (see UI/EvalDashboardView.swift) reads the
//  directory and renders the rows in reverse-chronological order
//  with delta arrows against the previous run.
//

import Foundation
import OSLog

public actor NarrativeEvalReportStore {
    public static let shared = NarrativeEvalReportStore()

    private let directory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init() {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        self.directory = base
            .appendingPathComponent("Kalsmritikosh", isDirectory: true)
            .appendingPathComponent("eval", isDirectory: true)
            .appendingPathComponent("narrative", isDirectory: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        self.encoder = enc
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        self.decoder = dec
    }

    public func save(_ report: NarrativeEvalKit.Report) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let stamp = formatter.string(from: report.timestamp)
            .replacingOccurrences(of: ":", with: "-")
        let url = directory.appendingPathComponent("\(stamp).json")
        let data = try encoder.encode(report)
        try data.write(to: url, options: .atomic)
        KalsmritikoshLog.app.info("NarrativeEval: saved report \(url.lastPathComponent, privacy: .public)")
    }

    /// Most-recent-first list, capped so the dashboard's table stays
    /// manageable even after months of eval runs.
    public func loadRecent(limit: Int = 20) -> [NarrativeEvalKit.Report] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return [] }
        let sorted = entries.sorted { lhs, rhs in
            let lDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            let rDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            return lDate > rDate
        }
        return sorted.prefix(limit).compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let report = try? decoder.decode(NarrativeEvalKit.Report.self, from: data)
            else { return nil }
            return report
        }
    }

    public func directoryURL() -> URL { directory }
}
