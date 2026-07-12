//
//  DocumentProfile.swift
//  Kalsmritikosh
//
//  A1 (spec §9.3 / P3.0m) — a per-source-version DETERMINISTIC index card. It
//  is NOT an LLM summary: every field is computed from parsed blocks + file
//  metadata. Used for source health, navigation, and routing. The "first
//  meaningful block" excludes page numbers, running headers/footers,
//  signatures, disclaimers and boilerplate (P3.0n).
//

import Foundation

public nonisolated struct DocumentProfile: Sendable, Hashable {
    public let sourceVersionID: UUID
    public let filename: String
    public let detectedType: SourceType
    public let mimeType: String?
    public let contentHash: String
    public let sizeBytes: Int64
    public let parser: String
    public let parserVersion: String
    public let language: String?
    /// Heading section outline (from sectionHeading blocks, in order).
    public let sectionOutline: [String]
    /// First substantive block's normalized text (deterministic; not an LLM gist).
    public let firstMeaningfulBlock: String?
    public let blockCount: Int
    /// Counts by structural unit where the format has them.
    public let pageCount: Int?
    public let sheetCount: Int?
    public let slideCount: Int?
    public let messageCount: Int?
    public let attachmentCount: Int?
    public let childCount: Int?           // archive members / embedded objects
    public let extractionStatus: ExtractionStatus
    public let warningCount: Int
    /// 0…1 mean extraction confidence across blocks.
    public let extractionConfidence: Double
    public let isQueryable: Bool

    public nonisolated init(
        sourceVersionID: UUID,
        filename: String,
        detectedType: SourceType,
        mimeType: String? = nil,
        contentHash: String,
        sizeBytes: Int64 = 0,
        parser: String,
        parserVersion: String,
        language: String? = nil,
        sectionOutline: [String] = [],
        firstMeaningfulBlock: String? = nil,
        blockCount: Int,
        pageCount: Int? = nil,
        sheetCount: Int? = nil,
        slideCount: Int? = nil,
        messageCount: Int? = nil,
        attachmentCount: Int? = nil,
        childCount: Int? = nil,
        extractionStatus: ExtractionStatus = .complete,
        warningCount: Int = 0,
        extractionConfidence: Double = 1.0,
        isQueryable: Bool = true
    ) {
        self.sourceVersionID = sourceVersionID
        self.filename = filename
        self.detectedType = detectedType
        self.mimeType = mimeType
        self.contentHash = contentHash
        self.sizeBytes = sizeBytes
        self.parser = parser
        self.parserVersion = parserVersion
        self.language = language
        self.sectionOutline = sectionOutline
        self.firstMeaningfulBlock = firstMeaningfulBlock
        self.blockCount = blockCount
        self.pageCount = pageCount
        self.sheetCount = sheetCount
        self.slideCount = slideCount
        self.messageCount = messageCount
        self.attachmentCount = attachmentCount
        self.childCount = childCount
        self.extractionStatus = extractionStatus
        self.warningCount = warningCount
        self.extractionConfidence = max(0, min(1, extractionConfidence))
        self.isQueryable = isQueryable
    }

    /// Build a profile deterministically from a ParsedDocument (no LLM).
    public nonisolated static func from(
        _ doc: ParsedDocument,
        parser: String,
        parserVersion: String,
        sizeBytes: Int64 = 0
    ) -> DocumentProfile {
        let outline = doc.blocks
            .filter { $0.kind == .sectionHeading || $0.kind == .documentTitle }
            .sorted { $0.ordinal < $1.ordinal }
            .map(\.normalizedText)
            .filter { !$0.isEmpty }
        let confidences = doc.blocks.map(\.extractionConfidence)
        let meanConf = confidences.isEmpty ? 1.0 : confidences.reduce(0, +) / Double(confidences.count)
        func count(_ kind: EvidenceBlockKind) -> Int? {
            let n = doc.blocks.filter { $0.kind == kind }.count
            return n > 0 ? n : nil
        }
        return DocumentProfile(
            sourceVersionID: doc.sourceVersionID,
            filename: doc.filename,
            detectedType: doc.detectedType,
            mimeType: doc.mimeType,
            contentHash: doc.contentHash,
            sizeBytes: sizeBytes,
            parser: parser,
            parserVersion: parserVersion,
            language: doc.blocks.compactMap(\.language).first,
            sectionOutline: outline,
            firstMeaningfulBlock: doc.meaningfulBlocks.first?.normalizedText,
            blockCount: doc.blocks.count,
            sheetCount: count(.spreadsheetSheet),
            slideCount: count(.slideTitle),
            messageCount: count(.emailBody),
            attachmentCount: count(.attachment),
            childCount: count(.archiveMember),
            extractionStatus: doc.extractionStatus,
            warningCount: doc.warnings.count,
            extractionConfidence: meanConf,
            isQueryable: doc.extractionStatus == .complete || doc.extractionStatus == .partial
        )
    }
}
