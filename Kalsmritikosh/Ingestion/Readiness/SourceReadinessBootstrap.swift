//
//  SourceReadinessBootstrap.swift
//  Kalsmritikosh
//
//  USF-002 — the deterministic INITIAL ten dimensions for a freshly-created source version
//  (§10.1). Preservation reflects the custody outcome; metadata is partial (custody metadata
//  exists, nothing parsed yet); text/structure/index/basicQA/typed/analysis start notStarted.
//  OCR is conditional for image/PDF and notApplicable otherwise; transcription is required for
//  audio/video and notApplicable otherwise. Audio/video are deferred at creation, so their
//  interpretation dimensions start blocked/deferred rather than pretending to be notStarted.
//

import Foundation

public enum SourceReadinessBootstrap {

    static let producerID = "usf-002.intake"
    static let producerVersion = "1"

    /// The ten initial dimension records for a new source version.
    public static func initialDimensions(
        sourceVersionID: UUID, detectedType: SourceType, preservationStatus: SourcePreservationStatus, at now: Date
    ) -> [SourceReadinessDimensionRecord] {
        let isMedia = detectedType.category == .audio || detectedType.category == .video
        let isOCRCandidate = detectedType.category == .image || detectedType == .pdf
        let basis = SourceReadinessBasis(kind: .sourceVersion, identifier: sourceVersionID.uuidString)

        func rec(_ dimension: SourceReadinessDimension, _ state: SourceReadinessDimensionState,
                 _ applicability: SourceReadinessApplicability, _ condition: SourceReadinessCondition? = nil) -> SourceReadinessDimensionRecord {
            SourceReadinessDimensionRecord(
                sourceVersionID: sourceVersionID, dimension: dimension, state: state, applicability: applicability,
                condition: condition, completedUnits: nil, totalUnits: nil, producerID: producerID,
                producerVersion: producerVersion, basis: basis, detail: nil, revision: 1, updatedAt: now)
        }

        let preservationState: SourceReadinessDimensionState =
            (preservationStatus == .referenceRecorded || preservationStatus == .managedCopyStored) ? .ready : .partial

        var dims: [SourceReadinessDimensionRecord] = [
            rec(.preservation, preservationState, .required),
            rec(.metadataExtraction, .partial, .required),
        ]

        if isMedia {
            dims.append(rec(.textExtraction, .blocked, .required, .deferred))
            dims.append(rec(.structuralExtraction, .blocked, .required, .deferred))
            dims.append(rec(.ocr, .ready, .notApplicable))
            dims.append(rec(.transcription, .blocked, .required, .deferred))
        } else {
            dims.append(rec(.textExtraction, .notStarted, .required))
            dims.append(rec(.structuralExtraction, .notStarted, .required))
            dims.append(rec(.ocr, isOCRCandidate ? .notStarted : .ready, isOCRCandidate ? .conditional : .notApplicable))
            dims.append(rec(.transcription, .ready, .notApplicable))
        }

        dims.append(rec(.indexing, .notStarted, .required))
        dims.append(rec(.basicQuestionAnswering, .notStarted, .required))
        dims.append(rec(.typedFieldExtraction, .notStarted, .conditional))
        dims.append(rec(.analyticalReadiness, .notStarted, .required))

        return dims.sorted { $0.dimension.ordinal < $1.dimension.ordinal }
    }
}
