//
//  AppState+CaseReading.swift
//  Kalsmritikosh
//
//  Plan A (owner, 2026-11-04) — the live wiring of the whole-case reader for questions asked inside a
//  case (InvestigationAnswerService): the case's documents from the ledger, the cloud gate, the reader
//  (only when AI may read documents now), the per-case permission store and sheet, the plan's limit and
//  the cost estimate.
//

import Foundation
import os

extension AppState {
    func caseWholeReading(objects: KnowledgeObjectRepository, sensitiveScopes: SensitiveScopeRepository) -> CaseWholeReading {
        let readers = cloudReaderHolder
        var plan = CaseWholeReading(
            documents: { versions in
                let byObject = try await objects.sourceVersionsByObject(inSourceVersionIDs: versions)
                let ids = Set(byObject.keys)
                let fileNames: [UUID: String]
                do { fileNames = try await objects.sourceFilenames(for: ids) } catch {
                    KalsmritikoshLog.brain.error("case reading: file names unreadable: \(String(describing: error), privacy: .public)")
                    fileNames = [:]
                }
                var out: [CaseReader.Document] = []
                for id in ids {
                    guard let text = try await objects.fetchContent(id: id), !text.isEmpty else { continue }
                    out.append(CaseReader.Document(objectID: id, sourceVersionID: byObject[id]?.sorted { $0.uuidString < $1.uuidString }.first,
                                                   fileName: fileNames[id], text: text))
                }
                return out
            },
            gate: { CloudSourceGate(sensitiveScope: sensitiveScopes, objects: objects) },
            reader: { [weak self] in
                let current = readers.current
                guard let reader = current.caseReader else { return nil }
                // The case bench forces the AI regime on with its own reader; the app asks the regime and
                // whether the provider may receive documents now.
                if current.modelsAllowedOverride == true { return reader }
                guard FeatureFlags.aiRegimeValue().allowsAI, let provider = await self?.onlineProvider,
                      await provider.acceptsDocuments() else { return nil }
                return reader
            },
            permissions: .live,
            askConsent: { request in await CaseReadConsent.shared.request(request) },
            wholeCaseLimit: { CaseReadLimits.current() },
            providerName: { OnlineSettings.kind.displayName },
            estimate: { caseTokens, questionTokens in
                CaseReadCostEstimate.line(kind: OnlineSettings.kind, caseTokens: caseTokens, questionTokens: questionTokens,
                                          maxOutputTokens: OnlineRequestBuilder.anthropicMaxTokens(OnlineRequestBuilder.caseReadReplyTokens),
                                          oneHourCache: true)
            })
        plan.otherReadersAvailable = { [weak self] in await self?.aiReadsDocuments() ?? false }
        return plan
    }

    /// Whether Ask may show AI-written (verified) answers now: AI on, document reading on, the provider
    /// set up and eligible. Otherwise Ask shows search results (OfflineSearchResults).
    func aiReadsDocuments() async -> Bool {
        let current = cloudReaderHolder.current
        if current.modelsAllowedOverride == true { return current.answerComposer != nil }
        guard FeatureFlags.aiRegimeValue().allowsAI, current.answerComposer != nil, let provider = onlineProvider else { return false }
        return await provider.acceptsDocuments()
    }
}
