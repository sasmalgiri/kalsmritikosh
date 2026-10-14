//
//  AppState+Trust.swift
//  Kalsmritikosh
//
//  The answer trust layer (plan Wave I): feeds the pure engines in Brain/Trust
//  with ledger data. Each entry point returns nil when its module is switched
//  off or the ledger is not ready, so the UI simply shows nothing.
//

import Foundation
import os

extension AppState {

    /// I-3 — independent-source reading for an answer's citations.
    public func corroboration(for answer: VerifiedAnswer) async -> CorroborationReading? {
        guard ProductModuleFlags.isEnabled(.corroborationMeter), let objects else { return nil }
        let cited = answer.citations.map(\.objectID)
        guard !cited.isEmpty else { return CorroborationMeter.read(citedObjectIDs: [], keys: [:]) }
        let provider = LedgerSourceIndependenceKeyProvider(objects: objects)
        let keys: [KnowledgeObject.ID: String]
        do {
            keys = try await provider.keys(for: Set(cited))
        } catch {
            KalsmritikoshLog.app.error("Corroboration keys failed: \(error.localizedDescription, privacy: .public)")
            // Conservative: without keys nothing counts as independent corroboration.
            keys = [:]
        }
        return CorroborationMeter.read(citedObjectIDs: cited, keys: keys)
    }

    /// I-4 — search uncited passages on the same subject for evidence against the answer.
    public func disconfirmation(for answer: VerifiedAnswer, passageLimit: Int = 60) async -> DisconfirmationReport? {
        guard ProductModuleFlags.isEnabled(.devilsAdvocate), !answer.refused, let chunks else { return nil }
        let question = answer.resolvedQuestion ?? ""
        let answerText = answer.answerText ?? answer.body
        // The query is the subject: question words plus the start of the answer.
        let query = question + " " + String(answerText.prefix(400))
        let hits: [Chunk]
        do {
            hits = try await chunks.searchFTS(query, limit: passageLimit)
        } catch {
            KalsmritikoshLog.app.error("Disconfirmation search failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        let candidates = hits.map { DisconfirmationScanner.Candidate(chunkID: $0.id, objectID: $0.objectID, text: $0.text) }
        return DisconfirmationScanner.scan(
            question: question,
            answer: answerText,
            citedChunkIDs: Set(answer.citations.compactMap(\.chunkID)),
            citedObjectIDs: Set(answer.citations.map(\.objectID)),
            candidates: candidates)
    }

    /// I-11 — plain-language account of how the answer was found.
    public func answerPath(for answer: VerifiedAnswer) -> [AnswerPathStep]? {
        guard ProductModuleFlags.isEnabled(.answerPath) else { return nil }
        return AnswerPathExplainer.explain(trace: answer.reasoningTrace,
                                           citations: answer.citations.count,
                                           refused: answer.refused,
                                           contradictions: answer.contradictions.count)
    }
}
