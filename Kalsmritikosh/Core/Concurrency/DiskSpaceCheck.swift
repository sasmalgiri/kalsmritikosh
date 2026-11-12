//
//  DiskSpaceCheck.swift
//  Kalsmritikosh
//
//  Smart-map S14 (PERF-08) — disk pressure is handled explicitly: before the app writes a file of known size
//  (an export, a backup) it asks the volume for its free space and refuses when the file plus a safety margin
//  does not fit, saying how much is needed. A refusal writes nothing, so a full disk cannot leave a half-written
//  output recorded as an export, and the ledger is never touched by it.
//

import Foundation
import os

public nonisolated enum DiskSpaceCheck {
    /// Kept free beyond the file itself (an atomic write holds a temporary copy; the ledger must still be able to grow).
    public static let safetyMargin: Int64 = 64 * 1_048_576

    /// The bytes needed (file twice for the atomic temporary copy, plus the margin) when `available` is short of it;
    /// nil when the write fits.
    public static func shortfall(writing bytes: Int64, available: Int64, margin: Int64 = safetyMargin) -> Int64? {
        let needed = max(0, bytes) * 2 + margin
        return available < needed ? needed : nil
    }

    /// The free space of the volume holding `url` (or its folder, when the file does not exist yet), for important
    /// use; nil when the volume does not say (the write then goes ahead and its own failure is reported).
    public static func availableCapacity(at url: URL) -> Int64? {
        let probe = FileManager.default.fileExists(atPath: url.path) ? url : url.deletingLastPathComponent()
        do {
            let values = try probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
            if let important = values.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
            return values.volumeAvailableCapacity.map(Int64.init)
        } catch {
            KalsmritikoshLog.app.error("Free space unknown at the destination: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
