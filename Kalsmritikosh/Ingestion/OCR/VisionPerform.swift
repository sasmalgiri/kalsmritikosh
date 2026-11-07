//
//  VisionPerform.swift
//  Kalsmritikosh
//
//  One Vision text-recognition pass that survives a busy Neural Engine.
//
//  FOUND BY THE CASE BENCH, 2026-10-20: with Apple's on-device language model working in other
//  processes, Vision text recognition failed outright ("e5rt_execution_stream_operation_create_
//  precompiled_compute_operation_with_options call failed", 13). The OCR engines caught the error
//  and returned no lines, so a scanned decision was stored with no text at all — silently. The
//  same page read normally seconds later, and on the CPU.
//
//  A failed pass is retried once after a short pause, then once more on the CPU; only an error
//  that survives both is reported as a failure (logged — never an empty page in disguise).
//

import Foundation
#if canImport(Vision)
import Vision
import CoreML
import OSLog
import os

enum VisionPerform {
    /// Passes that failed even on the CPU, process-wide — telemetry only. Attribution to a page or a
    /// document uses a `Tally` (below): a concurrent document's failure must never be charged to this one
    /// (N8, mandate 2026-11-01).
    nonisolated static let failures = OSAllocatedUnfairLock(initialState: 0)
    nonisolated static func failureCount() -> Int { failures.withLock { $0 } }

    /// What happened to the recognitions made inside one `tallying` scope (one page, one document).
    nonisolated final class Tally: @unchecked Sendable {
        private let lock = NSLock()
        private var _failed = 0, _cancelled = 0
        private weak var current: VNRequest?
        var failed: Int { lock.lock(); defer { lock.unlock() }; return _failed }
        var cancelled: Int { lock.lock(); defer { lock.unlock() }; return _cancelled }
        func noteFailed() { lock.lock(); _failed += 1; lock.unlock() }
        func noteCancelled() { lock.lock(); _cancelled += 1; lock.unlock() }
        func begin(_ r: VNRequest) { lock.lock(); current = r; lock.unlock() }
        func end() { lock.lock(); current = nil; lock.unlock() }
        /// Ask Vision to stop the request in flight (VNRequest.cancel()); the perform then returns early.
        func cancelCurrent() { lock.lock(); let r = current; lock.unlock(); r?.cancel() }
    }

    @TaskLocal nonisolated static var tally: Tally?

    #if DEBUG
    /// Tests only: make every recognition attempt in this task fail, to prove attribution.
    @TaskLocal nonisolated static var forceFailureForTesting = false
    #endif

    /// Run `body` with its own tally; cancelling the surrounding task cancels the Vision request in
    /// flight (cooperative cancellation through VNRequest.cancel()) and stops any retry.
    nonisolated static func tallying<T: Sendable>(_ t: Tally, _ body: () async -> T) async -> T {
        await withTaskCancellationHandler {
            await $tally.withValue(t) { await body() }
        } onCancel: {
            t.cancelCurrent()
        }
    }

    /// Recognitions running right now, process-wide (telemetry and tests).
    private nonisolated static let inFlight = OSAllocatedUnfairLock(initialState: 0)
    /// Whether any recognition has started in this process. Once Vision has loaded its compiled models,
    /// removing the cache does not reload them — it only damages the cache for the next process.
    private nonisolated static let everStarted = OSAllocatedUnfairLock(initialState: false)

