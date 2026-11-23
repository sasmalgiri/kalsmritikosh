//
//  CaseWholeReading.swift
//  Kalsmritikosh
//
//  Plan A (owner, 2026-11-04) — what InvestigationAnswerService needs to let the person's AI read a
//  whole case: the case's documents, the cloud gate, the reader (only when AI may read documents now),
//  the permission store and the one-per-case consent, and the size limit. Every part is a closure the
//  app injects (AppState) or a test scripts; nil (no plan wired) keeps the service exactly as before.
//

import Foundation
import os

/// What the person is shown before a case's first AI read: exactly what would go, what would not and
/// why, and what the first read costs.
public nonisolated struct CaseReadConsentRequest: Sendable, Identifiable, Equatable {
    public struct Item: Sendable, Equatable, Hashable {
        public let name: String
        public let bytes: Int
        public let reason: String?
        public init(name: String, bytes: Int, reason: String? = nil) { self.name = name; self.bytes = bytes; self.reason = reason }
    }
    public let id: UUID
    public let caseID: UUID
    public let provider: String
    /// The documents that will be sent.
    public let documents: [Item]
    /// Documents of the case that will NOT be sent, each with its reason (privileged, restricted …).
    public let excluded: [Item]
    public let totalBytes: Int
    public let estimatedTokens: Int
    /// Whether the case is read whole (false: too large — the passages most related to each question).
    public let readsWhole: Bool
    /// Credits (plan) or dollars (own key) for the first read.
    public let estimate: String
    /// The document set the permission is pinned to.
    public let fingerprint: String
    /// Package B (P0-A display) — the case's documents this Mac could not read, or read only in part, each
    /// with its reason (password-protected, unsupported type, text recognition failed …). They are not sent.
    public let notReadable: [Item]
    /// Package B (P1-E) — the AI plan's credits left, next to the estimate (nil: own key, or not known yet).
    public let balance: String?
    /// AI split AI-44 (owner 2026-11-23) — the agent's limits (steps per question, the token ceiling, the background
    /// case picture), shown before the first run (nil: no agent steps).
    public let agentLimits: String?
    public init(id: UUID = UUID(), caseID: UUID, provider: String, documents: [Item], excluded: [Item], totalBytes: Int,
                estimatedTokens: Int, readsWhole: Bool, estimate: String, fingerprint: String,
                notReadable: [Item] = [], balance: String? = nil, agentLimits: String? = nil) {
        self.agentLimits = agentLimits
        self.id = id; self.caseID = caseID; self.provider = provider; self.documents = documents; self.excluded = excluded
        self.totalBytes = totalBytes; self.estimatedTokens = estimatedTokens; self.readsWhole = readsWhole
        self.estimate = estimate; self.fingerprint = fingerprint
        self.notReadable = notReadable; self.balance = balance
    }
}

