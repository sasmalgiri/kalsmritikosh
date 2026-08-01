//
//  ContentSurfaceProjector.swift
//  Kalsmritikosh
//
//  USF-004 — projects the ALREADY-ACCEPTED EvidenceBlock model + document metadata into the closed
//  content-surface set. It invents no new block hierarchy and no readiness state: it merely
//  describes what the parser recovered. `typedFields` stays notApplicable until an accepted
//  typed-field producer exists (generic metadata / GenericFacts are NOT typed fields).
//

import Foundation

public enum ContentSurfaceProjector {

    private static let textKinds: Set<EvidenceBlockKind> = [
        .documentTitle, .documentHeader, .sectionHeading, .paragraph, .listItem, .quote, .codeBlock,
        .footnote, .endnote, .emailBody, .quotedEmail, .slideTitle, .slideBody, .slideNotes,
        .transcriptSegment, .logRecord]
    private static let tableKinds: Set<EvidenceBlockKind> = [
        .table, .tableRow, .tableCell, .spreadsheetSheet, .spreadsheetRow, .spreadsheetCell]
    private static let imageKinds: Set<EvidenceBlockKind> = [.image, .figureCaption]

    private static func isSubstantive(_ b: EvidenceBlock) -> Bool {
        !b.kind.isBoilerplate && b.normalizedText.count >= 3
    }

    /// Project a parsed document's blocks + metadata into content surfaces.
    public static func project(blocks: [EvidenceBlock], metadata: [String: AnyCodable],
                               extractionStatus: ExtractionStatus) -> [ContentSurfaceReceipt] {
        let substantive = blocks.filter(isSubstantive)
        func blockReceipt(_ kind: ContentSurfaceKind, _ matching: [EvidenceBlock]) -> ContentSurfaceReceipt {
            guard !matching.isEmpty else { return ContentSurfaceReceipt(kind: kind, coverage: .notApplicable, unitCount: 0) }
            let coverage: ContentSurfaceCoverage = extractionStatus == .complete ? .complete : .partial
            return ContentSurfaceReceipt(kind: kind, coverage: coverage, unitCount: matching.count, basisBlockIDs: matching.map(\.id))
        }

        let text = substantive.filter { textKinds.contains($0.kind) }
        let tables = blocks.filter { tableKinds.contains($0.kind) }
        let images = blocks.filter { imageKinds.contains($0.kind) }
        let attachments = blocks.filter { $0.kind == .attachment }
        let transcript = blocks.filter { $0.kind == .transcriptSegment }
        let located = substantive.filter { $0.locator.isResolvable }

        var surfaces: [ContentSurfaceReceipt] = []
        surfaces.append(blockReceipt(.text, text))
        surfaces.append(metadata.isEmpty
            ? ContentSurfaceReceipt(kind: .metadata, coverage: .notApplicable, unitCount: 0)
            : ContentSurfaceReceipt(kind: .metadata, coverage: .complete, unitCount: metadata.count))
        // structure: located substantive blocks; complete only when the parse completed AND every
        // substantive block is located (mirrors the durable structural-readiness gate).
        if located.isEmpty {
            surfaces.append(ContentSurfaceReceipt(kind: .structure, coverage: .notApplicable, unitCount: 0))
        } else {
            let complete = extractionStatus == .complete && located.count == substantive.count
            surfaces.append(ContentSurfaceReceipt(kind: .structure, coverage: complete ? .complete : .partial,
                                                  unitCount: located.count, basisBlockIDs: located.map(\.id)))
        }
        surfaces.append(blockReceipt(.tables, tables))
        surfaces.append(blockReceipt(.images, images))
        surfaces.append(blockReceipt(.attachments, attachments))
        surfaces.append(blockReceipt(.transcript, transcript))
        surfaces.append(ContentSurfaceReceipt(kind: .typedFields, coverage: .notApplicable, unitCount: 0))
        return surfaces
    }

    /// Surfaces for a structure-less plugin (loader-only): a text surface derived from the produced
    /// KnowledgeObjects, everything else notApplicable. Never fabricates structure.
    public static func projectFromObjects(_ objects: [KnowledgeObject], extractionStatus: ExtractionStatus) -> [ContentSurfaceReceipt] {
        let hasText = objects.contains { !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        var surfaces: [ContentSurfaceReceipt] = []
        surfaces.append(hasText
            ? ContentSurfaceReceipt(kind: .text, coverage: extractionStatus == .complete ? .complete : .partial, unitCount: objects.count)
            : ContentSurfaceReceipt(kind: .text, coverage: .notApplicable, unitCount: 0))
        for kind in ContentSurfaceKind.allCases where kind != .text {
            surfaces.append(ContentSurfaceReceipt(kind: kind, coverage: .notApplicable, unitCount: 0))
        }
        return surfaces
    }
}
