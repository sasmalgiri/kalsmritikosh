//
//  CitedSourceResolver.swift
//  Kalsmritikosh
//
//  SRC-01 / SRC-08 — open the CITED version of a source, never silently a newer one. A citation pins a
//  source version (its content hash). The document's file on disk is whatever is there now: it may have
//  been replaced by a newer version (re-ingested: the cited version is superseded) or edited since it
//  was read (not yet re-ingested). Opening "the object's file" would then show different words under
//  the citation. This resolver opens:
//    • the vault's kept copy of the cited version, when there is one (labelled "A newer version exists"
//      when the cited version is no longer current);
//    • the file on disk only when its bytes ARE the cited version (SHA-256 equal to the version's hash);
//  and otherwise says why the cited version is unavailable — superseded, changed on disk, missing, erased
//  or access denied — so the caller shows the cited passage from the ledger with that label instead.
//
//  S2 (2026-11-08) — EVERY citation opener goes through here (Ask chips, case file, contradictions, history,
//  fund flow, drafts, case search, map; UI helper `CitedSourceOpening`). A citation that names only a
//  document (no version) is pinned to the version that document was read from (its passages' version), so
//  it too opens that version or is labelled — never the newer file silently. The vault is passed in (it
//  holds the key for sealed copies, IN-02).
//

import Foundation
import CryptoKit
import os

