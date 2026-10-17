//
//  ScaleRunRecorder.swift
//  Kalsmritikosh
//
//  W0-1 — evidence for the recorded scale run. While a large import runs, this
//  samples the process's physical memory footprint (`phys_footprint`, the same
//  figure Xcode's memory gauge and the system memory limit use — method from
//  mailin's ProcessFootprint) together with how many documents have been read,
//  and writes a CSV plus a plain summary: baseline, peak, the trend over the
//  second half of the run (flat or growing), and documents per minute. The
//  summary is worded to paste into SHIP_DECISIONS.md. Nothing is sent anywhere.
//

import Foundation
import os

nonisolated enum ProcessFootprint {
    /// Current physical footprint in bytes; 0 when the kernel call fails (reported, never guessed).
    static func bytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
    }
}

nonisolated struct ScaleSample: Sendable {
    let at: Date
    let footprint: UInt64
    let documents: Int
}

nonisolated enum ScaleRunSummary {
    static let mib = 1_048_576.0
    /// Below this, a per-hour slope extrapolates seconds of noise; the summary says so instead.
    static let minimumTrendMinutes = 10.0

    /// Least-squares slope of footprint (MiB per hour) over the second half of the samples.
    static func lateSlopeMiBPerHour(_ s: [ScaleSample]) -> Double? {
        let tail = Array(s.suffix(max(2, s.count / 2)))
        guard tail.count >= 2, let t0 = tail.first?.at else { return nil }
        let xs = tail.map { $0.at.timeIntervalSince(t0) / 3600 }
        let ys = tail.map { Double($0.footprint) / mib }
        let mx = xs.reduce(0, +) / Double(xs.count), my = ys.reduce(0, +) / Double(ys.count)
        let den = zip(xs, xs).map { ($0 - mx) * ($1 - mx) }.reduce(0, +)
        guard den > 0 else { return nil }
        return zip(xs, ys).map { ($0 - mx) * ($1 - my) }.reduce(0, +) / den
    }

    static func text(_ s: [ScaleSample], hardware: String) -> String {
        guard let first = s.first, let last = s.last, s.count >= 2 else { return "Not enough samples (need at least two)." }
        let peak = s.map(\.footprint).max() ?? 0
        let minutes = last.at.timeIntervalSince(first.at) / 60
        let docs = last.documents - first.documents
        let slope = lateSlopeMiBPerHour(s)
        // "Flat" = the second half grows by less than 5 % of the peak per hour. Falling memory
        // (caches released, pages returned) is not growth, so a negative slope counts as flat.
        let flat = slope.map { $0 < Double(peak) / mib * 0.05 } ?? false
        let interval = last.at.timeIntervalSince(first.at) / Double(s.count - 1)
        return """
        Scale run \(ISO8601DateFormatter().string(from: first.at)) on \(hardware):
        \(docs) documents read in \(String(format: "%.1f", minutes)) min (\(minutes > 0 ? String(format: "%.0f", Double(docs) / minutes) : "–") per min); \(last.documents) in the ledger at the end.
        Memory footprint: baseline \(String(format: "%.0f", Double(first.footprint) / mib)) MiB, peak \(String(format: "%.0f", Double(peak) / mib)) MiB, end \(String(format: "%.0f", Double(last.footprint) / mib)) MiB.
        Second-half trend: \(minutes < Self.minimumTrendMinutes
            ? "not judged — the run lasted under \(Int(Self.minimumTrendMinutes)) minutes, too short for an hourly trend"
            : (slope.map { String(format: "%+.0f MiB/hour", $0) } ?? "not measurable") + " — " + (flat ? "flat" : "NOT flat")).
        Samples: \(s.count) (every \(interval >= 1 ? String(format: "%.0f s", interval) : String(format: "%.2f s", interval)) on average).
        """
    }
}

@MainActor
@Observable
final class ScaleRunRecorder {
    static let shared = ScaleRunRecorder()
    private(set) var samples: [ScaleSample] = []
    private(set) var running = false
    private(set) var lastReport: URL?
    private var task: Task<Void, Never>?

    func start(appState: AppState) {
        guard !running else { return }
        samples = []; running = true
        task = Task { [weak self] in
            while !Task.isCancelled {
                let docs = await appState.ingestProgress().filesDone
                self?.samples.append(ScaleSample(at: Date(), footprint: ProcessFootprint.bytes(), documents: docs))
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    /// Stop and write `ScaleRuns/<time>.csv` + `.txt` under Application Support. Returns the summary.
    func stop() -> String {
        task?.cancel(); task = nil; running = false
        let hardware = Self.hardware()
        let summary = ScaleRunSummary.text(samples, hardware: hardware)
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Kalsmritikosh/ScaleRuns", isDirectory: true) else { return summary }
        do {
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let iso = ISO8601DateFormatter()
            let csv = "time,footprint_bytes,documents\n" + samples.map { "\(iso.string(from: $0.at)),\($0.footprint),\($0.documents)" }.joined(separator: "\n") + "\n"
            try Data(csv.utf8).write(to: base.appendingPathComponent("\(stamp).csv"))
            let txt = base.appendingPathComponent("\(stamp).txt")
            try Data(summary.utf8).write(to: txt)
            lastReport = txt
        } catch {
            KalsmritikoshLog.app.error("Scale run report failed: \(error.localizedDescription, privacy: .public)")
        }
        return summary
    }

    static func hardware() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &model, &size, nil, 0)
        let ram = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        let name = String(decoding: model.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return "\(name), \(String(format: "%.0f", ram)) GB RAM, \(ProcessInfo.processInfo.processorCount) cores, macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
    }
}
