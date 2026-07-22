//
//  SourceType.swift
//  Kalsmritikosh
//
//  The kinds of source files the system can ingest. Used by every
//  KnowledgeObject so downstream layers never need to inspect the
//  raw file to know what they're dealing with.
//

import Foundation

public enum SourceType: String, Codable, CaseIterable, Sendable {
    // Documents
    case pdf, docx, doc, txt, markdown, rtf, odt, epub

    // PAR-008 — structured text: web/data/config/log formats with a
    // deterministic structure we can parse into typed blocks.
    case html, json, xml, log

    // Spreadsheets
    case xlsx, xls, csv, ods

    // Presentations
    case pptx, ppt, keynote

    // Email
    case mbox, pst, eml, msg, appleMail, nsf

    // Images
    case png, jpg, heic, tiff, webp

    // Audio — mp3/wav/m4a/aac plus mobile/voice-note containers that
    // AVFoundation decodes natively (aiff, caf, flac, AAC-in-3GP).
    case mp3, wav, m4a, aac, aiff, caf, flac, threegp

    // Video
    case mp4, mov

    // Archives
    case zip, rar, sevenZip

    // Phase K — chat + browser ingest. Each maps to a dedicated
    // loader that knows how to read the source's schema (SQLite for
    // imessage / browser history; structured text for chat exports).
    case imessage
    case safariHistory
    case chromeHistory
    case chatExport

    // Fallback
    case unknown

    /// Best-effort detection from a file URL.
    public nonisolated static func detect(from url: URL) -> SourceType {
        // Phase K — pattern-based detection for sources whose
        // canonical filename / location is meaningful (chat.db lives
        // at ~/Library/Messages/chat.db; History.db is Safari;
        // bare "History" is Chrome's profile DB).
        let name = url.lastPathComponent.lowercased()
        let path = url.path.lowercased()
        if name == "chat.db"
            || path.contains("/library/messages/") {
            return .imessage
        }
        if name == "history.db"
            || path.contains("/library/safari/history") {
            return .safariHistory
        }
        if name == "history"
            && (path.contains("/google/chrome/")
                || path.contains("/brave-browser/")
                || path.contains("/microsoft/edge/")
                || path.contains("/arc/user data/")) {
            return .chromeHistory
        }
        if name.hasPrefix("whatsapp chat ")
            || name.hasPrefix("_chat ")
            || name.contains("signal-")
            || name.contains("slack-export") {
            return .chatExport
        }
        switch url.pathExtension.lowercased() {
        case "pdf": return .pdf
        case "docx": return .docx
        case "doc": return .doc
        case "txt": return .txt
        case "md", "markdown": return .markdown
        case "rtf": return .rtf
        case "odt": return .odt
        case "epub": return .epub
        case "html", "htm", "xhtml": return .html
        case "json", "jsonl", "ndjson": return .json
        case "xml", "plist": return .xml
        case "log": return .log
        case "xlsx": return .xlsx
        case "xls": return .xls
        case "csv": return .csv
        case "ods": return .ods
        case "pptx": return .pptx
        case "ppt": return .ppt
        case "key": return .keynote
        case "mbox": return .mbox
        case "pst": return .pst
        case "eml": return .eml
        case "msg": return .msg
        case "emlx": return .appleMail
        case "nsf": return .nsf
        case "png": return .png
        case "jpg", "jpeg": return .jpg
        case "heic": return .heic
        case "tiff", "tif": return .tiff
        case "webp": return .webp
        case "mp3": return .mp3
        case "wav": return .wav
        case "m4a": return .m4a
        case "aac": return .aac
        case "aiff", "aif", "aifc": return .aiff
        case "caf": return .caf
        case "flac": return .flac
        case "3gp", "3gpp": return .threegp
        case "mp4": return .mp4
        case "mov": return .mov
        case "zip": return .zip
        case "rar": return .rar
        case "7z": return .sevenZip
        default: return .unknown
        }
    }

    /// Content-based fallback for when the filename has no (or an unknown)
    /// extension — reads leading magic bytes. Used by the ingest path only when
    /// `detect(from:)` returns `.unknown` (e.g. an email attachment named as a
    /// bare hash). OLE2 (.doc/.xls/.ppt) is intentionally NOT sniffed here —
    /// magic bytes can't tell those apart without parsing the CFB directory, so
    /// we leave them to the MIME-type mapping rather than risk mis-routing.
    public nonisolated static func sniffMagicBytes(_ data: Data) -> SourceType? {
        let b = [UInt8](data.prefix(16))
        guard b.count >= 4 else { return nil }
        func has(_ sig: [UInt8]) -> Bool { b.count >= sig.count && Array(b.prefix(sig.count)) == sig }
        if has([0xFF, 0xD8, 0xFF]) { return .jpg }
        if has([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return .png }
        if has([0x25, 0x50, 0x44, 0x46]) { return .pdf }                       // %PDF
        if has([0x49, 0x49, 0x2A, 0x00]) || has([0x4D, 0x4D, 0x00, 0x2A]) { return .tiff }
        if has([0x52, 0x49, 0x46, 0x46]), b.count >= 12,
           Array(b[8..<12]) == [0x57, 0x45, 0x42, 0x50] { return .webp }        // RIFF....WEBP
        // ZIP container (also docx/xlsx/pptx/epub) — route to the archive path,
        // which expands members and types each one individually.
        if has([0x50, 0x4B, 0x03, 0x04]) { return .zip }
        return nil
    }

    public nonisolated var category: Category {
        switch self {
        case .pdf, .docx, .doc, .txt, .markdown, .rtf, .odt, .epub,
             .html, .json, .xml, .log: return .document
        case .xlsx, .xls, .csv, .ods: return .spreadsheet
        case .pptx, .ppt, .keynote: return .presentation
        case .mbox, .pst, .eml, .msg, .appleMail, .nsf: return .email
        case .png, .jpg, .heic, .tiff, .webp: return .image
        case .mp3, .wav, .m4a, .aac, .aiff, .caf, .flac, .threegp: return .audio
        case .mp4, .mov: return .video
        case .zip, .rar, .sevenZip: return .archive
        case .imessage, .chatExport: return .chat
        case .safariHistory, .chromeHistory: return .browserHistory
        case .unknown: return .unknown
        }
    }

    public enum Category: String, Codable, Sendable {
        case document, spreadsheet, presentation, email, image, audio, video,
             archive, chat, browserHistory, unknown
    }
}
