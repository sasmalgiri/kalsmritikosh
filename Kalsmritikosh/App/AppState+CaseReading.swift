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
                    // AI-19 — the reader's cleaned copy (v199); cleaned now when the ingest has not written it yet.
                    guard let stored = try await objects.fetchReaderText(id: id), !stored.content.isEmpty else { continue }
                    let text = stored.clean ?? ReaderTextCleaner.clean(stored.content)
                    guard !text.isEmpty else { continue }
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
        // Unified path (AI-18) — the case briefing from the ledger, with the coverage gaps.
        if let db = database {
            let briefingRepo = CaseBriefingRepository(database: db)
            plan.briefing = { [weak self] caseID, docs in
                let number = Dictionary(docs.enumerated().map { ($1.objectID, $0 + 1) }, uniquingKeysWith: { a, _ in a })
                var versionToObject: [UUID: UUID] = [:]
                for d in docs { if let v = d.sourceVersionID { versionToObject[v] = d.objectID } }
                do {
                    // Unified path AI-38 (owner 2026-11-22, round 2) — not tested yet: every source of the case.
                    var material = try await briefingRepo.material(objectIDs: docs.map(\.objectID), versionToObject: versionToObject,
                                                                   caseID: caseID,
                                                                   texts: Dictionary(docs.map { ($0.objectID, $0.text) }, uniquingKeysWith: { a, _ in a }))
                    if let readout = await self?.caseCoverage(caseID: caseID) {
                        material.coverageGaps = readout.entries.map { ($0.name, ($0.status == .notRead ? "not read: " : "partly read: ") + ($0.reason ?? "unknown")) }
                    }
                    return CaseLedgerBriefing.build(material, number: number)
                } catch {
                    KalsmritikoshLog.brain.error("case briefing unavailable: \(String(describing: error), privacy: .public)")
                    return nil
                }
            }
        }
        // AI split AI-44 / AI-45 (owner 2026-11-23): the AI's quote-checked records and the case picture's read state.
        if let db = database { plan.aiRecords = CaseAIRecordRepository(database: db) }
        // ALCOA ALC-02 — the provider and the model the app asks for, kept on every AI run and record.
        plan.providerID = { OnlineSettings.kind.rawValue }
        plan.modelRequested = { OnlineSettings.model }
        // Unified path AI-37 (owner 2026-11-22, round 2) — not tested yet. The briefing's AI suggestions, kept per
        // case document set in the ledger.
        if let db = database {
            let repo = CaseBriefingRepository(database: db)
            plan.cachedSuggestions = { caseID, fp in await repo.aiSuggestions(caseID: caseID, documentFingerprint: fp) }
            plan.storeSuggestions = { caseID, fp, bfp, outcome in
                await repo.storeAISuggestions(caseID: caseID, documentFingerprint: fp, briefingFingerprint: bfp, outcome: outcome)
            }
        }
        // Unified path (AI-20) — the ledger tools, answered here and limited to the case's documents.
        plan.tools = { [weak self] question, docs in
            guard let self else { return nil }
            return self.caseLedgerTools(question: question, documents: docs)
        }
        plan.balanceLine = {
            guard OnlineSettings.kind == .included else { return nil }
            return await MainActor.run {
                let m = AICreditMeter.shared
                return CaseReadCostLines.balance(m.balance, packsOnly: m.tier == nil && m.payAsYouGo)   // pay as you go: the pack balance
            }
        }
        return plan
    }

    /// Unified path (AI-20) — the ledger tools a case reader may ask for, answered on this Mac. Every
    /// result is limited to the case's documents and tagged with their [D<n>] numbers; a result with no
    /// case document is left out.
    nonisolated func caseLedgerTools(question: String, documents: [CaseReader.Document]) -> (@Sendable ([CaseReader.ToolRequest]) async -> String)? {
        let number = Dictionary(documents.enumerated().map { ($1.objectID, $0 + 1) }, uniquingKeysWith: { a, _ in a })
        return { [weak self] requests in
            guard let self, let tools = await self.ledgerToolsForCase() else { return "(The ledger tools are not available.)" }
            var lines: [String] = []
            for r in requests {
                let arg = (r.arg ?? question).trimmingCharacters(in: .whitespacesAndNewlines)
                // Unified path SEARCH-17 (owner 2026-11-22, round 2) — not tested yet. The reference shelf: labelled,
                // never tagged with a document number, never evidence.
                if r.tool.lowercased() == "shelf" {
                    lines.append("shelf(\(arg)): " + (await self.shelfToolLines(arg)))
                    continue
                }
                let results: [ToolResult]
                switch r.tool.lowercased() {
                case "history": results = await tools.historyOf(question: arg)
                case "field": results = await tools.lookupField(arg)
                case "count": results = await tools.countEvents(question: arg)
                case "timeline": results = await tools.timelineSlice(question: arg, from: nil, to: nil)
                case "passages": results = await tools.fetchSpans(question: arg, shape: QuestionShapeRouter.route(arg).shape)
                default: lines.append("\(r.tool)(\(arg)): unknown tool"); continue
                }
                let kept = results.compactMap { t -> String? in
                    let tags = t.objectIDs.compactMap { number[$0] }.sorted().map { "[D\($0)]" }
                    return tags.isEmpty ? nil : "- \(t.text.prefix(300)) \(tags.joined(separator: " "))"
                }
                lines.append("\(r.tool)(\(arg)): " + (kept.isEmpty ? "nothing in this case's documents" : "\n" + kept.joined(separator: "\n")))
            }
            return lines.joined(separator: "\n")
        }
    }

    /// Unified path SEARCH-17 (owner 2026-11-22, round 2) — not tested yet. The shelf tool's result for the reader:
    /// passages labelled "From your reference shelf" with their document title and section — never [D<n>].
    func shelfToolLines(_ term: String) async -> String {
        guard let shelf = referenceShelf else { return "the reference shelf is not available" }
        do {
            let hits = try await shelf.search(term, limit: 5)
            guard !hits.isEmpty else { return "nothing on your reference shelf" }
            return "\n" + hits.map { h in
                "- From your reference shelf (reference, not evidence) — \(h.documentTitle)\(h.section.map { ", " + $0 } ?? ""): \(h.text.prefix(300))"
            }.joined(separator: "\n")
        } catch {
            KalsmritikoshLog.app.error("Reference shelf tool: search failed: \(String(describing: error), privacy: .public)")
            return "the reference shelf could not be searched"
        }
    }

    /// The ledger tools over this ledger (nil while it is not open).
    func ledgerToolsForCase() -> LedgerTools? {
        guard let events, let genericFacts, let chunks else { return nil }
        var tools = LedgerTools(
            events: { [weak events] tokens in (try? await events?.findByTitleTokens(tokens)) ?? [] },
            facts: { [weak genericFacts] field in (try? await genericFacts?.facts(field: field)) ?? [] },
            chunksForQuestion: { [weak chunks] q in
                let hits = (try? await chunks?.searchFTS(SlotFieldResolver.expandAliases(q), limit: 15)) ?? []
                return hits.map { RetrievedChunk(chunk: $0, score: 1.0, viaLayer: .metadata) }
            })
        if let evidenceStore { tools.blockOwners = LedgerTools.blockOwners(using: evidenceStore) }
        return tools
    }

    /// Package B (P0-A display) — the case's reading coverage from what ingestion already recorded (the
    /// workspace's coverage manifest, limited to the case's authorised sources). nil while the ledger or
    /// the case is not available. No extraction, no writes.
    func caseCoverage(caseID: UUID) async -> CaseCoverageReadout? {
        guard let db = database, let answers = investigationAnswers, objects != nil else { return nil }
        do {
            let context = try await answers.scopeContext(caseID: caseID)
            // IN-12 — with the intake inventory it rests on (selected / received / decided / not taken in).
            return try await CaseCoverageReadout.load(database: db, workspaceID: context.workspaceID, scope: context.scope.authorizedSourceVersionIDs,
                                                      caseID: caseID)
        } catch {
            KalsmritikoshLog.app.error("Case coverage unavailable: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// The one step after the person allowed it on the setup sheet: AI reading on for `kind` (see
    /// AISetup.enable), then the readers re-installed so the next question is read by the AI.
    func enableAIReading(_ kind: OnlineProviderKind) async {
        #if DEBUG
        // GUI walk (DEBUG only): under a simulated AI plan the switches are held in memory for this process only.
        if UIWalkSimulatedPlan.launchPlan != nil {
            UIWalkSimulatedPlan.keepInMemory { AISetup.enable(kind) }
        } else {
            AISetup.enable(kind)
        }
        #else
        AISetup.enable(kind)
        #endif
        OneAI.invalidate()   // Unified path AI-36 (owner 2026-11-22, round 2) — not tested yet: re-read "set up" now.
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
        // Unified path AI-36 (owner 2026-11-22, round 2) — not tested yet. One AI: no on-device model step; what the
        // rules could not place goes to the online AI (question only).
        let onDevice: (any QuestionInterpreting)? = nil
        let cloud: (any QuestionInterpreting)? = KnowledgeModuleFlags.isEnabled(.questionInterpreter)
            ? CloudQuestionInterpreter { [weak self] prompt in
                guard let provider = await self?.onlineProvider, await provider.isAvailable() else {
                    throw OnlineCloudProvider.OnlineError.notAvailable
                }
                // The question (and field names) only — no document text.
                return try await provider.generateQuestionOnly(prompt: prompt, options: GenerationOptions(maxTokens: 16, temperature: 0))
            } : nil
        // Any wording → one canonical form, the same cascade.
        // Unified path AI-36 (owner 2026-11-22, round 2) — not tested yet: the rewriter likewise goes to the online AI.
        let rewriteOnDevice: (any QuestionRewriting)? = nil
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
            // "Look for conflicts with AI…" reads a large case's cleared passages the same way.
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
