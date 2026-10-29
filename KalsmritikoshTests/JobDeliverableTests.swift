//
//  JobDeliverableTests.swift
//  KalsmritikoshTests
//
//  Release-block directive 2026-10-29, item 1 — the deliverables of the sixteen jobs B3 had reopened,
//  beyond their acceptance scenario (`JobAcceptanceScenarioTests`): the completion rules each one
//  refuses on, the enforcement a result has outside its own screen (a privilege code withholds the
//  document from a production; a protected source's name is kept out of exports and refused at the
//  cloud boundary), the lineage chart, the person's saved analysis query, and the merge path.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Reopened-job deliverables — rules, production, protection, chart, query")
struct JobDeliverableTests {

    static func day(_ s: String) -> Date { JobFamilyExecutorTests.day(s) }

    nonisolated final class Spy: @unchecked Sendable {
        private let lock = NSLock(); private var n = 0; private var bodies: [Data] = []
        func hit(_ body: Data) { lock.withLock { n += 1; bodies.append(body) } }
        var count: Int { lock.withLock { n } }
        var sent: [String] { lock.withLock { bodies.map { String(decoding: $0, as: UTF8.self) } } }
    }

    @Test("Scenario rules: an unsourced question, an untraced report figure, a translation without its transcription or original, a protected source without its identity, an annotation on no passage, a privilege code on no document — each refused; the fix completes")
    func rules() async throws {
        func refused(_ job: String, _ bad: [JobResultRow], _ fix: [JobResultRow]) async throws {
            let (repo, base) = try await JobAcceptanceScenarioTests.repoWith(job, rows: bad.map { var r = $0; r.decision = nil; r.fields = nil; r.note = nil; return r })
            await #expect(throws: JobResultReviewError.self, "\(job) completed against its scenario") {
                try await repo.saveReview(of: base, rows: bad, complete: true, note: "Reviewed", actor: "Reviewer")
            }
            try await repo.saveReview(of: base, rows: fix, complete: true, note: "Reviewed", actor: "Reviewer")
        }
        func filled(_ job: String, _ row: JobResultRow, _ o: [String: String] = [:]) -> JobResultRow { JobAcceptanceScenarioTests.filled(job, row, o) }
        func manual(_ title: String) -> JobResultRow { var r = JobResultRow(title: title); r.manual = true; return r }
        func rejected(_ row: JobResultRow) -> JobResultRow { var r = row; r.decision = .rejected; return r }

