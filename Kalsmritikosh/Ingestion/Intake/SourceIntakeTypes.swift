//
//  SourceIntakeTypes.swift
//  Kalsmritikosh
//
//  USF-001 — the domain vocabulary for universal safe intake. Every accessible file
//  receives a canonical source + source-version custody record BEFORE any loader,
//  parser, OCR, transcription, extractor, embedder or model runs. These types are the
//  closed vocabularies that back the v82 ledger; they introduce no second source
//  authority (source_versions remains the one version authority).
//

import Foundation

// MARK: - Closed custody vocabularies (mirror the v82 CHECKs)

/// How the exact bytes are preserved. `referenced` keeps the original in place;
/// `managed` stores an immutable content-addressed copy in the evidence vault.
public nonisolated enum SourceCustodyMode: String, Sendable, Codable, CaseIterable, Hashable {
    case referenced
    case managed
}

/// The preservation outcome recorded on a source version. A managed-copy failure is a
/// visible state, never a silent downgrade to `managedCopyStored`.
public nonisolated enum SourcePreservationStatus: String, Sendable, Codable, CaseIterable, Hashable {
    case referenceRecorded
    case managedCopyStored
    case managedCopyFailed
    case legacyImported
}

/// How the detected type was decided (recorded separately from the declared extension).
public nonisolated enum SourceDetectionBasis: String, Sendable, Codable, CaseIterable, Hashable {
    case pathPattern
    case declaredExtension
    case magicBytes
    case unknown
}

/// The canonical-identity decision an intake produced. `shouldProcess` is true only for
/// the two outcomes that introduce new bytes to understand.
public nonisolated enum SourceIntakeOutcome: String, Sendable, Codable, CaseIterable, Hashable {
    case newLogicalSource
    case newVersion
    case unchanged
    case moved
    case aliased

    /// Whether the downstream pipeline should attempt loading/parsing for this outcome.
    public var shouldProcess: Bool {
        switch self {
        case .newLogicalSource, .newVersion: return true
        case .unchanged, .moved, .aliased:   return false
        }
    }
}

// MARK: - Request

/// A version-level parent for a child source (e.g. an email for its attachment). The
/// relation reuses the accepted file-level `SourceRelationsRepository.Relation` vocabulary.
public nonisolated struct SourceParentReference: Sendable, Hashable {
    public let parentSourceVersionID: UUID
    public let relation: SourceRelationsRepository.Relation
    public let ordinal: Int?

    public nonisolated init(parentSourceVersionID: UUID,
                            relation: SourceRelationsRepository.Relation, ordinal: Int? = nil) {
        self.parentSourceVersionID = parentSourceVersionID
        self.relation = relation
        self.ordinal = ordinal
    }
}

/// One universal-intake request for a single accessible input.
public nonisolated struct SourceIntakeRequest: Sendable, Hashable {
    public let url: URL
    public let custodyMode: SourceCustodyMode
    public let parent: SourceParentReference?
    public let recordedAt: Date

    public nonisolated init(url: URL, custodyMode: SourceCustodyMode,
                            parent: SourceParentReference? = nil, recordedAt: Date) {
        self.url = url
        self.custodyMode = custodyMode
        self.parent = parent
        self.recordedAt = recordedAt
    }
}

// MARK: - Handle (the accepted custody identity)

/// The durable custody identity produced by a successful intake, handed to the loader
/// pipeline. It carries everything downstream needs so no later stage re-derives source
/// identity. `shouldProcess` gates whether loading/parsing should run.
public nonisolated struct SourceIntakeHandle: Sendable, Hashable {
    public let occurrenceFileID: UUID
    public let logicalSourceID: UUID
    public let sourceVersionID: UUID
    public let outcome: SourceIntakeOutcome
    public let filename: String
    public let declaredExtension: String
    public let detectedType: SourceType
    public let mimeType: String?
    public let detectionBasis: SourceDetectionBasis
    public let contentHash: String
    public let sizeBytes: Int64
    public let custodyMode: SourceCustodyMode
    public let preservationStatus: SourcePreservationStatus
    public let vaultAddress: String?
    /// USF-001.2 — the immutable per-intake processing snapshot the loader and structural parser
    /// must consume (its bytes are exactly those that produced `contentHash`). `nil` when no
    /// snapshot was produced (e.g. a direct repository intake in a test). The caller owns the
    /// snapshot's lifetime and removes its containing directory after processing.
    public let processingSnapshotURL: URL?

    /// True only for `newLogicalSource` / `newVersion`; unchanged/moved/aliased must not reparse.
    public var shouldProcess: Bool { outcome.shouldProcess }

    public nonisolated init(
        occurrenceFileID: UUID, logicalSourceID: UUID, sourceVersionID: UUID,
        outcome: SourceIntakeOutcome, filename: String, declaredExtension: String,
        detectedType: SourceType, mimeType: String?, detectionBasis: SourceDetectionBasis,
        contentHash: String, sizeBytes: Int64, custodyMode: SourceCustodyMode,
        preservationStatus: SourcePreservationStatus, vaultAddress: String?,
        processingSnapshotURL: URL? = nil
    ) {
        self.occurrenceFileID = occurrenceFileID
        self.logicalSourceID = logicalSourceID
        self.sourceVersionID = sourceVersionID
        self.outcome = outcome
        self.filename = filename
        self.declaredExtension = declaredExtension
        self.detectedType = detectedType
        self.mimeType = mimeType
        self.detectionBasis = detectionBasis
        self.contentHash = contentHash
        self.sizeBytes = sizeBytes
        self.custodyMode = custodyMode
        self.preservationStatus = preservationStatus
        self.vaultAddress = vaultAddress
        self.processingSnapshotURL = processingSnapshotURL
    }

    /// Return a copy carrying the given processing-snapshot URL (the repository builds the
    /// handle before the snapshot is threaded through by the coordinator).
    public nonisolated func withProcessingSnapshot(_ url: URL?) -> SourceIntakeHandle {
        SourceIntakeHandle(
            occurrenceFileID: occurrenceFileID, logicalSourceID: logicalSourceID, sourceVersionID: sourceVersionID,
            outcome: outcome, filename: filename, declaredExtension: declaredExtension,
            detectedType: detectedType, mimeType: mimeType, detectionBasis: detectionBasis,
            contentHash: contentHash, sizeBytes: sizeBytes, custodyMode: custodyMode,
            preservationStatus: preservationStatus, vaultAddress: vaultAddress, processingSnapshotURL: url)
    }
}

// MARK: - Captured bytes (byte-capture output)

/// The stable-snapshot result of streaming a file's bytes: its normalized SHA-256, size,
/// modification time, and separately-recorded type detection. Produced BEFORE any loader.
public nonisolated struct CapturedSource: Sendable, Hashable {
    public let contentHash: String        // normalized lowercase 64-char SHA-256
    public let sizeBytes: Int64
    public let modifiedAt: Date?
    public let filename: String
    public let declaredExtension: String
    public let detectedType: SourceType
    public let detectionBasis: SourceDetectionBasis
    public let mimeType: String?

    public nonisolated init(
        contentHash: String, sizeBytes: Int64, modifiedAt: Date?, filename: String,
        declaredExtension: String, detectedType: SourceType,
        detectionBasis: SourceDetectionBasis, mimeType: String?
    ) {
        self.contentHash = contentHash
        self.sizeBytes = sizeBytes
        self.modifiedAt = modifiedAt
        self.filename = filename
        self.declaredExtension = declaredExtension
        self.detectedType = detectedType
        self.detectionBasis = detectionBasis
        self.mimeType = mimeType
    }
}
