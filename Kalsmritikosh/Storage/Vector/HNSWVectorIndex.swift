//
//  HNSWVectorIndex.swift
//  Kalsmritikosh
//
//  Hierarchical Navigable Small Worlds — approximate-nearest-neighbour
//  vector index in pure Swift. Item #4 from the long-term data-
//  structure list, escalated to "must ship" once the target scale
//  moved from 4k chunks to ~4 TB of source data (10-100M chunks).
//
//  Why this exists:
//
//  The existing SQLiteVectorStore.nearest scans every row in the
//  `vectors` table and computes cosine on int8 blobs. That is O(N)
//  per query. At 4k chunks: 5ms — fine. At 10M chunks: ~10s — broken.
//  At 100M: completely unusable. HNSW gives logarithmic query
//  cost (in practice 10-100x faster than brute force on N=10M).
//
//  Algorithm (Malkov & Yashunin, 2016 — the canonical reference):
//
//    Build:
//      - Each vector gets a random layer ℓ sampled from
//        exponential distribution (mL = 1/ln(M)).
//      - Insertion starts from the entry point at the top layer
//        and greedily descends to the insertion layer.
//      - At each layer ≤ ℓ, pick M nearest neighbours from an
//        efConstruction-sized candidate frontier, then bidirectionally
//        connect.
//
//    Query:
//      - Greedy descend from entry point to layer 1 (ef=1).
//      - At layer 0, run an ef-sized candidate frontier and return
//        the top-K results.
//
//  This implementation:
//
//  - Pure Swift, actor isolation, no third-party deps.
//  - Distance: same int8 cosine the SQLiteVectorStore already uses
//    (re-decoded inside the index to keep parity).
//  - Memory: ~M × avgLayers × 16B per UUID = ~2 KB / vector neighbours
//    + dim bytes for the int8 blob.  At 10M vectors with dim=384,
//    M=16: ~25 GB. Bounded; can be disk-backed in a future iteration.
//  - Persistence: NOT persisted. Rebuilt from SQL at every boot,
//    same lifecycle pattern as InMemoryBondGraph + MemoryHashCache.
//

import Foundation
import CryptoKit
import Accelerate
import OSLog

