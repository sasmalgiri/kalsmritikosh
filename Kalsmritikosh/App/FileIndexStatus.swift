//
//  FileIndexStatus.swift
//  Kalsmritikosh
//
//  U-3.6 (W-6) — every file in the Sources list carries an explicit,
//  honest status so the user never sees a document sitting there with no
//  account of what happened to it. Derived deterministically from the
//  file's SourceType and what ingestion actually produced (chunks / text /
//  expanded members). Pure.
//

import Foundation

public enum FileIndexStatus: String, Sendable, Equatable {
    /// Text was read and chunked — fully searchable.
    case indexed
    /// A scanned/photographed source read via OCR — searchable, but the
    /// text is only as good as the scan (surfaced with OCR confidence).
    case limitedScan
    /// Audio/video that produced a transcript.
    case transcribed
    /// Audio/video with no transcript yet (or transcription off).
    case notTranscribed
    /// An archive whose members were extracted and ingested.
    case expanded
    /// An archive that has not been expanded.
    case notExpanded
    /// A recognized file the app cannot read into text (no loader yields
    /// content for it) — listed honestly, not hidden.
    case unsupported

    public var label: String {
        switch self {
        case .indexed:        return "Indexed"
        case .limitedScan:    return "Limited scan"
        case .transcribed:    return "Transcribed"
        case .notTranscribed: return "Not transcribed"
        case .expanded:       return "Expanded"
        case .notExpanded:    return "Not expanded"
        case .unsupported:    return "Unsupported"
        }
    }

    /// Classify from the source type and ingestion outcome.
    /// - chunkCount: chunks produced from this file (searchable units).
    /// - expandedMemberCount: for archives, how many members were extracted.
    public nonisolated static func classify(
        sourceType: SourceType,
        chunkCount: Int,
        expandedMemberCount: Int = 0
    ) -> FileIndexStatus {
        switch category(of: sourceType) {
        case .archive:
            return expandedMemberCount > 0 ? .expanded : .notExpanded
        case .audioVideo:
            return chunkCount > 0 ? .transcribed : .notTranscribed
        case .image:
            return chunkCount > 0 ? .limitedScan : .unsupported
        case .textLike:
            return chunkCount > 0 ? .indexed : .unsupported
        case .unknown:
            // An unknown-type file that nonetheless yielded text (a
            // mislabeled .txt) is indexed; otherwise honestly unsupported.
            return chunkCount > 0 ? .indexed : .unsupported
        }
    }

    // MARK: - Categories

    enum Category { case textLike, image, audioVideo, archive, unknown }

    nonisolated static func category(of t: SourceType) -> Category {
        switch t {
        case .pdf, .docx, .doc, .txt, .markdown, .rtf, .odt, .epub,
             .html, .json, .xml, .log, .sqlite, .plist, .registryHive,
             .xlsx, .xls, .csv, .ods, .pptx, .ppt, .keynote,
             .mbox, .pst, .eml, .msg, .appleMail, .nsf,
             .imessage, .safariHistory, .chromeHistory, .chatExport:
            return .textLike
        case .png, .jpg, .heic, .tiff, .webp:
            return .image
        case .mp3, .wav, .m4a, .aac, .aiff, .caf, .flac, .threegp, .mp4, .mov:
            return .audioVideo
        case .zip, .rar, .sevenZip:
            return .archive
        case .unknown:
            return .unknown
        }
    }
}
