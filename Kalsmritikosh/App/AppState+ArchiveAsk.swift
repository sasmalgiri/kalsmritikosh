//
//  AppState+ArchiveAsk.swift
//  Kalsmritikosh
//
//  AI split AI-47 (owner 2026-11-23) — Ask outside a case. With AI set up: the archive agent loop (ArchiveAgent) over the
//  documents the search finds, every send an Online document send (clearance, masking, preview, outbound record). With no AI
//  set up: "Set up AI (your key or a plan)" and the search results as a list — never prose. The rule answer path runs only
//  when RetiredPaths.ruleAnswerComposers is switched back on (then Ask is exactly as before).
//

import Foundation
import os

extension AppState {
    /// The archive agent over this ledger (nil while the ledger is not open).
    func archiveAgent(access: SensitiveAccessContext) -> ArchiveAgent? {
        guard let objects, let sensitiveScopes else { return nil }
        let brain = self.brain
        let gate = CloudSourceGate(sensitiveScope: sensitiveScopes, objects: objects, localCeiling: access.scope.maximumSensitivity)
        return ArchiveAgent(
            search: { words in
                let found = await brain.searchResults(question: words, access: access, limit: 20)
                return found.citations.map { ArchiveAgent.Hit(objectID: $0.objectID, snippet: $0.snippet) }
            },
            document: { id in
                do {
                    guard let stored = try await objects.fetchReaderText(id: id), !stored.content.isEmpty else { return nil }
                    let text = stored.clean ?? ReaderTextCleaner.clean(stored.content)
                    guard !text.isEmpty else { return nil }
                    let name: String?
                    do { name = try await objects.sourceFilenames(for: [id])[id] } catch {
                        KalsmritikoshLog.brain.error("archive reading: file name unreadable: \(String(describing: error), privacy: .public)")
                        name = nil
                    }
                    return CaseReader.Document(objectID: id, fileName: name, text: text)
                } catch {
                    KalsmritikoshLog.brain.error("archive reading: document unreadable: \(String(describing: error), privacy: .public)")
                    return nil
                }
            },
            clear: { ids in await gate.clear(ids, purpose: "archive.reading") },
            send: { [weak self] prompt, clearance in
                guard let provider = await self?.onlineProvider, await provider.acceptsDocuments() else {
                    throw VerifiedAnswerComposer.NotSent("Online document reading is not set up")
                }
                do {
                    return try await provider.generateFromDocuments(
                        prompt: prompt, options: GenerationOptions(maxTokens: OnlineRequestBuilder.caseReadReplyTokens, temperature: 0,
                                                                   sourceClearance: clearance))
                } catch OnlineCloudProvider.OnlineError.declined {
                    KalsmritikoshLog.brain.info("archive reading declined by the person")
                    throw VerifiedAnswerComposer.NotSent("declined")
                }
            })
    }

    /// Ask outside a case (AI-47).
    func answerArchive(question q: String) async -> VerifiedAnswer {
        let access = SensitiveAccessContext(scope: .globalOwnerRetrieval())
        if RetiredPaths.isOn(.ruleAnswerComposers) {
            // The retired path, unchanged: the rule pipeline, shown as search results without an AI reader.
            let pipelineAnswer = await brain.answer(question: q, access: access)
            return await aiReadsDocuments()
                ? pipelineAnswer
                : OfflineSearchResults.present(pipelineAnswer, question: q, reason: AISetupCenter.shared.noteOffline()?.note)
        }
        let found = await brain.searchResults(question: q, access: access)
        func list(_ reason: String?, note: String? = nil) async -> VerifiedAnswer {
            var shown = OfflineSearchResults.present(found, question: q, reason: reason)
            if let note { shown = CaseReader.noting(shown, note) }
            return await brain.commitReading(question: q, verified: shown, originScopeID: nil)
        }
        guard await aiReadsDocuments(), let agent = archiveAgent(access: access) else {
            return await list(AISetupCenter.shared.noteOffline()?.note ?? OfflineSearchResults.defaultReason)
        }
        switch await agent.answer(question: q) {
        case .read(let a, let documents, let steps):
            KalsmritikoshLog.brain.info("archive reading: \(documents, privacy: .public) document(s), \(steps, privacy: .public) step(s)")
            return await brain.commitReading(question: q, verified: a, originScopeID: nil)
        case .noDocuments(let withheld):
            let why = withheld > 0 ? "No matching document may be sent to the AI (\(withheld) privileged or restricted)" : "The search found no document for the AI to read"
            return await list(why)
        case .failed(let reason, let notSent):
            let shown = await list(notSent ? InvestigationAnswerService.readingNotUsed : InvestigationAnswerService.readingFailed)
            return notSent ? shown : VerifiedAnswerComposer.flagged(shown, reason: reason)
        }
    }
}
