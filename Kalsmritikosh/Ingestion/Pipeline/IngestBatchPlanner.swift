//
//  IngestBatchPlanner.swift
//  Kalsmritikosh
//
//  Unified-path program (owner, 2026-11-22), PERF-15 — packs the files of the chosen folders into
//  batches that each fit one import worker's memory share (`WorkerBudget.bytesPerWorker`). Folders are
//  walked exactly as the folder import walks them (`AppState.enumerateAndIngest`: regular files, hidden
//  files and package contents skipped). Files are packed largest first (first-fit decreasing) by byte
//  size, with a cap on the number of files per batch so a folder of many small files still spreads over
//  the workers. A file larger than one share (a big mailbox, PDF or archive) gets a batch of its own.
//
//  Remaining limit: one file is never split into page or record ranges here — no loader accepts an
//  outside page/record range today. A very large mailbox or archive is held to bounded memory by the
//  coordinator's own streaming path (IngestMemoryBudget / resumable stream cursors), not by the planner.
//
//  Not tested yet (owner 2026-11-22: implement now, test later).
//

import Foundation
import os

/// One planned file.
public nonisolated struct IngestPlannedFile: Sendable, Hashable {
    public let url: URL
    public let bytes: UInt64
    public init(url: URL, bytes: UInt64) { self.url = url; self.bytes = bytes }
}

/// One worker's batch.
public nonisolated struct IngestBatch: Sendable {
    public var files: [IngestPlannedFile] = []
    public var bytes: UInt64 = 0
    /// True when the batch holds one file larger than a whole share.
    public var oversized = false
    public init() {}
}

public nonisolated struct IngestBatchPlan: Sendable {
    public let batches: [IngestBatch]
    public let bytesPerBatch: UInt64
    public let workers: Int
    public var fileCount: Int { batches.reduce(0) { $0 + $1.files.count } }
    public var totalBytes: UInt64 { batches.reduce(0) { $0 + $1.bytes } }
}

public nonisolated enum IngestBatchPlanner {
    /// The most files one batch takes, whatever their size.
    public static let maxFilesPerBatch = 1_500
    /// The smallest share a batch is cut to, so a squeezed Mac does not plan thousands of tiny batches.
    public static let minimumBytesPerBatch: UInt64 = 64 * 1_048_576

    /// Every regular file under `roots` (files given directly are taken as they are), walked as the
    /// folder import walks them.
    public static func enumerate(_ roots: [URL]) -> [IngestPlannedFile] {
        var out: [IngestPlannedFile] = []
        var seen = Set<String>()
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .isDirectoryKey]
        for root in roots {
            let values = try? root.resourceValues(forKeys: Set(keys))
            if values?.isRegularFile == true {
                if seen.insert(root.standardizedFileURL.path).inserted {
                    out.append(IngestPlannedFile(url: root, bytes: UInt64(max(0, values?.fileSize ?? 0))))
                }
                continue
            }
            let walker = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants])
            while let next = walker?.nextObject() as? URL {
                guard let v = try? next.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                      v.isRegularFile == true else { continue }
                guard seen.insert(next.standardizedFileURL.path).inserted else { continue }
                out.append(IngestPlannedFile(url: next, bytes: UInt64(max(0, v.fileSize ?? 0))))
            }
        }
        return out
    }

    /// Pack `files` into batches of at most `bytesPerBatch` bytes and `maxFiles` files (first-fit
    /// decreasing). A file over `bytesPerBatch` gets its own batch.
    public static func pack(_ files: [IngestPlannedFile], bytesPerBatch: UInt64,
                            maxFiles: Int = IngestBatchPlanner.maxFilesPerBatch) -> [IngestBatch] {
        let cap = max(1, bytesPerBatch)
        let fileCap = max(1, maxFiles)
        var batches: [IngestBatch] = []
        for file in files.sorted(by: { $0.bytes > $1.bytes }) {
            if file.bytes >= cap {
                var solo = IngestBatch()
                solo.files = [file]; solo.bytes = file.bytes; solo.oversized = true
                batches.append(solo)
                continue
            }
            if let i = batches.firstIndex(where: { !$0.oversized && $0.files.count < fileCap && $0.bytes + file.bytes <= cap }) {
                batches[i].files.append(file)
                batches[i].bytes += file.bytes
            } else {
                var b = IngestBatch()
                b.files = [file]; b.bytes = file.bytes
                batches.append(b)
            }
        }
        return batches
    }

    /// Speed PERF-36 torrent (owner 2026-11-23) — not tested yet. Batches holding a document of the open case / the current
    /// question run first (and those files first inside them); the packing itself is unchanged.
    public static func prioritised(_ batches: [IngestBatch]) -> [IngestBatch] {
        let paths = PriorityPieces.current.paths
        guard !paths.isEmpty else { return batches }
        func hit(_ f: IngestPlannedFile) -> Bool { paths.contains(f.url.standardizedFileURL.path) }
        let reordered = batches.map { b -> IngestBatch in
            var c = b
            c.files = PriorityPieces.ordered(b.files, isPriority: hit)
            return c
        }
        return PriorityPieces.ordered(reordered) { $0.files.contains(where: hit) }
    }

    /// The plan for a folder import now: the worker count and share come from `budget`.
    public static func plan(roots: [URL], budget: WorkerBudget,
                            perWorkerBytes: UInt64 = IngestWorkerPool.defaultPerWorkerBytes) -> IngestBatchPlan {
        let files = enumerate(roots)
        let workers = budget.workers(perWorkerBytes: perWorkerBytes)
        let share = max(minimumBytesPerBatch, budget.bytesPerWorker(count: workers))
        let batches = prioritised(pack(files, bytesPerBatch: share))
        KalsmritikoshLog.ingestion.info("IngestBatchPlanner: \(files.count, privacy: .public) file(s) → \(batches.count, privacy: .public) batch(es) of ≤ \(share, privacy: .public) bytes for \(workers, privacy: .public) worker(s)")
        return IngestBatchPlan(batches: batches, bytesPerBatch: share, workers: workers)
    }
}
