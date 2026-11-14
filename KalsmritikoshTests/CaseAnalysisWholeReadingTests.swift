//
//  CaseAnalysisWholeReadingTests.swift
//  KalsmritikoshTests
//
//  Plan A follow-up (2026-11-04) — fake closures and scripted transports only: no model, no network.
//    • case analysis (contradictions, roles, drafts) reads the whole case over the SAME cached prefix as
//      questions (byte-identical through the cache breakpoint) and verifies every item as before;
//    • a case too large to read whole falls back to passages, under the stored permission;
//    • the outbound record keeps one full copy of a case text and references it afterwards; a new
//      document set stores a new copy; a record that cannot be written refuses the send;
//    • passages of permitted documents send with no second preview, still masked and re-cleared;
//      a document outside the permitted set is previewed.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Plan A — case analysis on the whole-case path; outbound record; permitted passages", .serialized)
struct CaseAnalysisWholeReadingTests {
    typealias Doc = CaseWholeReadingTests.Doc
    typealias F = CaseContradictionFinder

    nonisolated final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var _sends: [CaseReadSend] = []
        private var _passages: [(String, CaseReadPermittedSet?)] = []
        private var _consents = 0
        func send(_ s: CaseReadSend) { lock.withLock { _sends.append(s) } }
        func passage(_ p: String) { lock.withLock { _passages.append((p, CaseReadPermittedSet.current)) } }
        func consent() { lock.withLock { _consents += 1 } }
        var sends: [CaseReadSend] { lock.withLock { _sends } }
        var passages: [(String, CaseReadPermittedSet?)] { lock.withLock { _passages } }
        var consents: Int { lock.withLock { _consents } }
    }

    struct Rig {
        let answers: InvestigationAnswerService
        let desk: InvestigationContradictionGapService
        let plan: CaseWholeReading
        let caseID: UUID
        let log: Log
        let docs: [Doc]
    }

    static func pairReply() -> String {
        """
        {"pairs": [
          {"about": "William Jamey Thompson", "kind": "amount",
           "a": {"passage": 1, "quote": "approximately $75,000 to obtain a fraudulently-inflated $1 million insurance policy"},
           "b": {"passage": 2, "quote": "Thompson, in exchange for placing coverage, received $50,000."},
           "value_a": "$75,000", "value_b": "$50,000"},
          {"about": "William Jamey Thompson", "kind": "amount",
           "a": {"passage": 1, "quote": "Mr. Glick then paid co-defendant William Jamey Thompson $90,000"},
           "b": {"passage": 2, "quote": "Thompson, in exchange for placing coverage, received $50,000."},
           "value_a": "$90,000", "value_b": "$50,000"}
        ]}
        """
    }

    static func timelineReply() -> String {
        """
        {"events": [{"date": "2021-03-03", "what": "Sentenced to 60 months.", "who": "William Jamey Thompson",
                     "quote": "On March 3, 2021, William Jamey Thompson was sentenced to 60 months.", "passage": 1}],
         "gaps": []}
        """
    }

    /// One case over two documents (names sort so release1 is Document 1); one plan shared by the answer
    /// service and the case desk, exactly as the app wires it.
    static func rig(limit: Int = 300_000, grant: Bool = true) async throws -> Rig {
        let docs = [Doc(version: UUID(), object: UUID(), name: "a-release1.txt", text: CaseContradictionFinderTests.release1),
                    Doc(version: UUID(), object: UUID(), name: "b-release4.txt", text: CaseContradictionFinderTests.release4)]
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        let ws = UUID()
        try await db.exec("INSERT INTO workspaces (id, title, created_at, updated_at) VALUES (?,?,?,?);",
                          [.uuid(ws), .text("Matter"), .real(1), .real(1)])
        let cases = InvestigationCaseRepository(database: db)
        let evidence = EvidenceStore(database: db)
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        var c = try await cases.createCase(workspaceID: ws, title: "Logan", actor: "u", at: t0)
        for d in docs {
            c = try await cases.includeSource(caseID: c.id, expectedRevision: c.revision, sourceRef: d.version.uuidString,
                                              sourceKind: .sourceVersion, actor: "u", at: t0)
        }
        let byVersion = Dictionary(uniqueKeysWithValues: docs.map { ($0.version, $0) })
        let log = Log()
        let permissions = CaseReadPermissionStore.inMemory()
        let gate = { CloudSourceGate(resolve: { _ in .resolved(ProtectionLabel(sensitivity: .internalLevel, privileged: false)) },
                                     legacyPrivileged: { [] }) }
        let plan = CaseWholeReading(
            documents: { versions in versions.compactMap { byVersion[$0] }.map {
                CaseReader.Document(objectID: $0.object, sourceVersionID: $0.version, fileName: $0.name, text: $0.text) } },
            gate: gate,
            reader: { CaseReader { send in
                log.send(send)
                switch send.purpose {
                case "case.analysis.contradictions": return CaseReader.Reply(text: Self.pairReply())
                case "case.analysis.drafts": return CaseReader.Reply(text: Self.timelineReply())
                case "case.analysis.roles": return CaseReader.Reply(text: #"{"roles": []}"#)
                default: return CaseReader.Reply(text: CaseWholeReadingTests.answered())
                }
            } },
            permissions: permissions,
            askConsent: { _ in log.consent(); return true },
            wholeCaseLimit: { limit })
        let answers = InvestigationAnswerService(
            cases: cases, resolver: CaseRetrievalScopeResolver(evidence: evidence), baseRetriever: CaseWholeReadingTests.EmptyRetriever(),
            evidence: evidence, makeBrain: { MasterBrain(retriever: $0) },
            objectVersions: { versions in
                Dictionary(uniqueKeysWithValues: versions.compactMap { byVersion[$0] }.map { ($0.object, Set([$0.version])) })
            },
            caseReading: plan)
        let caseID = c.id
        var pass = CaseContradictionPass(
            documents: { versions in versions.compactMap { byVersion[$0] }.map {
                F.Document(objectID: $0.object, sourceVersionID: $0.version, text: $0.text, fileName: $0.name) } },
            gate: { id in gate().bound(to: answers.cloudScope(caseID: id)) },
            reader: { CaseContradictionReader { prompt, _ in log.passage(prompt); return #"{"pairs": []}"# } })
        pass.draftReader = { CaseDraftReader { prompt, _ in log.passage(prompt); return #"{"events": [], "gaps": []}"# } }
        pass.roleReader = { VerifiedRoleReader { prompt, _ in log.passage(prompt); return #"{"roles": []}"# } }
        pass.caseReading = plan
        pass.caseBinding = { answers.cloudScope(caseID: $0) }
        let desk = InvestigationContradictionGapService(
            cases: cases, resolver: CaseRetrievalScopeResolver(evidence: evidence), evidence: evidence,
            contradictions: ContradictionsRepository(database: db), gaps: GapNodeRepository(database: db),
            reviews: InvestigationDeskReviewRepository(database: db), pass: pass)
        if grant {
            let prepared = try #require(await plan.prepare(caseID: caseID, versions: Set(docs.map(\.version)),
                                                           binding: answers.cloudScope(caseID: caseID)).prepared)
            permissions.grant(caseID: caseID, fingerprint: prepared.fingerprint, documentCount: prepared.documents.count)
        }
        return Rig(answers: answers, desk: desk, plan: plan, caseID: caseID, log: log, docs: docs)
    }

    static func body(_ r: CaseReadSend) throws -> String {
        let req = try OnlineRequestBuilder.buildCaseReading(kind: .anthropic, model: "test-model", apiKey: "k", system: nil, prefix: r.prefix,
                                                            suffix: r.suffix, replyTokens: r.replyTokens, ttl: r.ttl, effort: r.effort)
        return String(decoding: req.body, as: UTF8.self)
    }

    // MARK: - Analysis on the whole case

    @Test("Contradictions: one whole-case call over the questions' prefix (byte-identical through the breakpoint); every pair verified as before")
    func contradictionsWholeCase() async throws {
        let r = try await Self.rig()
        _ = try await r.answers.answer(caseID: r.caseID, question: "How much was William Jamey Thompson paid?", access: .testUnrestricted())
        let run = try await r.desk.findContradictions(caseID: r.caseID, at: Date(timeIntervalSince1970: 1_767_500_000))
        #expect(run.readWholeCase && run.calls == 1 && run.failedCalls == 0, "\(run.failures) \(run.passagePathReason ?? "")")
        #expect(r.log.passages.isEmpty, "no passage batches when the whole case is read")
        #expect(r.log.consents == 0, "the stored permission is used, never asked by an analysis")
        let sends = r.log.sends
        #expect(sends.map(\.purpose) == ["case.question", "case.analysis.contradictions"])
        guard sends.count == 2 else { return }
        #expect(sends[0].prefix == sends[1].prefix && sends[0].ttl == sends[1].ttl)
        #expect(sends[1].suffix == F.wholeCaseTask() && sends[1].replyTokens == F.wholeCaseReplyTokens)
        // The cache is keyed by the prompt (system, messages) through the breakpoint, not by max_tokens:
        // compare the bodies from "messages" on (sorted keys; the reply budget differs per analysis kind).
        func messages(_ body: String) -> String { body.range(of: #""messages":"#).map { String(body[$0.lowerBound...]) } ?? "" }
        let b0 = messages(try Self.body(sends[0])), b1 = messages(try Self.body(sends[1]))
        #expect(!b0.isEmpty && !b1.isEmpty)
        let shared = String(b0.prefix(zip(b0, b1).prefix { $0 == $1 }.count))
        #expect(shared.contains(#""cache_control":{"ttl":"1h","type":"ephemeral"}"#), "the cache breakpoint is inside the shared bytes")
        #expect(shared.contains("End of the case"))
        // The verification is unchanged: the fabricated $90,000 pair is dropped; the real one is the rules' pair.
        #expect(run.aiDropped.contains { $0.hasPrefix("quote not in its passage") }, "\(run.aiDropped)")
        #expect(run.aiAgreedWithRules == 1 && run.aiFindings.isEmpty)
    }

    @Test("Drafts: one role call and one drafting call over the same prefix; items verified as before")
    func draftsWholeCase() async throws {
        let r = try await Self.rig()
        let out = try await r.desk.buildDrafts(caseID: r.caseID, useAI: true)
        #expect(out.readWholeCase && out.calls == 1, "\(out.failures)")
        #expect(r.log.passages.isEmpty)
        let sends = r.log.sends
        #expect(Set(sends.map(\.purpose)) == ["case.analysis.roles", "case.analysis.drafts"])
        #expect(Set(sends.map(\.prefix)).count == 1, "one cached prefix for every analysis kind")
        #expect(out.dropped.contains { $0.contains("quote not in its passage") }, "a quote not in the document never ships: \(out.dropped)")
        #expect(!out.timeline.contains { $0.provenance == .aiRead })
    }

    @Test("Too large to read whole: analysis reads passages, under the stored permission")
    func tooLargeAnalysisFallsBack() async throws {
        let r = try await Self.rig(limit: 10)
        let run = try await r.desk.findContradictions(caseID: r.caseID, at: Date(timeIntervalSince1970: 1_767_500_000))
        #expect(!run.readWholeCase && run.passagePathReason?.contains("too large") == true, "\(run.passagePathReason ?? "")")
        #expect(r.log.sends.isEmpty, "no whole-case call")
        let passages = r.log.passages
        #expect(!passages.isEmpty)
        #expect(passages.allSatisfy { $0.1?.caseID == r.caseID && $0.1?.versions.count == 2 }, "the permitted set reaches the send")
    }

    @Test("No stored permission: analysis reads passages as before, with no permitted set")
    func noPermissionPassagesAsBefore() async throws {
        let r = try await Self.rig(grant: false)
        let run = try await r.desk.findContradictions(caseID: r.caseID, at: Date(timeIntervalSince1970: 1_767_500_000))
        #expect(!run.readWholeCase && r.log.sends.isEmpty && r.log.consents == 0)
        #expect(!r.log.passages.isEmpty && r.log.passages.allSatisfy { $0.1 == nil })
    }

    // MARK: - The provider: outbound record and permitted passages

    nonisolated final class Counter: @unchecked Sendable {
        private let lock = NSLock(); private var n = 0; private var bodies: [Data] = []
        func hit(_ d: Data) { lock.withLock { n += 1; bodies.append(d) } }
        var count: Int { lock.withLock { n } }
        var all: [Data] { lock.withLock { bodies } }
    }

    nonisolated final class Flag: @unchecked Sendable {
        private let lock = NSLock(); private var v = false
        func set() { lock.withLock { v = true } }
        var isSet: Bool { lock.withLock { v } }
    }

    static let snapshot = OnlineSnapshot(cloudAllowed: true, kind: .anthropic, model: "test-model", apiKey: "test-key",
                                         confirmedDocumentTerms: OnlineProviderKind.anthropic.documentTermsVersion, dailyByteCap: nil)
    static let reply = Data(#"{"content":[{"type":"text","text":"An answer."}],"usage":{"input_tokens":3,"output_tokens":2}}"#.utf8)

    static func clearance(_ caseID: UUID, _ map: [UUID: Set<UUID>], current: (@Sendable () -> [UUID: Set<UUID>])? = nil) async -> CloudSourceClearance {
        let now = current ?? { map }
        return await CloudSourceGate(resolve: { _ in .resolved(ProtectionLabel(sensitivity: .internalLevel, privileged: false)) },
                                     legacyPrivileged: { [] })
            .bound(to: CloudScopeBinding(scopeID: caseID) { now() }).clear(Array(map.keys), purpose: "case.reading").clearance
    }

    @Test("Outbound record: the case text is kept once per exact text and referenced after; a new document set stores a new copy")
    func outboundLogOneCopy() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        let caseID = UUID(), o1 = UUID(), v1 = UUID(), o2 = UUID(), v2 = UUID()
        let permissions = CaseReadPermissionStore.inMemory()
        let counter = Counter()
        var seams = OnlineCloudProvider.Seams(settings: { Self.snapshot }, consent: { _ in Issue.record("no per-send dialog"); return false },
                                              transport: { req in counter.hit(req.body); return OutboundHTTPResponse(status: 200, body: Self.reply) })
        seams.casePermission = { id, fp in permissions.isGranted(caseID: id, fingerprint: fp) }
        let provider = OnlineCloudProvider(outboundLog: OutboundLogRepository(database: db), knownNames: { [] }, seams: seams)
        let one = await Self.clearance(caseID, [o1: [v1]])
        permissions.grant(caseID: caseID, fingerprint: CaseReadPermission.fingerprint(caseID: caseID, versions: one.versions), documentCount: 1)
        let prefix1 = [CaseReader.header, "[Document 1]\n" + CaseWholeReadingTests.sentencing + "\n\n" + CaseReader.footer]
        for q in ["When?", "Who?", "How long?"] {
            _ = try await provider.readCase(CaseReadSend(caseID: caseID, prefix: prefix1, suffix: CaseReader.questionSuffix(q),
                                                         ttl: .oneHour, purpose: "case.question", clearance: one))
        }
        #expect(counter.count == 3)
        let repo = OutboundLogRepository(database: db)
        var log = try await repo.recent()
        #expect(log.count == 6, "a pending and a sent entry per read")
        #expect(log.filter { $0.payloadText.contains(CaseWholeReadingTests.sentencing) }.count == 1, "ONE full copy of the case text")
        let refs = log.filter { $0.payloadText.hasPrefix("[Case text not repeated") }
        #expect(refs.count == 5)
        #expect(refs.allSatisfy { $0.payloadText.contains(caseID.uuidString) && !$0.payloadText.contains(CaseWholeReadingTests.sentencing) })
        #expect(refs.contains { $0.payloadText.contains("How long?") }, "the question itself is recorded")
        // The full copy is found by the marker in a reference's detail; every entry's SHA is of the full text sent.
        let digest = OnlineCloudProvider.sha256(prefix1.joined(separator: "\n\n"))
        let full = try #require(try await repo.firstEntry(detailContaining: OnlineCloudProvider.caseTextFullTag(digest)))
        #expect(full.payloadText.contains(CaseWholeReadingTests.sentencing))
        let sentWho = OnlineCloudProvider.sha256(prefix1.joined(separator: "\n\n") + "\n\n" + CaseReader.questionSuffix("Who?"))
        #expect(log.contains { $0.payloadSHA256 == sentWho && $0.payloadText.hasPrefix("[Case text not repeated") })
        // A new document set: a new full copy.
        let two = await Self.clearance(caseID, [o1: [v1], o2: [v2]])
        permissions.grant(caseID: caseID, fingerprint: CaseReadPermission.fingerprint(caseID: caseID, versions: two.versions), documentCount: 2)
        let prefix2 = [CaseReader.header, "[Document 1]\n" + CaseWholeReadingTests.sentencing,
                       "[Document 2]\n" + CaseWholeReadingTests.charging + "\n\n" + CaseReader.footer]
        _ = try await provider.readCase(CaseReadSend(caseID: caseID, prefix: prefix2, suffix: CaseReader.questionSuffix("When?"),
                                                     ttl: .oneHour, purpose: "case.question", clearance: two))
        log = try await repo.recent()
        #expect(log.filter { $0.payloadText.contains(CaseWholeReadingTests.charging) }.count == 1, "the new set is stored in full once")
        #expect(log.filter { $0.payloadText.contains(CaseWholeReadingTests.sentencing) }.count == 2)
    }

    @Test("No record, no send: a record that cannot be written refuses the case read")
    func loggingFailureRefuses() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        let caseID = UUID(), o = UUID(), v = UUID()
        let counter = Counter()
        var seams = OnlineCloudProvider.Seams(settings: { Self.snapshot }, consent: { _ in false },
                                              transport: { req in counter.hit(req.body); return OutboundHTTPResponse(status: 200, body: Self.reply) })
        seams.casePermission = { _, _ in true }
        let provider = OnlineCloudProvider(outboundLog: OutboundLogRepository(database: db), knownNames: { [] }, seams: seams)
        try await db.exec("DROP TABLE outbound_log;")
        let send = CaseReadSend(caseID: caseID, prefix: [CaseReader.header, "[Document 1]\n" + CaseWholeReadingTests.sentencing],
                                suffix: CaseReader.questionSuffix("When?"), ttl: .oneHour, purpose: "case.question",
                                clearance: await Self.clearance(caseID, [o: [v]]))
        do {
            _ = try await provider.readCase(send)
            Issue.record("sent without a record")
        } catch let e as OnlineCloudProvider.OnlineError {
            guard case .logUnavailable = e else { Issue.record("expected logUnavailable, got \(e)"); return }
        }
        #expect(counter.count == 0, "nothing dispatched")
    }

    @Test("Permitted passages: no second preview, still masked and re-cleared; a document outside the set is previewed")
    func permittedPassages() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        let caseID = UUID(), o1 = UUID(), v1 = UUID(), o2 = UUID(), v2 = UUID(), outside = UUID(), vOut = UUID()
        let permissions = CaseReadPermissionStore.inMemory()
        let counter = Counter(), consents = Log()
        var seams = OnlineCloudProvider.Seams(settings: { Self.snapshot }, consent: { _ in consents.consent(); return true },
                                              transport: { req in counter.hit(req.body); return OutboundHTTPResponse(status: 200, body: Self.reply) })
        seams.casePermission = { id, fp in permissions.isGranted(caseID: id, fingerprint: fp) }
        let provider = OnlineCloudProvider(outboundLog: OutboundLogRepository(database: db), knownNames: { [] },
                                           protectedNames: { ["Mary Jones"] }, seams: seams)
        let permitted = CaseReadPermittedSet(caseID: caseID, versions: [o1: [v1], o2: [v2]])
        permissions.grant(caseID: caseID, fingerprint: permitted.fingerprint, documentCount: 2)
        let prompt = "Passage [1]: Mary Jones paid $5,000."
        // A passage of a permitted document: no preview, masked.
        let inSet = await Self.clearance(caseID, [o1: [v1]])
        let text = try await CaseReadPermittedSet.$current.withValue(permitted) {
            try await provider.generateFromDocuments(prompt: prompt, options: GenerationOptions(maxTokens: 64, temperature: 0, sourceClearance: inSet))
        }
        #expect(text == "An answer." && counter.count == 1 && consents.consents == 0)
        #expect(!String(decoding: try #require(counter.all.first), as: UTF8.self).contains("Mary Jones"), "masking still runs")
        let log = try await OutboundLogRepository(database: db).recent()
        #expect(log.contains { $0.outcome == "sent" && ($0.detail ?? "").contains("covered by the case's stored permission") })
        // Re-clearance still runs: the document left the case → refused, nothing dispatched.
        let gone = Flag()
        let leaving = await Self.clearance(caseID, [o1: [v1]], current: { gone.isSet ? [:] : [o1: [v1]] })
        gone.set()
        await #expect(throws: OnlineCloudProvider.OnlineError.self) {
            _ = try await CaseReadPermittedSet.$current.withValue(permitted) {
                try await provider.generateFromDocuments(prompt: prompt, options: GenerationOptions(maxTokens: 64, temperature: 0, sourceClearance: leaving))
            }
        }
        #expect(counter.count == 1 && consents.consents == 0)
        // A document outside the permitted set: the per-send preview, as always.
        let other = await Self.clearance(caseID, [o1: [v1], outside: [vOut]])
        _ = try await CaseReadPermittedSet.$current.withValue(permitted) {
            try await provider.generateFromDocuments(prompt: prompt, options: GenerationOptions(maxTokens: 64, temperature: 0, sourceClearance: other))
        }
        #expect(consents.consents == 1 && counter.count == 2)
        // A permitted set the person never allowed (forged versions): previewed.
        let forged = CaseReadPermittedSet(caseID: caseID, versions: [o1: [v1, UUID()]])
        let forgedClear = await Self.clearance(caseID, [o1: [v1]])
        _ = try await CaseReadPermittedSet.$current.withValue(forged) {
            try await provider.generateFromDocuments(prompt: prompt, options: GenerationOptions(maxTokens: 64, temperature: 0, sourceClearance: forgedClear))
        }
        #expect(consents.consents == 2)
        // No case at all: previewed.
        _ = try await provider.generateFromDocuments(prompt: prompt, options: GenerationOptions(maxTokens: 64, temperature: 0, sourceClearance: inSet))
        #expect(consents.consents == 3)
    }
}
