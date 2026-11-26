//
//  AIStepCheckpoint.swift
//  Kalsmritikosh
//
//  Speed PERF-22 (owner 2026-11-23) — not tested yet. A per-item checkpoint for a multi-part AI action that produces a
//  file (translation, scan rescue): each finished part's text is kept in the rescue folder under a key of the input
//  (its SHA-256), so running the same action again after a failure sends only the parts still missing. Removed once the
//  action finished. Kept beside the output the action writes anyway (ScanRescue.folder), never elsewhere.
//

import Foundation
import CryptoKit
import os

nonisolated struct AIStepCheckpoint: Sendable {
    let folder: URL?

    /// `kind` names the action ("translate"); `input` is what the parts are cut from.
    init(kind: String, input: String) {
        let key = SHA256.hash(data: Data((kind + "\u{1F}" + input).utf8)).map { String(format: "%02x", $0) }.joined()
        var url: URL?
        do {
            let f = try ScanRescue.folder().appendingPathComponent(".parts", isDirectory: true).appendingPathComponent(key, isDirectory: true)
            try FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
            url = f
        } catch {
            KalsmritikoshLog.app.error("AI checkpoint: no folder (parts are not kept): \(error.localizedDescription, privacy: .private)")
        }
        folder = url
    }

    func kept(_ part: Int) -> String? {
        guard let f = folder?.appendingPathComponent("\(part).txt"), FileManager.default.fileExists(atPath: f.path) else { return nil }
        do { return try String(contentsOf: f, encoding: .utf8) } catch {
            KalsmritikoshLog.app.error("AI checkpoint: part \(part, privacy: .public) unreadable (read again): \(error.localizedDescription, privacy: .private)")
            return nil
        }
    }

    func keep(_ part: Int, _ text: String) {
        guard let f = folder?.appendingPathComponent("\(part).txt") else { return }
        do { try text.write(to: f, atomically: true, encoding: .utf8) } catch {
            KalsmritikoshLog.app.error("AI checkpoint: part \(part, privacy: .public) not kept: \(error.localizedDescription, privacy: .private)")
        }
    }

    func clear() {
        guard let folder else { return }
        do { try FileManager.default.removeItem(at: folder) } catch {
            KalsmritikoshLog.app.error("AI checkpoint: not removed: \(error.localizedDescription, privacy: .private)")
        }
    }
}
