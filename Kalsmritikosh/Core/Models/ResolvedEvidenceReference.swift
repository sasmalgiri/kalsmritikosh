//
//  ResolvedEvidenceReference.swift
//  Kalsmritikosh
//
//  S0.5 (foundation correction). Trust rule 1 of the history contract is "no history
//  item without provenance". A GenericFact carries only EvidenceBlock ids, not the
//  KnowledgeObject they belong to; when such a fact is projected into a HistoryItem the
//  item could end up with an empty evidence array even though exact block evidence
//  exists. This type is the bridge: it resolves a block back to its owning
//  KnowledgeObject + source version + locator, so a GenericFact-derived HistoryItem
//  carries a real, reopenable citation (objectID AND blockID).
//
//  Pure value type; the resolution itself is done by the evidence store (DB), never here.
//

import Foundation

/// A block resolved to the exact evidence it can be reopened from.
public struct ResolvedEvidenceReference: Sendable, Hashable {
    public let objectID: KnowledgeObject.ID
    public let blockID: EvidenceBlock.ID
    public let sourceVersionID: UUID?
    public let locator: SourceLocator?

    public nonisolated init(
        objectID: KnowledgeObject.ID,
        blockID: EvidenceBlock.ID,
        sourceVersionID: UUID? = nil,
        locator: SourceLocator? = nil
    ) {
        self.objectID = objectID
        self.blockID = blockID
        self.sourceVersionID = sourceVersionID
        self.locator = locator
    }
}

/// Resolves EvidenceBlock ids to the KnowledgeObject / source version / locator that
/// back them. Implemented by the evidence store; injected into history projection so
/// the projector stays pure (tests pass a resolution map directly).
public protocol EvidenceBlockResolving: Sendable {
    func resolveEvidenceBlocks(_ blockIDs: [EvidenceBlock.ID]) async throws -> [ResolvedEvidenceReference]
}