    /// The compiled-model cache (Library/Caches/<bundle>/com.apple.e5rt.e5bundlecache) and the marker that
    /// asks for it to be rebuilt.
    private nonisolated static func cacheDirectories() -> [URL] {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return [] }
        let bundleCaches = Bundle.main.bundleIdentifier.map { caches.appendingPathComponent($0, isDirectory: true) } ?? caches
        return [bundleCaches, caches].map { $0.appendingPathComponent("com.apple.e5rt.e5bundlecache", isDirectory: true) }
    }
    private nonisolated static var rebuildMarker: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("kalsmritikosh.rebuild-vision-cache", isDirectory: false)
    }

    /// A recognition kept failing on the compiled model (a cache left incomplete — case bench 2026-10-21:
    /// written while the disk was full, "Missing E5 bundle resource … Must re-compile the E5"). The cache
    /// is NOT removed now: removing it while this process — or another recognition in it — has it open
    /// leaves a half-rebuilt cache that fails the next process too (N8 tests, 2026-11-01: a self-repeating
    /// cycle). It is marked, and removed at the next launch before any recognition runs.
    nonisolated static func markCompiledModelCacheForRebuild() {
        guard let marker = rebuildMarker, !FileManager.default.fileExists(atPath: marker.path) else { return }
        FileManager.default.createFile(atPath: marker.path, contents: Data())
        KalsmritikoshLog.ingestion.notice("VisionPerform: the compiled-model cache is marked for rebuild at the next launch")
    }

    /// At launch, before any recognition: remove a cache marked for rebuild. Returns true when removed.
    @discardableResult
    nonisolated static func rebuildCompiledModelCacheIfMarked() -> Bool {
        guard !everStarted.withLock({ $0 }), let marker = rebuildMarker, FileManager.default.fileExists(atPath: marker.path) else { return false }
        var removed = false
        for e5 in cacheDirectories() where FileManager.default.fileExists(atPath: e5.path) {
            do {
                try FileManager.default.removeItem(at: e5)
                // Vision's compiler writes its output INTO this folder and does not create it again.
                try FileManager.default.createDirectory(at: e5, withIntermediateDirectories: true)
                removed = true
                KalsmritikoshLog.ingestion.notice("VisionPerform: removed the compiled-model cache at \(e5.path, privacy: .public) before any recognition; it is rebuilt on first use")
            } catch {
                KalsmritikoshLog.ingestion.error("VisionPerform: could not remove the compiled-model cache: \(String(describing: error), privacy: .public)")
            }
        }
        try? FileManager.default.removeItem(at: marker)
        return removed
    }

    /// Perform `request` on `cgImage`; true when it ran. The request's results are read by the caller.
    nonisolated static func perform(_ request: VNRequest, cgImage: CGImage, orientation: CGImagePropertyOrientation) -> Bool {
        let tally = Self.tally
        func attempt() throws {
            tally?.begin(request)
            everStarted.withLock { $0 = true }
            inFlight.withLock { $0 += 1 }
            defer { tally?.end(); inFlight.withLock { $0 -= 1 } }
            try VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:]).perform([request])
        }
        #if DEBUG
        // Tests only: a failure that reaches no recovery step (no retry, no cache removal).
        if forceFailureForTesting { tally?.noteFailed(); return false }
        #endif
        /// A cancelled task stops here: no retry, and a cancellation is not a recognition failure.
        func stoppedByCancel() -> Bool {
            guard Task.isCancelled else { return false }
            tally?.noteCancelled()
            return true
        }
        if stoppedByCancel() { return false }
        do { try attempt(); return true } catch {
            if stoppedByCancel() { return false }
            KalsmritikoshLog.ingestion.error("VisionPerform: recognition failed (\(String(describing: error), privacy: .public)); retrying")
        }
        Thread.sleep(forTimeInterval: 1.0)
        if stoppedByCancel() { return false }
        do { try attempt(); return true } catch {
            KalsmritikoshLog.ingestion.error("VisionPerform: retry failed (\(String(describing: error), privacy: .public)); trying the CPU")
        }
        // A compiled-model cache left incomplete fails every later load: mark it for rebuild at the next
        // launch (never removed under a running recognition), then try the CPU now.
        markCompiledModelCacheForRebuild()
        if let devices = try? request.supportedComputeStageDevices {
            for (stage, list) in devices {
                if let cpu = list.first(where: { if case .cpu = $0 { return true }; return false }) {
                    request.setComputeDevice(cpu, for: stage)
                }
            }
        }
        do { try attempt(); return true } catch {
            if stoppedByCancel() { return false }
            KalsmritikoshLog.ingestion.error("VisionPerform: recognition failed on the CPU too (\(String(describing: error), privacy: .public)); the page has no recognized text")
            failures.withLock { $0 += 1 }
            tally?.noteFailed()
            return false
        }
    }
}
#endif