public nonisolated enum CitedSourceResolver {

    public enum Unavailable: Equatable, Sendable {
        /// The version record is gone (erased).
        case erased
        /// A newer version replaced it and the cited bytes were not kept.
        case superseded
        /// The file on disk is no longer the cited bytes (edited or replaced since it was read).
        case changedOnDisk
        /// The file is not where it was, and no copy was kept.
        case missingOriginal
        /// The file is there but this Mac refuses to let the app read it (permissions / sandbox access lost).
        case accessDenied

        public var label: String {
            switch self {
            case .erased: return "Cited version unavailable: it was erased. Only what the ledger still holds is shown."
            case .superseded: return "Cited version unavailable: a newer version of this document exists and the cited version's file was not kept. The cited passage is shown from the ledger, not the newer document."
            case .changedOnDisk: return "Cited version unavailable: the file has changed since it was cited, so it is not opened in its place. The cited passage is shown from the ledger."
            case .missingOriginal: return "Cited version unavailable: the original file is missing and no copy was kept. The cited passage is shown from the ledger."
            case .accessDenied: return "Cited version unavailable: this Mac does not let the app read the file now (access was removed or the folder is no longer shared with the app). Add the folder again to restore access. The cited passage is shown from the ledger."
            }
        }
    }

    public enum Outcome: Equatable, Sendable {
        /// Open this file; `note` labels it (nil: the current file, verified to be the cited version).
        case open(URL, note: String?)
        case unavailable(Unavailable)
    }

    public static let newerVersionNote = "A newer version exists. This is the cited version (the copy kept when it was read)."
    public static let unpinnedNote = "This citation does not record which version it cites; the document's current file is shown."
    public static let unverifiableNote = "This version was recorded before content hashes; it could not be confirmed that the file is unchanged since it was cited."

    /// Resolve what to open for a citation of `sourceVersionID` (falling back to `objectID`'s file only
    /// when the citation pins no version, and saying so).
    public static func resolve(sourceVersionID: UUID?, objectID: UUID?, database: Database, ledgerURL: URL,
                               vault suppliedVault: EvidenceVault? = nil) async throws -> Outcome {
        var pinned = sourceVersionID
        if pinned == nil, let object = objectID { pinned = try await readVersion(objectID: object, database: database) }
        guard let version = pinned else {
            guard let object = objectID, let url = try await fileURL(objectID: object, database: database) else { return .unavailable(.missingOriginal) }
            guard FileManager.default.fileExists(atPath: url.path) else { return .unavailable(.missingOriginal) }
            return FileManager.default.isReadableFile(atPath: url.path) ? .open(url, note: unpinnedNote) : .unavailable(.accessDenied)
        }
        guard let row = try await database.query("""
            SELECT lower(content_hash), is_current, original_url, vault_address, filename FROM source_versions WHERE id = ?;
            """, [.uuid(version)]).first, let hash = row.string(0) else {
            return .unavailable(.erased)
        }
        let isCurrent = (row.int(1) ?? 1) == 1
        // 1. The kept copy of exactly these bytes.
        let vault = suppliedVault ?? EvidenceVault(root: ledgerURL.deletingLastPathComponent().appendingPathComponent("EvidenceVault", isDirectory: true))
        for address in [row.string(3), hash].compactMap({ $0 }) where !address.isEmpty {
            if let copy = await vault.url(for: address.lowercased(), filename: row.string(4)) { return .open(copy, note: isCurrent ? nil : newerVersionNote) }
        }
        // 2. Superseded and not kept: never the newer document in its place.
        guard isCurrent else { return .unavailable(.superseded) }
        // 3. The current version: the file on disk, only if its bytes are the cited ones.
        var candidate = row.string(2).flatMap(parseURL)
        if candidate == nil, let object = objectID { candidate = try await fileURL(objectID: object, database: database) }
        guard let url = candidate, FileManager.default.fileExists(atPath: url.path) else { return .unavailable(.missingOriginal) }
        guard FileManager.default.isReadableFile(atPath: url.path) else { return .unavailable(.accessDenied) }
        guard hash.count == 64, hash.allSatisfy(\.isHexDigit) else { return .open(url, note: unverifiableNote) }
        let onDisk: String
        do {
            onDisk = try await Task.detached(priority: .userInitiated) { try sha256(of: url) }.value
        } catch let error as CocoaError where error.code == .fileReadNoPermission {
            KalsmritikoshLog.ui.error("Cited source: read refused: \(error.localizedDescription, privacy: .public)")
            return .unavailable(.accessDenied)
        }
        return onDisk == hash ? .open(url, note: nil) : .unavailable(.changedOnDisk)
    }

    // MARK: - S14 (SRC-08): a cited place the viewer cannot show

    /// The label for a citation whose locator points at a place the source viewer cannot show (it shows PDF pages and
    /// text ranges): a spreadsheet cell, an image region, an audio/video time, a slide or a database row. The document
    /// then opens at its start, or the cited passage is shown from the ledger — never a different place silently.
    /// Nil when the locator is one the viewer can show, or carries no place at all.
    public static func unsupportedLocatorNote(_ l: SourceLocator) -> String? { unsupportedLocatorNote(l, fileExtension: nil) }

    /// S14 part 3 (SRC-01) — as above, for the file that actually opens: a recording opens AT the cited time and an image
    /// shows the cited region outlined (Vision's 0–1 box), so those places are no longer listed as "not shown" for them.
    /// Sheets, cells, slides, database rows and pixel-unit regions still are.
    public static func unsupportedLocatorNote(_ l: SourceLocator, fileExtension: String?) -> String? {
        let ext = fileExtension?.lowercased()
        var place: [String] = []
        if let sheet = l.sheet { place.append("sheet “\(sheet)”") }
        if let cells = l.cellRange { place.append("cells \(cells)") }
        else if let column = l.column, let row = l.row { place.append("cell \(column)\(row)") }
        else if let row = l.row, l.tableID != nil || l.sheet != nil { place.append("row \(row)") }
        if l.boundingBox?.isEmpty == false, l.page == nil, !(ext.map(imageExtensions.contains) ?? false && normalisedBox(l.boundingBox) != nil) {
            place.append("a region of the image")
        }
        if let start = l.transcriptStart, !(ext.map(recordingExtensions.contains) ?? false) {
            place.append("the recording at \(timecode(start))" + (l.transcriptEnd.map { "–\(timecode($0))" } ?? ""))
        }
        if let slide = l.slide { place.append("slide \(slide)") }
        if let key = l.databaseRowKey { place.append("database row \(key)") }
        guard !place.isEmpty else { return nil }
        return "Cited place not shown: the citation points at \(place.joined(separator: ", ")), which this viewer cannot go to. The document opens at its start; find the place by the cited words."
    }

    /// S14 part 3 (SRC-01) — a cited place the source viewer goes to for this kind of file.
    public enum CitedPlace: Hashable, Sendable {
        /// A PDF page (1-based).
        case page(Int)
        /// A time in a recording (seconds), opened there.
        case recordingTime(start: Double, end: Double?)
        /// A region of an image, Vision's normalised box (0–1, origin bottom-left), outlined.
        case imageRegion(x: Double, y: Double, width: Double, height: Double)
    }

    public static let recordingExtensions: Set<String> = ["mp3", "m4a", "wav", "aif", "aiff", "aac", "caf", "mp4", "mov", "m4v"]
    public static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "gif", "bmp", "webp"]

    /// The place to open `l` at in a file with this extension, nil when the viewer cannot go there for that file
    /// (then `unsupportedLocatorNote(_:fileExtension:)` names it).
    public static func showablePlace(_ l: SourceLocator, fileExtension: String) -> CitedPlace? {
        let ext = fileExtension.lowercased()
        if recordingExtensions.contains(ext), let start = l.transcriptStart, start.isFinite, start >= 0 {
            let end = l.transcriptEnd.flatMap { $0.isFinite && $0 > start ? $0 : nil }
            return .recordingTime(start: start, end: end)
        }
        if imageExtensions.contains(ext), l.page == nil, let box = normalisedBox(l.boundingBox) {
            return .imageRegion(x: box[0], y: box[1], width: box[2], height: box[3])
        }
        if ext == "pdf", let page = l.page, page >= 1 { return .page(page) }
        return nil
    }

    /// A box usable as Vision's normalised rectangle: four finite numbers inside 0…1 with a positive size.
    static func normalisedBox(_ box: [Double]?) -> [Double]? {
        guard let b = box, b.count == 4, b.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }), b[2] > 0, b[3] > 0,
              b[0] + b[2] <= 1.000_001, b[1] + b[3] <= 1.000_001 else { return nil }
        return b
    }

    /// S14 part 3 (SRC-01) — what a passage pins: the version and evidence block it was read from, and its own words.
    public struct PassagePin: Equatable, Sendable {
        public let sourceVersionID: UUID?
        public let blockID: UUID?
        /// The passage's words (at most 400 characters), nil when the passage is gone.
        public let quote: String?
    }

    /// The pin of a stored passage (chunk); all nil when the passage is gone (erased or re-read).
    public static func chunkPin(chunkID: UUID, database: Database) async throws -> PassagePin {
        guard let row = try await database.query("SELECT source_version_id, evidence_block_id, text FROM chunks WHERE id = ? LIMIT 1;",
                                                 [.uuid(chunkID)]).first else {
            return PassagePin(sourceVersionID: nil, blockID: nil, quote: nil)
        }
        let text = row.string(2)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return PassagePin(sourceVersionID: row.uuid(0), blockID: row.uuid(1), quote: (text?.isEmpty ?? true) ? nil : text.map { String($0.prefix(400)) })
    }

    /// The locator of a cited passage (its evidence block), nil when the block is gone or records none.
    public static func locator(blockID: UUID, database: Database) async throws -> SourceLocator? {
        guard let json = try await database.query("SELECT locator FROM evidence_blocks WHERE id = ? LIMIT 1;", [.uuid(blockID)]).first?.string(0),
              let data = json.data(using: .utf8) else { return nil }
        do { return try JSONDecoder().decode(SourceLocator.self, from: data) } catch {
            KalsmritikoshLog.ui.error("Cited source: locator unreadable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    static func timecode(_ seconds: Double) -> String {
        let t = max(0, Int(seconds.rounded(.down)))
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }

    /// The version a document was READ from: the source version its passages carry (the most passages, if a
    /// document somehow spans several). nil for a document recorded before source versions existed.
    static func readVersion(objectID: UUID, database: Database) async throws -> UUID? {
        if let v = try await database.query("""
            SELECT source_version_id FROM chunks WHERE object_id = ? AND source_version_id IS NOT NULL
            GROUP BY source_version_id ORDER BY COUNT(*) DESC LIMIT 1;
            """, [.uuid(objectID)]).first?.uuid(0) { return v }
        return try await database.query("""
            SELECT b.source_version_id FROM evidence_block_objects o JOIN evidence_blocks b ON b.id = o.evidence_block_id
            WHERE o.knowledge_object_id = ? AND b.source_version_id IS NOT NULL
            GROUP BY b.source_version_id ORDER BY COUNT(*) DESC LIMIT 1;
            """, [.uuid(objectID)]).first?.uuid(0)
    }

    static func fileURL(objectID: UUID, database: Database) async throws -> URL? {
        try await database.query("SELECT f.url FROM knowledge_objects k JOIN files f ON f.id = k.file_id WHERE k.id = ? LIMIT 1;",
                                 [.uuid(objectID)]).first?.string(0).flatMap(parseURL)
    }

    static func parseURL(_ s: String) -> URL? {
        if let u = URL(string: s), u.scheme != nil { return u.isFileURL ? u : nil }
        return URL(fileURLWithPath: s)
    }

    /// SHA-256 of a file, streamed (lowercase hex).
    static func sha256(of url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