        // law.deposition / siu.euo-prep — a question with no passage.
        let e = JobAcceptanceScenarioTests.evidence(for: "law.deposition")
        let question = SourcedQuestionsExecutor.run(e).content.rows[0]
        for job in ["law.deposition", "siu.euo-prep"] {
            let free = filled(job, manual("Did you approve INV-1?"))
            try await refused(job, [free], [filled(job, question), rejected(free)])
        }
        // fa.workpapers — an untraced report figure accepted.
        let wp = WorkpaperExecutor.run(JobAcceptanceScenarioTests.evidence(for: "fa.workpapers")).content.rows
        let untraced = try #require(wp.first { $0.flags.contains(WorkpaperExecutor.untraced) })
        let traced = try #require(wp.first { $0.flags.contains("traces to WP-001") })
        try await refused("fa.workpapers", [filled("fa.workpapers", untraced)], [filled("fa.workpapers", traced), rejected(untraced)])
        // res.transcription — a translation without its transcription; a translation on a row with no original.
        let passage = TranscriptionExecutor.run(e).content.rows[0]
        try await refused("res.transcription", [filled("res.transcription", passage, ["transcription": "", "translation": "The invoice was checked twice."])],
                          [filled("res.transcription", passage, ["transcription": "the invoice was checked twice", "translation": "La facture a été vérifiée deux fois."])])
        let orphan = filled("res.transcription", manual("Translated line"), ["transcription": "x", "translation": "y"])
        try await refused("res.transcription", [orphan], [filled("res.transcription", passage), rejected(orphan)])
        // jrn.source-vault — protected without an identity.
        let vault = SourceVaultExecutor.run(e).content.rows[0]
        try await refused("jrn.source-vault", [filled("jrn.source-vault", vault, ["protected": "yes", "identity": ""])],
                          [filled("jrn.source-vault", vault, ["protected": "yes", "identity": "Meera Iyer"])])
        // res.edition — an annotation on a row without a passage.
        let line = AnnotatedEditionExecutor.run(e).content.rows[0]
        let note = filled("res.edition", manual("Editorial note"), ["annotation": "Later hand"])
        try await refused("res.edition", [note], [filled("res.edition", line, ["annotation": "Signature is a later addition"]), rejected(note)])
        // law.document-coding — a privilege code on a row that cites no document.
        let coded = DocumentCodingExecutor.run(e).content.rows[0]
        let stray = filled("law.document-coding", manual("Unknown letter"), ["privilege": "privileged"])
        try await refused("law.document-coding", [stray], [filled("law.document-coding", coded, ["privilege": "privileged"]), rejected(stray)])
    }

    @Test("A document coded privileged (or partly privileged) is withheld from the production: slip sheet, empty text, privilege-log line; a rejected code withholds nothing")
    func codingWithholdsFromProduction() throws {
        let e = JobAcceptanceScenarioTests.evidence(for: "law.document-coding")
        var rows = DocumentCodingExecutor.run(e).content.rows
        rows[0].fields = ["issues": "Approval", "relevance": "relevant", "privilege": "privileged"]; rows[0].decision = .accepted
        rows[1].fields = ["issues": "Approval", "relevance": "relevant", "privilege": "partly privileged"]   // undecided: still withheld (fail closed)
        var rejectedCode = rows[1]; rejectedCode.decision = .rejected
        let withheld = DocumentCodingProduction.withheld(in: rows)
        #expect(withheld == Set(e.facts.documents.map(\.objectID)), "both codes withhold")
        #expect(DocumentCodingProduction.withheld(in: [rows[0], rejectedCode]) == [e.facts.documents[0].objectID], "a rejected code withholds nothing")
        // Through the production builder, as AppState.productionDocuments feeds it.
        let docs = e.facts.documents.map { d in
            ProductionDocument(id: d.objectID, fileName: d.name, text: e.texts[d.objectID] ?? "", nativeURL: nil, privileged: withheld.contains(d.objectID))
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("prod-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let result = try ProductionBuilder.build(docs, options: ProductionOptions(prefix: "ACME", startNumber: 1, includeNatives: false), into: folder)
        #expect(result.withheld == 2 && result.documents == 2)
        let log = try String(contentsOf: folder.appendingPathComponent("PRIVILEGE_LOG.csv"), encoding: .utf8)
        #expect(log.contains("memo.txt") && log.contains("email.eml"))
        let texts = try FileManager.default.contentsOfDirectory(at: folder.appendingPathComponent("TEXT"), includingPropertiesForKeys: nil)
        #expect(texts.count == 2 && texts.allSatisfy { (try? Data(contentsOf: $0))?.isEmpty == true }, "a withheld document's text is not produced")
    }

    @Test("A protected source's name never appears in exports or AI payloads: scrubbed and verified in the rendered export; masked at the cloud boundary; a name that would survive stops the send")
    func protectedIdentityKeptOut() async throws {
        let e = JobAcceptanceScenarioTests.evidence(for: "jrn.source-vault")
        var rows = SourceVaultExecutor.run(e).content.rows
        rows[0].fields = ["hash": String(repeating: "a", count: 64), "protected": "yes", "identity": "Meera Iyer; M. Iyer", "access": "Viewed 1 June"]
        rows[1].fields = ["protected": "no", "identity": "Not protected person", "access": "—"]
        var rejected = rows[0]; rejected.decision = .rejected
        #expect(ProtectedIdentities.names(in: rows) == ["Meera Iyer", "M. Iyer"])
        #expect(ProtectedIdentities.names(in: [rejected]).isEmpty, "a rejected vault row protects nothing")
        // The ledger: the vault saved for a case; the names are read back across cases.
        let (repo, record) = try await JobAcceptanceScenarioTests.repoWith("jrn.source-vault", rows: rows)
        #expect(try await repo.protectedIdentityNames() == ["Meera Iyer", "M. Iyer"])
        #expect(try await repo.protectedIdentityNames(caseID: record.caseID) == ["Meera Iyer", "M. Iyer"])
        #expect(try await repo.protectedIdentityNames(caseID: UUID()).isEmpty)
        // Export text: scrubbed, verified gone; a split spelling is a leak the export refuses.
        let names = try await repo.protectedIdentityNames()
        let clean = ProtectedIdentities.scrub("Source Meera Iyer confirmed the figure; m. iyer again.", names: names)
        #expect(clean.leaks.isEmpty && !clean.text.localizedCaseInsensitiveContains("Iyer") && clean.text.contains("[PROTECTED SOURCE]"))
        let split = ProtectedIdentities.scrub("Source Me<b>era</b> Iyer confirmed the figure.", names: names)
        #expect(!split.leaks.isEmpty, "a name recoverable through markup is reported, so the export is refused")
        // Cloud boundary: the real provider send path with a transport spy and the ledger's protected names.
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        let spy = Spy()
        let snapshot = OnlineSnapshot(cloudAllowed: true, kind: .anthropic, model: "test-model", apiKey: "test-key",
                                      confirmedDocumentTerms: OnlineProviderKind.anthropic.documentTermsVersion, dailyByteCap: nil)
        let reply = Data(#"{"content":[{"type":"text","text":"An answer."}]}"#.utf8)
        let provider = OnlineCloudProvider(outboundLog: OutboundLogRepository(database: db), knownNames: { [] },
                                           protectedNames: { names },
                                           seams: .init(settings: { snapshot }, consent: { _ in true },
                                                        transport: { req in spy.hit(req.body); return OutboundHTTPResponse(status: 200, body: reply) }))
        let options = GenerationOptions(maxTokens: 64, temperature: 0.2, systemPrompt: "Meera Iyer is the source.", sourceClearance: nil)
        let text = try await provider.generateQuestionOnly(prompt: "What did Meera Iyer say about M. Iyer's figure?", options: options)
        #expect(text == "An answer." && spy.count == 1)
        #expect(spy.sent.allSatisfy { !$0.localizedCaseInsensitiveContains("Iyer") }, "the name left the Mac: \(spy.sent)")
        // A spelling the masker cannot match but a reader can recover: refused, nothing dispatched.
        await #expect(throws: OnlineCloudProvider.OnlineError.self) {
            _ = try await provider.generateQuestionOnly(prompt: "What did Me<b>era</b> Iyer say?", options: GenerationOptions(maxTokens: 64, temperature: 0.2, systemPrompt: nil, sourceClearance: nil))
        }
        #expect(spy.count == 1, "no dispatch with a recoverable protected identity")
        let log = try await OutboundLogRepository(database: db).recent()
        #expect(log.contains { $0.outcome == "blocked" && ($0.detail ?? "").contains("protected source identity") })
    }

    @Test("The lineage chart draws a sourced relationship solid and a hand-added one without a source dashed as unproven; the export carries the chart")
    func lineageChart() async throws {
        let e = JobAcceptanceScenarioTests.evidence(for: "gen.family-lines")
        var rows = LineageExecutor.run(e).content.rows
        var unproven = JobResultRow(title: "Dev Sharma — son of — Ravi Sharma", fields: ["person": "Dev Sharma", "relationship": "son of", "relative": "Ravi Sharma"])
        unproven.manual = true
        rows.append(unproven)
        let chart = try #require(LineageChart.mermaid(rows: rows))
        #expect(chart.contains("-->|\"daughter of\"|") && chart.contains("-.->|\"son of (\(LineageChart.unprovenLabel))\"|"), "\(chart)")
        var hidden = unproven; hidden.decision = .rejected
        #expect(LineageChart.mermaid(rows: rows.dropLast() + [hidden])?.contains("-.->") == false, "a rejected relationship is not drawn")
        let (repo, record) = try await JobAcceptanceScenarioTests.repoWith("gen.family-lines", rows: rows)
        let md = JobResultMarkdown.render(try #require(try await repo.latest(caseID: record.caseID, jobID: "gen.family-lines")), title: "Family lines")
        #expect(md.contains("## Lineage chart") && md.contains("```mermaid") && md.contains("-.->"))
    }

    @Test("The person's analysis query: a filter on one document totals that document's amounts only; every row cites its source; the saved query is read back for the next run")
    func analysisQuery() throws {
        let e = JobAcceptanceScenarioTests.evidence(for: "inv.data-lab")
        let all = ConfigurableAnalysisExecutor.run(e)
        #expect(all.content.rows.contains { $0.title.hasPrefix("Field amount") && ($0.detail ?? "").contains("INR 2,000.00") })
        let memoOnly = ConfigurableAnalysisExecutor.run(e, query: DataAnalysisQuery(filter: "document = memo.txt", groupBy: "document", total: "amount"))
        let group = try #require(memoOnly.content.rows.first { $0.title.hasPrefix("Document memo.txt") })
        #expect((group.detail ?? "").contains("INR 1,000.00") && !(group.detail ?? "").contains("2,000"), "\(group.detail ?? "")")
        #expect(!memoOnly.content.rows.contains { $0.title.hasPrefix("Document email.eml") })
        #expect(memoOnly.content.rows.allSatisfy { !$0.refs.isEmpty }, "a computed row without its sources")
        #expect(group.refs.allSatisfy { $0.objectID == e.facts.documents[0].objectID }, "a total cites a row it did not include")
        // The query the person saved on the Analysis row is what the next run applies.
        var saved = memoOnly.content.rows
        saved[0].fields?["filter"] = "amount contains ₹"
        let next = DataAnalysisQuery.from(rows: saved)
        #expect(next.filter == "amount contains ₹" && next.groupBy == "document" && next.total == "amount")
        #expect(DataAnalysisQuery.from(rows: []) == .default)
        let contains = ConfigurableAnalysisExecutor.run(e, query: next)
        #expect(contains.content.rows.filter { $0.title.hasPrefix("amount = ") }.count == 2 && !contains.content.rows.contains { $0.title.hasPrefix("date = ") || $0.title.contains("$2.75") })
    }

    @Test("Parties: without a confirmed merge two name forms stay two parties, flagged; a reversed merge is not a merge; the speaker of a statement is the person named first")
    func mergesAndSpeakers() {
        let e = JobAcceptanceScenarioTests.evidence(for: "law.parties-issues")
        let unmerged = JobEvidence(facts: e.facts, texts: e.texts, withheld: e.withheld, now: e.now, mergedIdentities: [])
        let rows = PartiesIssuesExecutor.run(unmerged).content.rows
        #expect(rows.contains { $0.title == "A. Rao" && $0.flags.contains { $0.hasPrefix(PartiesIssuesExecutor.lookalike) && $0.hasSuffix("Asha Rao") } })
        #expect(rows.contains { $0.title == "Asha Rao" && !$0.flags.contains("merged by a person") })
        let w = UUID(), l = UUID(), c = UUID()
        func d(_ seq: Int, _ kind: IdentityDecisionKind) -> IdentityResolutionDecision {
            IdentityResolutionDecision(id: UUID(), caseID: c, sequence: seq, kind: kind, winnerEntityID: w, loserEntityID: l, rationale: nil, actor: "Counsel", priorDecisionID: nil, occurredAt: Self.day("2026-05-01"))
        }
        #expect(MergedIdentity.confirmedPairs([d(1, .mergeProposed), d(2, .mergeConfirmed)]).count == 1)
        #expect(MergedIdentity.confirmedPairs([d(1, .mergeProposed), d(2, .mergeConfirmed), d(3, .mergeReversed)]).isEmpty, "a reversed merge is not a merge")
        #expect(MergedIdentity.confirmedPairs([d(1, .mergeProposed)]).isEmpty, "a proposal merges nothing")
        let grouped = MergedIdentity.grouped([MergedIdentity(canonical: "Asha Rao", aliases: ["A. Rao"], decidedBy: "x", decidedAt: Self.day("2026-05-01")),
                                              MergedIdentity(canonical: "Asha Rao", aliases: ["Asha R."], decidedBy: "x", decidedAt: Self.day("2026-05-02"))])
        #expect(grouped.count == 1 && grouped[0].aliases == ["A. Rao", "Asha R."])
        // Speaker attribution: "Vikram Rao wrote that Asha Rao signed" is Vikram's statement.
        let base = JobAcceptanceScenarioTests.evidence()
        let statements = JobDeliverableText.attributedStatements(base)
        #expect(statements.contains { $0.speaker == "Vikram Rao" && $0.sentence.hasPrefix("Vikram Rao wrote") })
        #expect(!statements.contains { $0.speaker == "Asha Rao" && $0.sentence.hasPrefix("Vikram Rao wrote") })
    }
}
