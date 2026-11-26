//
//  PieceMap.swift
//  Kalsmritikosh
//
//  Speed PERF-35 torrent (owner 2026-11-23) — not tested yet. "A piece map": a big file's bytes cut into fixed-size pieces
//  (4 MiB) with the SHA-256 of each, kept per source version (v206 `source_piece_maps`). When a file has grown or changed
//  (an mbox appended to, a watched folder's file edited), the new version's map is compared with the previous version's:
//
//    • the unchanged LEADING bytes are known (every piece before the first differing one, plus the old partial last piece
//      when its bytes are proven equal) — `Delta.unchangedPrefixBytes`;
//    • an mbox's message offsets inside that prefix come from the previous version's kept index (`record_offsets`), so the
//      mailbox is not scanned for message starts there again; messages starting in changed pieces are found by the scan;
//    • other formats are read whole (their unchanged chunks reuse results through the content cache, PERF-34).
//
//  Never-delete: a changed file is still a NEW source version with its own map; nothing of the previous version changes.
//  The piece digests are for change detection only — custody digests stay the exact stored bytes' (intake).
//

import Foundation
import CryptoKit
import os

public nonisolated struct PieceMap: Sendable, Equatable {
    /// Piece size (4 MiB).
    public static let defaultPieceBytes = 4 << 20
    /// Files below this size get no map (one or two pieces: re-reading is as cheap as comparing).
    public static let minimumFileBytes: Int64 = 3 * Int64(defaultPieceBytes)

    public let pieceBytes: Int
    public let fileBytes: Int64
    public let digests: [String]
    /// The digest of `extraRange` when one was asked for (the bytes of the previous map's partial last piece).
    public let extraDigest: String?

    public var root: String {
        var h = SHA256()
        for d in digests { h.update(data: Data(d.utf8)) }
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Hash `url` in pieces (one streaming pass, 1 MiB reads). `extraRange` is hashed in the same pass.
    public static func compute(_ url: URL, pieceBytes: Int = defaultPieceBytes, extraRange: Range<Int64>? = nil) -> PieceMap? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var digests: [String] = []
        var piece = SHA256(), inPiece = 0
        var extra = extraRange.map { _ in SHA256() }
        var offset: Int64 = 0
        func hex(_ d: SHA256.Digest) -> String { d.map { String(format: "%02x", $0) }.joined() }
        while true {
            let chunk: Data
            do { chunk = try h.read(upToCount: 1 << 20) ?? Data() } catch {
                KalsmritikoshLog.ingestion.error("piece map: read failed: \(String(describing: error), privacy: .private)")
                return nil
            }
            if chunk.isEmpty { break }
            var i = chunk.startIndex
            while i < chunk.endIndex {
                let take = min(pieceBytes - inPiece, chunk.endIndex - i)
                let part = chunk[i..<(i + take)]
                piece.update(data: part)
                if let r = extraRange, extra != nil {
                    let lo = max(r.lowerBound, offset), hi = min(r.upperBound, offset + Int64(take))
                    if lo < hi {
                        let a = i + Int(lo - offset), b = i + Int(hi - offset)
                        extra?.update(data: chunk[a..<b])
                    }
                }
                inPiece += take; i += take; offset += Int64(take)
                if inPiece == pieceBytes { digests.append(hex(piece.finalize())); piece = SHA256(); inPiece = 0 }
            }
        }
        if inPiece > 0 { digests.append(hex(piece.finalize())) }
        var extraDigest: String? = nil
        if let r = extraRange, let e = extra, r.upperBound <= offset { extraDigest = hex(e.finalize()) }
        return PieceMap(pieceBytes: pieceBytes, fileBytes: offset, digests: digests, extraDigest: extraDigest)
    }

    /// The previous map's partial last piece (nil when it ends on a piece boundary).
    public var partialTail: Range<Int64>? {
        let full = Int64(fileBytes / Int64(pieceBytes)) * Int64(pieceBytes)
        return full < fileBytes ? full..<fileBytes : nil
    }

    /// How the new file differs from the previous version's.
    public nonisolated struct Delta: Sendable, Equatable {
        public let previousVersionID: UUID
        /// The leading bytes proven identical to the previous version's.
        public let unchangedPrefixBytes: Int64
        /// Pieces (of the new map) whose bytes differ or are new.
        public let changedPieces: [Int]
        /// Only bytes were added at the end (the whole previous file is the new file's prefix).
        public let appendedOnly: Bool
        /// The previous version's mbox message starts (when kept).
        public let previousRecordOffsets: [Int64]
        /// Speed PERF-35 (owner 2026-11-23): the previous version's message fingerprints by start (SHA-256 of each message's
        /// bytes), so a message proven unchanged is looked up in the content cache without being read or hashed again.
        public let previousRecordDigests: [Int64: String]
        public init(previousVersionID: UUID, unchangedPrefixBytes: Int64, changedPieces: [Int], appendedOnly: Bool,
                    previousRecordOffsets: [Int64], previousRecordDigests: [Int64: String] = [:]) {
            self.previousVersionID = previousVersionID; self.unchangedPrefixBytes = unchangedPrefixBytes
            self.changedPieces = changedPieces; self.appendedOnly = appendedOnly
            self.previousRecordOffsets = previousRecordOffsets; self.previousRecordDigests = previousRecordDigests
        }
    }

    /// Compare with `old` (the new map must have been computed with `extraRange: old.partialTail`).
    public func delta(from old: PieceMap, previousVersionID: UUID, previousRecordOffsets: [Int64],
                      previousRecordDigests: [Int64: String] = [:]) -> Delta? {
        guard old.pieceBytes == pieceBytes else { return nil }
        let oldFull = Int(old.fileBytes / Int64(pieceBytes))
        var same = 0
        while same < min(oldFull, digests.count), old.digests[same] == digests[same] { same += 1 }
        var prefix = Int64(same) * Int64(pieceBytes)
        // The old partial last piece: its bytes are equal when the new file holds them unchanged (hashed in the same pass).
        if same == oldFull, let tail = old.partialTail, let mine = extraDigest, tail.upperBound <= fileBytes,
           old.digests.count == oldFull + 1, Self.tailDigestMatches(oldPieceDigest: old.digests[oldFull], newRangeDigest: mine) {
            prefix = old.fileBytes
        }
        let appended = prefix == old.fileBytes && fileBytes >= old.fileBytes
        let firstChanged = Int(prefix / Int64(pieceBytes))
        return Delta(previousVersionID: previousVersionID, unchangedPrefixBytes: prefix,
                     changedPieces: Array(firstChanged..<digests.count).filter { $0 >= same },
                     appendedOnly: appended, previousRecordOffsets: previousRecordOffsets,
                     previousRecordDigests: previousRecordDigests)
    }

    /// The old partial piece's digest is the SHA-256 of exactly its bytes, so it equals the digest of the same range read
    /// from the new file when those bytes are unchanged.
    static func tailDigestMatches(oldPieceDigest: String, newRangeDigest: String) -> Bool { oldPieceDigest == newRangeDigest }

    /// The (start → end) message ranges of the previous version proven unchanged: both ends and the next separator
    /// ("\nFrom " around the next start) lie inside the unchanged prefix.
    public static func provenRecords(_ delta: Delta) -> [Int: Int] {
        let o = delta.previousRecordOffsets
        guard o.count >= 2 else { return [:] }
        var out: [Int: Int] = [:]
        for k in 0..<(o.count - 1) where o[k + 1] + 5 <= delta.unchangedPrefixBytes && o[k] < o[k + 1] {
            out[Int(o[k])] = Int(o[k + 1])
        }
        return out
    }
}

