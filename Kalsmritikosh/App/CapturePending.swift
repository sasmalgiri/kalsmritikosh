//
//  CapturePending.swift
//  Kalsmritikosh
//
//  Case plan 2026-11-16 (IN-13, IN-14) — field capture with confirmation before admission. A photo, a recording or a video
//  dropped into Capture waits in a pending inbox (the app's own container, beside the intake folder, never read as a
//  source) with a preview — the recognised text line by line with the image region each line came from, or the transcript
//  with each line's time — that the person corrects and selects from. Only "Add to archive" admits it: the ORIGINAL is
//  saved byte for byte into the intake folder with its custody line, and the corrected, selected text is saved beside it
//  as a separate file that says it is a correction (the original is never edited). Discarding admits nothing. The same
//  bytes are refused while pending or once admitted (no duplicate). Pending items survive a restart (a manifest on disk).
//  Nothing goes online: recognition and transcription run on this Mac.
//

import Foundation
import CryptoKit
import CoreGraphics
import os

nonisolated struct CapturePendingItem: Codable, Identifiable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable { case image, audio, video, other }
    enum State: String, Codable, Sendable { case pending, admitted, discarded }

    /// One line of the preview: what was recognised, where (image region, normalised, or the time in the recording), the
    /// person's correction (nil: as recognised) and whether it is kept.
    struct Line: Codable, Sendable, Equatable, Identifiable {
        var id: Int
        var recognised: String
        var confidence: Double
        /// "x,y,w,h" for an image region (normalised, origin bottom-left), "mm:ss–mm:ss" for a recording.
        var locator: String
        var corrected: String?
        var kept: Bool = true
        var text: String { corrected ?? recognised }
    }

    let id: UUID
    let name: String
    let kind: Kind
    let sha256: String
    let bytes: Int
    let origin: String
    let receivedAt: Date
    var state: State
    var lines: [Line]
    /// Why there is no preview (the recogniser could not run, or the format has none). nil when a preview was made.
    var previewNote: String?
    var decidedAt: Date?

    static func kind(of name: String) -> Kind {
        switch (name as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "gif", "bmp": return .image
        case "m4a", "mp3", "wav", "aiff", "aif", "caf", "aac", "flac": return .audio
        case "mov", "mp4", "m4v": return .video
        default: return .other
        }
    }
}

nonisolated enum CapturePendingError: Error, Equatable, LocalizedError {
    case duplicate(String)
    case notPending
    case nothingKept
    var errorDescription: String? {
        switch self {
        case .duplicate(let n): return "These exact bytes are already \(n) — nothing was added twice."
        case .notPending: return "This item is no longer waiting (it was added or discarded)."
        case .nothingKept: return "No line is kept; keep at least one, or add the original without text."
        }
    }
}

