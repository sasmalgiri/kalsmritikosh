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
    /// The most documents one check reads. A larger case is checked a page at a time: the run says how many it compared of
    /// how many, and "Compare the next documents" continues from where it stopped (CaseContradictionRun.continuation).
    nonisolated static let caseContradictionDocumentCap = 400

    /// One page of the case's documents for the contradiction check: in a stable order (by document id), from position
    /// `from`, at most `caseContradictionDocumentCap` of them. The run says how many it compared of how many.
    nonisolated static func caseContradictionDocuments(objects: KnowledgeObjectRepository, versions: Set<UUID>,
                                                       from: Int, question: String? = nil) async throws -> [CaseContradictionFinder.Document] {
        let byObject = try await objects.sourceVersionsByObject(inSourceVersionIDs: versions)
        let ids = Array(try await caseContradictionOrder(objects: objects, ids: Set(byObject.keys), question: question)
            .dropFirst(max(0, from)).prefix(caseContradictionDocumentCap))
        if byObject.count > caseContradictionDocumentCap {
            KalsmritikoshLog.knowledge.info("case contradiction check: \(byObject.count, privacy: .public) documents, comparing \(ids.count, privacy: .public) from position \(from, privacy: .public)")
        }
        let fileNames: [UUID: String]
        do { fileNames = try await objects.sourceFilenames(for: Set(ids)) } catch {
            KalsmritikoshLog.knowledge.error("case contradiction check: file names unreadable: \(String(describing: error), privacy: .public)")
            fileNames = [:]
        }
        var out: [CaseContradictionFinder.Document] = []
        for id in ids {
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
    }

    /// SEARCH-13 — the order the check reads a case in: with a question, the documents matching its words first (best
    /// first), then the rest; without one, by document id. Stable either way, so pages continue without gaps or repeats.
    nonisolated static func caseContradictionOrder(objects: KnowledgeObjectRepository, ids: Set<UUID>, question: String?) async throws -> [UUID] {
        let byID = ids.sorted { $0.uuidString < $1.uuidString }
        guard let q = question?.trimmingCharacters(in: .whitespacesAndNewlines), !q.isEmpty else { return byID }
        let ranked: [UUID]
        do { ranked = try await objects.objectIDsRanked(matching: q).filter(ids.contains) } catch {
            KalsmritikoshLog.knowledge.error("case contradiction check: question order unavailable: \(String(describing: error), privacy: .public)")
            return byID
        }
        return caseContradictionOrder(byID: byID, ranked: ranked)
    }
    nonisolated static func caseContradictionOrder(byID: [UUID], ranked: [UUID]) -> [UUID] {
        var seen = Set<UUID>()
        let first = ranked.filter { seen.insert($0).inserted }
        return first + byID.filter { !seen.contains($0) }
    }

    nonisolated static func caseContradictionPass(objects: KnowledgeObjectRepository, sensitiveScopes: SensitiveScopeRepository,
                                                  claims: ClaimRepository, links: ClaimContradictionRepository,
                                                  answers: InvestigationAnswerService?, readers: CloudReaderHolder,
                                                  caseReading: CaseWholeReading? = nil, caseFiles: CaseFileRepository? = nil,
                                                  conflictDetails: CaseConflictDetailsRepository? = nil) -> CaseContradictionPass {
        var pass = CaseContradictionPass(
            documents: { versions in try await caseContradictionDocuments(objects: objects, versions: versions, from: 0) },
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
        // Case plan 2026-11-16 (SEARCH-13): the next page in the same stable order, for "Compare the next documents".
        pass.documentsFrom = { versions, from in try await caseContradictionDocuments(objects: objects, versions: versions, from: from) }
        // SEARCH-13: pages in the order of the case question.
        pass.documentsForQuestion = { versions, from, question in
            try await caseContradictionDocuments(objects: objects, versions: versions, from: from, question: question)
        }
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
