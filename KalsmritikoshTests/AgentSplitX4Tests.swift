//
//  AgentSplitX4Tests.swift
//  KalsmritikoshTests
//
//  AI split X4 (AI-49, owner 2026-11-24) — an archive question asks permission ONCE (then the agent's steps run with no
//  further preview, through the real Online provider: clearance, masking, re-clearance, the outbound record); privileged
//  documents are never sent; "Not now" sends nothing; the permission is bound to the question, the cap, the AI account and
//  an unscoped archive-reading clearance. The archive-wide answer callers route through the agent. The screens label the
//  AI's records "Found by AI · quote checked" and rule output "Hint (rule-made, not checked)"; the Quality strip counts only
//  AI-verified conflicts. Scripted transport only: no model, no network, no API spend.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("AI split X4 — archive consent once per question, callers on the agent, AI vs hint labels", .serialized)
struct AgentSplitX4Tests {

    nonisolated final class Counter: @unchecked Sendable {
        private let lock = NSLock(); private var n = 0; private var bodies: [String] = []
        func bump() { lock.withLock { n += 1 } }
        var count: Int { lock.withLock { n } }
        func add(_ s: String) { lock.withLock { bodies.append(s) } }
        var all: [String] { lock.withLock { bodies } }
    }

    static let gate = { (privileged: UUID) in
        CloudSourceGate(resolve: { id in .resolved(ProtectionLabel(sensitivity: .internalLevel, privileged: id == privileged)) },
                        legacyPrivileged: { [] })
    }

    /// The archive agent over three documents (bank, credit note, privileged advice) sending through the REAL Online provider
    /// with a scripted transport; `previews` counts the provider's per-send consent previews.
    static func world(previews: Counter, transport: Counter, db: Database) -> (ArchiveAgent, OnlineCloudProvider, [UUID]) {
        let ids = [UUID(), UUID(), UUID()]
        let texts = [ids[0]: AgentSplitX3Tests.bank, ids[1]: AgentSplitX3Tests.refund, ids[2]: AgentSplitX3Tests.privileged]
        let names = [ids[0]: "bank.txt", ids[1]: "credit-note.txt", ids[2]: "advice.txt"]
        let snapshot = OnlineSnapshot(cloudAllowed: true, kind: .anthropic, model: "test-model", apiKey: "test-key",
                                      confirmedDocumentTerms: OnlineProviderKind.anthropic.documentTermsVersion, dailyByteCap: nil)
        var seams = OnlineCloudProvider.Seams(settings: { snapshot }, consent: { _ in previews.bump(); return false }, transport: { req in
            transport.bump()
            let sent = String(decoding: req.body, as: UTF8.self)
            transport.add(sent)
            let inner = AgentSplitX3Tests.reader(sent)
            let reply = UnifiedPathCaseTests.json(["content": [["type": "text", "text": inner]],
                                                   "usage": ["input_tokens": 10, "output_tokens": 5]])
            return OutboundHTTPResponse(status: 200, body: Data(reply.utf8))
        })
        seams.questionIdentity = { "test-account" }
        seams.ownKeyRefusal = { _ in nil }
        seams.ownKeyTally = { _, _ in }
        let provider = OnlineCloudProvider(outboundLog: OutboundLogRepository(database: db), knownNames: { [] }, seams: seams)
        let gate = Self.gate(ids[2])
        let agent = ArchiveAgent(
            search: { words in
                if words.lowercased().contains("refund") {
                    return [ArchiveAgent.Hit(objectID: ids[1], snippet: AgentSplitX3Tests.refund), ArchiveAgent.Hit(objectID: ids[2], snippet: AgentSplitX3Tests.privileged)]
                }
                return [ArchiveAgent.Hit(objectID: ids[0], snippet: AgentSplitX3Tests.bank), ArchiveAgent.Hit(objectID: ids[2], snippet: AgentSplitX3Tests.privileged)]
            },
            document: { id in texts[id].map { CaseReader.Document(objectID: id, fileName: names[id], text: $0) } },
            clear: { list in await gate.clear(list, purpose: ArchiveQuestionPermission.purpose) },
            send: { prompt, clearance in
                try await provider.generateFromDocuments(prompt: prompt, options: GenerationOptions(maxTokens: 2_000, temperature: 0, sourceClearance: clearance))
            })
        return (agent, provider, ids)
    }

