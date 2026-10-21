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
    /// Passes that failed even on the CPU, process-wide. A parser compares the count before and
    /// after a page so a failed recognition is reported as a failure, not as a blank page.
    nonisolated static let failures = OSAllocatedUnfairLock(initialState: 0)
    nonisolated static func failureCount() -> Int { failures.withLock { $0 } }

    private nonisolated static let cacheCleared = OSAllocatedUnfairLock(initialState: false)

    /// Remove this app's compiled-model cache (Library/Caches/<bundle>/com.apple.e5rt.e5bundlecache)
    /// the first time recognition keeps failing in this process; true when it was removed now.
    nonisolated static func clearCompiledModelCacheOnce() -> Bool {
        let first = cacheCleared.withLock { done -> Bool in
            if done { return false }
            done = true
            return true
        }
        guard first, let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return false }
        let bundleCaches = Bundle.main.bundleIdentifier.map { caches.appendingPathComponent($0, isDirectory: true) } ?? caches
        var removed = false
        for dir in [bundleCaches, caches] {
            let e5 = dir.appendingPathComponent("com.apple.e5rt.e5bundlecache", isDirectory: true)
            if FileManager.default.fileExists(atPath: e5.path) {
                do {
                    try FileManager.default.removeItem(at: e5)
                    removed = true
                    KalsmritikoshLog.ingestion.notice("VisionPerform: removed the compiled-model cache at \(e5.path, privacy: .public); it is rebuilt on the next load")
                } catch {
                    KalsmritikoshLog.ingestion.error("VisionPerform: could not remove the compiled-model cache: \(String(describing: error), privacy: .public)")
                }
            }
        }
        return removed
    }

    /// Perform `request` on `cgImage`; true when it ran. The request's results are read by the caller.
    nonisolated static func perform(_ request: VNRequest, cgImage: CGImage, orientation: CGImagePropertyOrientation) -> Bool {
        func attempt() throws {
            try VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:]).perform([request])
        }
        do { try attempt(); return true } catch {
            KalsmritikoshLog.ingestion.error("VisionPerform: recognition failed (\(String(describing: error), privacy: .public)); retrying")
        }
        Thread.sleep(forTimeInterval: 1.0)
        do { try attempt(); return true } catch {
            KalsmritikoshLog.ingestion.error("VisionPerform: retry failed (\(String(describing: error), privacy: .public)); trying the CPU")
        }
        // A compiled-model cache entry left incomplete (case bench 2026-10-21: written while the
        // disk was full — "Missing E5 bundle resource … Must re-compile the E5") fails every
        // later load in every process of this app until the cache is rebuilt. The cache is the
        // app's own and rebuildable: clear it once per process and try again.
        if Self.clearCompiledModelCacheOnce() {
            do { try attempt(); return true } catch {
                KalsmritikoshLog.ingestion.error("VisionPerform: failed after rebuilding the model cache (\(String(describing: error), privacy: .public)); trying the CPU")
            }
        }
        if let devices = try? request.supportedComputeStageDevices {
            for (stage, list) in devices {
                if let cpu = list.first(where: { if case .cpu = $0 { return true }; return false }) {
                    request.setComputeDevice(cpu, for: stage)
                }
            }
        }
        do { try attempt(); return true } catch {
            KalsmritikoshLog.ingestion.error("VisionPerform: recognition failed on the CPU too (\(String(describing: error), privacy: .public)); the page has no recognized text")
            failures.withLock { $0 += 1 }
            return false
        }
    }
}
#endif
