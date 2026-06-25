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
    case mbox, pst, eml, msg, appleMail

    // Images
    case png, jpg, heic, tiff, webp

    // Audio
    case mp3, wav, m4a, aac

    // Video
    case mp4, mov

    // Archives
    case zip, rar, sevenZip

    // Fallback
    case unknown

    /// Best-effort detection from a file URL.
    public nonisolated static func detect(from url: URL) -> SourceType {
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
        case "png": return .png
        case "jpg", "jpeg": return .jpg
        case "heic": return .heic
        case "tiff", "tif": return .tiff
        case "webp": return .webp
        case "mp3": return .mp3
        case "wav": return .wav
        case "m4a": return .m4a
        case "aac": return .aac
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
        case .mbox, .pst, .eml, .msg, .appleMail: return .email
        case .png, .jpg, .heic, .tiff, .webp: return .image
        case .mp3, .wav, .m4a, .aac: return .audio
        case .mp4, .mov: return .video
        case .zip, .rar, .sevenZip: return .archive
        case .unknown: return .unknown
        }
    }

    public enum Category: String, Codable, Sendable {
        case document, spreadsheet, presentation, email, image, audio, video, archive, unknown
    }
}
