//
//  UniversalParserTypes.swift
//  Kalsmritikosh
//
//  USF-M1 (USF-003) — the common vocabulary for the one Universal Parser Platform that replaces
//  the two independent routing authorities (LoaderRegistry + StructuralParserRegistry). Every
//  plugin has a stable code-backed identity; every execution consumes the USF-001.2 immutable
//  processing snapshot (never the mutable original) and returns one common result whose identity is
//  gated against the request. No schema change: source_versions / ParsedDocument / EvidenceBlock /
//  StructuralPersistenceReceipt / SourceReadiness remain the durable authorities.
//

import Foundation

/// How a source type is processed. Closed vocabulary.
public nonisolated enum UniversalParserExecutionMode: String, Sendable, Codable, CaseIterable, Hashable {
    case immediate      // txt/docx/pdf/email/xlsx/… — parse now
    case container      // zip — hand off to member expansion (USF-006 completes recursion)
    case deferred       // audio/video — custody kept, interpretation postponed (MMI owns it)
    case preservedOnly  // recognized but no interpretation available
}

/// A plugin's declared capabilities — read from code so the capability manifest cannot drift.
public nonisolated struct UniversalParserCapabilities: Sendable, Codable, Hashable {
    /// True when the plugin has a structural parser that produces typed, located EvidenceBlocks.
    public let producesStructure: Bool
    /// True when the plugin depends on an OCR engine (fidelity varies with image quality).
    public let requiresOCR: Bool
    /// The surfaces the plugin declares it can produce (advisory; the executor validates outputs).
    public let declaredSurfaces: Set<ContentSurfaceKind>

    public nonisolated init(producesStructure: Bool, requiresOCR: Bool, declaredSurfaces: Set<ContentSurfaceKind>) {
        self.producesStructure = producesStructure
        self.requiresOCR = requiresOCR
        self.declaredSurfaces = declaredSurfaces
    }
}

/// USF-M3 (USF-009 §21) — how much parsing a request wants. `searchCore` may skip the structural parser
/// when the loader already produced usable searchable text (fast initial pass); `evidenceStructure` /
/// `fullAvailable` run the structural parser (evidence upgrade). This does NOT create an alternate parser
/// path — it is one flag on the ONE UniversalParserRegistry.
public nonisolated enum UniversalParserIntent: String, Sendable, Codable, CaseIterable, Hashable {
    case searchCore
    case evidenceStructure
    case fullAvailable
}

/// One parse request. Plugins parse the immutable processing snapshot, never the original.
public nonisolated struct UniversalParserRequest: Sendable, Hashable {
    public let originalURL: URL
    public let processingSnapshotURL: URL
    public let logicalSourceID: UUID
    public let sourceVersionID: UUID
    public let sourceType: SourceType
    public let contentHash: String
    public let sizeBytes: Int64
    public let intent: UniversalParserIntent

    public nonisolated init(originalURL: URL, processingSnapshotURL: URL, logicalSourceID: UUID,
                            sourceVersionID: UUID, sourceType: SourceType, contentHash: String, sizeBytes: Int64,
                            intent: UniversalParserIntent = .fullAvailable) {
        self.originalURL = originalURL
        self.processingSnapshotURL = processingSnapshotURL
        self.logicalSourceID = logicalSourceID
        self.sourceVersionID = sourceVersionID
        self.sourceType = sourceType
        self.contentHash = contentHash
        self.sizeBytes = sizeBytes
        self.intent = intent
    }
}

/// The one result every parser execution returns. Its identity is gated against the request by the
/// executor — a plugin can never relabel a result to make it pass.
public nonisolated struct UniversalParserResult: Sendable {
    public let pluginID: String
    public let pluginVersion: String
    public let sourceType: SourceType
    public let logicalSourceID: UUID
    public let sourceVersionID: UUID
    public let contentHash: String
    /// KnowledgeObject projections (one for most formats; many for mbox/pst-shaped multi-record loaders).
    public let knowledgeObjects: [KnowledgeObject]
    /// The typed structural document, when the plugin produced one (nil for structure-less plugins).
    public let parsedDocument: ParsedDocument?
    /// The advisory content surfaces the plugin recovered.
    public let contentSurfaces: [ContentSurfaceReceipt]
    public let warnings: [ParserWarning]
    public let extractionStatus: ExtractionStatus

    public nonisolated init(
        pluginID: String, pluginVersion: String, sourceType: SourceType, logicalSourceID: UUID,
        sourceVersionID: UUID, contentHash: String, knowledgeObjects: [KnowledgeObject],
        parsedDocument: ParsedDocument?, contentSurfaces: [ContentSurfaceReceipt],
        warnings: [ParserWarning], extractionStatus: ExtractionStatus
    ) {
        self.pluginID = pluginID
        self.pluginVersion = pluginVersion
        self.sourceType = sourceType
        self.logicalSourceID = logicalSourceID
        self.sourceVersionID = sourceVersionID
        self.contentHash = contentHash
        self.knowledgeObjects = knowledgeObjects
        self.parsedDocument = parsedDocument
        self.contentSurfaces = contentSurfaces
        self.warnings = warnings
        self.extractionStatus = extractionStatus
    }

    /// Surface lookup convenience.
    public func surface(_ kind: ContentSurfaceKind) -> ContentSurfaceReceipt? {
        contentSurfaces.first { $0.kind == kind }
    }
}
