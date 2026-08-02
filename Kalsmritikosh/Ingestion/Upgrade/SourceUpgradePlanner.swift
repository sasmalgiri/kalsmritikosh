//
//  SourceUpgradePlanner.swift
//  Kalsmritikosh
//
//  USF-M3 (USF-009 §24/§25) — PURE planning: given an exact source version's readiness + type + container
//  state, produce the MINIMAL deterministic set of upgrade kinds needed to reach a requested goal, or a
//  typed blocker when the goal cannot currently be reached. The planner chooses the minimum required work
//  (never deep-study when only OCR + structure is needed) and never enqueues impossible jobs forever.
//

import Foundation

public enum SourceUpgradePlanner {

    public struct Plan: Sendable, Equatable {
        public let sourceVersionID: UUID
        public let goal: SourceUpgradeGoal
        public let kinds: [SourceUpgradeKind]   // minimal, ordered
        public var alreadySatisfied: Bool { kinds.isEmpty }
    }

    /// OCR-dependent formats (fidelity varies with image quality) — text needs OCR before it exists.
    private static func isOCRDependent(_ t: SourceType) -> Bool {
        switch t { case .pdf, .png, .jpg, .heic, .tiff, .webp: return true; default: return false }
    }

    public nonisolated static func plan(sourceVersionID: UUID, goal: SourceUpgradeGoal,
                                        detectedType: SourceType, readiness: SourceReadinessSnapshot,
                                        containerStatus: ContainerManifestStatus? = nil) throws -> Plan {
        func p(_ kinds: [SourceUpgradeKind]) -> Plan { Plan(sourceVersionID: sourceVersionID, goal: goal, kinds: kinds) }

        // Locked / corrupt content can't advance search/evidence/analytical.
        let cs = readiness.completionState
        if (cs == .encrypted || cs == .corrupt), goal != .containerInspection {
            throw SourceUpgradeError.policyBlocked("source is \(cs.rawValue)")
        }
        // Media whose only text path is transcription — USF-M3 activates no transcription engine.
        if detectedType.category == .audio || detectedType.category == .video,
           goal == .searchReady || goal == .evidenceReady || goal == .analyticallyReady {
            throw SourceUpgradeError.unsupportedCapability(.transcription)
        }

        switch goal {
        case .containerInspection:
            guard detectedType.category == .archive else { throw SourceUpgradeError.policyBlocked("not a container") }
            return containerStatus == nil ? p([.containerInspection]) : p([])

        case .searchReady:
            return readiness.isSearchReady ? p([]) : p(searchKinds(detectedType, readiness))

        case .evidenceReady:
            if readiness.isEvidenceReady { return p([]) }
            var kinds = searchKinds(detectedType, readiness)
            for k in evidenceKinds(detectedType, readiness) where !kinds.contains(k) { kinds.append(k) }
            return p(kinds)

        case .analyticallyReady:
            if readiness.isAnalyticallyReady { return p([]) }
            var kinds = searchKinds(detectedType, readiness)
            for k in evidenceKinds(detectedType, readiness) where !kinds.contains(k) { kinds.append(k) }
            for k in analyticalKinds(readiness) where !kinds.contains(k) { kinds.append(k) }
            return p(kinds)

        case .specificDimension:
            // A specific dimension is requested by kind through `ensure(kind:)`, not planned from a goal.
            throw SourceUpgradeError.missingDependency("specificDimension requires an explicit kind")
        }
    }

    // MARK: - Minimal kind sets

    private nonisolated static func present(_ r: SourceReadinessSnapshot, _ d: SourceReadinessDimension) -> Bool {
        r.dimension(d)?.hasPresentContent ?? false
    }

    private nonisolated static func searchKinds(_ type: SourceType, _ r: SourceReadinessSnapshot) -> [SourceUpgradeKind] {
        var kinds: [SourceUpgradeKind] = []
        if !present(r, .textExtraction) {
            // No usable text yet: OCR for image/PDF (§22 essential OCR), otherwise re-run structural extraction.
            kinds.append(isOCRDependent(type) ? .ocr : .structuralExtraction)
        }
        if !present(r, .indexing) { kinds.append(.indexing) }
        return kinds
    }

    private nonisolated static func evidenceKinds(_ type: SourceType, _ r: SourceReadinessSnapshot) -> [SourceUpgradeKind] {
        guard r.dimension(.structuralExtraction)?.state != .ready else { return [] }
        var kinds: [SourceUpgradeKind] = []
        if isOCRDependent(type), r.dimension(.ocr)?.state != .ready { kinds.append(.ocr) }
        kinds.append(.structuralExtraction)
        return kinds
    }

    private nonisolated static func analyticalKinds(_ r: SourceReadinessSnapshot) -> [SourceUpgradeKind] {
        var kinds: [SourceUpgradeKind] = [.embedding, .entityReconciliation]
        if let typed = r.dimension(.typedFieldExtraction), typed.applicability == .required, typed.state != .ready {
            kinds.append(.typedFieldExtraction)
        }
        kinds.append(.analyticalReadiness)
        return kinds
    }
}
