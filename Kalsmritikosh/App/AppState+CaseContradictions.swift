//
//  AppState+CaseContradictions.swift
//  Kalsmritikosh
//
//  P3 — the live wiring of the case contradiction check (InvestigationContradictionGapService
//  .findContradictions): the case's documents from the ledger, the cloud gate bound to the case's
//  scope, the person's AI reader (only when AI is allowed and Online document reading is set up), and
//  the claim links that carry a found contradiction into the findings report's conflicts section.
//

import Foundation
import os

extension AppState {
    /// The most documents one check reads (a larger case is checked over its first documents and says so in the log).
    nonisolated static let caseContradictionDocumentCap = 400

    nonisolated static func caseContradictionPass(objects: KnowledgeObjectRepository, sensitiveScopes: SensitiveScopeRepository,
                                                  claims: ClaimRepository, links: ClaimContradictionRepository,
                                                  answers: InvestigationAnswerService?, readers: CloudReaderHolder) -> CaseContradictionPass {
        CaseContradictionPass(
            documents: { versions in
                let byObject = try await objects.sourceVersionsByObject(inSourceVersionIDs: versions)
                let ids = byObject.keys.sorted { $0.uuidString < $1.uuidString }
                if ids.count > caseContradictionDocumentCap {
                    KalsmritikoshLog.knowledge.info("case contradiction check: \(ids.count, privacy: .public) documents, the first \(caseContradictionDocumentCap, privacy: .public) are compared")
                }
                let fileNames: [UUID: String]
                do { fileNames = try await objects.sourceFilenames(for: Set(ids)) } catch {
                    KalsmritikoshLog.knowledge.error("case contradiction check: file names unreadable: \(String(describing: error), privacy: .public)")
                    fileNames = [:]
                }
                var out: [CaseContradictionFinder.Document] = []
                for id in ids.prefix(caseContradictionDocumentCap) {
                    guard let ko = try await objects.load(id: id), !ko.content.isEmpty else { continue }
                    let header: String? = {
                        guard let v = ko.metadata["date"]?.value else { return nil }
                        if case .string(let s) = v { return s }
                        return nil
                    }()
                    out.append(CaseContradictionFinder.Document(
                        objectID: id, sourceVersionID: byObject[id]?.sorted { $0.uuidString < $1.uuidString }.first,
                        text: ko.content, fileName: fileNames[id],
                        date: CaseContradictionFinder.documentDate([header, ko.content].compactMap { $0 })))
                }
                return out
            },
            gate: { caseID in
                CloudSourceGate(sensitiveScope: sensitiveScopes, objects: objects).bound(to: answers?.cloudScope(caseID: caseID))
            },
            reader: {
                let current = readers.current
                guard current.modelsAllowedOverride ?? FeatureFlags.aiRegimeValue().allowsAI else { return nil }
                return current.contradictionReader
            },
            linkClaims: { found in
                var made = 0
                for c in found {
                    for object in [c.evidenceA, c.evidenceB].compactMap({ $0 }) {
                        do {
                            for claim in try await claims.claimIDs(citingObject: object) {
                                try await links.link(claimID: claim, contradictionID: c.id)
                                made += 1
                            }
                        } catch {
                            KalsmritikoshLog.knowledge.error("case contradiction check: claim link failed: \(String(describing: error), privacy: .public)")
                        }
                    }
                }
                return made
            })
    }
}
