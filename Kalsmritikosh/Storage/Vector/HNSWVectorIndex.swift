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
import OSLog

public actor HNSWVectorIndex {

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

    private struct Node {
        let chunkID: Chunk.ID
        /// Quantized int8 vector + scale. Kept in memory so cosine
        /// can be computed without a SQLite round-trip per candidate.
        let bytes: [UInt8]
        let scale: Double
        /// neighbours[layer] = adjacency at that layer. Layer 0 always
        /// exists; higher layers only when the node was assigned that
        /// high during sampling.
        var neighbours: [[Chunk.ID]]
        var layer: Int
    }

    private var nodes: [Chunk.ID: Node] = [:]
    private var entryPoint: Chunk.ID? = nil
    private var maxLayer: Int = -1
    private var warmed = false
    /// Last build's stats — surfaced to DataHealthCheck + AppState.
    private var lastStats: BuildStats?
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
    public func size() -> Int { nodes.count }
    public func stats() -> BuildStats? { lastStats }

    // MARK: - Build

    public struct BuildStats: Sendable {
        public let vectorsLoaded: Int
        public let maxLayer: Int
        public let buildSeconds: Double
    }

    /// Page through every row in the `vectors` table and insert into
    /// the graph. Idempotent — calling twice clears the graph and
    /// rebuilds. Logs progress per page so a 10M-vector build can
    /// be observed via `log show`.
    @discardableResult
    public func build(from store: SQLiteVectorStore, pageSize: Int = 5_000) async -> BuildStats {
        nodes.removeAll(keepingCapacity: true)
        entryPoint = nil
        maxLayer = -1
        let started = Date()
        KalsmritikoshLog.storage.info("HNSW: build starting")
        var offset = 0
        var total = 0
        while true {
            let page: [SQLiteVectorStore.RawVector]
            do {
                page = try await store.listAll(offset: offset, pageSize: pageSize)
            } catch {
                KalsmritikoshLog.storage.error("HNSW: page fetch failed at offset \(offset, privacy: .public) — \(String(describing: error), privacy: .public)")
                break
            }
            if page.isEmpty { break }
            for raw in page {
                insert(chunkID: raw.chunkID, bytes: raw.bytes, scale: raw.scale)
                total += 1
            }
            offset += page.count
            if page.count < pageSize { break }
        }
        let elapsed = Date().timeIntervalSince(started)
        warmed = true
        let stats = BuildStats(vectorsLoaded: total, maxLayer: maxLayer, buildSeconds: elapsed)
        lastStats = stats
        KalsmritikoshLog.storage.info("HNSW: built vectors=\(total, privacy: .public) maxLayer=\(self.maxLayer, privacy: .public) elapsed=\(String(format: "%.2f", elapsed), privacy: .public)s")
        return stats
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
    public func persist(to url: URL) -> Bool {
        guard warmed else { return false }
        var data = Data()
        data.reserveCapacity(nodes.count * 512)

        // Header
        appendU32(&data, Self.fileMagic)
        appendU16(&data, Self.fileVersion)
        appendU16(&data, UInt16(M))
        // dim — read from the first node we encounter
        let dim = UInt32(nodes.values.first?.bytes.count ?? 0)
        appendU32(&data, dim)
        appendU64(&data, UInt64(nodes.count))
        appendUUID(&data, entryPoint ?? UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)))
        appendI32(&data, Int32(maxLayer))

        // Nodes — order doesn't matter since adjacency uses UUIDs.
        for node in nodes.values {
            appendUUID(&data, node.chunkID)
            appendF64(&data, node.scale)
            data.append(UInt8(node.layer))
            appendU32(&data, UInt32(node.bytes.count))
            data.append(contentsOf: node.bytes)
            // Per-layer adjacency
            for layer in 0...node.layer {
                let nbrs = layer < node.neighbours.count ? node.neighbours[layer] : []
                appendU16(&data, UInt16(nbrs.count))
                for nid in nbrs { appendUUID(&data, nid) }
            }
        }

        do {
            try data.write(to: url, options: .atomic)
            persistedVectorCount = nodes.count
            KalsmritikoshLog.storage.info("HNSW: persisted \(self.nodes.count, privacy: .public) vectors to \(url.lastPathComponent, privacy: .public) (\(data.count, privacy: .public) bytes)")
            return true
        } catch {
            KalsmritikoshLog.storage.error("HNSW: persist failed → \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// Load a previously-persisted graph from disk. Returns `false`
    /// when the file doesn't exist, magic/version mismatches, or
    /// `expectedCount` (the live row count in the `vectors` table)
    /// disagrees with the file — caller should fall back to a fresh
    /// build in those cases.
    @discardableResult
    public func load(from url: URL, expectedCount: Int) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            KalsmritikoshLog.storage.error("HNSW: load read failed → \(String(describing: error), privacy: .public)")
            return false
        }
        let started = Date()
        var cursor = 0

        // Header
        guard let magic = readU32(data, &cursor), magic == Self.fileMagic,
              let version = readU16(data, &cursor), version == Self.fileVersion,
              let mLoaded = readU16(data, &cursor),
              let dim = readU32(data, &cursor),
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
        _ = dim // only used during build; consistency check would compare against the embedder dim if exposed

        // Reset state
        nodes.removeAll(keepingCapacity: true)
        nodes.reserveCapacity(Int(vectorCount))
        let zeroUUID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        entryPoint = (entryID == zeroUUID) ? nil : entryID
        maxLayer = Int(maxL)

        // Nodes
        for _ in 0..<Int(vectorCount) {
            guard let chunkID = readUUID(data, &cursor),
                  let scale = readF64(data, &cursor),
                  let layer = readU8(data, &cursor),
                  let blobLen = readU32(data, &cursor)
            else {
                KalsmritikoshLog.storage.warning("HNSW: load truncated at node payload")
                nodes.removeAll(keepingCapacity: false)
                return false
            }
            guard cursor + Int(blobLen) <= data.count else { return false }
            let bytes = Array(data[cursor..<(cursor + Int(blobLen))])
            cursor += Int(blobLen)
            var neighbours: [[Chunk.ID]] = Array(repeating: [], count: Int(layer) + 1)
            for ℓ in 0...Int(layer) {
                guard let nCount = readU16(data, &cursor) else { return false }
                var bucket: [Chunk.ID] = []
                bucket.reserveCapacity(Int(nCount))
                for _ in 0..<Int(nCount) {
                    guard let nid = readUUID(data, &cursor) else { return false }
                    bucket.append(nid)
                }
                neighbours[ℓ] = bucket
            }
            nodes[chunkID] = Node(
                chunkID: chunkID,
                bytes: bytes,
                scale: scale,
                neighbours: neighbours,
                layer: Int(layer)
            )
        }

        warmed = true
        persistedVectorCount = nodes.count
        let elapsed = Date().timeIntervalSince(started)
        lastStats = BuildStats(
            vectorsLoaded: nodes.count,
            maxLayer: maxLayer,
            buildSeconds: elapsed
        )
        KalsmritikoshLog.storage.info("HNSW: loaded \(self.nodes.count, privacy: .public) vectors from disk in \(String(format: "%.2f", elapsed), privacy: .public)s")
        return true
    }

    // MARK: - Binary helpers

    private func appendU16(_ d: inout Data, _ v: UInt16) {
        var v = v.littleEndian
        d.append(Data(bytes: &v, count: 2))
    }
    private func appendU32(_ d: inout Data, _ v: UInt32) {
        var v = v.littleEndian
        d.append(Data(bytes: &v, count: 4))
    }
    private func appendU64(_ d: inout Data, _ v: UInt64) {
        var v = v.littleEndian
        d.append(Data(bytes: &v, count: 8))
    }
    private func appendI32(_ d: inout Data, _ v: Int32) {
        var v = v.littleEndian
        d.append(Data(bytes: &v, count: 4))
    }
    private func appendF64(_ d: inout Data, _ v: Double) {
        var bits = v.bitPattern.littleEndian
        d.append(Data(bytes: &bits, count: 8))
    }
    private func appendUUID(_ d: inout Data, _ id: UUID) {
        let t = id.uuid
        let bytes: [UInt8] = [
            t.0, t.1, t.2, t.3, t.4, t.5, t.6, t.7,
            t.8, t.9, t.10, t.11, t.12, t.13, t.14, t.15
        ]
        d.append(contentsOf: bytes)
    }
    private func readU8(_ d: Data, _ c: inout Int) -> UInt8? {
        guard c + 1 <= d.count else { return nil }
        defer { c += 1 }
        return d[c]
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
        let b = Array(d[c..<(c + 16)])
        c += 16
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                          b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
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
        guard let entry = entryPoint, limit > 0 else { return [] }
        let (qBytes, qScale) = quantize(query)
        let qNorm = vectorNorm(bytes: qBytes, scale: qScale)
        guard qNorm > 0 else { return [] }

        // Descend from top layer to layer 1, single-best-candidate.
        var current = entry
        var currentDist = distance(toQuery: qBytes, qScale: qScale, qNorm: qNorm, candidate: current)
        var layer = maxLayer
        while layer > 0 {
            var improved = true
            while improved {
                improved = false
                guard let node = nodes[current] else { break }
                if layer < node.neighbours.count {
                    for neighbour in node.neighbours[layer] {
                        let d = distance(toQuery: qBytes, qScale: qScale, qNorm: qNorm, candidate: neighbour)
                        if d < currentDist {
                            current = neighbour
                            currentDist = d
                            improved = true
                        }
                    }
                }
            }
            layer -= 1
        }

        // Layer 0: efSearch-sized frontier.
        let ef = max(limit, efSearch)
        let candidates = searchLayer(
            qBytes: qBytes, qScale: qScale, qNorm: qNorm,
            entry: current, entryDistance: currentDist,
            layer: 0, ef: ef
        )
        // Convert distance (lower-better) back to cosine score
        // (higher-better) for parity with SQLiteVectorStore.
        return candidates.prefix(limit).map { cand in
            VectorHit(chunkID: cand.id, score: 1.0 - cand.distance)
        }
    }

    // MARK: - Insertion

    private func insert(chunkID: Chunk.ID, bytes: [UInt8], scale: Double) {
        let layer = randomLayer()
        let layerCount = layer + 1
        var node = Node(
            chunkID: chunkID,
            bytes: bytes,
            scale: scale,
            neighbours: Array(repeating: [Chunk.ID](), count: layerCount),
            layer: layer
        )
        nodes[chunkID] = node

        guard let entry = entryPoint else {
            entryPoint = chunkID
            maxLayer = layer
            return
        }

        let qNorm = vectorNorm(bytes: bytes, scale: scale)
        guard qNorm > 0 else { return }

        // Descend from current maxLayer down to insertion layer + 1
        // greedily.
        var current = entry
        var currentDist = distance(toQuery: bytes, qScale: scale, qNorm: qNorm, candidate: current)
        var l = maxLayer
        while l > layer {
            var improved = true
            while improved {
                improved = false
                if let n = nodes[current], l < n.neighbours.count {
                    for neighbour in n.neighbours[l] {
                        let d = distance(toQuery: bytes, qScale: scale, qNorm: qNorm, candidate: neighbour)
                        if d < currentDist {
                            current = neighbour
                            currentDist = d
                            improved = true
                        }
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
            let cands = searchLayer(
                qBytes: bytes, qScale: scale, qNorm: qNorm,
                entry: currentEntry, entryDistance: currentEntryDist,
                layer: ll, ef: efConstruction
            )
            let neighbours = selectNeighbours(cands, M: ll == 0 ? Mmax0 : M)
            node.neighbours[ll] = neighbours.map(\.id)
            nodes[chunkID] = node
            // Bidirectional: connect each neighbour back to the new
            // node, pruning to Mmax (Mmax0 at layer 0).
            for cand in neighbours {
                if var nn = nodes[cand.id], ll < nn.neighbours.count {
                    nn.neighbours[ll].append(chunkID)
                    let cap = ll == 0 ? Mmax0 : M
                    if nn.neighbours[ll].count > cap {
                        // Prune to the M nearest of the union (cheap
                        // heuristic — full HNSW prunes via the
                        // diverse-neighbour selector; this is good
                        // enough for our scale).
                        var withDist: [(Chunk.ID, Double)] = []
                        let nnBytes = nn.bytes
                        let nnScale = nn.scale
                        let nnNorm = vectorNorm(bytes: nnBytes, scale: nnScale)
                        for nid in nn.neighbours[ll] {
                            let d = distance(toQuery: nnBytes, qScale: nnScale, qNorm: nnNorm, candidate: nid)
                            withDist.append((nid, d))
                        }
                        withDist.sort { $0.1 < $1.1 }
                        nn.neighbours[ll] = withDist.prefix(cap).map(\.0)
                    }
                    nodes[cand.id] = nn
                }
            }
            if let first = neighbours.first {
                currentEntry = first.id
                currentEntryDist = first.distance
            }
            ll -= 1
        }

        if layer > maxLayer {
            maxLayer = layer
            entryPoint = chunkID
        }
    }

    // MARK: - Search-layer (the ef-sized frontier)

    private struct Candidate: Comparable {
        let id: Chunk.ID
        let distance: Double
        static func < (l: Candidate, r: Candidate) -> Bool { l.distance < r.distance }
    }

    private func searchLayer(
        qBytes: [UInt8],
        qScale: Double,
        qNorm: Double,
        entry: Chunk.ID,
        entryDistance: Double,
        layer: Int,
        ef: Int
    ) -> [Candidate] {
        var visited: Set<Chunk.ID> = [entry]
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
            guard let node = nodes[nearest.id], layer < node.neighbours.count else { continue }
            for neighbour in node.neighbours[layer] where !visited.contains(neighbour) {
                visited.insert(neighbour)
                let d = distance(toQuery: qBytes, qScale: qScale, qNorm: qNorm, candidate: neighbour)
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

    // MARK: - Distance (cosine on int8)

    private func distance(
        toQuery qBytes: [UInt8],
        qScale: Double,
        qNorm: Double,
        candidate id: Chunk.ID
    ) -> Double {
        guard let node = nodes[id], node.bytes.count == qBytes.count else { return .infinity }
        var dot: Double = 0
        var rowNormSq: Double = 0
        let n = node.bytes.count
        for i in 0..<n {
            let a = Double(Int8(bitPattern: qBytes[i]))
            let b = Double(Int8(bitPattern: node.bytes[i]))
            dot += a * b
            rowNormSq += b * b
        }
        let rowNorm = rowNormSq.squareRoot() * node.scale
        guard rowNorm > 0 else { return .infinity }
        let cosine = (dot * qScale * node.scale) / (qNorm * rowNorm)
        // Lower distance = closer; cosine 1.0 → distance 0.0
        return 1.0 - cosine
    }

    private func vectorNorm(bytes: [UInt8], scale: Double) -> Double {
        var sumSq: Double = 0
        for b in bytes {
            let v = Double(Int8(bitPattern: b))
            sumSq += v * v
        }
        return sumSq.squareRoot() * scale
    }

    private func quantize(_ embedding: [Float]) -> ([UInt8], Double) {
        var maxAbs: Float = 0
        for x in embedding { let a = Swift.abs(x); if a > maxAbs { maxAbs = a } }
        let scale = maxAbs == 0 ? 1.0 : Double(maxAbs) / 127.0
        var out = [UInt8](repeating: 0, count: embedding.count)
        if scale > 0 {
            for i in 0..<embedding.count {
                let v = (Double(embedding[i]) / scale).rounded()
                let clamped = Swift.max(-127.0, Swift.min(127.0, v))
                out[i] = UInt8(bitPattern: Int8(clamped))
            }
        }
        return (out, scale)
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
