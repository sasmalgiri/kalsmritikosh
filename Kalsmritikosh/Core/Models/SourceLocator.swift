//
//  SourceLocator.swift
//  Kalsmritikosh
//
//  A1 (spec §6.2 / P3.0d) — the universal, format-spanning way to point at the
//  exact place a piece of evidence lives, so every citation can reopen its
//  source at the right spot regardless of format. Supersedes `SourceRange`
//  (chunk/char/page/line only) while decoding old SourceRange JSON unchanged.
//
//  All fields are optional; a locator carries only the axes that apply to its
//  block's format (a PDF paragraph uses page + bbox + char range; a
//  spreadsheet cell uses sheet + row + column; an email uses messageID +
//  header field; a transcript uses start/end + speaker).
//

import Foundation

public nonisolated struct SourceLocator: Codable, Sendable, Hashable {
    // Evidence anchor (EV-002) — the block this locator points at. Lossless: a citation
    // resolves to its EvidenceBlock even if chunks are re-sliced. Optional so old locators
    // (and formats without blocks) still decode unchanged.
    public var evidenceBlockID: UUID?
    // Text/position
    public var chunkID: UUID?
    public var characterLower: Int?
    public var characterUpper: Int?
    public var page: Int?
    public var line: Int?
    public var boundingBox: [Double]?     // [x, y, w, h] in page/image units
    public var sectionPath: [String]?     // e.g. ["1. Intro", "1.2 Scope"]
    public var paragraphIndex: Int?
    // Tables / spreadsheets
    public var tableID: String?
    public var row: Int?
    public var column: String?
    public var cellRange: String?         // e.g. "B2:D5"
    public var sheet: String?
    // Slides
    public var slide: Int?
    public var shape: String?
    // Email
    public var messageID: String?
    public var emailHeaderField: String?  // e.g. "From", "Date"
    public var attachmentID: String?
    // Archives
    public var archiveMemberPath: String?
    // Audio/video
    public var transcriptStart: Double?   // seconds
    public var transcriptEnd: Double?
    public var speaker: String?
    // Databases/logs
    public var databaseRowKey: String?

    /// USF-002.1 — whether this locator carries a real positional anchor (not merely a self-reference
    /// to its own block/chunk). Evidence readiness requires substantive blocks whose locators can
    /// actually reopen the source at an exact spot; a bare/empty locator does not count as located.
    public var isResolvable: Bool {
        page != nil || line != nil || characterLower != nil || characterUpper != nil
            || boundingBox?.isEmpty == false || sectionPath?.isEmpty == false || paragraphIndex != nil
            || tableID != nil || row != nil || column != nil || cellRange != nil || sheet != nil
            || slide != nil || shape != nil || messageID != nil || emailHeaderField != nil
            || attachmentID != nil || archiveMemberPath != nil || transcriptStart != nil
            || transcriptEnd != nil || databaseRowKey != nil
    }

    public nonisolated init(
        evidenceBlockID: UUID? = nil,
        chunkID: UUID? = nil,
        characterRange: Range<Int>? = nil,
        page: Int? = nil,
        line: Int? = nil,
        boundingBox: [Double]? = nil,
        sectionPath: [String]? = nil,
        paragraphIndex: Int? = nil,
        tableID: String? = nil,
        row: Int? = nil,
        column: String? = nil,
        cellRange: String? = nil,
        sheet: String? = nil,
        slide: Int? = nil,
        shape: String? = nil,
        messageID: String? = nil,
        emailHeaderField: String? = nil,
        attachmentID: String? = nil,
        archiveMemberPath: String? = nil,
        transcriptStart: Double? = nil,
        transcriptEnd: Double? = nil,
        speaker: String? = nil,
        databaseRowKey: String? = nil
    ) {
        self.evidenceBlockID = evidenceBlockID
        self.chunkID = chunkID
        self.characterLower = characterRange?.lowerBound
        self.characterUpper = characterRange?.upperBound
        self.page = page
        self.line = line
        self.boundingBox = boundingBox
        self.sectionPath = sectionPath
        self.paragraphIndex = paragraphIndex
        self.tableID = tableID
        self.row = row
        self.column = column
        self.cellRange = cellRange
        self.sheet = sheet
        self.slide = slide
        self.shape = shape
        self.messageID = messageID
        self.emailHeaderField = emailHeaderField
        self.attachmentID = attachmentID
        self.archiveMemberPath = archiveMemberPath
        self.transcriptStart = transcriptStart
        self.transcriptEnd = transcriptEnd
        self.speaker = speaker
        self.databaseRowKey = databaseRowKey
    }

    /// Character range as a `Range<Int>` when both bounds are present.
    public var characterRange: Range<Int>? {
        guard let l = characterLower, let u = characterUpper, l <= u else { return nil }
        return l..<u
    }

    // MARK: - Backward compatibility with SourceRange

    /// Build from a legacy `SourceRange` so old citations keep resolving.
    public nonisolated init(sourceRange r: SourceRange) {
        self.init(
            chunkID: r.chunkID,
            characterRange: r.characterRange,
            page: r.pageNumber,
            line: r.line
        )
    }

    /// Project back to the legacy `SourceRange` shape (loses the richer axes)
    /// for surfaces that still consume SourceRange.
    public var asSourceRange: SourceRange {
        SourceRange(chunkID: chunkID, characterRange: characterRange, pageNumber: page, line: line)
    }
}
