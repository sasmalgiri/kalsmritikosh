//
//  WorkflowStepProvenanceProducing.swift
//  Kalsmritikosh
//
//  PJE-007 — step-level provenance production.
//
//  Executors that hold canonical references implement `provenance(...)` to emit
//  their ordered WorkflowProvenanceReference list from the RESULTING state.
//  Executors remain repository-free: they read only their own state JSON.
//  Executors without canonical references use the default empty implementation.
//

import Foundation

// MARK: - Protocol

public protocol WorkflowStepProvenanceProducing: WorkflowStepExecutor {
    /// The ordered canonical references underlying `resultingStateJSON`.
    func provenance(
        context: WorkflowStepExecutionContext,
        resultingStateJSON: String
    ) async throws -> [WorkflowProvenanceReference]
}

public extension WorkflowStepProvenanceProducing {
    /// Default: no canonical references (a valid EMPTY snapshot is still written).
    func provenance(
        context: WorkflowStepExecutionContext,
        resultingStateJSON: String
    ) async throws -> [WorkflowProvenanceReference] { [] }
}

// MARK: - Shared decoding helper

private nonisolated func decodeState<State: Codable & Sendable>(
    _ type: State.Type, from json: String
) throws -> State {
    try WorkflowStepPayloadCodec.decode(
        WorkflowStepStateEnvelope<State>.self, from: json).state
}

private nonisolated func referenceKind(fromObjectKind kind: WorkflowEvidenceObjectKind)
    -> WorkflowProvenanceReferenceKind? {
    WorkflowProvenanceReferenceKind(rawValue: kind.rawValue)
}

// MARK: - selectEvidence: every selected reference, in selection order

extension SelectEvidenceStepExecutor: WorkflowStepProvenanceProducing {
    public func provenance(
        context: WorkflowStepExecutionContext,
        resultingStateJSON: String
    ) async throws -> [WorkflowProvenanceReference] {
        let state = try decodeState(SelectEvidenceStepState.self, from: resultingStateJSON)
        return state.items.compactMap { item in
            guard let kind = referenceKind(fromObjectKind: item.objectKind),
                  let objectID = UUID(uuidString: item.canonicalObjectID) else { return nil }
            return WorkflowProvenanceReference(
                kind: kind, canonicalObjectID: objectID,
                role: .selected, disposition: .active,
                label: nil, note: item.selectionReason)
        }
    }
}

// MARK: - reviewEvidence: reviewed references with mapped dispositions

extension ReviewEvidenceStepExecutor: WorkflowStepProvenanceProducing {
    public func provenance(
        context: WorkflowStepExecutionContext,
        resultingStateJSON: String
    ) async throws -> [WorkflowProvenanceReference] {
        let state = try decodeState(ReviewEvidenceStepState.self, from: resultingStateJSON)
        let selection = Self.selectedItems(in: context.aggregate)
        return selection.compactMap { item in
            guard let review = state.reviews[item.id.uuidString],
                  let kind = referenceKind(fromObjectKind: item.objectKind),
                  let objectID = UUID(uuidString: item.canonicalObjectID) else { return nil }
            let disposition: WorkflowProvenanceDisposition
            switch review.status {
            case .reviewed:                 disposition = .active
            case .needsFollowUp:            disposition = .needsFollowUp
            case .excludedFromThisWorkflow: disposition = .excludedFromWorkflow
            }
            return WorkflowProvenanceReference(
                kind: kind, canonicalObjectID: objectID,
                role: .reviewed, disposition: disposition,
                note: review.note)
        }
    }
}

// MARK: - timeline: the canonical references underlying each entry
// (scenario ordering overlays are proposal-layer state, NOT canonical provenance)

