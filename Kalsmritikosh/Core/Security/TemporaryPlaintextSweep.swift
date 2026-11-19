//
//  TemporaryPlaintextSweep.swift
//  Kalsmritikosh
//
//  Smart-map S16 (SEC-03) — plaintext working copies the app writes to its temporary folder are removed when the work is
//  done (`defer`), but a crash, a forced quit or a hand-off to another app leaves some behind: the exact-original copy
//  opened from the provenance chain (`original-*`, never removed before this), the DEVONthink hand-off file
//  (`kalsmritikosh-devonthink`), page renders for text recognition, unlock and capture scratch, and intake / backup scratch.
//  At launch every such item OLDER than `minimumAge` is removed (younger ones may belong to work still running in this
//  process, or to a test running beside it). Only names this app creates are touched; nothing else in the folder is.
//  docs/STORAGE_KEY_INVENTORY.md lists every store; StorageInventoryTests checks this list against it.
//

import Foundation
import os

public nonisolated enum TemporaryPlaintextSweep {
    /// Name prefixes of the app's own temporary plaintext (files or folders directly inside the temporary folder).
    public static let prefixes: [String] = [
        "original-", "kalsmritikosh-devonthink", "kalsmritikosh-pdfpage-", "unlock-", "capture-", "usf-intake-snapshot",
        "usf-upgrade-reopen", "usfm2-expand-", "usfm2-7z-", "kalsmritikosh-cbackup-", "kalsmritikosh-backup-", "kalsnap-",
    ]
    public static let minimumAge: TimeInterval = 3600

    /// Remove leftovers in `folder` (the temporary folder by default); returns how many items were removed.
    @discardableResult
    public static func run(in folder: URL = FileManager.default.temporaryDirectory, now: Date = Date(),
                           minimumAge: TimeInterval = minimumAge) -> Int {
        let fm = FileManager.default
        let items: [URL]
        do {
            items = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey], options: [])
        } catch {
            KalsmritikoshLog.app.notice("Temporary sweep: the temporary folder could not be listed: \(String(describing: type(of: error)), privacy: .public)")
            return 0
        }
        var removed = 0
        for url in items where prefixes.contains(where: { url.lastPathComponent.hasPrefix($0) }) {
            let modified: Date
            do { modified = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? now } catch {
                KalsmritikoshLog.app.notice("Temporary sweep: an item's age could not be read: \(String(describing: type(of: error)), privacy: .public)")
                continue
            }
            guard now.timeIntervalSince(modified) >= minimumAge else { continue }
            do {
                // Read-only copies (0444 / 0400) inside a folder are made writable first so the folder can go.
                if let walker = fm.enumerator(at: url, includingPropertiesForKeys: nil) {
                    for case let inner as URL in walker {
                        do { try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: inner.path) } catch {
                            KalsmritikoshLog.app.notice("Temporary sweep: permissions not changed: \(String(describing: type(of: error)), privacy: .public)")
                        }
                    }
                }
                try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
                try fm.removeItem(at: url)
                removed += 1
            } catch {
                KalsmritikoshLog.app.notice("Temporary sweep: a leftover could not be removed: \(String(describing: type(of: error)), privacy: .public)")
            }
        }
        return removed
    }
}
