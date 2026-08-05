//
//  CaseScopedEntityResolver.swift
//  Kalsmritikosh
//
//  INV-02 / INV-03 — the ONE way the Investigator asks "does this canonical entity belong to the case?"
//  and "what does the case's authorized evidence say about it?". It composes the SHARED EntitiesRepository
//  (canonical mentions) with the SHARED EvidenceStore's object→source-version resolution — the identical
//  path SourceScopedRetriever uses to bound retrieval — so subject dossiers and identity decisions inherit
//  exactly the same source-version authorization as Ask / Methods / DataLab. It reads canonical evidence;
//  it never mutates it.
//

import Foundation

public actor CaseScopedEntityResolver {
    private let entities: EntitiesRepository
    private let evidence: EvidenceStore

    public init(entities: EntitiesRepository, evidence: EvidenceStore) {
        self.entities = entities
        self.evidence = evidence
    }

    /// The mentions of a canonical entity that fall WITHIN an authorized source scope, each cited to its
    /// exact source version + knowledge object + surface form. A mention whose source version is not in the
    /// scope is excluded (fail-closed); a mention that cannot be resolved to a version is excluded too.
    /// Deterministic order. Empty when nothing about the entity is authorized for the case.
    public func inScopeMentions(entityID: UUID, scope: RetrievalSourceScope, limit: Int = 500) async throws -> [InvestigationDossierItem] {
        let authorized = Set(scope.authorizedSourceVersionIDs)
        guard !authorized.isEmpty else { return [] }
        let mentions = try await entities.mentions(forEntityID: entityID, limit: limit)
        var items: [InvestigationDossierItem] = []
        for m in mentions {
            guard let version = try await evidence.currentVersionID(forObject: m.objectID),
                  authorized.contains(version) else { continue }
            items.append(InvestigationDossierItem(sourceVersionID: version, knowledgeObjectID: m.objectID, surface: m.surface))
        }
        return items.sorted {
            ($0.sourceVersionID.uuidString, $0.knowledgeObjectID.uuidString)
                < ($1.sourceVersionID.uuidString, $1.knowledgeObjectID.uuidString)
        }
    }

    /// Whether the canonical entity has at least one mention inside the case's authorized sources. A subject
    /// or a merge target with NO in-scope evidence is out of scope — the persona may not act on it.
    public func isInScope(entityID: UUID, scope: RetrievalSourceScope) async throws -> Bool {
        !(try await inScopeMentions(entityID: entityID, scope: scope)).isEmpty
    }
}
