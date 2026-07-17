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

    public nonisolated var category: Category {
        switch self {
        case .pdf, .docx, .doc, .txt, .markdown, .rtf, .odt, .epub: return .document
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
