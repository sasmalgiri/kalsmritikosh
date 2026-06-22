//
//  HardwareProbe.swift
//  Kalsmritikosh
//
//  Captures the machine's relevant inference budget at launch. Cached for
//  the lifetime of the process — AutoRecommendation reads this once to
//  decide which models the CapabilityRegistry should make available by
//  default.
//

import Foundation
#if canImport(IOKit)
import IOKit
#endif

public struct HardwareProfile: Codable, Sendable, Hashable {
    public let totalRAMBytes: Int64
    public let availableRAMBytes: Int64
    public let processorCount: Int
    public let isAppleSilicon: Bool
    public let chipName: String
    public let hasNeuralEngine: Bool
    public let probedAt: Date

    public init(
        totalRAMBytes: Int64,
        availableRAMBytes: Int64,
        processorCount: Int,
        isAppleSilicon: Bool,
        chipName: String,
        hasNeuralEngine: Bool,
        probedAt: Date = .init()
    ) {
        self.totalRAMBytes = totalRAMBytes
        self.availableRAMBytes = availableRAMBytes
        self.processorCount = processorCount
        self.isAppleSilicon = isAppleSilicon
        self.chipName = chipName
        self.hasNeuralEngine = hasNeuralEngine
        self.probedAt = probedAt
    }

    /// Tier used by AutoRecommendation to pick default models without
    /// reading any specific model identifier.
    public nonisolated var tier: ModelManifest.Tier {
        switch totalRAMBytes {
        case ..<(10 * 1_073_741_824): return .small      // < 10 GB
        case ..<(20 * 1_073_741_824): return .medium     // < 20 GB
        default: return .large
        }
    }
}

public enum HardwareProbe {
    /// Runs once at app boot; cheap (< 1ms).
    public static func probe() -> HardwareProfile {
        let total = Int64(ProcessInfo.processInfo.physicalMemory)
        let available = total - Int64(usedMemoryBytes())
        let cores = ProcessInfo.processInfo.activeProcessorCount

        #if arch(arm64)
        let appleSilicon = true
        #else
        let appleSilicon = false
        #endif

        return HardwareProfile(
            totalRAMBytes: total,
            availableRAMBytes: max(0, available),
            processorCount: cores,
            isAppleSilicon: appleSilicon,
            chipName: detectChipName(),
            hasNeuralEngine: appleSilicon
        )
    }

    private static func usedMemoryBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let kerr = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    intPtr,
                    &count
                )
            }
        }
        return kerr == KERN_SUCCESS ? info.resident_size : 0
    }

    private static func detectChipName() -> String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        guard size > 0 else { return "unknown" }
        var bytes = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &bytes, &size, nil, 0)
        return String(cString: bytes)
    }
}
