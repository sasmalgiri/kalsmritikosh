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