extension TimelineStepExecutor: WorkflowStepProvenanceProducing {
    public func provenance(
        context: WorkflowStepExecutionContext,
        resultingStateJSON: String
    ) async throws -> [WorkflowProvenanceReference] {
        let state = try decodeState(TimelineStepState.self, from: resultingStateJSON)
        return state.entries.compactMap { entry in
            guard let kind = referenceKind(fromObjectKind: entry.objectKind),
                  let objectID = UUID(uuidString: entry.canonicalObjectID) else { return nil }
            return WorkflowProvenanceReference(
                kind: kind, canonicalObjectID: objectID,
                role: .contextual, disposition: .active,
                label: entry.label)
        }
    }
}

// MARK: - graph: canonical nodes ONLY (proposal nodes and candidate edges stay proposals)

extension GraphStepExecutor: WorkflowStepProvenanceProducing {
    public func provenance(
        context: WorkflowStepExecutionContext,
        resultingStateJSON: String
    ) async throws -> [WorkflowProvenanceReference] {
        let state = try decodeState(GraphStepState.self, from: resultingStateJSON)
        return state.nodes.compactMap { node in
            guard case .canonical(let objectKind, let canonicalObjectID) = node.reference,
                  let kind = referenceKind(fromObjectKind: objectKind),
                  let objectID = UUID(uuidString: canonicalObjectID) else { return nil }
            return WorkflowProvenanceReference(
                kind: kind, canonicalObjectID: objectID,
                role: .contextual, disposition: .active)
        }
    }
}

// MARK: - calculation: canonical referenced inputs (literals stay in step state)

extension CalculationStepExecutor: WorkflowStepProvenanceProducing {
    public func provenance(
        context: WorkflowStepExecutionContext,
        resultingStateJSON: String
    ) async throws -> [WorkflowProvenanceReference] {
        let state = try decodeState(CalculationStepState.self, from: resultingStateJSON)
        var references: [WorkflowProvenanceReference] = []
        for calculation in state.calculations {
            for input in calculation.inputs {
                guard let refObjectKind = input.referenceKind,
                      let kind = referenceKind(fromObjectKind: refObjectKind),
                      let refIDString = input.referenceID,
                      let objectID = UUID(uuidString: refIDString) else { continue }
                references.append(WorkflowProvenanceReference(
                    kind: kind, canonicalObjectID: objectID,
                    role: .calculationInput, disposition: .active,
                    note: calculation.operation.rawValue))
            }
        }
        return references
    }
}

// MARK: - method: gate-verified method-result provenance references

extension MethodStepExecutor: WorkflowStepProvenanceProducing {
    public func provenance(
        context: WorkflowStepExecutionContext,
        resultingStateJSON: String
    ) async throws -> [WorkflowProvenanceReference] {
        let state = try decodeState(MethodStepState.self, from: resultingStateJSON)
        guard let result = state.result else { return [] }
        return result.provenanceReferences.compactMap { ref in
            guard let objectKind = WorkflowEvidenceObjectKind(rawValue: ref.objectKind),
                  let kind = referenceKind(fromObjectKind: objectKind),
                  let objectID = UUID(uuidString: ref.canonicalObjectID) else { return nil }
            return WorkflowProvenanceReference(
                kind: kind, canonicalObjectID: objectID,
                role: .methodInput, disposition: .active)
        }
    }
}

// MARK: - registered method (v2): provenance from the STORED completed-result snapshot
// (never queried from the method repository at provenance time)

extension RegisteredMethodStepExecutor: WorkflowStepProvenanceProducing {
    public func provenance(
        context: WorkflowStepExecutionContext,
        resultingStateJSON: String
    ) async throws -> [WorkflowProvenanceReference] {
        let state = try decodeState(RegisteredMethodStepState.self, from: resultingStateJSON)
        guard let result = state.result else { return [] }
        return result.provenanceReferences.compactMap { ref in
            guard let objectKind = WorkflowEvidenceObjectKind(rawValue: ref.objectKind),
                  let kind = referenceKind(fromObjectKind: objectKind),
                  let objectID = UUID(uuidString: ref.canonicalObjectID) else { return nil }
            return WorkflowProvenanceReference(
                kind: kind, canonicalObjectID: objectID,
                role: .methodInput, disposition: .active)
        }
    }
}
