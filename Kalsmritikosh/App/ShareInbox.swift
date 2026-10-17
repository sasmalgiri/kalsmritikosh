//
//  ShareInbox.swift
//  Kalsmritikosh
//
//  W3-6 — the app side of the Share extension (KalsmritikoshShare). The extension
//  drops each shared item into the app group's Inbox/<stamp>-<uuid>/ (payload file +
//  item.json with the SHA-256 it computed); this moves every complete item into the
//  capture intake through CaptureIntake.save, so it gets the same custody line as a
//  dropped file, plus when and from where it was shared.
//
//  An inbox copy is removed only after the intake copy is saved AND its SHA-256
//  equals the one the extension recorded — the inbox is a hand-over point, the
//  intake copy is the kept one. An item whose bytes no longer match is left where
//  it is and reported, never imported.
//

import AppKit
import os

nonisolated enum ShareInbox {
    static let appGroup = "6TPTCJD42Q.ecosanskritiinnovation.Kalsmritikosh"
    static let inboxFolder = "Inbox"
    static let itemFile = "item.json"
    /// The extension reads this to know whether "Share and capture" is on.
    static let enabledKey = "kalsmritikosh.share.enabled"

    static var inbox: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent(inboxFolder, isDirectory: true)
    }

    /// Copy the module switch where the extension can read it.
    static func mirrorSwitch() {
        UserDefaults(suiteName: appGroup)?.set(ProductModuleFlags.isEnabled(.captureExtensions), forKey: enabledKey)
    }

    struct Result: Sendable, Equatable {
        var moved = 0
        var refused: [String] = []      // item folder names left in the inbox, with the reason
    }

    /// Move every complete item (folders whose name does not start with ".") into the intake.
    /// `save` is CaptureIntake.save in the app; tests pass their own.
    static func drain(_ inbox: URL,
                      save: (Data, String, String) throws -> CaptureIntake.Saved = CaptureIntake.save) -> Result {
        var result = Result()
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: inbox, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return result
        }
        for dir in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let tag = dir.lastPathComponent
            guard let metaData = try? Data(contentsOf: dir.appendingPathComponent(itemFile)),
                  let meta = try? JSONSerialization.jsonObject(with: metaData) as? [String: String],
                  let name = meta["name"], let expected = meta["sha256"] else {
                result.refused.append("\(tag): no item record"); continue
            }
            let payload = dir.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: payload) else { result.refused.append("\(tag): payload missing"); continue }
            guard CaptureIntake.sha256(data) == expected else {
                result.refused.append("\(tag): bytes do not match the SHA-256 recorded when shared"); continue
            }
            let origin = "\(meta["origin"] ?? "Share menu") — shared \(meta["sharedAt"] ?? "?")" + (meta["kind"].map { " (\($0))" } ?? "")
            do {
                let saved = try save(data, name, origin)
                guard saved.sha256 == expected else { result.refused.append("\(tag): intake copy did not verify"); continue }
                try fm.removeItem(at: dir)
                result.moved += 1
            } catch {
                KalsmritikoshLog.app.error("Share inbox item failed: \(error.localizedDescription, privacy: .public)")
                result.refused.append("\(tag): \(error.localizedDescription)")
            }
        }
        return result
    }
}

extension AppState {
    /// Drain the Share inbox (when the module is on) and read the intake.
    func receiveSharedItems() async {
        ShareInbox.mirrorSwitch()
        // Items wait in the inbox until the ledger is open, so a drain never outruns the read.
        guard database != nil, ProductModuleFlags.isEnabled(.captureExtensions), let inbox = ShareInbox.inbox else { return }
        let r = await Task.detached { ShareInbox.drain(inbox) }.value
        for line in r.refused { KalsmritikoshLog.app.notice("Share inbox kept: \(line, privacy: .private)") }
        if r.moved > 0 { _ = await readCaptureIntake() }
    }
}
