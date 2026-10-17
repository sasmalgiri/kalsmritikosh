//
//  ImportReceiptWriter.swift
//  Kalsmritikosh
//
//  W1-3 — every user import ends in a receipt: one entry per file with its
//  content hash and size as recorded in the ledger, or the reason it could not
//  be imported. Sealed (hash chain) and signed (installation key) through the
//  same path as every other receipt, and kept beside the ledger in
//  Receipts/import-<date>.json.
//

import Foundation
import os

extension AppState {

    struct ImportOutcome: Sendable {
        let url: URL
        let error: String?
    }

    /// Write the receipt for one batch. Returns the file written, or nil when the
    /// module is off or nothing was attempted.
    @discardableResult
    func writeImportReceipt(_ outcomes: [ImportOutcome]) async -> URL? {
        guard ProductModuleFlags.isEnabled(.signedReceipts), !outcomes.isEmpty, let database else { return nil }
        var drafts: [ReceiptDraft] = []
        for o in outcomes {
            let row = try? await database.query(
                "SELECT content_hash, size_bytes, modified_at FROM files WHERE url = ? ORDER BY ingested_at DESC LIMIT 1;",
                [.text(o.url.absoluteString)]).first
            if let error = o.error {
                drafts.append(ReceiptDraft(claim: "Could not import", source: o.url.lastPathComponent,
                                           date: nil, passage: error))
            } else if let hash = row?.string(0) {
                let size = Int(row?.int(1) ?? 0)
                let modified = row?.double(2).map { Date(timeIntervalSince1970: $0) }
                drafts.append(ReceiptDraft(claim: "Imported", source: o.url.lastPathComponent,
                                           date: modified, passage: "sha256:\(hash) size:\(size)"))
            } else {
                drafts.append(ReceiptDraft(claim: "Imported (no content hash recorded)",
                                           source: o.url.lastPathComponent, date: nil, passage: o.url.path))
            }
        }
        let iso = ISO8601DateFormatter()
        let stamp = iso.string(from: Date())
        let sealed = VerifiableReceipt.seal(title: "Import receipt \(stamp) — \(outcomes.count) file(s)", drafts: drafts)
        let json = ReceiptSigner.exportJSON(sealed)
        do {
            let dir = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
                .appendingPathComponent("KalsmritikoshChronicaMemora/Receipts", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("import-\(stamp.replacingOccurrences(of: ":", with: "-")).json")
            try Data(json.utf8).write(to: url, options: .atomic)
            KalsmritikoshLog.app.info("Import receipt written: \(url.lastPathComponent, privacy: .public)")
            return url
        } catch {
            KalsmritikoshLog.app.error("Import receipt write failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