public nonisolated struct CaseWholeReading: Sendable {
    /// The documents of these source versions (ledger text, file name), read on this Mac.
    public var documents: @Sendable (Set<UUID>) async throws -> [CaseReader.Document]
    /// The cloud gate (the service binds it to the case's scope).
    public var gate: @Sendable () -> CloudSourceGate?
    /// The reader when the person's AI may read documents now (AI on, Online set up, provider eligible
    /// and confirmed); nil = no AI: Ask returns search results.
    public var reader: @Sendable () async -> CaseReader?
    public var permissions: CaseReadPermissionStore
    /// Show the consent sheet and wait: true = Allow (the permission is then stored), false = Not now.
    public var askConsent: @Sendable (CaseReadConsentRequest) async -> Bool
    /// The most tokens of case text read whole (the plan's limit, or the own-key setting).
    public var wholeCaseLimit: @Sendable () -> Int
    public var providerName: @Sendable () -> String
    /// The estimate line for the first read (caseTokens, questionTokens).
    public var estimate: @Sendable (_ caseTokens: Int, _ questionTokens: Int) -> String
    /// Questions asked from an open case are interactive: the case text is cached for an hour.
    public var questionTTL: CaseReadCacheTTL = .oneHour
    // Case analysis (contradictions, roles, drafts) reuses this cached prefix with its task as the
    // suffix (`analysisRoute` / `readForAnalysis`), at the SAME TTL as questions so the request is
    // byte-identical through the cache breakpoint and the cache is shared.
    // Unified path AI-24 (owner 2026-11-22) — background analysis reads ask for the provider's batch service
    // (`CaseReadSend.batch`); questions stay interactive.
    /// Whether another AI reader (the passage composer) may answer when no whole-case reader is
    /// installed: then the case is answered the way it was before plan A, not as search results.
    public var otherReadersAvailable: @Sendable () async -> Bool = { false }
    /// Why no AI reader is installed now, in the person's words (the missing setup step: no plan or key,
    /// Online off, AI switched off, terms not accepted, blocked country, relay or credits); nil = unknown.
    public var offlineReason: @Sendable () async -> String? = { nil }
    /// Package B (P0-A display) — the case's documents not (fully) read on this Mac, for the permission
    /// sheet. Display only: it changes nothing that is sent. Default: none known.
    public var notReadable: @Sendable (_ caseID: UUID) async -> [CaseReadConsentRequest.Item] = { _ in [] }
    /// Package B (P1-E) — the plan's balance line for the permission sheet (nil: none to show).
    public var balanceLine: @Sendable () async -> String? = { nil }
    /// Unified path (AI-18) — the case briefing from the ledger for these documents (numbers = their
    /// [Document N]); nil = no briefing (the documents alone are read).
    public var briefing: @Sendable (_ caseID: UUID, _ documents: [CaseReader.Document]) async -> CaseLedgerBriefing? = { _, _ in nil }
    /// Unified path (AI-20) — the ledger tools for a case question, answered on this Mac and limited to
    /// these documents (numbers = their [Document N]); nil = no tools.
    public var tools: (@Sendable (_ question: String, _ documents: [CaseReader.Document]) -> (@Sendable ([CaseReader.ToolRequest]) async -> String)?) = { _, _ in nil }
    /// Unified path AI-37 (owner 2026-11-22, round 2) — not tested yet. The AI suggestions kept for a case
    /// document set (the permission fingerprint), and where new ones are kept. Default: none (nothing stored).
    public var cachedSuggestions: @Sendable (_ caseID: UUID, _ documentFingerprint: String) async -> String? = { _, _ in nil }
    public var storeSuggestions: @Sendable (_ caseID: UUID, _ documentFingerprint: String, _ briefingFingerprint: String,
                                            _ outcome: CaseAISuggestions.Outcome) async -> Void = { _, _, _, _ in }
    /// AI split AI-44 / AI-45 (owner 2026-11-23) — where the AI's quote-checked records and the case picture's read state
    /// are kept (nil: no agent writes are stored and no picture is built; the older ledger tools answer alone).
    public var aiRecords: CaseAIRecordRepository?
    /// Unified path (PERF-18) — how many parts may be read at once (WorkerBudget).
    public var concurrency: @Sendable () -> Int = { WorkerBudget.current().workers(perWorkerBytes: 64 * 1_048_576) }

    public init(documents: @escaping @Sendable (Set<UUID>) async throws -> [CaseReader.Document],
                gate: @escaping @Sendable () -> CloudSourceGate?,
                reader: @escaping @Sendable () async -> CaseReader?,
                permissions: CaseReadPermissionStore,
                askConsent: @escaping @Sendable (CaseReadConsentRequest) async -> Bool,
                wholeCaseLimit: @escaping @Sendable () -> Int = { CaseWholeReading.defaultLimit },
                providerName: @escaping @Sendable () -> String = { "your AI provider" },
                estimate: @escaping @Sendable (Int, Int) -> String = { tokens, _ in "About \(tokens.formatted()) tokens of case text." }) {
        self.documents = documents; self.gate = gate; self.reader = reader; self.permissions = permissions
        self.askConsent = askConsent; self.wholeCaseLimit = wholeCaseLimit; self.providerName = providerName; self.estimate = estimate
    }

    /// The own-key default (and AI Included's plan limit): about 300k tokens read whole. The plan limits
    /// come from AIPricing (the mirror of relay/src/policy.ts) through CaseReadLimits — never stored.
    public static let defaultLimit = 300_000
    /// AI Pro's whole-case limit (AIPricing.aiPro.caseReadTokens).
    public static var proLimit: Int { AIPricing.aiPro.caseReadTokens }

    // MARK: - The prepared case

    public struct Prepared: Sendable {
        public let documents: [CaseReader.Document]
        public let prefix: [String]
        public let tokens: Int
        public let clearance: CloudSourceClearance
        public let fingerprint: String
        public let excluded: [CaseReadConsentRequest.Item]
        public let caseDocuments: Int
        public let fits: Bool
        public let limit: Int
        /// Unified path — the briefing text and every part's prefix (a small case: one part, `prefix`).
        public let briefing: String
        public let parts: [[String]]
    }

    /// Load, clear and assemble the case. nil: nothing of the case may be sent (no gate, or every
    /// document denied) — the excluded list says why.
    public func prepare(caseID: UUID, versions: Set<UUID>, binding: CloudScopeBinding) async -> (prepared: Prepared?, excluded: [CaseReadConsentRequest.Item]) {
        guard let gate = gate()?.bound(to: binding) else { return (nil, []) }
        let all: [CaseReader.Document]
        do { all = try await documents(versions) } catch {
            KalsmritikoshLog.brain.error("case reading: documents unreadable: \(String(describing: error), privacy: .public)")
            return (nil, [])
        }
        let (clearance, denied) = await gate.clear(all.map(\.objectID), purpose: "case.reading")
        let excluded = all.filter { denied[$0.objectID] != nil }
            .map { CaseReadConsentRequest.Item(name: $0.fileName ?? "a document", bytes: $0.text.utf8.count, reason: denied[$0.objectID]) }
            .sorted { $0.name < $1.name }
        let cleared = all.filter { clearance.clearedObjectIDs.contains($0.objectID) }
        let (exact, duplicates) = CaseReader.prepare(cleared)
        // AI-19 — near-identical copies (MinHash) are sent once, named under the copy that is sent.
        let (docs, nearCopies) = CaseReader.collapseNearDuplicates(exact)
        guard !docs.isEmpty else { return (nil, excluded) }
        if duplicates + nearCopies > 0 {
            KalsmritikoshLog.brain.info("case reading: \(duplicates, privacy: .public) duplicate and \(nearCopies, privacy: .public) near-identical document(s) sent once")
        }
        // AI-17 / AI-18 / PERF-18 — ONE path: the briefing, then the documents in parts that fit the limit.
        // AI split AI-45 (owner 2026-11-23): the prefix is the case picture + the documents only. The AI suggestions (AI-37)
        // are no longer inserted here — they grew per question and broke the provider's cache; they stay on the Case tools
        // screen, and the picture's gaps and questions take their place in the briefing.
        let brief = await briefing(caseID, docs)?.text ?? ""
        let limit = wholeCaseLimit()
        let budget = CaseReader.partBudget(limit: limit, briefingTokens: CaseReader.estimatedTokens([brief]))
        let pieces = CaseReader.parts(docs, budgetTokens: budget)
        let parts = pieces.enumerated().map { i, part in
            CaseReader.partPrefix(briefing: brief, documents: docs, part: part, index: i, count: pieces.count)
        }
        let tokens = parts.reduce(0) { $0 + CaseReader.estimatedTokens($1) }
        return (Prepared(documents: docs, prefix: parts.first ?? [], tokens: tokens, clearance: clearance,
                         fingerprint: CaseReadPermission.fingerprint(caseID: caseID, versions: clearance.versions),
                         excluded: excluded, caseDocuments: all.count, fits: parts.count <= 1, limit: limit,
                         briefing: brief, parts: parts), excluded)
    }

    /// The permission for this document set: stored → true; otherwise the sheet, once; Allow stores it.
    public func permitted(caseID: UUID, prepared: Prepared, question: String) async -> Bool {
        if permissions.isGranted(caseID: caseID, fingerprint: prepared.fingerprint) { return true }
        let request = CaseReadConsentRequest(
            caseID: caseID, provider: providerName(),
            documents: prepared.documents.map { .init(name: $0.fileName ?? "a document", bytes: $0.text.utf8.count) },
            excluded: prepared.excluded, totalBytes: prepared.prefix.reduce(0) { $0 + $1.utf8.count },
            estimatedTokens: prepared.tokens, readsWhole: prepared.fits,
            estimate: estimate(prepared.tokens, CaseReader.estimatedTokens([CaseReader.questionSuffix(question)]) * max(1, prepared.parts.count)),
            fingerprint: prepared.fingerprint,
            notReadable: await notReadable(caseID), balance: await balanceLine(),
            agentLimits: aiRecords == nil ? nil : Self.agentLimitLine(prepared))
        // S10 (AI-03) — the answer covers the destination, model and key shown; one changed while the sheet was open voids it.
        let shownIdentity = permissions.currentIdentity()
        guard await askConsent(request) else {
            KalsmritikoshLog.brain.info("case reading: the person chose not now — nothing sent")
            return false
        }
        guard permissions.currentIdentity() == shownIdentity else {
            KalsmritikoshLog.brain.notice("case reading: the AI provider, model or key changed while the permission sheet was open — not stored, nothing sent")
            return false
        }
        permissions.grant(caseID: caseID, fingerprint: prepared.fingerprint, documentCount: prepared.documents.count)
        return true
    }

    // MARK: - AI split AI-44 / AI-45 (owner 2026-11-23): the agent and the case picture

    /// The limits the person is shown before the first run.
    public static func agentLimitLine(_ prepared: Prepared) -> String {
        let ceiling = CaseAgent.tokenCeiling(caseTokens: prepared.tokens, limit: prepared.limit)
        return "AI steps: each question may take up to \(CaseAgent.maxRounds) steps (search, read, the app's exact sums and dates, quote-checked records), "
            + "each re-reading the cached case, so a question can cost up to \(CaseAgent.maxRounds + 1) times the per-question amount above and never "
            + "more than about \(ceiling.formatted()) tokens. Once, and again only for new or changed documents, the AI also reads every document in "
            + "the background to build the case picture (people, events, money, conflicts and gaps — every line quote-checked), at the batch price where the provider has one."
    }

    /// The agent's tools for one question (nil: no record store wired — the older ledger tools answer alone).
    public func agentTools(caseID: UUID, question: String, documents docs: [CaseReader.Document]) -> CaseAgentTools? {
        guard let repo = aiRecords else { return nil }
        return CaseAgentTools(documents: docs, origin: "question", ledger: tools(question, docs),
                              storedRecords: Self.storedRecords(repo, caseID: caseID), store: Self.storing(repo, caseID: caseID))
    }

    static func storedRecords(_ repo: CaseAIRecordRepository, caseID: UUID) -> @Sendable () async -> [CaseAIRecord] {
        {
            do { return try await repo.records(caseID: caseID) } catch {
                KalsmritikoshLog.storage.error("AI records unreadable: \(String(describing: error), privacy: .public)")
                return []
            }
        }
    }

    static func storing(_ repo: CaseAIRecordRepository, caseID: UUID) -> @Sendable ([CaseAIRecord]) async -> Bool {
        { records in
            do { try await repo.record(caseID: caseID, records); return true } catch {
                KalsmritikoshLog.storage.error("AI records not stored: \(String(describing: error), privacy: .public)")
                return false
            }
        }
    }

    /// The case picture's read state (document → fingerprint); nil when no record store is wired.
    public func pictureState(caseID: UUID) async -> [UUID: String]? {
        guard let repo = aiRecords else { return nil }
        do { return try await repo.pictureState(caseID: caseID) } catch {
            KalsmritikoshLog.storage.error("case picture state unreadable: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// The [Document N] numbers a part's blocks carry.
    static func documentNumbers(in part: [String]) -> [Int] {
        part.compactMap { block in
            guard block.hasPrefix("[Document "), let close = block.firstIndex(of: "]") else { return nil }
            return Int(block[block.index(block.startIndex, offsetBy: 10)..<close])
        }
    }

    /// The task of one picture step (the documents to read in this part, the WRITE tools, the results so far).
    public static func pictureTask(documents: [Int], toolsAllowed: Bool, results: String?) -> String {
        var s = """
        Task: build the case picture — the investigator's map of this case — from the documents above. Read \(documents.count == 1 ? "Document" : "Documents") \(documents.map(String.init).joined(separator: ", ")) in full. \
        Record with the WRITE tools everything an investigator needs: every person and organisation (record_entity, with its type and \
        its role in the case), every dated event (record_event, the date exactly as written), every amount and money movement \
        (record_fact, saying who paid whom, the amount as written and any reference), relationships between people, organisations \
        and accounts (record_relationship), every conflict between documents (record_conflict), and what is missing or should be \
        asked (record_task, ask_person). Quote exactly; one record per statement; never record what the documents do not state. \
        When everything is recorded reply {"status": "done"}.
        """
        if toolsAllowed { s += "\n\n" + CaseAgent.guide(write: true) }
        else { s += "\n\nThis is the last step: send your remaining WRITE requests now in {\"status\": \"need_tools\", \"requests\": [...]}; nothing after this step is read." }
        if let results, !results.isEmpty { s += "\n\nTool results so far (from the app):\n" + results }
        return s
    }

    /// AI split AI-45 (owner 2026-11-23). Build or bring up to date the case picture: every document of the case whose text
    /// is new or changed since the picture last read it is read by the AI (part by part, at the batch price where available,
    /// the same cached prefix as questions), which records what it finds through the WRITE tools — each record quote-checked
    /// before it is stored. Records of a changed or removed document are withdrawn first (kept, never deleted). Runs only
    /// under the case permission already given. Returns how many records were stored.
    @discardableResult
    public func ensurePicture(_ reader: CaseReader, _ prepared: Prepared, caseID: UUID) async -> Int {
        guard let repo = aiRecords, permissions.isGranted(caseID: caseID, fingerprint: prepared.fingerprint),
              let state = await pictureState(caseID: caseID) else { return 0 }
        let docs = prepared.documents
        let fps = docs.map { CaseAgent.fingerprint($0.text) }
        let changed = Set(docs.indices.filter { state[docs[$0].objectID] != fps[$0] }.map { $0 + 1 })
        let current = Set(docs.map(\.objectID))
        let stale = docs.indices.filter { changed.contains($0 + 1) && state[docs[$0].objectID] != nil }.map { docs[$0].objectID }
            + state.keys.filter { !current.contains($0) }.sorted { $0.uuidString < $1.uuidString }
        if !stale.isEmpty {
            do { try await repo.withdraw(caseID: caseID, documents: stale, reason: "the document changed or left the case; read again") } catch {
                KalsmritikoshLog.storage.error("case picture: stale records not withdrawn: \(String(describing: error), privacy: .public)")
            }
        }
        guard !changed.isEmpty else { return 0 }
        let parts = prepared.parts.isEmpty ? [prepared.prefix] : prepared.parts
        let work = parts.indices.compactMap { i -> (Int, [Int])? in
            let nums = Self.documentNumbers(in: parts[i]).filter { changed.contains($0) }
            return nums.isEmpty ? nil : (i, Array(Set(nums)).sorted())
        }
        let clearance = prepared.clearance, ttl = questionTTL
        let width = max(1, min(concurrency(), work.count))
        do {
            let stored = try await AdaptiveConcurrency.map(work.map(\.0), cap: width, start: min(2, width)) { i in
                let nums = work.first { $0.0 == i }?.1 ?? []
                let agent = CaseAgentTools(documents: docs, origin: "picture", storedRecords: Self.storedRecords(repo, caseID: caseID),
                                           store: Self.storing(repo, caseID: caseID))
                _ = try await CaseReader.agentLoop(parts[i], rounds: CaseAgent.pictureRounds, ceiling: nil, agent: agent, processLast: true,
                                                   task: { allow, results in Self.pictureTask(documents: nums, toolsAllowed: allow, results: results) }) { prefix, suffix in
                    try await reader.send(CaseReadSend(caseID: caseID, prefix: prefix, suffix: suffix, replyTokens: CaseAgent.pictureReplyTokens,
                                                       ttl: ttl, effort: .high, purpose: "case.picture", clearance: clearance, batch: true))
                }
                do {
                    try await repo.markRead(caseID: caseID, documents: nums.map { (docs[$0 - 1].objectID, fps[$0 - 1]) },
                                            records: agent.recorded.count, rejected: agent.rejected)
                } catch {
                    KalsmritikoshLog.storage.error("case picture: read state not kept: \(String(describing: error), privacy: .public)")
                }
                return agent.recorded.count
            }
            let total = stored.reduce(0, +)
            KalsmritikoshLog.brain.info("case picture: \(changed.count, privacy: .public) document(s) read, \(total, privacy: .public) record(s) stored")
            return total
        } catch is CancellationError {
            KalsmritikoshLog.brain.info("case picture: cancelled")
            return 0
        } catch {
            KalsmritikoshLog.brain.error("case picture failed: \(OnlineFailure.scrubbed(String(describing: error)), privacy: .public)")
            return 0
        }
    }

    // MARK: - Case analysis on the whole-case path

    /// How a case analysis reads with AI. Analysis never asks for the permission: it uses the one the
    /// person already gave for the case's current documents, or reads passages as before.
    public enum AnalysisRoute: Sendable {
        /// The case fits and its permission is stored: one whole-case read per analysis kind.
        case wholeCase(CaseReader, Prepared)
        /// Read passages (today's path). `permitted`: the case's stored permission covers the passages
        /// of its cleared documents (too large to read whole) — no second per-send preview for them.
        case passages(permitted: CaseReadPermittedSet?, why: String)
    }

    public func analysisRoute(caseID: UUID, versions: Set<UUID>, binding: CloudScopeBinding) async -> AnalysisRoute {
        guard let reader = await reader() else { return .passages(permitted: nil, why: "no whole-case reader") }
        let (prepared, _) = await prepare(caseID: caseID, versions: versions, binding: binding)
        guard let prepared else { return .passages(permitted: nil, why: "nothing of the case may be sent whole") }
        guard permissions.isGranted(caseID: caseID, fingerprint: prepared.fingerprint) else {
            return .passages(permitted: nil, why: "the case's current documents are not allowed yet")
        }
        // Unified path AI-23 (owner 2026-11-22) — not tested yet. ONE path, like questions: a case too large for one
        // read is no longer sent as passages — it is read as the briefing + every part (`readForAnalysis`).
        return .wholeCase(reader, prepared)
    }

    /// Unified path AI-23 (owner 2026-11-22) — not tested yet. A case analysis on the same path as questions: the
    /// briefing + every part (`Prepared.parts`; a small case is one part, byte-identical to a question's cached
    /// prefix), each read with the analysis task as the suffix, concurrently up to `concurrency()`, and the parts'
    /// replies merged into ONE reply of the same JSON shape (`mergeAnalysisReplies`), so each analysis parses it
    /// exactly as before. Documents are numbered case-wide, so a quote cited in any part resolves.
    /// `background` (AI-24): a background analysis (method review, conflict look) — the read may go through the
    /// provider's batch service; interactive analyses (claim check, assisted runs, drafts) leave it false.
    public func readForAnalysis(_ reader: CaseReader, _ prepared: Prepared, caseID: UUID, task: String, replyTokens: Int,
                                purpose: String, background: Bool = false) async throws -> CaseReader.Reply {
        let parts = prepared.parts.isEmpty ? [prepared.prefix] : prepared.parts
        let ttl = questionTTL, clearance = prepared.clearance
        let send: @Sendable ([String]) async throws -> CaseReader.Reply = { prefix in
            try await reader.send(CaseReadSend(caseID: caseID, prefix: prefix, suffix: task, replyTokens: replyTokens,
                                               ttl: ttl, effort: .high, purpose: purpose, clearance: clearance,
                                               batch: background))
        }
        if parts.count == 1 { return try await send(parts[0]) }
        // Speed PERF-22 (owner 2026-11-23) — not tested yet. The parts under an AIMD limiter (start 2, capped by the
        // worker budget, halved on overload, Retry-After honoured); each finished part's reply kept by (case, part
        // fingerprint, task digest, part) so a retry of the same analysis re-reads only the missing parts.
        let store = CasePartReplies.current
        let width = max(1, min(concurrency(), parts.count))
        let got = try await AdaptiveConcurrency.map(Array(parts.indices), cap: width, start: min(2, width)) { i in
            try await CaseReader.keptOrRead(store: store, caseID: caseID, prefix: parts[i], task: task, part: i,
                                            usable: { $0.contains("{") && $0.contains("}") }) {
                try await send(parts[i])
            }
        }
        KalsmritikoshLog.brain.info("case analysis: \(got.count, privacy: .public) part(s) read and merged (\(purpose, privacy: .public))")
        return CaseReader.Reply(text: Self.mergeAnalysisReplies(got.map(\.text)), usage: Self.sum(got.compactMap(\.usage)))
    }

    /// Unified path AI-37 (owner 2026-11-22, round 2) — not tested yet. AI all the time: once per case document set,
    /// one extra read (briefing + documents, the suggestions task) for leads, questions and gaps; only items that cite
    /// real case documents (and quote them verbatim when they quote) are kept, labelled "AI suggestion". Runs only
    /// under the case permission already given; a failure is logged and leaves the briefing as it was.
    public func ensureAISuggestions(_ reader: CaseReader, _ prepared: Prepared, caseID: UUID) async {
        guard !prepared.briefing.isEmpty, !prepared.briefing.contains("## AI suggestions"),
              permissions.isGranted(caseID: caseID, fingerprint: prepared.fingerprint),
              await cachedSuggestions(caseID, prepared.fingerprint) == nil else { return }
        do {
            let reply = try await readForAnalysis(reader, prepared, caseID: caseID, task: CaseAISuggestions.task,
                                                  replyTokens: CaseAISuggestions.replyTokens, purpose: "case.suggestions")
            let outcome = CaseAISuggestions.verify(reply: reply.text, texts: prepared.documents.map(\.text))
            let briefingFingerprint = OnlineCloudProvider.sha256(prepared.briefing)
            await storeSuggestions(caseID, prepared.fingerprint, briefingFingerprint, outcome)
            KalsmritikoshLog.brain.info("AI suggestions: \(outcome.items.count, privacy: .public) kept, \(outcome.dropped, privacy: .public) dropped")
        } catch is CancellationError {
            KalsmritikoshLog.brain.info("AI suggestions: cancelled")
        } catch {
            KalsmritikoshLog.brain.error("AI suggestions failed: \(OnlineFailure.scrubbed(String(describing: error)), privacy: .public)")
        }
    }

    /// AI-23 — the parts' usage as one (tokens added; the first part's model and purpose).
    static func sum(_ usages: [CloudCallUsage]) -> CloudCallUsage? {
        guard var total = usages.first else { return nil }
        for u in usages.dropFirst() {
            total.inputTokens += u.inputTokens; total.cacheWriteTokens += u.cacheWriteTokens
            total.cacheReadTokens += u.cacheReadTokens; total.outputTokens += u.outputTokens
            if u.stopReason == "max_tokens" { total.stopReason = "max_tokens" }
        }
        return total
    }

    /// AI-23 — the parts' JSON replies as one reply of the same shape: for each top-level key, arrays are joined
    /// (an item repeated verbatim kept once), texts joined when different, `status` is the first that is not
    /// "not_stated", booleans are true only when every part says true (e.g. "complete"), anything else is the first
    /// part's. A part whose reply is not a JSON object is skipped (logged); none readable → the first reply as is.
    public static func mergeAnalysisReplies(_ replies: [String]) -> String {
        var merged: [String: Any] = [:]
        var order: [String] = []
        var seenItems: [String: Set<String>] = [:]
        var readable = 0
        for r in replies {
            let body = r.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let start = body.firstIndex(of: "{"), let end = body.lastIndex(of: "}"), start < end,
                  let data = String(body[start...end]).data(using: .utf8) else {
                KalsmritikoshLog.brain.info("case analysis: a part's reply has no JSON object; skipped in the merge")
                continue
            }
            let root: [String: Any]
            do {
                guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                root = obj
            } catch {
                KalsmritikoshLog.brain.info("case analysis: a part's reply is not JSON (\(error.localizedDescription, privacy: .public)); skipped in the merge")
                continue
            }
            readable += 1
            for key in root.keys.sorted() {
                let value = root[key] as Any
                guard let current = merged[key] else {
                    merged[key] = value; order.append(key)
                    if let list = value as? [Any] { seenItems[key] = Set(list.map(Self.canonical)) }
                    continue
                }
                if var list = current as? [Any], let more = value as? [Any] {
                    var seen = seenItems[key] ?? []
                    for item in more where seen.insert(Self.canonical(item)).inserted { list.append(item) }
                    merged[key] = list; seenItems[key] = seen
                } else if key == "status", let a = current as? String, let b = value as? String {
                    if a.lowercased() == "not_stated", b.lowercased() != "not_stated" { merged[key] = b }
                } else if Self.isBool(current), Self.isBool(value), let a = current as? Bool, let b = value as? Bool {
                    merged[key] = a && b
                } else if let a = current as? String, let b = value as? String {
                    let bt = b.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !bt.isEmpty, !a.contains(bt) { merged[key] = a.isEmpty ? bt : a + " " + bt }
                }
            }
        }
        guard readable > 0 else { return replies.first ?? "" }
        do {
            return String(decoding: try JSONSerialization.data(withJSONObject: merged, options: [.sortedKeys]), as: UTF8.self)
        } catch {
            KalsmritikoshLog.brain.error("case analysis: merged reply could not be encoded: \(error.localizedDescription, privacy: .public)")
            return replies.first ?? ""
        }
    }

    static func isBool(_ v: Any) -> Bool {
        guard let n = v as? NSNumber else { return false }
        return CFGetTypeID(n) == CFBooleanGetTypeID()
    }

    static func canonical(_ item: Any) -> String {
        if JSONSerialization.isValidJSONObject(item),
           let d = try? JSONSerialization.data(withJSONObject: item, options: [.sortedKeys]) { return String(decoding: d, as: UTF8.self) }
        return String(describing: item)
    }
}