    // MARK: - A. Consent once per question

    @Test("AI-49: an archive question asks once; the agent's steps then send with no further preview; privileged never sent; every send recorded")
    func askedOncePerQuestionThenNoFurtherPrompts() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        let previews = Counter(), transport = Counter(), asks = Counter()
        var (agent, _, _) = Self.world(previews: previews, transport: transport, db: db)
        let session = ArchiveQuestionSession(question: "How much did Kestrel Supplies keep?", maxDocuments: agent.maxDocuments)
        defer { session.end() }
        agent.permit = { _, _ in
            await session.decide {
                asks.bump()
                ArchiveQuestionPermission.grant(session.permission, identity: "test-account")
                return true
            }
        }
        let outcome = await ArchiveQuestionPermission.$current.withValue(session.permission) {
            await agent.answer(question: "How much did Kestrel Supplies keep?")
        }
        guard case .read(let a, let documents, let steps) = outcome else { Issue.record("no reading: \(outcome)"); return }
        #expect(asks.count == 1, "asked once for the question")
        #expect(previews.count == 0, "no per-send preview after the question's permission")
        #expect(steps == 2 && transport.count == 2, "both agent steps were sent")
        #expect(documents == 2)
        #expect(transport.all.allSatisfy { !$0.contains("Privileged legal advice") }, "the privileged document is never sent")
        #expect(a.body.contains("privileged or restricted: never sent to the AI"))
        #expect(ArchiveQuestionPermission.documentsSent(session.permission) == 2, "the cap counts distinct documents sent")
        let log = try await OutboundLogRepository(database: db).recent(limit: 10)
        #expect(log.filter { $0.outcome == "sent" && $0.detail == "covered by the question's permission" }.count == 2,
                "every send is in the outbound record, marked as covered by the question's permission")
    }

    @Test("AI-49: Not now → nothing is sent and no preview is shown")
    func notNowSendsNothing() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        let previews = Counter(), transport = Counter()
        var (agent, _, _) = Self.world(previews: previews, transport: transport, db: db)
        agent.permit = { _, _ in false }
        let outcome = await agent.answer(question: "How much did Kestrel Supplies keep?")
        guard case .notAllowed = outcome else { Issue.record("expected not allowed: \(outcome)"); return }
        #expect(transport.count == 0 && previews.count == 0)
    }

    @Test("AI-49: without the question's permission every agent step is previewed (declined here) — nothing is sent")
    func withoutPermissionEachSendPreviews() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        let previews = Counter(), transport = Counter()
        let (agent, _, _) = Self.world(previews: previews, transport: transport, db: db)
        let outcome = await agent.answer(question: "How much did Kestrel Supplies keep?")
        guard case .failed(_, let notSent) = outcome else { Issue.record("expected failed: \(outcome)"); return }
        #expect(notSent && previews.count == 1 && transport.count == 0)
    }

    @Test("AI-49: the permission covers only this question, its cap, the same AI account, an unscoped archive clearance")
    func permissionBoundaries() async {
        let ids = (0..<4).map { _ in UUID() }
        let gate = CloudSourceGate(resolve: { _ in .resolved(ProtectionLabel(sensitivity: .internalLevel, privileged: false)) }, legacyPrivileged: { [] })
        let clearA = await gate.clear([ids[0], ids[1]], purpose: ArchiveQuestionPermission.purpose).clearance
        let clearB = await gate.clear([ids[2], ids[3]], purpose: ArchiveQuestionPermission.purpose).clearance
        let otherPurpose = await gate.clear([ids[0]], purpose: "case.reading").clearance
        let caseBound = await gate.bound(to: CloudScopeBinding(scopeID: UUID()) { [ids[0]: [UUID()]] })
            .clear([ids[0]], purpose: ArchiveQuestionPermission.purpose).clearance
        let noGate = CloudSourceClearance(clearedObjectIDs: [ids[0]], deniedCount: 0, checkedAt: Date(), purpose: ArchiveQuestionPermission.purpose)
        let p = ArchiveQuestionPermission(maxDocuments: 3)
        func covers(_ c: CloudSourceClearance?, _ q: ArchiveQuestionPermission? = nil, identity: String = "acct", docs: Bool = true) -> Bool {
            ArchiveQuestionPermission.covers(q ?? p, clearance: c, carriesDocuments: docs, identity: identity)
        }
        #expect(!covers(clearA), "not granted yet")
        ArchiveQuestionPermission.grant(p, identity: "acct")
        defer { ArchiveQuestionPermission.end(p) }
        #expect(!covers(clearA, identity: "another key"), "another AI account is not covered")
        #expect(!covers(otherPurpose) && !covers(caseBound) && !covers(noGate) && !covers(nil), "only an unscoped archive-reading clearance with a gate")
        #expect(!covers(clearA, ArchiveQuestionPermission(maxDocuments: 3)), "another question is not covered")
        #expect(covers(clearA) && covers(clearA), "this question, within the cap (the same documents again count once)")
        #expect(!covers(clearB), "four distinct documents would pass the cap of three")
        #expect(ArchiveQuestionPermission.documentsSent(p) == 2)
        ArchiveQuestionPermission.end(p)
        #expect(!covers(clearA), "ended with the question")
    }

    @Test("AI-49: one question's several agent runs (an investigation's steps) share one ask")
    func sessionAsksOnce() async {
        let session = ArchiveQuestionSession(question: "q", maxDocuments: 20)
        defer { session.end() }
        let asks = Counter()
        let results = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<5 {
                group.addTask { await session.decide { asks.bump(); try? await Task.sleep(nanoseconds: 50_000_000); return true } }
            }
            var out: [Bool] = []
            for await r in group { out.append(r) }
            return out
        }
        #expect(asks.count == 1 && results == Array(repeating: true, count: 5))
    }

    @Test("AI-49: the sheet's request shows the document cap and an estimate")
    func consentRequestShowsCapAndEstimate() {
        let r = ArchiveQuestionConsent.makeRequest(question: "q", maxDocuments: 10, perDocumentCharacters: 8_000, maxRounds: 4,
                                                   found: 3, withheld: 1)
        #expect(r.maxDocuments == 10 && r.found == 3 && r.withheld == 1)
        #expect(!r.estimate.isEmpty)
        let two = ArchiveQuestionConsent.makeRequest(question: "q", maxDocuments: 20, perDocumentCharacters: 8_000, maxRounds: 4,
                                                     runs: 2, found: 3, withheld: 0)
        #expect(two.maxDocuments == 20)
    }

    // MARK: - B. Callers route through the agent

    static func source(_ rel: String) throws -> String {
        try String(contentsOf: SmartMapS9Tests.repoRoot.appendingPathComponent(rel), encoding: .utf8)
    }

    @Test("AI-49: Library, History, Highlights, as-of-date, Shortcuts/AppleScript and investigations answer through the archive agent")
    func callersRouteThroughTheAgent() throws {
        let callers = ["Kalsmritikosh/UI/LibraryView.swift", "Kalsmritikosh/UI/HistoryView.swift", "Kalsmritikosh/UI/Killer/KillerFeaturesView.swift",
                       "Kalsmritikosh/App/AppState+TimeTravel.swift", "Kalsmritikosh/App/Intents/KalsmritikoshIntents.swift"]
        for rel in callers {
            let s = try Self.source(rel)
            #expect(s.contains("answerArchive("), "\(rel) asks the archive agent")
            #expect(!s.contains("brain.answer(") && !s.contains("brain.answerStream(") && !s.contains("brain.answerWithDiagnostics("),
                    "\(rel) no longer answers on the brain's own path")
        }
        let app = try Self.source("Kalsmritikosh/App/AppState.swift")
        #expect(app.contains("makeInvestigationRunner("), "the investigation runner is the agent-backed one")
        let ask = try Self.source("Kalsmritikosh/App/AppState+ArchiveAsk.swift")
        #expect(ask.contains("answerStep: step") && ask.contains("answerArchive(question: step, session: session"),
                "an investigation's steps are read by the agent under one permission")
        let runner = try Self.source("Kalsmritikosh/Brain/InvestigationRunner.swift")
        #expect(runner.contains("if let answerStep { return await answerStep("))
    }

    // MARK: - C. Screens: AI vs hint; Quality strip

    static func record(_ kind: CaseAIRecord.Kind, _ text: String, date: String? = nil, type: String? = nil, role: String? = nil,
                       quote: String = "q", quoteB: String? = nil) -> CaseAIRecord {
        CaseAIRecord(kind: kind, text: text, entityType: type, role: role, dateText: date, quote: quote, document: UUID(), quoteB: quoteB)
    }

    @Test("AI-49: every screen's AI lines are labelled 'Found by AI · quote checked'; with no AI record the screen shows hints")
    func screensLabelAIVersusHint() throws {
        let records = [Self.record(.event, "Second debit", date: "12 Mar 2026"), Self.record(.event, "First debit", date: "05 Mar 2026"),
                       Self.record(.entity, "Kestrel Supplies", type: "organisation", role: "payee"),
                       Self.record(.entity, "Asha Rao", type: "person", role: "finance officer"),
                       Self.record(.relationship, "pays"), Self.record(.fact, "Paid twice", quote: "debit"),
                       Self.record(.conflict, "Dates differ", quote: "debit", quoteB: "refund")]
        let events = AIFindingLabels.rows(.events, records: records)
        #expect(events.map(\.title) == ["05 Mar 2026 — First debit", "12 Mar 2026 — Second debit"])
        for lens in AIFindingLabels.Lens.allCases {
            let rows = AIFindingLabels.rows(lens, records: records)
            #expect(!rows.isEmpty, "\(lens) shows the AI's records")
            #expect(rows.allSatisfy { $0.label == AIFindingLabels.ai }, "\(lens) labels AI lines")
        }
        #expect(AIFindingLabels.rows(.people, records: records).map(\.title) == ["Asha Rao"])
        #expect(AIFindingLabels.rows(.facts, records: records).first?.detail.hasPrefix("In conflict") == true)
        #expect(AIFindingLabels.rows(.story, records: records, subject: "second").count == 1)
        #expect(AIFindingLabels.source(aiRecordCount: 0) == .ruleHints && AIFindingLabels.source(aiRecordCount: 2) == .aiRecords)
        #expect(AIFindingLabels.hinted("x") == "Hint (rule-made, not checked): x" && AIFindingLabels.hinted(AIFindingLabels.hinted("x")) == AIFindingLabels.hinted("x"))
        #expect(ConflictFoundBy.rule.label == AIFindingLabels.hint && ConflictFoundBy.ai.label == AIFindingLabels.ai)
        #expect(CaseMapAssertion.rule("the archive scan").label.hasPrefix(AIFindingLabels.hint), "a rule-made map item is a hint")
        #expect(CaseMapAssertion.model("x").label.hasPrefix(AIFindingLabels.ai))
        // Every understanding screen carries the AI block and the hint banner.
        for rel in ["InsightsView", "FactStatusView", "RelationshipGraphView", "TimelineView", "CaseStoryView", "DossierView", "HistoryView", "KnowledgeView"] {
            let s = try Self.source("Kalsmritikosh/UI/\(rel).swift")
            #expect(s.contains("AIPictureBlock(") && s.contains("RuleHintBanner("), "\(rel) shows AI findings and labels rule output a hint")
        }
        #expect(try Self.source("Kalsmritikosh/UI/CaseFileView.swift").contains("CaseAIPictureSection("), "inside a case: the AI case picture")
    }

    @Test("AI-49: the Quality strip counts only AI-verified conflicts; rule conflicts are hints")
    func qualityStripCountsOnlyAIConflicts() {
        let rule = VerifiedAnswer.Contradiction(description: "Two dates", claimA: "a", claimB: "b")
        let base = VerifiedAnswer(body: "x", citations: [], confidence: .zero, contradictions: [rule])
        #expect(QualityStrip.formatLine(base).hasSuffix("Conflicts: 0"), "a rule-made conflict is not counted")
        let withAI = AIFindingLabels.withAIConflicts(base, [Self.record(.conflict, "Paid on two dates", quote: "05 Mar", quoteB: "12 Mar"),
                                                           Self.record(.fact, "not a conflict")])
        #expect(withAI.contradictions.count == 2 && withAI.aiVerifiedConflicts.count == 1 && withAI.conflictHints == [rule])
        #expect(QualityStrip.formatLine(withAI).hasSuffix("Conflicts: 1"))
        #expect(AIFindingLabels.withAIConflicts(withAI, [Self.record(.conflict, "Paid on two dates", quote: "05 Mar", quoteB: "12 Mar")]).contradictions.count == 2,
                "the same AI conflict is not added twice")
    }
}
