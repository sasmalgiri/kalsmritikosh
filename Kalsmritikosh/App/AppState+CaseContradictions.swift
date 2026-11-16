//
//  AppState+CaseContradictions.swift
//  Kalsmritikosh
//
//  P3 — the live wiring of the case contradiction check (InvestigationContradictionGapService
//  .findContradictions, the rules) and of its one AI path, "Look for conflicts with AI…" (.lookForConflictsWithAI,
//  owner request 2026-11-16): the case's documents from the ledger, the cloud gate bound to the case's scope, the
//  whole-case reading, the person's AI passage reader (only when AI is allowed and Online document reading is set up)
//  for a case too large to read whole, and the claim links that carry a found contradiction into the findings report's
//  conflicts section.
//

import Foundation
import os

extension AppState {
    /// The most documents one check reads. A larger case is checked over its first documents and the run says how many
    /// it did not compare (CaseContradictionRun.documentsInCase); a continuation is SEARCH-13's remaining work.
    nonisolated static let caseContradictionDocumentCap = 400

    nonisolated static func caseContradictionPass(objects: KnowledgeObjectRepository, sensitiveScopes: SensitiveScopeRepository,
                                                  claims: ClaimRepository, links: ClaimContradictionRepository,
                                                  answers: InvestigationAnswerService?, readers: CloudReaderHolder,
                                                  caseReading: CaseWholeReading? = nil, caseFiles: CaseFileRepository? = nil,
                                                  conflictDetails: CaseConflictDetailsRepository? = nil) -> CaseContradictionPass {
        var pass = CaseContradictionPass(
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
        // P5 — the case drafts read through the same gate, under the same AI conditions.
        pass.draftReader = {
            let current = readers.current
            guard current.modelsAllowedOverride ?? FeatureFlags.aiRegimeValue().allowsAI else { return nil }
            return current.draftReader
        }
        pass.roleReader = {
            let current = readers.current
            guard current.modelsAllowedOverride ?? FeatureFlags.aiRegimeValue().allowsAI else { return nil }
            return current.roleReader
        }
        // Plan A — a case that fits and whose documents the person allowed is analysed whole, over the
        // same cached case prefix as its questions.
        pass.caseReading = caseReading
        pass.caseBinding = { caseID in answers?.cloudScope(caseID: caseID) }
        // Ease fixes A — the case's own money records, for the rule that compares a document's payments with them.
        if let caseFiles {
            pass.moneyMovements = { caseID in try await caseFiles.moneyLedger(caseID: caseID).contradictionMovements() }
        }
        // Owner request 2026-11-16 — "Look for conflicts with AI…" keeps each conflict's detail here.
        pass.conflictDetails = conflictDetails
        // Case plan 2026-11-16 (SEARCH-13): the documents before the cap, so a capped run says what it left out.
        pass.documentCount = { versions in try await objects.sourceVersionsByObject(inSourceVersionIDs: versions).count }
        return pass
    }
}
