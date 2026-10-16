//
//  OwnerLedgerProbeTests.swift
//  KalsmritikoshTests
//
//  W2-7 safety probe and tripwire — READ ONLY. Reports the state of the person's real ledger file (header
//  only, plus an immutable quick_check per candidate key) so a test-host boot that touched it
//  can be detected. Writes nothing; never stores a key. Result is attached as owner-ledger.txt.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Owner ledger probe (read only)")
struct OwnerLedgerProbeTests {
    @Test func reportOwnerLedgerState() {
        let url = DatabaseLocations.defaultDatabaseURL
        let fm = FileManager.default
        var lines: [String] = ["path: \(url.path)"]
        let state = LedgerFileState.of(url)
        lines.append("state: \(state)")
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int { lines.append("bytes: \(size)") }
        for side in ["-wal", "-shm", ".plaintext-pending", ".encrypting", ".plaintext-pending-wal"] {
            let p = side.hasPrefix("-") ? url.path + side : url.appendingPathExtension(String(side.dropFirst())).path
            lines.append("\(side): \(fm.fileExists(atPath: p) ? "present" : "absent")")
        }
        let testKey = LedgerKeychain.load()
        let personKey = LedgerKeychain.loadPersonKey()
        lines.append("test key present: \(testKey != nil); person key present: \(personKey != nil); same: \(testKey != nil && testKey == personKey)")
        if state == .encrypted {
            lines.append("opens with test key: \(testKey.map { Database.quickCheck(fileAt: url, key: $0) == nil } ?? false)")
            lines.append("opens with person key: \(personKey.map { Database.quickCheck(fileAt: url, key: $0) == nil } ?? false)")
        } else if state == .plaintext {
            lines.append("plaintext quick_check: \(Database.quickCheck(fileAt: url) ?? "ok")")
        }
        Attachment.record(lines.joined(separator: "\n") + "\n", named: "owner-ledger.txt")
        // Tripwire: an encrypted real ledger must open with the person's own key. If it does not,
        // something (a test-host boot, a test storing a key) has locked the person out.
        if state == .encrypted {
            #expect(personKey.map { Database.quickCheck(fileAt: url, key: $0) == nil } ?? false,
                    "the person's ledger is encrypted with a key the real app does not hold")
        }
    }
}
