//
//  SourceUpgradeTypes.swift
//  Kalsmritikosh
//
//  USF-M3 (USF-009) — the closed vocabulary for exact-SourceVersion progressive upgrade work. A job
//  KIND describes work; a GOAL is a requested target; NEITHER asserts readiness (source_readiness_* is
//  the only authority). Scope distinguishes new exact-version jobs from preserved legacy subject jobs.
//

import Foundation

/// The kind of upgrade work a job performs. Superset of the legacy EnrichmentJobKind so v88 rows
/// round-trip, plus the source-readiness dimensions and container inspection.
public nonisolated enum SourceUpgradeKind: String, Sendable, Codable, CaseIterable, Hashable {
    // Readiness-dimension work.
    case structuralExtraction
    case ocr
    case transcription
    case indexing
    case basicQuestionAnswering
    case typedFieldExtraction
    case analyticalReadiness
    case containerInspection
    // Analytical enrichment (legacy EnrichmentJobKind values — preserved).
    case embedding
    case typedFacts
    case entityReconciliation
    case contradictionScan
    case deepStudy

    /// The readiness dimension this kind advances, when it maps to one (advisory).
    public var targetDimension: SourceReadinessDimension? {
        switch self {
        case .structuralExtraction: return .structuralExtraction
        case .ocr: return .ocr
        case .transcription: return .transcription
        case .indexing: return .indexing
        case .basicQuestionAnswering: return .basicQuestionAnswering
        case .typedFieldExtraction: return .typedFieldExtraction
        case .analyticalReadiness: return .analyticalReadiness
        default: return nil
        }
    }
}

/// A REQUESTED processing target — not a readiness declaration.
public nonisolated enum SourceUpgradeGoal: String, Sendable, Codable, CaseIterable, Hashable {
    case searchReady
    case evidenceReady
    case analyticallyReady
    case specificDimension
    case containerInspection
}

/// Stable priority classes. Higher runs first; background yields to interactive queries.
public nonisolated enum SourceUpgradePriority: Int, Sendable, Codable, CaseIterable, Hashable {
    case interactive = 100
    case userRequested = 80
    case caseRelevant = 60
    case background = 40
    case maintenance = 20
}

/// Where a job came from (operational provenance).
public nonisolated enum SourceUpgradeOrigin: String, Sendable, Codable, CaseIterable, Hashable {
    case initialIngest
    case userRequested
    case caseUpgrade
    case backgroundPolicy
    case legacy
}

/// The closed source-upgrade job lifecycle (mirrors the v88 CHECK).
public nonisolated enum SourceUpgradeJobState: String, Sendable, Codable, CaseIterable, Hashable {
    case pending
    case running
    case done
    case failed
    case blocked
    case cancelled
    case superseded

    public var isActive: Bool { self == .pending || self == .running }
    public var isTerminal: Bool { self == .done || self == .cancelled || self == .superseded }
}

/// A job's scope (mirrors the v88 CHECK).
public nonisolated enum SourceUpgradeScope: String, Sendable, Codable, CaseIterable, Hashable {
    case legacySubject
    case sourceVersion
}

/// How the caller wants a requested upgrade run.
public nonisolated enum SourceUpgradeExecutionMode: String, Sendable, Codable, CaseIterable, Hashable {
    case background   // plan + persist, return immediately
    case foreground   // enqueue/reuse -> claim -> execute -> verify postcondition -> mark done
}

/// The intent of a processing pass (initial fast vs full vs on-demand upgrade).
public nonisolated enum SourceProcessingIntent: String, Sendable, Codable, CaseIterable, Hashable {
    case initialFast        // custody + searchable text only; structure/analytical become upgrades
    case fullAvailable      // the prior default — everything the initial pass could do
    case evidenceUpgrade
    case analyticalUpgrade
}