public actor HNSWVectorIndex {

    // MARK: - Adaptive scale gate (P9.3)

    /// The largest vector count we'll hold in the in-memory graph, sized to the
    /// device's RAM. Above this, callers SKIP the HNSW build and let the
    /// memory-bounded SQLite path serve queries (correct, slower) instead of
    /// risking an out-of-memory crash on a very large corpus. Budgets ~40% of
    /// RAM at ~3 KB per vector (int8 bytes + adjacency + dictionary overhead),
    /// clamped to a sane floor/ceiling. Pure for testability.
    public nonisolated static func maxInMemoryVectors(physicalMemoryBytes: UInt64) -> Int {
        let budget = Double(physicalMemoryBytes) * 0.40
        let perVectorBytes = 3_072.0
        let cap = Int((budget / perVectorBytes).rounded(.down))
        return min(max(cap, 250_000), 20_000_000)
    }

    /// The cap for this device.
    public nonisolated static var recommendedMaxInMemoryVectors: Int {
        maxInMemoryVectors(physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory)
    }

    // MARK: - Hyperparameters

    /// Max neighbours per node per layer. 16 is the canonical default;
    /// higher values lift recall but quadruple memory.
    private let M: Int
    /// Doubled at layer 0 since most queries terminate there.
    private let Mmax0: Int
    /// Build-time candidate-frontier size. Higher = better graph,
    /// slower build. 200 is the standard recommendation.
    private let efConstruction: Int
    /// Layer assignment parameter. ℓ = floor(-ln(uniform) × mL).
    private let mL: Double

    // MARK: - State
    //
    // Speed PERF-28 (owner 2026-11-23) — not tested yet: dense storage. Nodes live in parallel
    // arrays addressed by an Int32 slot (no per-candidate dictionary copy of a Node), vectors are
    // kept unit-normalised as one contiguous Float buffer so a distance is one vDSP dot product,
    // and adjacency holds slots, not UUIDs. The int8 bytes + scale written to the cache are
    // re-quantized from the unit vector (cosine is scale-invariant, so scores are unchanged).

    /// slot → chunk id.
    private var ids: [Chunk.ID] = []
    /// chunk id → slot.
    private var slotOf: [Chunk.ID: Int32] = [:]
    /// Row-major unit vectors, `dim` floats per slot (zeros for an unusable vector).
    private var vecs: [Float] = []
    /// The dimension of the first usable vector; a vector of another size is unusable.
    private var dim: Int = 0
    /// false = zero norm or wrong size: kept (counted, persisted) but never linked or matched.
    private var usable: [Bool] = []
    /// slot → top layer.
    private var levels: [Int] = []
    /// slot → per-layer adjacency (slots).
    private var links: [[[Int32]]] = []
    /// Generation-stamped visited marks for searchLayer (no per-search Set).
    private var visitMark: [UInt32] = []
    private var visitGeneration: UInt32 = 0

    private var entryPoint: Int32 = -1
    private var maxLayer: Int = -1
    private var warmed = false
    /// Last build's stats — surfaced to DataHealthCheck + AppState.
    private var lastStats: BuildStats?
    /// How many vectors the last build took from a saved partial build (0 = it started over).
    public private(set) var lastResumedVectors = 0
    #if DEBUG
    /// Speed test phase (2026-11-23): stop a build right after its Nth checkpoint, as a quit or crash would (the
    /// partial-build file stays). Tests only.
    private var debugStopAfterCheckpoints: Int?
    func debugStopBuild(afterCheckpoints n: Int?) { debugStopAfterCheckpoints = n }
    #endif
    /// Deterministic PRNG state so build is reproducible. xorshift64*.
    private var rngState: UInt64 = 0x9E37_79B9_7F4A_7C15

    /// File magic + version. Bumped if the on-disk layout changes so
    /// stale caches get rejected instead of loaded incorrectly.
    private static let fileMagic: UInt32 = 0x484E_5357 // "HNSW"
    private static let fileVersion: UInt16 = 1
    /// Stored to disk so a corpus that grew or shrank since the last
    /// persist triggers a rebuild instead of loading a stale graph.
    private var persistedVectorCount: Int = 0

    public init(M: Int = 16, efConstruction: Int = 200) {
        self.M = M
        self.Mmax0 = 2 * M
        self.efConstruction = efConstruction
        self.mL = 1.0 / log(Double(M))
    }

    public func isBuilt() -> Bool { warmed }
    public func size() -> Int { ids.count }
    public func stats() -> BuildStats? { lastStats }

    private func resetGraph() {
        ids.removeAll(keepingCapacity: true)
        slotOf.removeAll(keepingCapacity: true)
        vecs.removeAll(keepingCapacity: true)
        usable.removeAll(keepingCapacity: true)
        levels.removeAll(keepingCapacity: true)
        links.removeAll(keepingCapacity: true)
        visitMark.removeAll(keepingCapacity: true)
        visitGeneration = 0
        dim = 0
        entryPoint = -1
        maxLayer = -1
    }

    // MARK: - Build

    public struct BuildStats: Sendable {
        public let vectorsLoaded: Int
        public let maxLayer: Int
        public let buildSeconds: Double
    }

    /// Speed PERF-28 (owner 2026-11-23) — not tested yet: where a long build saves its partial
    /// graph (sealed, like the cache) every `everyVectors` inserts, so a restart resumes after the
    /// last saved chunk instead of starting over. The file is removed when the build completes.
    public struct Checkpoint: Sendable {
        public let url: URL
        public let key: SymmetricKey
        public let everyVectors: Int
        public init(url: URL, key: SymmetricKey, everyVectors: Int = 50_000) {
            self.url = url
            self.key = key
            self.everyVectors = max(1_000, everyVectors)
        }
    }

    /// Page through every row in the `vectors` table and insert into
    /// the graph. Idempotent — calling twice clears the graph and
    /// rebuilds. Logs progress per page so a 10M-vector build can
    /// be observed via `log show`.
    @discardableResult
    public func build(from store: SQLiteVectorStore, pageSize: Int = 5_000, checkpoint: Checkpoint? = nil) async -> BuildStats {
        resetGraph()
        let started = Date()
        KalsmritikoshLog.storage.info("HNSW: build starting")
        // Speed PERF-23 (owner 2026-11-23) — not tested yet: keyset pages by chunk id, not OFFSET.
        var after: Chunk.ID? = nil
        var total = 0
        var resumedRawCount = 0
        // Speed PERF-28 (owner 2026-11-23) — not tested yet: resume from a saved partial graph when the
        // ledger still holds exactly the vectors it covered (same count up to its last chunk id).
        if let checkpoint, let resumed = await resume(from: checkpoint, store: store) {
            after = resumed.lastKey
            resumedRawCount = resumed.rawCovered
            total = ids.count
            KalsmritikoshLog.storage.info("HNSW: resumed a partial build at \(total, privacy: .public) vectors")
        }
        lastResumedVectors = total
        var sinceCheckpoint = 0
        var rawCovered = resumedRawCount
        #if DEBUG
        var checkpointsSaved = 0
        #endif
        while true {
            let page: (rows: [SQLiteVectorStore.RawVector], next: Chunk.ID?, rawCount: Int)
            do {
                page = try await store.listAll(after: after, pageSize: pageSize)
            } catch {
                KalsmritikoshLog.storage.error("HNSW: page fetch failed after \(total, privacy: .public) vectors — \(String(describing: error), privacy: .public)")
                break
            }
            if page.rawCount == 0 { break }
            rawCovered += page.rawCount
            for raw in page.rows {
                insert(chunkID: raw.chunkID, bytes: raw.bytes, scale: raw.scale)
                total += 1
                sinceCheckpoint += 1
            }
            guard page.rawCount >= pageSize, let next = page.next else { break }
            after = next
            if let checkpoint, sinceCheckpoint >= checkpoint.everyVectors {
                sinceCheckpoint = 0
                saveCheckpoint(checkpoint, lastKey: next, rawCovered: rawCovered)
                #if DEBUG
                checkpointsSaved += 1
                if let stop = debugStopAfterCheckpoints, checkpointsSaved >= stop {
                    return BuildStats(vectorsLoaded: total, maxLayer: maxLayer, buildSeconds: Date().timeIntervalSince(started))
                }
                #endif
            }
        }
        let elapsed = Date().timeIntervalSince(started)
        warmed = true
        let stats = BuildStats(vectorsLoaded: total, maxLayer: maxLayer, buildSeconds: elapsed)
        lastStats = stats
        if let checkpoint, FileManager.default.fileExists(atPath: checkpoint.url.path) {
            do { try FileManager.default.removeItem(at: checkpoint.url) } catch {
                KalsmritikoshLog.storage.error("HNSW: partial-build file not removed → \(String(describing: error), privacy: .private)")
            }
        }
        KalsmritikoshLog.storage.info("HNSW: built vectors=\(total, privacy: .public) maxLayer=\(self.maxLayer, privacy: .public) elapsed=\(String(format: "%.2f", elapsed), privacy: .public)s")
        return stats
    }

    /// The partial graph plus the count of ledger vectors up to `lastKey`, sealed.
    private func saveCheckpoint(_ checkpoint: Checkpoint, lastKey: Chunk.ID, rawCovered: Int) {
        var data = Data()
        appendUUID(&data, lastKey)
        appendU64(&data, UInt64(rawCovered))
        data.append(encodeGraph())
        do {
            guard let sealed = try AES.GCM.seal(data, using: checkpoint.key).combined else { return }
            try sealed.write(to: checkpoint.url, options: [.atomic, .completeFileProtection])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: checkpoint.url.path)
        } catch {
            KalsmritikoshLog.storage.error("HNSW: partial-build save failed → \(String(describing: error), privacy: .private)")
        }
    }

    /// Loads the partial graph; returns the chunk id to continue after, or nil (fresh build).
    private func resume(from checkpoint: Checkpoint, store: SQLiteVectorStore) async -> (lastKey: Chunk.ID, rawCovered: Int)? {
        guard FileManager.default.fileExists(atPath: checkpoint.url.path) else { return nil }
        let data: Data
        do {
            data = try AES.GCM.open(AES.GCM.SealedBox(combined: Data(contentsOf: checkpoint.url)), using: checkpoint.key)
        } catch {
            KalsmritikoshLog.storage.error("HNSW: partial-build file not opened (fresh build) → \(String(describing: error), privacy: .private)")
            return nil
        }
        var cursor = 0
        guard let lastKey = readUUID(data, &cursor), let covered = readU64(data, &cursor) else { return nil }
        let live: Int
        do { live = try await store.count(through: lastKey) } catch {
            KalsmritikoshLog.storage.error("HNSW: partial-build check failed (fresh build) → \(String(describing: error), privacy: .public)")
            return nil
        }
        let payload = data.subdata(in: cursor..<data.count)
        var headerCursor = 12 // magic u32 + version u16 + M u16 + dim u32, then vector_count u64
        guard live == Int(covered), let nodeCount = readU64(payload, &headerCursor),
              decodeGraph(payload, expectedCount: Int(nodeCount)) else {
            resetGraph()
            KalsmritikoshLog.storage.info("HNSW: partial build no longer matches the ledger — fresh build")
            return nil
        }
        return (lastKey, live)
    }

    // MARK: - Disk persistence (G4.2)
    //
    // Cold-start rebuild is O(N log N) — at 10M vectors that's
    // 30-60s. Persisting the built graph to disk lets the next boot
    // load it in ~100ms. Format is a custom binary blob (NOT JSON)
    // since the node-adjacency lists are dense + repeated.
    //
    // File layout (little-endian):
    //   header: magic (u32) | version (u16) | M (u16) | dim (u32)
    //           vector_count (u64) | entry_point (16 bytes UUID, or all-zero if nil)
    //           max_layer (i32)
    //   node[i]: chunk_id (16 bytes) | scale (f64) | layer (u8)
    //            blob_len (u32) | blob (blob_len bytes)
    //            for each layer ℓ in 0..<=node.layer:
    //              neighbour_count (u16) | neighbour_ids (count × 16 bytes)
    //
    // Validation: load() returns false if magic/version mismatch OR
    // vector_count != expectedCount (caller's `vectors.count()`).

    /// Persist the current built graph to a binary file. Returns
    /// `false` on any error (file write fail, encoding fail). Safe to
    /// call from any time after `build` completes.
    @discardableResult
    public func persist(to url: URL, sealedWith key: SymmetricKey?) -> Bool {
        // K11 — the cache holds every chunk's vector: it is written only sealed (AES-GCM under a key
        // derived from the ledger key), never in the clear. No key, no file; the graph stays in memory.
        guard warmed, let key else { return false }
        let data = encodeGraph()
        do {
            guard let sealed = try AES.GCM.seal(data, using: key).combined else { return false }
            try sealed.write(to: url, options: [.atomic, .completeFileProtection])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            persistedVectorCount = ids.count
            KalsmritikoshLog.storage.info("HNSW: persisted \(self.ids.count, privacy: .public) vectors to \(url.lastPathComponent, privacy: .private) (\(data.count, privacy: .public) bytes)")
            return true
        } catch {
            KalsmritikoshLog.storage.error("HNSW: persist failed → \(String(describing: error), privacy: .public)")
            return false
        }
    }

    private func encodeGraph() -> Data {
        var data = Data()
        data.reserveCapacity(ids.count * (dim + 16 * Mmax0 + 64))
        appendU32(&data, Self.fileMagic)
        appendU16(&data, Self.fileVersion)
        appendU16(&data, UInt16(M))
        appendU32(&data, UInt32(dim))
        appendU64(&data, UInt64(ids.count))
        appendUUID(&data, entryPoint >= 0 ? ids[Int(entryPoint)] : UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)))
        appendI32(&data, Int32(maxLayer))
        for slot in 0..<ids.count {
            appendUUID(&data, ids[slot])
            let bytes: [UInt8]
            let scale: Double
            if usable[slot] {
                let base = slot * dim
                (bytes, scale) = VectorQuantization.quantizeToBytes(Array(vecs[base..<(base + dim)]))
            } else {
                (bytes, scale) = ([], 0)
            }
            appendF64(&data, scale)
            data.append(UInt8(levels[slot]))
            appendU32(&data, UInt32(bytes.count))
            data.append(contentsOf: bytes)
            for layer in 0...levels[slot] {
                let nbrs = layer < links[slot].count ? links[slot][layer] : []
                appendU16(&data, UInt16(nbrs.count))
                for n in nbrs { appendUUID(&data, ids[Int(n)]) }
            }
        }
        return data
    }

    /// Load a previously-persisted graph from disk. Returns `false`
    /// when the file doesn't exist, magic/version mismatches, or
    /// `expectedCount` (the live row count in the `vectors` table)
    /// disagrees with the file — caller should fall back to a fresh
    /// build in those cases.
    @discardableResult
    public func load(from url: URL, expectedCount: Int, sealedWith key: SymmetricKey?) -> Bool {
        guard let key, FileManager.default.fileExists(atPath: url.path) else { return false }
        let data: Data
        do { data = try AES.GCM.open(AES.GCM.SealedBox(combined: Data(contentsOf: url)), using: key) } catch {
            // An unsealed (older) or foreign cache is not trusted: rebuilt from the ledger.
            KalsmritikoshLog.storage.error("HNSW: cache not opened (rebuilding) → \(String(describing: error), privacy: .public)")
            return false
        }
        let started = Date()
        guard decodeGraph(data, expectedCount: expectedCount) else { return false }
        warmed = true
        persistedVectorCount = ids.count
        let elapsed = Date().timeIntervalSince(started)
        lastStats = BuildStats(vectorsLoaded: ids.count, maxLayer: maxLayer, buildSeconds: elapsed)
        KalsmritikoshLog.storage.info("HNSW: loaded \(self.ids.count, privacy: .public) vectors from disk in \(String(format: "%.2f", elapsed), privacy: .public)s")
        return true
    }

    /// Speed PERF-28 (owner 2026-11-23) — not tested yet: one forward pass over the payload; node
    /// vectors are appended straight into the contiguous buffer and neighbour UUIDs are resolved to
    /// slots after every node is known (no intermediate Node dictionary).
    private func decodeGraph(_ data: Data, expectedCount: Int) -> Bool {
        var cursor = 0
        guard let magic = readU32(data, &cursor), magic == Self.fileMagic,
              let version = readU16(data, &cursor), version == Self.fileVersion,
              let mLoaded = readU16(data, &cursor),
              let fileDim = readU32(data, &cursor),
              let vectorCount = readU64(data, &cursor),
              let entryID = readUUID(data, &cursor),
              let maxL = readI32(data, &cursor)
        else {
            KalsmritikoshLog.storage.warning("HNSW: load rejected — header malformed")
            return false
        }
        if Int(vectorCount) != expectedCount {
            KalsmritikoshLog.storage.info("HNSW: load rejected — file has \(vectorCount, privacy: .public) vectors, ledger has \(expectedCount, privacy: .public). Rebuilding.")
            return false
        }
        guard Int(mLoaded) == M else {
            KalsmritikoshLog.storage.info("HNSW: load rejected — file M=\(mLoaded, privacy: .public), runtime M=\(self.M, privacy: .public)")
            return false
        }
        resetGraph()
        let count = Int(vectorCount)
        ids.reserveCapacity(count)
        slotOf.reserveCapacity(count)
        levels.reserveCapacity(count)
        links.reserveCapacity(count)
        usable.reserveCapacity(count)
        dim = Int(fileDim)
        vecs.reserveCapacity(count * dim)
        var pendingLinks: [[[UUID]]] = []
        pendingLinks.reserveCapacity(count)
        for _ in 0..<count {
            guard let chunkID = readUUID(data, &cursor),
                  let scale = readF64(data, &cursor),
                  let layer = readU8(data, &cursor),
                  let blobLen = readU32(data, &cursor),
                  cursor + Int(blobLen) <= data.count
            else {
                KalsmritikoshLog.storage.warning("HNSW: load truncated at node payload")
                resetGraph()
                return false
            }
            let bytes = Array(data[cursor..<(cursor + Int(blobLen))])
            cursor += Int(blobLen)
            appendSlot(chunkID: chunkID, bytes: bytes, scale: scale, layer: Int(layer))
            var perLayer: [[UUID]] = []
            perLayer.reserveCapacity(Int(layer) + 1)
            for _ in 0...Int(layer) {
                guard let nCount = readU16(data, &cursor) else { resetGraph(); return false }
                var bucket: [UUID] = []
                bucket.reserveCapacity(Int(nCount))
                for _ in 0..<Int(nCount) {
                    guard let nid = readUUID(data, &cursor) else { resetGraph(); return false }
                    bucket.append(nid)
                }
                perLayer.append(bucket)
            }
            pendingLinks.append(perLayer)
        }
        for slot in 0..<pendingLinks.count {
            links[slot] = pendingLinks[slot].map { layer in layer.compactMap { slotOf[$0] } }
        }
        let zeroUUID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        entryPoint = entryID == zeroUUID ? -1 : (slotOf[entryID] ?? -1)
        maxLayer = Int(maxL)
        return true
    }

    // MARK: - Binary helpers

    private func appendU16(_ d: inout Data, _ v: UInt16) {
        withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) }
    }
    private func appendU32(_ d: inout Data, _ v: UInt32) {
        withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) }
    }
    private func appendU64(_ d: inout Data, _ v: UInt64) {
        withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) }
    }
    private func appendI32(_ d: inout Data, _ v: Int32) {
        withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) }
    }
    private func appendF64(_ d: inout Data, _ v: Double) {
        withUnsafeBytes(of: v.bitPattern.littleEndian) { d.append(contentsOf: $0) }
    }
    private func appendUUID(_ d: inout Data, _ id: UUID) {
        withUnsafeBytes(of: id.uuid) { d.append(contentsOf: $0) }
    }
    private func readU8(_ d: Data, _ c: inout Int) -> UInt8? {
        guard c + 1 <= d.count else { return nil }
        defer { c += 1 }
        return d[d.startIndex + c]
    }
    private func readU16(_ d: Data, _ c: inout Int) -> UInt16? {
        guard c + 2 <= d.count else { return nil }
        let v: UInt16 = d.withUnsafeBytes { buf in
            buf.loadUnaligned(fromByteOffset: c, as: UInt16.self).littleEndian
        }
        c += 2
        return v
    }
    private func readU32(_ d: Data, _ c: inout Int) -> UInt32? {
        guard c + 4 <= d.count else { return nil }
        let v: UInt32 = d.withUnsafeBytes { buf in
            buf.loadUnaligned(fromByteOffset: c, as: UInt32.self).littleEndian
        }
        c += 4
        return v
    }
    private func readU64(_ d: Data, _ c: inout Int) -> UInt64? {
        guard c + 8 <= d.count else { return nil }
        let v: UInt64 = d.withUnsafeBytes { buf in
            buf.loadUnaligned(fromByteOffset: c, as: UInt64.self).littleEndian
        }
        c += 8
        return v
    }
    private func readI32(_ d: Data, _ c: inout Int) -> Int32? {
        guard c + 4 <= d.count else { return nil }
        let v: Int32 = d.withUnsafeBytes { buf in
            buf.loadUnaligned(fromByteOffset: c, as: Int32.self).littleEndian
        }
        c += 4
        return v
    }
    private func readF64(_ d: Data, _ c: inout Int) -> Double? {
        guard c + 8 <= d.count else { return nil }
        let bits: UInt64 = d.withUnsafeBytes { buf in
            buf.loadUnaligned(fromByteOffset: c, as: UInt64.self).littleEndian
        }
        c += 8
        return Double(bitPattern: bits)
    }
    private func readUUID(_ d: Data, _ c: inout Int) -> UUID? {
        guard c + 16 <= d.count else { return nil }
        let t: uuid_t = d.withUnsafeBytes { buf in buf.loadUnaligned(fromByteOffset: c, as: uuid_t.self) }
        c += 16
        return UUID(uuid: t)
    }

    // MARK: - Vectors

    /// Adds one slot: the int8 vector is expanded and unit-normalised into the shared buffer.
    @discardableResult
    private func appendSlot(chunkID: Chunk.ID, bytes: [UInt8], scale: Double, layer: Int) -> Int32 {
        let slot = Int32(ids.count)
        if dim == 0, !bytes.isEmpty { dim = bytes.count }
        var unit = [Float](repeating: 0, count: dim)
        var ok = false
        if dim > 0, bytes.count == dim, scale > 0 {
            bytes.withUnsafeBufferPointer { buf in
                buf.baseAddress!.withMemoryRebound(to: Int8.self, capacity: dim) { p in
                    vDSP_vflt8(p, 1, &unit, 1, vDSP_Length(dim))
                }
            }
            var normSq: Float = 0
            vDSP_svesq(unit, 1, &normSq, vDSP_Length(dim))
            if normSq > 0 {
                var inv = 1 / normSq.squareRoot()
                vDSP_vsmul(unit, 1, &inv, &unit, 1, vDSP_Length(dim))
                ok = true
            }
        }
        if !ok { unit = [Float](repeating: 0, count: dim) }
        ids.append(chunkID)
        slotOf[chunkID] = slot
        vecs.append(contentsOf: unit)
        usable.append(ok)
        levels.append(layer)
        links.append(Array(repeating: [Int32](), count: layer + 1))
        visitMark.append(0)
        return slot
    }

    /// 1 − cosine between the unit query `q` and slot `s`.
    @inline(__always)
    private func dist(_ q: UnsafePointer<Float>, _ s: Int32, _ base: UnsafePointer<Float>) -> Double {
        guard usable[Int(s)] else { return .infinity }
        var dot: Float = 0
        vDSP_dotpr(q, 1, base + Int(s) * dim, 1, &dot, vDSP_Length(dim))
        return 1.0 - Double(dot)
    }

    // MARK: - Query

    /// efSearch controls recall/latency tradeoff at query time. 50 is
    /// the standard recommendation; raise for better recall on dense
    /// hot regions.
    public func nearest(
        to query: [Float],
        limit: Int,
        efSearch: Int = 50
    ) -> [VectorHit] {
        guard entryPoint >= 0, limit > 0, dim > 0, query.count == dim else { return [] }
        // Parity with the stored side: the query is int8-quantized, then unit-normalised.
        let (qBytes, qScale) = quantize(query)
        guard qScale > 0 else { return [] }
        var q = [Float](repeating: 0, count: dim)
        qBytes.withUnsafeBufferPointer { buf in
            buf.baseAddress!.withMemoryRebound(to: Int8.self, capacity: dim) { p in
                vDSP_vflt8(p, 1, &q, 1, vDSP_Length(dim))
            }
        }
        var normSq: Float = 0
        vDSP_svesq(q, 1, &normSq, vDSP_Length(dim))
        guard normSq > 0 else { return [] }
        var inv = 1 / normSq.squareRoot()
        vDSP_vsmul(q, 1, &inv, &q, 1, vDSP_Length(dim))

        let ef = max(limit, efSearch)
        let snapshot = vecs
        let candidates: [Candidate] = snapshot.withUnsafeBufferPointer { vb in
            q.withUnsafeBufferPointer { qb in
                let base = vb.baseAddress!, qp = qb.baseAddress!
                // Descend from top layer to layer 1, single-best-candidate.
                var current = entryPoint
                var currentDist = dist(qp, current, base)
                var layer = maxLayer
                while layer > 0 {
                    var improved = true
                    while improved {
                        improved = false
                        if layer < links[Int(current)].count {
                            for neighbour in links[Int(current)][layer] {
                                let d = dist(qp, neighbour, base)
                                if d < currentDist { current = neighbour; currentDist = d; improved = true }
                            }
                        }
                    }
                    layer -= 1
                }
                return searchLayer(q: qp, base: base, entry: current, entryDistance: currentDist, layer: 0, ef: ef)
            }
        }
        // Convert distance (lower-better) back to cosine score
        // (higher-better) for parity with SQLiteVectorStore.
        return candidates.prefix(limit).map { cand in
            VectorHit(chunkID: ids[Int(cand.id)], score: 1.0 - cand.distance)
        }
    }

    // MARK: - Insertion

    private func insert(chunkID: Chunk.ID, bytes: [UInt8], scale: Double) {
        // A chunk id seen twice (never expected from the keyset pager) is ignored, not duplicated.
        guard slotOf[chunkID] == nil else { return }
        let layer = randomLayer()
        let slot = appendSlot(chunkID: chunkID, bytes: bytes, scale: scale, layer: layer)

        guard entryPoint >= 0 else {
            entryPoint = slot
            maxLayer = layer
            return
        }
        guard usable[Int(slot)] else { return }

        // `vecs` is not appended to again during this insert, so one stable pointer serves it all.
        let snapshot = vecs
        snapshot.withUnsafeBufferPointer { vb in
            let base = vb.baseAddress!
            let qp = base + Int(slot) * dim

            // Descend from current maxLayer down to insertion layer + 1 greedily.
            var current = entryPoint
            var currentDist = dist(qp, current, base)
            var l = maxLayer
            while l > layer {
                var improved = true
                while improved {
                    improved = false
                    if l < links[Int(current)].count {
                        for neighbour in links[Int(current)][l] {
                            let d = dist(qp, neighbour, base)
                            if d < currentDist { current = neighbour; currentDist = d; improved = true }
                        }
                    }
                }
                l -= 1
            }

            // At each layer from min(maxLayer, layer) down to 0, run an
            // efConstruction-sized search and connect to M nearest.
            var currentEntry = current
            var currentEntryDist = currentDist
            var ll = min(maxLayer, layer)
            while ll >= 0 {
                let cands = searchLayer(q: qp, base: base, entry: currentEntry, entryDistance: currentEntryDist,
                                        layer: ll, ef: efConstruction)
                let cap = ll == 0 ? Mmax0 : M
                let neighbours = selectNeighbours(cands.filter { $0.id != slot }, M: cap)
                links[Int(slot)][ll] = neighbours.map(\.id)
                // Bidirectional: connect each neighbour back to the new
                // node, pruning to Mmax (Mmax0 at layer 0).
                for cand in neighbours {
                    let n = Int(cand.id)
                    guard ll < links[n].count else { continue }
                    links[n][ll].append(slot)
                    if links[n][ll].count > cap {
                        // Prune to the M nearest of the union (cheap heuristic —
                        // full HNSW prunes via the diverse-neighbour selector).
                        let np = base + n * dim
                        var withDist = links[n][ll].map { ($0, dist(np, $0, base)) }
                        withDist.sort { $0.1 < $1.1 }
                        links[n][ll] = withDist.prefix(cap).map(\.0)
                    }
                }
                if let first = neighbours.first {
                    currentEntry = first.id
                    currentEntryDist = first.distance
                }
                ll -= 1
            }
        }

        if layer > maxLayer {
            maxLayer = layer
            entryPoint = slot
        }
    }

    // MARK: - Search-layer (the ef-sized frontier)

    private struct Candidate: Comparable {
        let id: Int32
        let distance: Double
        static func < (l: Candidate, r: Candidate) -> Bool { l.distance < r.distance }
    }

    private func searchLayer(
        q: UnsafePointer<Float>,
        base: UnsafePointer<Float>,
        entry: Int32,
        entryDistance: Double,
        layer: Int,
        ef: Int
    ) -> [Candidate] {
        visitGeneration &+= 1
        if visitGeneration == 0 {
            // Wrapped: clear the marks once every 4 billion searches.
            for i in visitMark.indices { visitMark[i] = 0 }
            visitGeneration = 1
        }
        let generation = visitGeneration
        visitMark[Int(entry)] = generation
        var candidatesMin = MinHeap<Candidate>()       // closest-first frontier
        var resultsMax = MaxHeap<Candidate>(maxCount: ef)
        let initial = Candidate(id: entry, distance: entryDistance)
        candidatesMin.push(initial)
        resultsMax.push(initial)

        while let nearest = candidatesMin.pop() {
            // If the closest unexplored candidate is further than the
            // furthest result, the frontier is exhausted.
            if let worst = resultsMax.peek(), nearest.distance > worst.distance {
                break
            }
            let node = Int(nearest.id)
            guard layer < links[node].count else { continue }
            for neighbour in links[node][layer] where visitMark[Int(neighbour)] != generation {
                visitMark[Int(neighbour)] = generation
                let d = dist(q, neighbour, base)
                let cand = Candidate(id: neighbour, distance: d)
                if resultsMax.count < ef || d < (resultsMax.peek()?.distance ?? .infinity) {
                    candidatesMin.push(cand)
                    resultsMax.push(cand)
                }
            }
        }
        return resultsMax.sorted()
    }

    private func selectNeighbours(_ cands: [Candidate], M: Int) -> [Candidate] {
        Array(cands.prefix(M))
    }

    // P9.3 step 2 — delegates to the ONE shared kernel (VectorQuantization);
    // parity with the previous private copy is pinned by VectorQuantizationTests.
    private func quantize(_ embedding: [Float]) -> ([UInt8], Double) {
        VectorQuantization.quantizeToBytes(embedding)
    }

    // MARK: - Random layer (xorshift64* — deterministic, no need for SystemRandomNumberGenerator)

    private func randomLayer() -> Int {
        rngState ^= rngState >> 12
        rngState ^= rngState << 25
        rngState ^= rngState >> 27
        let raw = rngState &* 0x2545_F491_4F6C_DD1D
        let u = Double(raw % 1_000_000) / 1_000_000.0
        let u01 = u <= 0 ? 1e-9 : u
        return Int(floor(-log(u01) * mL))
    }
}

