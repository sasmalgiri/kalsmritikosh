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

    // MARK: - S17 (PERF-08): parser and extraction scratch space

    /// Tests only: the free space the scratch check sees (a task-local value, so a test never changes another's view).
    @TaskLocal public static var scratchCapacityOverride: Int64?

    /// A temporary copy refused because the temporary folder's volume is short of space. Nothing was written; the
    /// original is untouched and its custody record stays, so the item can be processed again once space is freed.
    public struct ScratchRefusal: Error, LocalizedError, CustomStringConvertible, Sendable, Equatable {
        public let purpose: String
        public let needed: Int64
        public let available: Int64
        /// The safe ways on from here, in order (shown with the refusal; the item is recorded as not processed, never dropped).
        public static let recoveryChoices = [
            "Free space on the Mac's start-up disk, then process the item again (it is kept as not processed, not dropped).",
            "Add the large item on its own later, after the rest of the archive is processed.",
            "Leave it unprocessed: its original and its custody record are kept and it stays listed as not read."
        ]
        public var errorDescription: String? {
            let f = ByteCountFormatter()
            return "Not enough free disk space for the temporary copy of \(purpose): it needs about \(f.string(fromByteCount: needed)) and "
                + "\(f.string(fromByteCount: available)) is free. Nothing was written and the original is untouched. "
                + Self.recoveryChoices.joined(separator: " Or: ")
        }
        /// The recorded failure (an ingest attempt keeps `String(describing:)` of the error) reads as the sentence above.
        public var description: String { errorDescription ?? "Not enough free disk space for a temporary copy." }
    }

    /// Refuse a temporary copy of `bytes` (a parser's scratch file, an archive member being extracted) when the temporary
    /// folder's volume cannot hold it plus the safety margin. When the volume does not say, the write goes ahead and its
    /// own failure is reported.
    ///
    /// A check only: other copies still being written (their reservations) count against the free space, but this one
    /// reserves nothing. A caller about to write uses `reserveScratch` and holds the reservation for the write.
    public static func requireScratch(_ bytes: Int64, for purpose: String, pool: ScratchPool = .shared) throws {
        try reserveScratch(bytes, for: purpose, pool: pool).release()
    }

    /// Deep dive 2026-11-14 batch 1 — the free-space check of a scratch copy and a reservation of its size, taken
    /// together under one lock: parsers running in parallel each saw the same free space and together overfilled the
    /// disk. The reservation is held until `release()` (call it once the copy is written or removed; dropping it
    /// releases it too). When the volume does not say, nothing is reserved and the write goes ahead.
    public static func reserveScratch(_ bytes: Int64, for purpose: String, pool: ScratchPool = .shared) throws -> ScratchReservation {
        let measured = scratchCapacityOverride ?? availableCapacity(at: FileManager.default.temporaryDirectory)
        guard let measured else { return ScratchReservation(bytes: 0, pool: pool) }
        // A scratch copy is written once (no atomic second copy): the file plus the margin.
        let size = max(0, bytes)
        let needed = size + safetyMargin
        if let free = pool.reserve(size, needed: needed, measured: measured) {
            KalsmritikoshLog.app.error("Temporary copy refused for lack of disk space (needs \(needed, privacy: .public) bytes, \(free, privacy: .public) free after other copies in progress)")
            throw ScratchRefusal(purpose: purpose, needed: needed, available: free)
        }
        return ScratchReservation(bytes: size, pool: pool)
    }

    /// The bytes of scratch copies being written now, process-wide (tests pass their own pool).
    public nonisolated final class ScratchPool: Sendable {
        public static let shared = ScratchPool()
        private let held = OSAllocatedUnfairLock<Int64>(initialState: 0)
        public init() {}

        /// Reserve `size` when `measured` free space, less what is already held, still leaves `needed`; otherwise
        /// nothing is reserved and the free space left is returned.
        func reserve(_ size: Int64, needed: Int64, measured: Int64) -> Int64? {
            held.withLock { total -> Int64? in
                let free = measured - total
                guard free >= needed else { return max(0, free) }
                total += size
                return nil
            }
        }

        func release(_ size: Int64) { held.withLock { $0 = max(0, $0 - size) } }

        /// The bytes held now.
        public var reserved: Int64 { held.withLock { $0 } }
    }

    /// One scratch copy's reservation; released once (explicitly, or when dropped).
    public nonisolated final class ScratchReservation: Sendable {
        public let bytes: Int64
        private let pool: ScratchPool
        private let released = OSAllocatedUnfairLock(initialState: false)
        init(bytes: Int64, pool: ScratchPool) { self.bytes = bytes; self.pool = pool }

        public func release() {
            let first = released.withLock { done -> Bool in
                if done { return false }
                done = true
                return true
            }
            if first && bytes > 0 { pool.release(bytes) }
        }

        deinit { release() }
    }
}
