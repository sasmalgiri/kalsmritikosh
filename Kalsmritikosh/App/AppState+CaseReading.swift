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
        plan.offlineReason = { await MainActor.run { AISetupCenter.shared.noteOffline()?.note } }
        // Package B (P0-A display) — the permission sheet also lists what this Mac could not read, and the
        // plan's balance next to the estimate (P1-E).
        plan.notReadable = { [weak self] caseID in
            guard let readout = await self?.caseCoverage(caseID: caseID) else { return [] }
            return readout.entries.map { CaseReadConsentRequest.Item(name: $0.name, bytes: 0, reason: ($0.status == .notRead ? "not read: " : "partly read: ") + ($0.reason ?? "unknown")) }
        }
        plan.balanceLine = {
            guard OnlineSettings.kind == .included else { return nil }
            return await MainActor.run { CaseReadCostLines.balance(AICreditMeter.shared.balance) }
        }
        return plan
    }

    /// Package B (P0-A display) — the case's reading coverage from what ingestion already recorded (the
    /// workspace's coverage manifest, limited to the case's authorised sources). nil while the ledger or
    /// the case is not available. No extraction, no writes.
    func caseCoverage(caseID: UUID) async -> CaseCoverageReadout? {
        guard let db = database, let answers = investigationAnswers, let objects else { return nil }
        do {
            let context = try await answers.scopeContext(caseID: caseID)
            let builder = CaseCoverageManifestBuilder(repository: CaseCoverageRepository(database: db),
                                                      readiness: SourceReadinessRepository(database: db),
                                                      container: ContainerInspectionRepository(database: db))
            let manifest = try await builder.build(workspaceID: context.workspaceID, generatedAt: Date())
            let scope = context.scope.authorizedSourceVersionIDs
            // The case's own versions too: one the manifest does not list is still counted, by name (LS14).
            let ids = manifest.canonicalSources.map(\.sourceVersionID) + manifest.unadmittedContainerMembers.map(\.parentSourceVersionID)
                + Array(scope)
            let coverageRepo = CaseCoverageRepository(database: db)
            let labels = try await coverageRepo.labels(for: ids)
            let logical = try await coverageRepo.logicalSources(for: Array(scope.subtracting(manifest.canonicalSources.map(\.sourceVersionID))))
            let withText = Set(try await objects.sourceVersionsByObject(inSourceVersionIDs: scope).values.flatMap { $0 })
            return CaseCoverageReadout.make(manifest: manifest, scope: scope, labels: labels, hasLedgerText: withText, logicalSources: logical)
        } catch {
            KalsmritikoshLog.app.error("Case coverage unavailable: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// The one step after the person allowed it on the setup sheet: AI reading on for `kind` (see
    /// AISetup.enable), then the readers re-installed so the next question is read by the AI.
    func enableAIReading(_ kind: OnlineProviderKind) async {
        AISetup.enable(kind)
        await installCloudReaders()
        AISetupCenter.shared.enabled()
    }

    /// Whether Ask may show AI-written (verified) answers now: AI on, document reading on, the provider
    /// set up and eligible. Otherwise Ask shows search results (OfflineSearchResults).
    func aiReadsDocuments() async -> Bool {
        let current = cloudReaderHolder.current
        if current.modelsAllowedOverride == true { return current.answerComposer != nil }
        guard FeatureFlags.aiRegimeValue().allowsAI, current.answerComposer != nil, let provider = onlineProvider else { return false }
        return await provider.acceptsDocuments()
    }

    /// The cloud readers, from the current switches: at boot, and again after the person turned AI reading
    /// on (candidate review UB1 — buying an AI plan or saving a key must not need a relaunch or hidden
    /// switches). Each reader still checks, at every send, that the provider may receive documents now.
    func installCloudReaders() async {
        let brain = self.brain
        // Understanding the question (owner decision 2026-10-25): rules first, then the
        // on-device model for what the rules could not place, then the person's own cloud AI
        // (Online mode only, through its masking, limit and consent) for what both missed.
        let onDevice: (any QuestionInterpreting)? = KnowledgeModuleFlags.isEnabled(.questionInterpreter)
            && FoundationModelsQuestionInterpreter.isAvailable() ? FoundationModelsQuestionInterpreter() : nil
        let cloud: (any QuestionInterpreting)? = KnowledgeModuleFlags.isEnabled(.questionInterpreter)
            ? CloudQuestionInterpreter { [weak self] prompt in
                guard let provider = await self?.onlineProvider, await provider.isAvailable() else {
                    throw OnlineCloudProvider.OnlineError.notAvailable
                }
                // The question (and field names) only — no document text.
                return try await provider.generateQuestionOnly(prompt: prompt, options: GenerationOptions(maxTokens: 16, temperature: 0))
            } : nil
        // Any wording → one canonical form, the same cascade.
        let rewriteOnDevice: (any QuestionRewriting)? = KnowledgeModuleFlags.isEnabled(.questionInterpreter)
            && FoundationModelsQuestionInterpreter.isAvailable() ? FoundationModelsQuestionRewriter() : nil
        let rewriteCloud: (any QuestionRewriting)? = KnowledgeModuleFlags.isEnabled(.questionInterpreter)
            ? CloudQuestionRewriter { [weak self] prompt in
                guard let provider = await self?.onlineProvider, await provider.isAvailable() else {
                    throw OnlineCloudProvider.OnlineError.notAvailable
                }
                // The question (and field names) only — no document text.
                return try await provider.generateQuestionOnly(prompt: prompt, options: GenerationOptions(maxTokens: 300, temperature: 0))
            } : nil
        // Verified record extraction (Online, AI on): the person's documents go through the Online
        // provider — its preview, masking and consent — and only a verbatim-verified answer is shown.
        // Final brief §3.5: its own switch, off by default — it sends document excerpts, unlike the
        // question interpreter, which sends only the question and field names.
        // P1 — the same switch governs the verified answer composer: it sends the retrieved passages.
        // One document reader for both. A send carries the clearance its passages were given
        // (CloudSourceGate, bound to the asking case); without one nothing is sent. Not set up,
        // not eligible for documents, or declined: nothing was sent and the evidence-only answer stands.
        let readDocuments: @Sendable (String, CloudSourceClearance?, Int) async throws -> String = { [weak self] prompt, clearance, maxTokens in
            guard let provider = await self?.onlineProvider, await provider.acceptsDocuments() else {
                throw VerifiedAnswerComposer.NotSent("Online document reading is not set up")
            }
            guard let clearance else { throw OnlineCloudProvider.OnlineError.documentsNotCleared }
            do {
                // Review L2: document excerpts go only to an eligible, confirmed provider.
                return try await provider.generateFromDocuments(
                    prompt: prompt, options: GenerationOptions(maxTokens: maxTokens, temperature: 0, sourceClearance: clearance))
            } catch OnlineCloudProvider.OnlineError.declined {
                KalsmritikoshLog.brain.info("document reading declined by the person")
                throw VerifiedAnswerComposer.NotSent("declined")
            }
        }
        let readsDocuments = KnowledgeModuleFlags.isEnabled(.onlineRecordReading)
        let readers = CloudReaders(
            interpreterOnDevice: onDevice, interpreterCloud: cloud,
            rewriterOnDevice: rewriteOnDevice, rewriterCloud: rewriteCloud,
            recordExtractor: readsDocuments ? VerifiedRecordExtractor { prompt, clearance in
                try await readDocuments(prompt, clearance, 600)
            } : nil,
            answerComposer: readsDocuments ? VerifiedAnswerComposer { prompt, clearance in
                try await readDocuments(prompt, clearance, 1_500)
            } : nil,
            // P3 — the case contradiction check reads the case's cleared passages the same way.
            contradictionReader: readsDocuments ? CaseContradictionReader { prompt, clearance in
                try await readDocuments(prompt, clearance, 1_500)
            } : nil)
        // P4 — the role reader (judge, prosecutor, defendant …) reads through the same document reader,
        // under the same switch; it runs when a case's findings are built (readCaseRoles).
        var readersWithRoles = readers
        readersWithRoles.roleReader = readsDocuments ? VerifiedRoleReader { prompt, clearance in
            try await readDocuments(prompt, clearance, 800)
        } : nil
        // P5 — the case drafts (chronology, open points, interview questions) read the same way.
        readersWithRoles.draftReader = readsDocuments ? CaseDraftReader { prompt, clearance in
            try await readDocuments(prompt, clearance, CaseDraftBuilder.readerReplyTokens)
        } : nil
        // Plan A — the whole-case reader: one call per question with the case's cleared documents as a
        // cached prefix, through the provider's case read (stored per-case permission, masking, limits,
        // re-clearance, outbound record, usage to the billing layer).
        readersWithRoles.caseReader = readsDocuments ? CaseReader { [weak self] send in
            guard let provider = await self?.onlineProvider, await provider.acceptsDocuments() else {
                throw VerifiedAnswerComposer.NotSent("Online document reading is not set up")
            }
            let r = try await provider.readCase(send)
            return CaseReader.Reply(text: r.text, usage: r.usage)
        } : nil
        cloudReaderHolder.set(readersWithRoles)
        await brain.setCloudReaders(readersWithRoles)
    }
}