/// The pending inbox: a folder of originals and a manifest, beside the intake folder.
nonisolated struct CapturePendingInbox {
    let root: URL

    static var standard: CapturePendingInbox? {
        TestHost.applicationSupport().map { CapturePendingInbox(root: $0.appendingPathComponent("Kalsmritikosh/CapturePending", isDirectory: true)) }
    }

    private var manifest: URL { root.appendingPathComponent("pending.json") }
    func originalURL(_ item: CapturePendingItem) -> URL { root.appendingPathComponent(item.id.uuidString + "-" + item.name) }

    func items() -> [CapturePendingItem] {
        guard let data = try? Data(contentsOf: manifest) else { return [] }
        do { return try JSONDecoder().decode([CapturePendingItem].self, from: data) } catch {
            KalsmritikoshLog.app.error("Capture pending manifest unreadable: \(String(describing: type(of: error)), privacy: .public) \(error.localizedDescription, privacy: .private)")
            return []
        }
    }

    private func write(_ items: [CapturePendingItem]) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys, .prettyPrinted]
        try enc.encode(items).write(to: manifest, options: .atomic)
    }

    /// Put bytes in the inbox (pending). Refused when the same bytes are pending or were admitted.
    @discardableResult
    func receive(_ data: Data, name: String, origin: String, at date: Date = Date()) throws -> CapturePendingItem {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        var all = items()
        if let same = all.first(where: { $0.sha256 == digest && $0.state != .discarded }) {
            throw CapturePendingError.duplicate(same.state == .pending ? "waiting in Capture" : "in the archive")
        }
        let item = CapturePendingItem(id: UUID(), name: name.isEmpty ? "Captured" : name, kind: CapturePendingItem.kind(of: name), sha256: digest,
                                      bytes: data.count, origin: origin, receivedAt: date, state: .pending, lines: [], previewNote: nil)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try data.write(to: originalURL(item), options: .withoutOverwriting)
        all.append(item)
        try write(all)
        return item
    }

    /// Replace an item's preview (lines with their locators) or say why there is none.
    func setPreview(_ id: UUID, lines: [CapturePendingItem.Line], note: String?) throws {
        var all = items()
        guard let i = all.firstIndex(where: { $0.id == id && $0.state == .pending }) else { throw CapturePendingError.notPending }
        all[i].lines = lines; all[i].previewNote = note
        try write(all)
    }

    /// Correct one line, or keep / drop it.
    func edit(_ id: UUID, line: Int, corrected: String?, kept: Bool) throws {
        var all = items()
        guard let i = all.firstIndex(where: { $0.id == id && $0.state == .pending }), let j = all[i].lines.firstIndex(where: { $0.id == line }) else {
            throw CapturePendingError.notPending
        }
        let c = corrected?.trimmingCharacters(in: .whitespacesAndNewlines)
        all[i].lines[j].corrected = (c == nil || c == all[i].lines[j].recognised) ? nil : c
        all[i].lines[j].kept = kept
        try write(all)
    }

    /// The text kept for admission: every kept line (corrected where corrected) with its locator, and a list of what was
    /// corrected — saved beside the original, labelled as a correction.
    static func correctedText(_ item: CapturePendingItem) -> String {
        let kept = item.lines.filter(\.kept)
        var out = "Text checked by a person from \(item.name) (\(item.kind.rawValue)); the original file is kept unchanged beside this one.\n\n"
        out += kept.map { "[\($0.locator)] \($0.text)" }.joined(separator: "\n")
        let corrections = kept.filter { $0.corrected != nil }
        if !corrections.isEmpty {
            out += "\n\nCorrections (recognised → corrected):\n" + corrections.map { "[\($0.locator)] \($0.recognised) → \($0.text)" }.joined(separator: "\n")
        }
        let dropped = item.lines.count - kept.count
        if dropped > 0 { out += "\n\n\(dropped) recognised line(s) were left out by the person." }
        return out
    }

    /// Admit: the original into the intake folder (custody line), and the checked text beside it when there is any.
    /// `save` is CaptureIntake.save (injected for tests).
    @discardableResult
    func admit(_ id: UUID, at date: Date = Date(), save: (Data, String, String) throws -> URL) throws -> (original: URL, text: URL?) {
        var all = items()
        guard let i = all.firstIndex(where: { $0.id == id && $0.state == .pending }) else { throw CapturePendingError.notPending }
        let item = all[i]
        if !item.lines.isEmpty && !item.lines.contains(where: \.kept) { throw CapturePendingError.nothingKept }
        let data = try Data(contentsOf: originalURL(item))
        let original = try save(data, item.name, "capture (confirmed): \(item.origin)")
        var text: URL?
        if item.lines.contains(where: \.kept) {
            let stem = (item.name as NSString).deletingPathExtension
            text = try save(Data(Self.correctedText(item).utf8), stem + " — checked text.txt", "capture (checked text of \(item.name))")
        }
        all[i].state = .admitted; all[i].decidedAt = date
        try write(all)
        try? FileManager.default.removeItem(at: originalURL(item))
        return (original, text)
    }

    /// Discard: nothing is admitted; the pending copy is removed.
    func discard(_ id: UUID, at date: Date = Date()) throws {
        var all = items()
        guard let i = all.firstIndex(where: { $0.id == id && $0.state == .pending }) else { throw CapturePendingError.notPending }
        try? FileManager.default.removeItem(at: originalURL(all[i]))
        all[i].state = .discarded; all[i].decidedAt = date
        try write(all)
    }
}

/// The preview, made on this Mac: recognised text lines with their image regions, or transcript lines with their times.
nonisolated enum CapturePreview {
    static func lines(fromOCR ocr: [OCRLine]) -> [CapturePendingItem.Line] {
        ocr.enumerated().map { i, l in
            let b = l.boundingBox
            return CapturePendingItem.Line(id: i, recognised: l.text, confidence: Double(l.confidence),
                                           locator: String(format: "region %.2f,%.2f,%.2f,%.2f", b.origin.x, b.origin.y, b.width, b.height))
        }
    }

    static func lines(fromTranscript segments: [ASRSegment]) -> [CapturePendingItem.Line] {
        segments.enumerated().map { i, s in
            CapturePendingItem.Line(id: i, recognised: s.text, confidence: s.confidence,
                                    locator: bare(ASRSegment.timecode(s.start)) + "–" + bare(ASRSegment.timecode(s.end)))
        }
    }

    /// A timecode without its brackets ("[00:12]" → "00:12"); the locator is bracketed once where it is printed.
    static func bare(_ t: String) -> String { t.trimmingCharacters(in: CharacterSet(charactersIn: "[]")) }

    /// Make the preview for a pending item (nil lines + a note when the recogniser cannot run or the format has none).
    static func make(_ item: CapturePendingItem, at url: URL) async -> (lines: [CapturePendingItem.Line], note: String?) {
        switch item.kind {
        case .image:
            let ocr = await VisionOCR().recognizeLines(at: url)
            return ocr.isEmpty ? ([], "No text was recognised in this image; you can still add the original.") : (lines(fromOCR: ocr), nil)
        case .audio, .video:
            do {
                let segs = try await SpeechTranscriber().transcribeSegments(audioAt: url)
                return segs.isEmpty ? ([], "No speech was transcribed; you can still add the original.") : (lines(fromTranscript: segs), nil)
            } catch {
                KalsmritikoshLog.app.error("Capture transcript failed: \(error.localizedDescription, privacy: .private)")
                return ([], "The recording could not be transcribed on this Mac (\(error.localizedDescription)); you can still add the original.")
            }
        case .other:
            return ([], "This kind of file has no preview; it is added as it is.")
        }
    }
}