// MARK: - Heaps (min/max) — small, hot, hand-written for performance

private nonisolated struct MinHeap<Element: Comparable> {
    private(set) var storage: [Element] = []
    var count: Int { storage.count }
    func peek() -> Element? { storage.first }

    mutating func push(_ value: Element) {
        storage.append(value)
        siftUp(storage.count - 1)
    }
    mutating func pop() -> Element? {
        guard !storage.isEmpty else { return nil }
        storage.swapAt(0, storage.count - 1)
        let v = storage.removeLast()
        if !storage.isEmpty { siftDown(0) }
        return v
    }
    private mutating func siftUp(_ i: Int) {
        var i = i
        while i > 0 {
            let parent = (i - 1) / 2
            if storage[i] < storage[parent] {
                storage.swapAt(i, parent)
                i = parent
            } else { break }
        }
    }
    private mutating func siftDown(_ i: Int) {
        var i = i
        let n = storage.count
        while true {
            let l = 2 * i + 1
            let r = 2 * i + 2
            var smallest = i
            if l < n && storage[l] < storage[smallest] { smallest = l }
            if r < n && storage[r] < storage[smallest] { smallest = r }
            if smallest == i { break }
            storage.swapAt(i, smallest)
            i = smallest
        }
    }
}

private nonisolated struct MaxHeap<Element: Comparable> {
    private(set) var storage: [Element] = []
    let maxCount: Int
    var count: Int { storage.count }
    init(maxCount: Int) { self.maxCount = maxCount }
    func peek() -> Element? { storage.first }

    mutating func push(_ value: Element) {
        if storage.count < maxCount {
            storage.append(value)
            siftUp(storage.count - 1)
        } else if let top = storage.first, value < top {
            storage[0] = value
            siftDown(0)
        }
    }
    func sorted() -> [Element] { storage.sorted() }

    private mutating func siftUp(_ i: Int) {
        var i = i
        while i > 0 {
            let parent = (i - 1) / 2
            if storage[parent] < storage[i] {
                storage.swapAt(i, parent)
                i = parent
            } else { break }
        }
    }
    private mutating func siftDown(_ i: Int) {
        var i = i
        let n = storage.count
        while true {
            let l = 2 * i + 1
            let r = 2 * i + 2
            var largest = i
            if l < n && storage[largest] < storage[l] { largest = l }
            if r < n && storage[largest] < storage[r] { largest = r }
            if largest == i { break }
            storage.swapAt(i, largest)
            i = largest
        }
    }
}