/// The piece maps of the ledger, and the task-local context of the file being read.
public nonisolated enum PieceMaps {
    /// What the import knows about the file being read now: its delta (nil = no previous map, or not big) and the message
    /// starts the loader finds (kept with this version's map for the next comparison).
    public final class Context: Sendable {
        private struct State {
            var delta: PieceMap.Delta?
            var offsets: [Int64] = []
            var digests: [Int64: String] = [:]
            var mapped = false
            var parsed = 0
            var reused = 0
        }
        private let state = OSAllocatedUnfairLock(initialState: State())
        public init() {}
        public var delta: PieceMap.Delta? { state.withLock { $0.delta } }
        public func setDelta(_ d: PieceMap.Delta?) { state.withLock { $0.delta = d } }
        public func noteRecordStarts(_ starts: [Int]) {
            guard !starts.isEmpty else { return }
            state.withLock { $0.offsets.append(contentsOf: starts.map(Int64.init)) }
        }
        public var recordOffsets: [Int64] { state.withLock { $0.offsets } }
        /// Speed PERF-35 (owner 2026-11-23): this file has a piece map (an mbox of `PieceMap.minimumFileBytes` or more), so
        /// its messages' decodes are kept for the next version and their fingerprints are kept with the map.
        public var isMapped: Bool { state.withLock { $0.mapped } }
        public func setMapped(_ on: Bool = true) { state.withLock { $0.mapped = on } }
        public func noteRecordDigests(_ d: [Int: String]) {
            guard !d.isEmpty else { return }
            state.withLock { for (k, v) in d { $0.digests[Int64(k)] = v } }
        }
        public var recordDigests: [Int64: String] { state.withLock { $0.digests } }
        /// Messages decoded from their bytes vs taken from the previous version's kept decode (unchanged pieces).
        public func noteMessages(parsed: Int, reused: Int) { state.withLock { $0.parsed += parsed; $0.reused += reused } }
        public var parsedMessages: Int { state.withLock { $0.parsed } }
        public var reusedMessages: Int { state.withLock { $0.reused } }
    }
    @TaskLocal public static var reading: Context?

    static func blob(_ offsets: [Int64]) -> Data {
        var v = offsets.map { $0.littleEndian }
        return v.withUnsafeMutableBytes { Data($0) }
    }

    /// Fingerprints aligned with sorted `offsets`: 32 raw bytes each (all zero = none kept for that message).
    static func digestBlob(_ offsets: [Int64], _ digests: [Int64: String]) -> Data {
        var out = Data(capacity: offsets.count * 32)
        for o in offsets {
            if let hex = digests[o], let raw = Self.rawDigest(hex) { out.append(raw) } else { out.append(Data(count: 32)) }
        }
        return out
    }

    static func digests(_ data: Data?, offsets: [Int64]) -> [Int64: String] {
        guard let data, data.count == offsets.count * 32 else { return [:] }
        var out: [Int64: String] = [:]
        for (k, o) in offsets.enumerated() {
            let slice = data[data.startIndex + k * 32 ..< data.startIndex + (k + 1) * 32]
            guard slice.contains(where: { $0 != 0 }) else { continue }
            out[o] = slice.map { String(format: "%02x", $0) }.joined()
        }
        return out
    }

    private static func rawDigest(_ hex: String) -> Data? {
        guard hex.utf8.count == 64 else { return nil }
        var out = Data(capacity: 32)
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            guard let b = UInt8(hex[i..<j], radix: 16) else { return nil }
            out.append(b)
            i = j
        }
        return out
    }

    static func offsets(_ data: Data?) -> [Int64] {
        guard let data, data.count >= 8 else { return [] }
        return data.withUnsafeBytes { raw in raw.bindMemory(to: Int64.self).map { Int64(littleEndian: $0) } }
    }

    /// Compute and keep the map of a new big version and compare it with the previous version's. Best-effort: a failure
    /// means the file is read whole, as before.
    public static func prepare(database: Database, fileAt url: URL, sizeBytes: Int64, logicalSourceID: UUID,
                               sourceVersionID: UUID, at now: Date = Date()) async -> PieceMap.Delta? {
        guard sizeBytes >= PieceMap.minimumFileBytes else { return nil }
        do {
            // The newest earlier version's map of the same document.
            let prior = try await database.query("""
                SELECT source_version_id, piece_bytes, file_bytes, piece_digests, record_offsets, record_digests FROM source_piece_maps
                WHERE logical_source_id = ? AND source_version_id <> ? ORDER BY created_at DESC LIMIT 1;
                """, [.uuid(logicalSourceID), .uuid(sourceVersionID)]).first
            let old: (id: UUID, map: PieceMap, offsets: [Int64], recordDigests: [Int64: String])? = prior.flatMap { r in
                guard let id = r.uuid(0), let pb = r.int(1), let fb = r.int(2), let ds = r.string(3) else { return nil }
                let digests = ds.split(separator: ",").map(String.init)
                let starts = offsets(r.blob(4))
                return (id, PieceMap(pieceBytes: Int(pb), fileBytes: fb, digests: digests, extraDigest: nil), starts,
                        Self.digests(r.blob(5), offsets: starts))
            }
            let pieceBytes = old?.map.pieceBytes ?? PieceMap.defaultPieceBytes
            guard let map = PieceMap.compute(url, pieceBytes: pieceBytes, extraRange: old?.map.partialTail) else { return nil }
            try await database.exec("""
                INSERT OR IGNORE INTO source_piece_maps (source_version_id, logical_source_id, piece_bytes, file_bytes, piece_digests, root, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?);
                """, [.uuid(sourceVersionID), .uuid(logicalSourceID), .integer(Int64(map.pieceBytes)), .integer(map.fileBytes),
                      .text(map.digests.joined(separator: ",")), .text(map.root), .date(now)])
            guard let old, let delta = map.delta(from: old.map, previousVersionID: old.id, previousRecordOffsets: old.offsets,
                                                 previousRecordDigests: old.recordDigests) else { return nil }
            KalsmritikoshLog.ingestion.info("piece map: \(delta.unchangedPrefixBytes, privacy: .public) of \(map.fileBytes, privacy: .public) bytes unchanged since the previous version (\(delta.changedPieces.count, privacy: .public) changed piece(s), appended only: \(delta.appendedOnly, privacy: .public))")
            return delta
        } catch {
            KalsmritikoshLog.ingestion.error("piece map not kept (the file is read whole): \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Keep the record starts the loader found with this version's map.
    public static func finish(database: Database, sourceVersionID: UUID, context: Context) async {
        let offsets = context.recordOffsets
        guard !offsets.isEmpty else { return }
        let sorted = Array(Set(offsets)).sorted()
        let digests = context.recordDigests
        do {
            try await database.exec("UPDATE source_piece_maps SET record_offsets = ?, record_digests = ? WHERE source_version_id = ?;",
                                    [.blob(blob(sorted)), digests.isEmpty ? .null : .blob(digestBlob(sorted, digests)), .uuid(sourceVersionID)])
        } catch {
            KalsmritikoshLog.ingestion.error("piece map record index not kept: \(String(describing: error), privacy: .public)")
        }
    }
}
