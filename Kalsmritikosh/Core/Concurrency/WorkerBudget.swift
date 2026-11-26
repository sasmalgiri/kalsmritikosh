//
//  WorkerBudget.swift
//  Kalsmritikosh
//
//  Unified-path program (owner, 2026-11-22), PERF-14 / PERF-18 — how many workers the Mac can carry
//  NOW, from the memory it has free (free + inactive + purgeable pages), the kernel's pressure level
//  and the thermal state; never a fixed count. Import workers (IngestWorkerPool) and the case reader's
//  parts (CaseReader) both size themselves from here, and re-ask between batches so the count follows
//  the machine while a long run goes on.
//
//  Not tested yet (owner 2026-11-22: implement now, test later).
//

import Foundation
import os

public nonisolated struct WorkerBudget: Sendable, Equatable {
    /// Memory the system reports as free or reclaimable now.
    public let availableBytes: UInt64
    /// Physical memory of the Mac.
    public let physicalBytes: UInt64
    /// Cores the scheduler may use.
    public let activeCores: Int
    public let pressure: MemoryPressureLevel
    public let thermal: ProcessInfo.ThermalState

    public init(availableBytes: UInt64, physicalBytes: UInt64, activeCores: Int,
                pressure: MemoryPressureLevel, thermal: ProcessInfo.ThermalState) {
        self.availableBytes = availableBytes; self.physicalBytes = physicalBytes; self.activeCores = activeCores
        self.pressure = pressure; self.thermal = thermal
    }

    /// The Mac as it is now. `pressure` comes from the app's MemoryPressureGovernor when it has one.
    public static func current(pressure: MemoryPressureLevel = .normal) -> WorkerBudget {
        let info = ProcessInfo.processInfo
        return WorkerBudget(availableBytes: availableMemoryBytes() ?? info.physicalMemory / 4,
                            physicalBytes: info.physicalMemory, activeCores: max(1, info.activeProcessorCount),
                            pressure: pressure, thermal: info.thermalState)
    }

    /// Half of what is free is left to the system and the rest of the app; the other half is shared out.
    public var shareableBytes: UInt64 { availableBytes / 2 }

    /// How many workers of `perWorkerBytes` fit now: at least 1, at most cores − 1, fewer under pressure
    /// or heat (warning halves, critical or serious-thermal → 1).
    public func workers(perWorkerBytes: UInt64) -> Int {
        guard perWorkerBytes > 0 else { return 1 }
        var n = Int(min(UInt64(Int.max), shareableBytes / perWorkerBytes))
        n = min(n, max(1, activeCores - 1))
        switch pressure {
        case .critical: n = 1
        case .warning: n = max(1, n / 2)
        case .normal: break
        }
        switch thermal {
        case .serious, .critical: n = 1
        case .fair: n = max(1, n - 1)
        default: break
        }
        return max(1, n)
    }

    /// The bytes one worker may hold when `count` share the budget.
    public func bytesPerWorker(count: Int) -> UInt64 { shareableBytes / UInt64(max(1, count)) }

    /// Free + inactive + purgeable + speculative pages (host_statistics64); nil when the call fails.
    static func availableMemoryBytes() -> UInt64? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            KalsmritikoshLog.app.error("WorkerBudget: host_statistics64 failed (\(result, privacy: .public)); using a quarter of physical memory")
            return nil
        }
        let page = UInt64(vm_kernel_page_size)
        let pages = UInt64(stats.free_count) + UInt64(stats.inactive_count) + UInt64(stats.purgeable_count)
            + UInt64(stats.speculative_count)
        return pages * page
    }
}
