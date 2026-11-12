//
//  TestScratchSweep.swift
//  KalsmritikoshTests
//
//  Disk hygiene for local runs (memory: temp-test-scratch-leak). Test rigs make throwaway ledgers in the SANDBOXED test
//  host's temporary folder with a `defer { removeItem }` that never runs when a run is killed (time limit, disk full).
//  That folder is the app container's tmp, which a shell cannot read (macOS app-data protection), so only the test host
//  can sweep it. This removes entries older than 30 minutes (a live run's scratch is younger) and reports what it freed.
//  It never runs on CI (fresh runners) and never touches anything outside the host's own temporary folder.
//

import Foundation
import Testing

@Suite("Test scratch sweep (local disk hygiene)")
struct TestScratchSweep {
    @Test("Remove test scratch older than 30 minutes from the test host's temporary folder", .enabled(if: ProcessInfo.processInfo.environment["CI"] == nil))
    func sweep() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
        let cutoff = Date().addingTimeInterval(-30 * 60)
        var removed = 0, bytes: Int64 = 0
        for url in (try? fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: [.contentModificationDateKey, .totalFileAllocatedSizeKey])) ?? [] {
            guard url.lastPathComponent != "TemporaryItems" else { continue }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            guard modified < cutoff else { continue }
            if let e = fm.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) {
                for case let f as URL in e { bytes += Int64((try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0) }
            }
            bytes += Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
            if (try? fm.removeItem(at: url)) != nil { removed += 1 }
        }
        print("TestScratchSweep: removed \(removed) item(s), \(bytes / 1_048_576) MiB, from \(tmp.path)")
    }
}
