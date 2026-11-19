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
    /// Whether this is a CI runner. The test host does not inherit `CI` from xcodebuild (only TEST_RUNNER_-prefixed variables
    /// reach it), so the runner's home folder is checked too. Found 2026-11-19: on CI the sweep ran and removed the
    /// verifier's fixture once it was 30 minutes old, failing the kalverify step of run 44378133847.
    static var onCI: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["CI"] != nil || env["TEST_RUNNER_CI"] != nil || env["GITHUB_ACTIONS"] != nil || NSHomeDirectory().hasPrefix("/Users/runner")
    }

    @Test("Remove test scratch older than 30 minutes from the test host's temporary folder", .enabled(if: !TestScratchSweep.onCI))
    func sweep() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
        let cutoff = Date().addingTimeInterval(-30 * 60)
        var removed = 0, bytes: Int64 = 0
        for url in (try? fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: [.contentModificationDateKey, .totalFileAllocatedSizeKey])) ?? [] {
            guard url.lastPathComponent != "TemporaryItems" else { continue }
            // The verifier's fixture outlives the run on purpose (the build script reads it afterwards).
            guard !url.lastPathComponent.hasPrefix("kalverify-") else { continue }
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
