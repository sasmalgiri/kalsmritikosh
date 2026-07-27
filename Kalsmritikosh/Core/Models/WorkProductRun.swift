//
//  WorkProductRun.swift
//  Kalsmritikosh
//
//  OPS-004 — immutable ledger record of one compose()-validated work product.
//  WorkProductRun is the header row stored in work_product_runs (schema v72);
//  child rows (work_product_sections, work_product_claim_occurrences,
//  work_product_manifests) provide full fidelity for reopen and comparison.
//  Deleting a run never touches canonical evidence, entities, or claims.
//

import Foundation

/// Immutable header record of one saved work-product compose() run.
/// Reopening uses the companion four v72 child-row tables.
public struct WorkProductRun: Sendable, Identifiable, Hashable {
    public typealias ID = UUID
    public let id: ID
    public let workspaceID: UUID
    public let template: WorkProductTemplate
    public let title: String
    public let subtitle: String?
    public let subjectLabel: String
    public let corpusSnapshotID: UUID?
    public let schemaVersion: Int
    public let appVersion: String
    public let composedAt: Date
    public let findingCount: Int
    public let disclaimer: String?

    public nonisolated init(
        id: ID = UUID(),
        workspaceID: UUID,
        template: WorkProductTemplate,
        title: String,
        subtitle: String? = nil,
        subjectLabel: String,
        corpusSnapshotID: UUID? = nil,
        schemaVersion: Int,
        appVersion: String,
        composedAt: Date,
        findingCount: Int,
        disclaimer: String? = nil
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.template = template
        self.title = title
        self.subtitle = subtitle
        self.subjectLabel = subjectLabel
        self.corpusSnapshotID = corpusSnapshotID
        self.schemaVersion = schemaVersion
        self.appVersion = appVersion
        self.composedAt = composedAt
        self.findingCount = findingCount
        self.disclaimer = disclaimer
    }
}

/// Result of proving a saved run's source-custody hashes against the current ledger.
/// `isValid` is true when every stored hash matches and no source version is missing.
public struct WorkProductValidationRecord: Sendable {
    public let runID: WorkProductRun.ID
    public let validatedAt: Date
    public let hashMatchCount: Int
    public let hashMismatchCount: Int
    public let missingVersionCount: Int

    public nonisolated init(
        runID: WorkProductRun.ID,
        validatedAt: Date,
        hashMatchCount: Int,
        hashMismatchCount: Int,
        missingVersionCount: Int
    ) {
        self.runID = runID
        self.validatedAt = validatedAt
        self.hashMatchCount = hashMatchCount
        self.hashMismatchCount = hashMismatchCount
        self.missingVersionCount = missingVersionCount
    }

    public var isValid: Bool { hashMismatchCount == 0 && missingVersionCount == 0 }
}
