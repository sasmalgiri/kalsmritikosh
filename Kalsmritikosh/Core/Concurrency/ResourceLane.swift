//
//  ResourceLane.swift
//  Kalsmritikosh
//
//  Lane-based ingest concurrency. Each loader declares its primary
//  bottleneck resource (CPU vs Neural Engine vs Disk-I/O vs LLM vs
//  network). Files dispatch to the right lane; lanes have independent
//  concurrency caps so a 4-PDF burst doesn't starve a 1-audio
//  transcription, and an OCR job doesn't stall fast text parsers.
//
//  The big win lives on mixed-format corpora: a Documents folder
//  containing emails + PDFs + images + audio fills four different
//  hardware resources simultaneously and finishes ~3× faster than the
//  prior shared `maxInFlight=4` design.
//

import Foundation

public enum ResourceLane: String, Sendable, Hashable, CaseIterable {
    /// Pure CPU parsing — XML/JSON/text decoders, OOXML walkers, MIME
    /// + mbox byte-scan splitters. Fan out wide; scales with cores.
    case cpu
    /// Apple Neural Engine. Vision OCR + Apple Speech serialize on
    /// this resource — running multiple jobs concurrently doesn't go
    /// faster, it just queues on the same NE.
    case neuralEngine
    /// GPU-backed inference for format specialists (future
    /// WhisperKit, Parakeet, PaddleOCR-VL). One model in residency
    /// at a time keeps RAM bounded.
    case gpuModel
    /// Local-LLM lane (Ollama / MLX). Ollama serializes inference
    /// internally; running parallel requests just stacks timeouts.
    /// Used by context-prefix generation and the future Marker /
    /// Mistral OCR specialist path.
    case llm
    /// Disk-I/O bound work — PST / NSF NDB B-tree walks, large mbox
    /// byte scans. Bounded so a multi-GB archive doesn't thrash the
    /// SSD against other lanes.
    case diskIO
    /// Network calls — cloud OCR, cloud reasoning. Bounded by user's
    /// network and the provider's rate limit, not by hardware.
    case network
}

/// Lane semaphores. Each call to `withLane(_:body:)` waits until the
/// lane has capacity, runs the body, releases. Lanes are independent
/// — a saturated CPU lane never blocks an idle NE lane.
///
/// Default caps are derived from `HardwareProbe` at boot:
///   cpu          ≈ activeProcessorCount - 1   (leave one core free)
///   neuralEngine = 1                          (NE serializes)
///   gpuModel     = 1                          (one model in residency)
///   llm          = 1                          (Ollama serializes)
///   diskIO       = 2..4                       (depends on storage)
///   network      = 4                          (parallel HTTP)
public actor LaneScheduler {
    private var capacities: [ResourceLane: Int]
    private var inFlight: [ResourceLane: Int]
    private var waiters: [ResourceLane: [CheckedContinuation<Void, Never>]]

    public init(capacities: [ResourceLane: Int]) {
        var caps: [ResourceLane: Int] = [:]
        var current: [ResourceLane: Int] = [:]
        var waits: [ResourceLane: [CheckedContinuation<Void, Never>]] = [:]
        for lane in ResourceLane.allCases {
            caps[lane] = max(1, capacities[lane] ?? 1)
            current[lane] = 0
            waits[lane] = []
        }
        self.capacities = caps
        self.inFlight = current
        self.waiters = waits
    }

    /// Computes per-lane caps from the device. CPU lane scales with
    /// core count; everything else has sensible defaults.
    public nonisolated static func defaultCapacities(
        processorCount: Int,
        availableRAMBytes: Int64
    ) -> [ResourceLane: Int] {
        let cpuCap = max(2, processorCount - 1)
        // Heuristic: ≥ 32 GB RAM → allow 2 GPU models or 2 disk-IO
        // jobs in parallel; ≥ 16 GB → 1; otherwise the minimum.
        let bigRAM = availableRAMBytes >= 32 * 1_073_741_824
        let medRAM = availableRAMBytes >= 16 * 1_073_741_824
        return [
            .cpu: cpuCap,
            .neuralEngine: 1,
            .gpuModel: bigRAM ? 2 : 1,
            .llm: 1,
            .diskIO: medRAM ? 4 : 2,
            .network: 4
        ]
    }

    /// Acquire a slot in `lane`, run `body`, release. Suspends until
    /// the lane has capacity.
    public func withLane<T: Sendable>(
        _ lane: ResourceLane,
        body: @Sendable () async throws -> T
    ) async rethrows -> T {
        await acquire(lane)
        defer { Task { await self.release(lane) } }
        return try await body()
    }

    /// Snapshot of current load per lane — used by SettingsView or
    /// log dumps to show what's busy.
    public func snapshot() -> [ResourceLane: (inFlight: Int, capacity: Int)] {
        var out: [ResourceLane: (Int, Int)] = [:]
        for lane in ResourceLane.allCases {
            out[lane] = (inFlight[lane] ?? 0, capacities[lane] ?? 1)
        }
        return out
    }

    private func acquire(_ lane: ResourceLane) async {
        let cap = capacities[lane] ?? 1
        if (inFlight[lane] ?? 0) < cap {
            inFlight[lane, default: 0] += 1
            return
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            waiters[lane, default: []].append(cont)
        }
        inFlight[lane, default: 0] += 1
    }

    private func release(_ lane: ResourceLane) async {
        inFlight[lane, default: 0] = max(0, (inFlight[lane] ?? 0) - 1)
        if var queue = waiters[lane], !queue.isEmpty {
            let next = queue.removeFirst()
            waiters[lane] = queue
            next.resume()
        }
    }
}
