//
//  ALCOAGroup2Tests.swift
//  KalsmritikoshTests
//
//  ALCOA++ program, group 2 (owner 2026-11-24; docs/ALCOA_PROGRAM_2026-11-24.md): ALC-02 attributable AI (runs, record
//  provenance, the person's decisions), ALC-07 traceable (new chain sources, append-only core logs), ALC-08 reliable model
//  (served model logged, fallback labelled, fair-eval gate), ALC-10 complete (revision capture with a reason).
//  Scripted readers only: no model, no network, no API spend.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("ALCOA group 2 — ALC-02/07/08/10", .serialized)
struct ALCOAGroup2Tests {

    static let asked = "model-asked-for"
    static let served = "model-that-answered"

    // MARK: - ALC-02

    @Test("ALC-02: every question and picture pass is a run (provider, model asked/served, person, inputs, coverage, usage); its records link to it")
    func attributedRunsAndRecords() async throws {
        let r = try await AgentSplitX2Tests.rig(AgentSplitX2Tests.docs(), served: { _ in Self.served }, requested: Self.asked) { send in
            send.purpose == "case.picture" ? AgentSplitX2Tests.pictureReply(send) : AgentSplitX2Tests.questionReply(send)
        }
        _ = try await r.service.answer(caseID: r.caseID, question: "Was Kestrel Supplies paid twice for INV-104?", access: .testUnrestricted())
        let runs = try await r.repo.runs(caseID: r.caseID)
        let picture = try #require(runs.first { $0.kind == "picture" }), question = try #require(runs.first { $0.kind == "question" })
        for run in [picture, question] {
            #expect(run.state == "done" && run.provider == "anthropic" && run.modelRequested == Self.asked, "\(run)")
            #expect(run.modelServed == Self.served && run.fallback, "another model answered: labelled a fallback")
            #expect(run.requestedBy == "this Mac's owner")
        }
        let row = try #require(try await r.db.query("""
            SELECT input_revisions_json, coverage_json, model_calls, input_tokens, prompt_version, length(cache_key) FROM case_ai_runs WHERE id = ?;
            """, [.uuid(question.id)]).first)
        #expect((row.string(0) ?? "").contains("-") && (row.string(1) ?? "").contains("\"sent\":2"), "inputs and coverage recorded")
        #expect((row.int(2) ?? 0) >= 2 && (row.int(3) ?? 0) >= 200, "every call counted")
        #expect(row.string(4) == CaseAgent.promptVersion && row.int(5) == 64)
        let records = try await r.repo.records(caseID: r.caseID)
        #expect(!records.isEmpty)
        for rec in records {
            #expect(rec.runID == picture.id, "a picture record links to its run")
            #expect(rec.modelRequested == Self.asked && rec.modelServed == Self.served && rec.requestedBy == "this Mac's owner")
            #expect(rec.promptVersion == CaseAgent.promptVersion && rec.requestSHA256?.count == 64)
        }
        #expect(CaseAIReviewText.provenance(records[0], run: picture).contains("answered by \(Self.served) (fallback)"))
    }

    @Test("ALC-02: a finished run is never edited; the run kinds the agent uses are admitted")
    func runIsFixed() async throws {
        let f = try await CaseErasureTests.boot()
        defer { try? FileManager.default.removeItem(at: f.temp) }
        let repo = CaseAIRecordRepository(database: f.db)
        let start = CaseAIRecordRepository.RunStart(kind: .question, task: "q", provider: "anthropic", modelRequested: Self.asked, requestedBy: "Asha",
                                                    documentsFingerprint: "fp", inputVersions: [UUID()], coverage: ["sent": 1], promptVersion: CaseAgent.promptVersion)
        let id = try await repo.openRun(caseID: f.caseA, start)
        var u = CloudCallUsage(inputTokens: 5, cacheWriteTokens: 0, cacheReadTokens: 0, outputTokens: 1, purpose: "case.question", provider: "anthropic")
        u.model = Self.asked
        try await repo.finishRun(id, caseID: f.caseA, state: "done", reason: nil, usage: [u], counts: ["recordsStored": 0])
        let run = try #require(try await repo.runs(caseID: f.caseA).first)
        #expect(run.requestedBy == "Asha" && run.modelServed == Self.asked && !run.fallback)
        await #expect(throws: (any Error).self) {
            try await f.db.exec("UPDATE case_ai_runs SET answered_by_model = 'x' WHERE id = ?;", [.uuid(id)])
        }
        await f.state.shutdown()
    }

    @Test("ALC-02: accept / reject / correct with approver and reason, append-only; a final report uses only accepted or corrected findings")
    func decisionsAndFinalReport() async throws {
        let f = try await CaseErasureTests.boot()
        defer { try? FileManager.default.removeItem(at: f.temp) }
        let repo = CaseAIRecordRepository(database: f.db)
        let doc = UUID()
        let a = CaseAIRecord(kind: .fact, text: "Kestrel was paid twice", quote: "debit INR 50,000 to Kestrel", document: doc, origin: "picture")
        let b = CaseAIRecord(kind: .fact, text: "Meera approved the amendment", quote: "Approved by Meera Iyer", document: doc, origin: "picture")
        let c = CaseAIRecord(kind: .fact, text: "The refund came on 18 March", quote: "19 Mar 2026: credit", document: doc, origin: "picture")
        try await repo.record(caseID: f.caseA, [a, b, c])
        // Rules: a reject or correct needs a reason; a correct needs wording; an approver is named.
        await #expect(throws: CaseAIRecordRepository.DecisionError.reasonNeeded) { try await repo.decide(caseID: f.caseA, recordID: a.id, .reject, reason: " ", approver: "Asha") }
        await #expect(throws: CaseAIRecordRepository.DecisionError.correctionNeeded) { try await repo.decide(caseID: f.caseA, recordID: c.id, .correct, reason: "date", approver: "Asha") }
        await #expect(throws: CaseAIRecordRepository.DecisionError.blankApprover) { try await repo.decide(caseID: f.caseA, recordID: b.id, .accept, reason: nil, approver: "") }
        await #expect(throws: CaseAIRecordRepository.DecisionError.notInCase) { try await repo.decide(caseID: f.caseB, recordID: b.id, .accept, reason: nil, approver: "Asha") }
        try await repo.decide(caseID: f.caseA, recordID: a.id, .reject, reason: "paid once; the second debit is INV-109", approver: "Asha")
        try await repo.decide(caseID: f.caseA, recordID: b.id, .accept, reason: nil, approver: "Asha")
        try await repo.decide(caseID: f.caseA, recordID: c.id, .correct, correctedText: "The refund came on 19 March", reason: "the date is 19 Mar", approver: "Asha")
        // A later decision is a new row; the latest counts.
        try await repo.decide(caseID: f.caseA, recordID: a.id, .accept, reason: nil, approver: "Ravi")
        #expect(try await repo.decisions(caseID: f.caseA).count == 4)
        #expect(try await repo.latestDecisions(caseID: f.caseA)[a.id]?.approver == "Ravi")
        let final = try await repo.reportRecords(caseID: f.caseA, final: true).map(\.text)
        #expect(Set(final) == ["Kestrel was paid twice", "Meera approved the amendment", "The refund came on 19 March"])
        try await repo.decide(caseID: f.caseA, recordID: a.id, .reject, reason: "on reflection, paid once", approver: "Ravi")
        let final2 = try await repo.reportRecords(caseID: f.caseA, final: true).map(\.text)
        #expect(!final2.contains("Kestrel was paid twice"))
        #expect(try await repo.reportRecords(caseID: f.caseA, final: false).count == 3, "a draft lists every finding")
        let text = CaseAIRecordRepository.reportText(try await repo.reportRecords(caseID: f.caseA, final: true), final: true)
        #expect(text.hasPrefix("AI findings — final") && text.contains("approved"))
        // Append-only.
        await #expect(throws: (any Error).self) { try await f.db.exec("UPDATE case_ai_record_decisions SET approver = 'x';", []) }
        await #expect(throws: (any Error).self) { try await f.db.exec("DELETE FROM case_ai_record_decisions;", []) }
        #expect(CaseAIReviewText.decision(try await repo.latestDecisions(caseID: f.caseA)[c.id]).contains("Corrected by Asha"))
        // A case erasure takes them with the case.
        let report = try await CaseEraser(database: f.db).erase(caseID: f.caseA, sourceVersionIDs: [], eraseExclusiveSources: false,
                                                                reason: "test", legalBasis: nil, actor: "Tester")
        #expect(report.refused == nil, "\(report.refused ?? "")")
        #expect(try await CaseErasureTests.count(f.db, "SELECT COUNT(*) FROM case_ai_record_decisions;", []) == 0)
        await f.state.shutdown()
    }
}

extension ALCOAGroup2Tests {

    // MARK: - ALC-07

    @Test("ALC-07: the app's chain seals AI records (and a withdrawal), runs, decisions, the outbound record, source versions, erasures and revisions; an edit breaks it")
    func chainSealsNewSources() async throws {
        let f = try await CaseErasureTests.boot()
        defer { try? FileManager.default.removeItem(at: f.temp) }
        let chain = try #require(await f.state.auditChain)
        let repo = CaseAIRecordRepository(database: f.db)
        let doc = UUID()
        let rec = CaseAIRecord(kind: .fact, text: "Kestrel was paid", quote: "debit INR 50,000 to Kestrel", document: doc, origin: "picture")
        try await repo.record(caseID: f.caseA, [rec])
        try await repo.decide(caseID: f.caseA, recordID: rec.id, .accept, reason: nil, approver: "Asha")
        let run = try await repo.openRun(caseID: f.caseA, .init(kind: .question, task: "q", provider: "anthropic", modelRequested: "m", requestedBy: "Asha",
                                                                 documentsFingerprint: nil, inputVersions: [], coverage: [:], promptVersion: CaseAgent.promptVersion))
        try await repo.finishRun(run, caseID: f.caseA, state: "done", reason: nil, usage: [], counts: [:])
        try await repo.withdraw(caseID: f.caseA, documents: [doc], reason: "changed")
        try await OutboundLogRepository(database: f.db).record(OutboundLogEntry(
            id: UUID(), sentAt: Date(), provider: "anthropic", model: "m", host: "api.anthropic.com", bytesSent: 10, maskedCount: 0,
            payloadSHA256: String(repeating: "a", count: 64), payloadText: "case text", responseBytes: 5, outcome: "sent", detail: nil))
        try await f.db.exec("""
            INSERT INTO case_record_revisions (id, case_id, action_id, record_kind, record_id, change, before_json, after_json, actor, recorded_at)
            VALUES (?, ?, NULL, 'profile', 'r1', 'profileSaved', '{"a":1}', '{"a":2}', 'Asha', ?);
            """, [.uuid(UUID()), .uuid(f.caseA), .date(Date())])
        let events = try await AuditChainLedgerSources.events(f.db)
        let kinds = Set(events.map(\.source))
        #expect(kinds.isSuperset(of: [.aiRecord, .aiRun, .aiDecision, .outbound, .sourceVersion, .recordRevision]), "\(kinds)")
        #expect(events.filter { $0.source == .aiRecord }.count == 2, "the record and its withdrawal")
        #expect(!events.contains { $0.canonicalPayload.contains("case text") || $0.canonicalPayload.contains("Kestrel") }, "no content in a payload")
        #expect(try await chain.seal() > 0)
        #expect(try await chain.verify().isIntact)
        // Editing a sealed AI record breaks the chain; putting it back restores it.
        try await f.db.exec("UPDATE case_ai_records SET text = 'Kestrel was paid twice' WHERE id = ?;", [.uuid(rec.id)])
        let v = try await chain.verify()
        #expect(!v.isIntact, "\(v.statusLine)")
        try await f.db.exec("UPDATE case_ai_records SET text = 'Kestrel was paid' WHERE id = ?;", [.uuid(rec.id)])
        #expect(try await chain.verify().isIntact)
        // An erasure register entry is an event too.
        _ = try await CaseEraser(database: f.db).erase(caseID: f.caseB, sourceVersionIDs: [], eraseExclusiveSources: false, reason: "test",
                                                       legalBasis: nil, actor: "Tester")
        #expect(try await AuditChainLedgerSources.events(f.db).contains { $0.source == .erasure })
        #expect(try await chain.seal() > 0, "the erasure seals (the CHECK admits the source)")
        await f.state.shutdown()
    }

    @Test("ALC-07: custody, reviews, the outbound record and source versions are append-only; only the documented exceptions pass, and erasure still works")
    func appendOnlyLogs() async throws {
        let f = try await CaseErasureTests.boot()
        defer { try? FileManager.default.removeItem(at: f.temp) }
        let db = f.db
        try await db.exec("INSERT INTO fact_reviews (id, subject_kind, subject_id, action, reviewer, reviewed_at) VALUES (?, 'event', 'e1', 'accept', 'u', 1);", [.uuid(UUID())])
        let out = UUID()
        try await OutboundLogRepository(database: db).record(OutboundLogEntry(
            id: out, sentAt: Date(), provider: "anthropic", model: "m", host: "h", bytesSent: 1, maskedCount: 0, payloadSHA256: "x",
            payloadText: "text \(OnlineCloudProvider.caseMarker(f.caseA))", responseBytes: nil, outcome: "sent", detail: OnlineCloudProvider.caseMarker(f.caseA)))
        #expect(try await CaseErasureTests.count(db, "SELECT COUNT(*) FROM custody_events;", []) > 0)
        for sql in ["UPDATE custody_events SET detail = 'x';", "DELETE FROM custody_events;", "UPDATE fact_reviews SET reason = 'x';", "DELETE FROM fact_reviews;",
                    "UPDATE outbound_log SET outcome = 'failed';", "UPDATE outbound_log SET payload_text = '[Erased with case x]';", "DELETE FROM outbound_log;",
                    "UPDATE source_versions SET content_hash = 'ab';", "UPDATE source_versions SET filename = 'renamed.txt';", "DELETE FROM source_versions;"] {
            await #expect(throws: (any Error).self, "\(sql)") { try await db.exec(sql, []) }
        }
        // Retiring a version once, and attaching its document once, still pass.
        let sv = try #require(try await db.query("SELECT id FROM source_versions WHERE is_current = 1 LIMIT 1;", []).first?.string(0))
        try await db.exec("UPDATE source_versions SET is_current = 0, valid_to = 5 WHERE id = ?;", [.text(sv)])
        await #expect(throws: (any Error).self) { try await db.exec("UPDATE source_versions SET is_current = 1 WHERE id = ?;", [.text(sv)]) }
        await #expect(throws: (any Error).self) { try await db.exec("UPDATE source_versions SET valid_to = 9 WHERE id = ?;", [.text(sv)]) }
        try await db.exec("UPDATE source_versions SET is_current = 1, valid_to = NULL WHERE 0;", [])
        #expect(try await CaseErasureTests.count(db, "SELECT COUNT(*) FROM append_only_logs;", []) == 4)
        // The documented exception: a case erasure (with its own documents) removes the text sent, its custody and versions.
        let versions = Set(try await db.query("SELECT id FROM source_versions;", []).compactMap { $0.uuid(0) })
        let report = try await CaseEraser(database: db).erase(caseID: f.caseA, sourceVersionIDs: versions, eraseExclusiveSources: true,
                                                              reason: "test", legalBasis: nil, actor: "Tester")
        #expect(report.refused == nil, "\(report.refused ?? "")")
        let text = try await db.query("SELECT payload_text, payload_sha256 FROM outbound_log WHERE id = ?;", [.uuid(out)]).first
        #expect(text?.string(0)?.hasPrefix(CaseEraser.erasedOutboundPrefix) == true && text?.string(1) == "x", "text gone, digest kept")
        #expect(try await CaseErasureTests.count(db, "SELECT COUNT(*) FROM source_versions WHERE logical_source_id = ?;", [.uuid(f.exclusiveFile)]) == 0)
        // A full erase still empties everything.
        #expect(await f.state.deleteAllData() >= 0)
        #expect(try await CaseErasureTests.count(db, "SELECT COUNT(*) FROM outbound_log;", []) == 0)
        #expect(try await CaseErasureTests.count(db, "SELECT COUNT(*) FROM custody_events;", []) == 0)
        #expect(try await CaseErasureTests.count(db, "SELECT COUNT(*) FROM source_versions;", []) == 0)
        await f.state.shutdown()
    }
}

extension ALCOAGroup2Tests {

    // MARK: - ALC-08

    @Test("ALC-08: the provider's case read logs the model that answered on the sent row; a fallback is visible; the row is fixed")
    func servedModelLogged() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        let caseID = UUID(), o = UUID(), v = UUID()
        let binding = CloudScopeBinding(scopeID: caseID) { [o: [v]] }
        let clearance = await CloudSourceGate(resolve: { _ in .resolved(ProtectionLabel(sensitivity: .internalLevel, privileged: false)) },
                                              legacyPrivileged: { [] }).bound(to: binding).clear([o], purpose: "case.reading").clearance
        let reply = Data(#"{"model":"other-model","content":[{"type":"text","text":"{\"status\":\"not_stated\"}"}],"usage":{"input_tokens":3,"output_tokens":8}}"#.utf8)
        let snapshot = OnlineSnapshot(cloudAllowed: true, kind: .anthropic, model: "asked-model", apiKey: "test-key",
                                      confirmedDocumentTerms: OnlineProviderKind.anthropic.documentTermsVersion, dailyByteCap: nil)
        let permissions = CaseReadPermissionStore.inMemory()
        var seams = OnlineCloudProvider.Seams(settings: { snapshot }, consent: { _ in false },
                                              transport: { _ in OutboundHTTPResponse(status: 200, body: reply) })
        seams.casePermission = { id, fp in permissions.isGranted(caseID: id, fingerprint: fp) }
        let log = OutboundLogRepository(database: db)
        let provider = OnlineCloudProvider(outboundLog: log, knownNames: { [] }, seams: seams)
        permissions.grant(caseID: caseID, fingerprint: CaseReadPermission.fingerprint(caseID: caseID, versions: clearance.versions), documentCount: 1)
        let send = CaseReadSend(caseID: caseID, prefix: [CaseReader.header, "[Document 1]\nA short case text.\n\n" + CaseReader.footer],
                                suffix: CaseReader.questionSuffix("When?"), ttl: .fiveMinutes, purpose: "case.question", clearance: clearance)
        let out = try await provider.readCase(send)
        #expect(out.usage?.model == "other-model")
        let sent = try #require(try await log.recent().first { $0.outcome == "sent" })
        #expect(sent.model == "asked-model" && sent.modelServed == "other-model" && sent.isFallback)
        #expect(try await log.recent().filter { $0.outcome == "sending" }.allSatisfy { $0.modelServed == nil }, "the pending row has no reply yet")
        await #expect(throws: (any Error).self) { try await db.exec("UPDATE outbound_log SET model_served = 'asked-model';", []) }
        // The relay's label is read when the reply has no model field of its own.
        #expect(OnlineRequestBuilder.servedModel(kind: .included, body: Data(#"{"content":[],"kals":{"model_served":"m2","fallback":true}}"#.utf8)) == "m2")
        #expect(OnlineRequestBuilder.servedModel(kind: .gemini, body: reply) == nil)
    }

    @Test("ALC-08: an answer read by another model than the one asked for says \"Answered by … (fallback)\"; the same model says nothing")
    func fallbackShownInAnswer() async throws {
        #expect(CaseWholeReading.fallbackNote(requested: "a", served: ["a"]) == nil)
        #expect(CaseWholeReading.fallbackNote(requested: "a", served: []) == nil)
        #expect(CaseWholeReading.fallbackNote(requested: "a", served: ["a", "b"])?.contains("Answered by b (fallback; a was asked for)") == true)
        let r = try await AgentSplitX2Tests.rig(AgentSplitX2Tests.docs(), served: { _ in Self.served }, requested: Self.asked) { send in
            send.purpose == "case.picture" ? AgentSplitX2Tests.pictureReply(send) : AgentSplitX2Tests.questionReply(send)
        }
        let a = try await r.service.answer(caseID: r.caseID, question: "Was Kestrel Supplies paid twice for INV-104?", access: .testUnrestricted()).verified
        #expect(a.body.contains("Answered by \(Self.served) (fallback; \(Self.asked) was asked for)"), "\(a.body)")
        let same = try await AgentSplitX2Tests.rig(AgentSplitX2Tests.docs(), served: { _ in Self.asked }, requested: Self.asked) { send in
            send.purpose == "case.picture" ? AgentSplitX2Tests.pictureReply(send) : AgentSplitX2Tests.questionReply(send)
        }
        let b = try await same.service.answer(caseID: same.caseID, question: "Was Kestrel Supplies paid twice for INV-104?", access: .testUnrestricted()).verified
        #expect(!b.body.contains("(fallback"))
    }

    @Test("ALC-08: the fair-eval release gate exists, is required, and checks the pinned models against a recorded fair evaluation")
    func fairEvalGate() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let gates = try String(contentsOf: root.appendingPathComponent("ci/release-gates.json"), encoding: .utf8)
        #expect(gates.contains("\"id\": \"fair-eval\"") && gates.contains("scripts/release-check-fair-eval.sh"))
        let script = try String(contentsOf: root.appendingPathComponent("scripts/release-check-fair-eval.sh"), encoding: .utf8)
        #expect(script.contains("DEFAULT_ANTHROPIC_MODEL") && script.contains("ANTHROPIC_MODEL") && script.contains("relayModel"))
        #expect(script.contains("Model evaluated:") && script.contains("agent-eval-*/FAIR*.md"))
    }
}

/// Test fixtures only: a fixture that simulates a changed or vanished source version edits source_versions directly, which
/// the v212 guards refuse. This drops the two guards on that test's own temporary ledger (never used by the app).
enum LedgerGuards {
    static func stepAside(_ db: Database) async throws {
        try await db.exec("DROP TRIGGER IF EXISTS source_versions_fixed;", [])
        try await db.exec("DROP TRIGGER IF EXISTS source_versions_kept;", [])
    }
}
