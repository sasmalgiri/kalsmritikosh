//
//  CaseRetrievalScopeResolver.swift
//  Kalsmritikosh
//
//  INV-01-B2 — turns an InvestigationCase's authorized source bindings into a concrete
//  RetrievalSourceScope (a set of authorized source-version ids) that the persona-neutral
//  SourceScopedRetriever / SourceScopeRetrievalPolicy enforce. This is the ONE place case→version
//  semantics live; it is reused by the answer path and (later) by Methods and DataLab so no downstream
//  surface reinvents case filtering.
//
//  Version semantics (deliberate, per the source-version authority — never a silent widen):
//    • .sourceVersion  — the sourceRef IS an exact source-version id; authorize that version only.
//    • .logicalSource  — authorize the CURRENT version of that logical source (the live retrievable
//                        content). Superseded versions are NOT authorized: a chunk belonging to an old
//                        version will not match, so scope never silently broadens to prior bytes.
//    • .workspaceSource — a workspace source is a logical source in the workspace; resolve as above.
//  Moving scope onto a newer version is an explicit case-source update (INV-01-A), not implicit here.
//
//  FAIL-CLOSED: a binding that cannot be resolved (malformed ref, unknown/absent version) contributes
//  NOTHING to the allow-set — it never widens scope. A case whose confirmed in-scope set resolves to
//  nothing yields an active-but-empty scope (honest empty retrieval), never a fall back to the workspace.
//

import Foundation

public struct CaseRetrievalScopeResolver: Sendable {
    private let evidence: EvidenceStore

    public init(evidence: EvidenceStore) {
        self.evidence = evidence
    }

    /// Resolve a case record's in-scope bindings to an ACTIVE RetrievalSourceScope. Only `inScope`
    /// sources contribute; excluded sources are ignored (they were never authorized).
    public func scope(for record: InvestigationCaseRecord) async throws -> RetrievalSourceScope {
        var authorized = Set<UUID>()
        for source in record.sources where source.inScope {
            switch source.sourceKind {
            case .sourceVersion:
                if let versionID = UUID(uuidString: source.sourceRef) {
                    authorized.insert(versionID)   // exact version; existence is enforced by the match
                }
            case .logicalSource, .workspaceSource:
                if let logicalID = UUID(uuidString: source.sourceRef),
                   let current = try await evidence.currentVersionID(forLogicalSource: logicalID) {
                    authorized.insert(current)
                }
            }
        }
        return RetrievalSourceScope.authorizing(authorized)
    }
}
