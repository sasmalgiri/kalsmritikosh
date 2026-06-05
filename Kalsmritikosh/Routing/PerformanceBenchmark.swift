//
//  PerformanceBenchmark.swift
//  Kalsmritikosh
//
//  Times a short generation per registered provider on first run so the
//  CapabilityRegistry can rank providers by actual measured speed on the
//  current hardware. Results are cached to Application Support so the
//  benchmark only re-runs when the hardware fingerprint changes.
//

import Foundation

public struct BenchmarkResult: Codable, Sendable, Hashable {
    public let providerID: String
    public let tokensPerSecond: Double
    public let latencyP50Ms: Double
    public let peakMemoryBytes: Int64
    public let measuredAt: Date

    public init(
        providerID: String,
        tokensPerSecond: Double,
        latencyP50Ms: Double,
        peakMemoryBytes: Int64,
        measuredAt: Date = .init()
    ) {
        self.providerID = providerID
        self.tokensPerSecond = tokensPerSecond
        self.latencyP50Ms = latencyP50Ms
        self.peakMemoryBytes = peakMemoryBytes
        self.measuredAt = measuredAt
    }

    /// Maps measured P50 to the matching LatencyHint, used by the resolver
    /// when ranking providers against `CapabilitySpec.maxLatency`.
    public var observedLatency: LatencyHint {
        switch latencyP50Ms {
        case ..<500: return .interactive
        case ..<3_000: return .background
        default: return .bulk
        }
    }
}

public actor PerformanceBenchmark {
    private var cached: [String: BenchmarkResult] = [:]
    private let storeURL: URL
    private let hardwareFingerprint: String

    public init(hardwareProfile: HardwareProfile) {
        let dir = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ))?
            .appendingPathComponent("AtlasChronicaMemora", isDirectory: true)
            ?? FileManager.default.temporaryDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.storeURL = dir.appendingPathComponent("benchmarks.json")
        self.hardwareFingerprint = "\(hardwareProfile.chipName)|\(hardwareProfile.totalRAMBytes)"
        self.cached = loadCache()
    }

    public func result(for providerID: String) -> BenchmarkResult? {
        cached[providerID]
    }

    /// Run a tiny benchmark via the provider, cache the result. Caller
    /// invokes this from CapabilityRegistry.bootstrap after registration.
    public func benchmark(_ provider: any ModelProvider) async {
        guard cached[provider.id] == nil else { return }
        let prompt = "Atlas warmup. Reply with one short sentence."
        let start = Date()
        let memoryBefore = currentResidentMemory()
        let response = try? await provider.generate(
            prompt: prompt,
            options: GenerationOptions(maxTokens: 32, temperature: 0.0)
        )
        let elapsedMs = Date().timeIntervalSince(start) * 1_000
        let memoryAfter = currentResidentMemory()
        let tokens = max(1, (response?.count ?? 0) / 4)
        let tps = elapsedMs > 0 ? (Double(tokens) / (elapsedMs / 1_000)) : 0

        let benchmark = BenchmarkResult(
            providerID: provider.id,
            tokensPerSecond: tps,
            latencyP50Ms: elapsedMs,
            peakMemoryBytes: max(0, Int64(memoryAfter) - Int64(memoryBefore))
        )
        cached[provider.id] = benchmark
        persistCache()
    }

    // MARK: - Persistence

    private struct CacheFile: Codable {
        let fingerprint: String
        let results: [String: BenchmarkResult]
    }

    private func loadCache() -> [String: BenchmarkResult] {
        guard let data = try? Data(contentsOf: storeURL) else { return [:] }
        guard let file = try? JSONDecoder().decode(CacheFile.self, from: data) else { return [:] }
        guard file.fingerprint == hardwareFingerprint else { return [:] }
        return file.results
    }

    private func persistCache() {
        let file = CacheFile(fingerprint: hardwareFingerprint, results: cached)
        if let data = try? JSONEncoder().encode(file) {
            try? data.write(to: storeURL, options: .atomic)
        }
    }

    private func currentResidentMemory() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let rc = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), intPtr, &count)
            }
        }
        return rc == KERN_SUCCESS ? info.resident_size : 0
    }
}
