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

    // MARK: Investigator workflow review 2026-10-30, I6

    @Test("Speaker attribution follows the reporting verb: several named people, passive 'by', inverted 'said X', nested reports, denials, 'according to', a transcript turn, a From: author; an ambiguous sentence stays unassigned")
    func speakerFollowsTheReportingVerb() {
        let names = ["Asha Rao", "Vikram Rao", "Dev Sharma"]
        func who(_ s: String, author: String? = nil) -> SpeakerAttribution.Resolution { SpeakerAttribution.resolve(s, named: names, author: author) }
        // The person named first is NOT the speaker when the verb belongs to someone else.
        let present = who("Asha Rao was present when Vikram Rao said the meeting ended at noon.")
        #expect(present.speaker == "Vikram Rao" && present.basis == "Vikram Rao named before “said”")
        // Passive with an agent.
        #expect(who("The approval was confirmed by Vikram Rao on 3 March.").speaker == "Vikram Rao")
        #expect(who("Asha Rao was told by Vikram Rao that the payment had cleared.").speaker == "Vikram Rao")
        // Inverted after a quote.
        #expect(who("“The payment was approved on 3 March,” said Vikram Rao.").speaker == "Vikram Rao")
        // Nested: Asha's statement, reporting Vikram's words.
        let nested = who("Asha Rao said Vikram Rao told her the payment was approved.")
        #expect(nested.speaker == "Asha Rao" && nested.reported == ["Vikram Rao"])
        // Denial.
        let denial = who("Vikram Rao denied approving the payment of ₹10,000.")
        #expect(denial.speaker == "Vikram Rao" && denial.isDenial)
        // According to.
        #expect(who("According to Asha Rao, the meeting ran late.").speaker == "Asha Rao")
        // Appositive is fine; a clause is not.
        #expect(who("Vikram Rao, the finance manager, stated that the invoice was paid once.").speaker == "Vikram Rao")
        #expect(who("Asha Rao, who hired Dev Sharma, said the invoice was paid once.").speaker == "Asha Rao")
        // Passive without an agent: nobody is tied to the verb → unassigned, with the reason.
        let passive = who("Asha Rao and Vikram Rao were present when it was said that the payment was approved.")
        #expect(passive.speaker == nil && passive.basis.contains("unassigned") && passive.basis.contains("passive “said” without a named agent"))
        // First person in a document from a known author; a transcript turn.
        #expect(who("I told the auditor the payment was approved.", author: "Dev Sharma").speaker == "Dev Sharma")
        #expect(who("Dev Sharma: the payment was approved by Asha.").speaker == "Dev Sharma")
        // The same sentence through the executor: a namesake present in the sentence is not the speaker.
        let base = JobAcceptanceScenarioTests.evidence(for: "hr.statements")
        let doc = StudioCaseDocument(objectID: UUID(), sourceVersionID: UUID(), name: "note.txt", date: nil)
        var texts = base.texts
        texts[doc.objectID] = "Asha Rao was present when Vikram Rao said the meeting about the payment ended at noon. Asha Rao and Vikram Rao were present when it was said that the payment of ₹1,000 was approved."
        let f = base.facts
        let facts = StudioCaseFacts(caseTitle: f.caseTitle, parties: f.parties, dates: f.dates, amounts: f.amounts, identifiers: f.identifiers,
                                    documents: f.documents + [doc], events: f.events, allFacts: f.allFacts, named: f.named, statedAmounts: f.statedAmounts, statedDates: f.statedDates)
        let e = JobEvidence(facts: facts, texts: texts, withheld: base.withheld, now: base.now, versionHashes: base.versionHashes, exports: [],
                            batesPrefix: base.batesPrefix, replacedVersions: base.replacedVersions, mergedIdentities: [])
        let statements = JobDeliverableText.attributedStatements(e).filter { $0.doc.objectID == doc.objectID }
        #expect(statements.count == 2)
        #expect(statements[0].speaker == "Vikram Rao", "the first-named person must not take the statement")
        #expect(statements[1].speaker == nil, "an ambiguous attribution stays unassigned")
        let r = StatementComparisonExecutor.run(e)
        let unassigned = r.content.rows.filter { $0.title.hasSuffix("speaker unassigned") }
        #expect(unassigned.count == 1 && unassigned[0].fields?["witness"] == "" && unassigned[0].flags.contains("assign the speaker before comparing"))
        #expect(!r.content.rows.contains { $0.fields?["witness"] == "Asha Rao" && $0.detail?.contains("ended at noon") == true }, "Asha was given Vikram's statement")
        // An unassigned row cannot be accepted until the witness is named.
        var row = unassigned[0]; row.decision = .accepted
        #expect(JobFields.completionProblems(job: "hr.statements", rows: [row]).contains { $0.contains("speaker is unassigned") })
        row.fields?["witness"] = "Vikram Rao"
        #expect(!JobFields.completionProblems(job: "hr.statements", rows: [row]).contains { $0.contains("speaker is unassigned") })
    }

    @Test("Comparison is narrow: equivalent money expressions are the same figure with both wordings kept, a denial and an assertion sharing a figure differ, and the same date is not called agreement on the event")
    func comparisonIsNarrow() {
        #expect(JobDeliverableText.normalisedAmount("₹10,000") == "INR 10000")
        #expect(JobDeliverableText.normalisedAmount("INR 10,000") == "INR 10000")
        #expect(JobDeliverableText.normalisedAmount("Rs. 10,000.00") == "INR 10000")
        #expect(JobDeliverableText.normalisedAmount("$2.75 million") == "USD 2750000")
        #expect(JobDeliverableText.normalisedAmount("1 lakh rupees") == "INR 100000")
        #expect(JobDeliverableText.normalisedAmount("₹2,000") != JobDeliverableText.normalisedAmount("₹10,000"))
        let base = JobAcceptanceScenarioTests.evidence()
        let d1 = StudioCaseDocument(objectID: UUID(), sourceVersionID: UUID(), name: "asha.txt", date: nil)
        let d2 = StudioCaseDocument(objectID: UUID(), sourceVersionID: UUID(), name: "vikram.txt", date: nil)
        var texts = base.texts
        texts[d1.objectID] = "Asha Rao said the supplier payment of ₹10,000 was approved at the meeting."
        texts[d2.objectID] = "Vikram Rao denied that the supplier payment of INR 10,000 was approved at the meeting."
        let f = base.facts
        let facts = StudioCaseFacts(caseTitle: f.caseTitle, parties: f.parties, dates: f.dates, amounts: f.amounts, identifiers: f.identifiers,
                                    documents: f.documents + [d1, d2], events: f.events, allFacts: f.allFacts, named: f.named, statedAmounts: f.statedAmounts, statedDates: f.statedDates)
        let e = JobEvidence(facts: facts, texts: texts, withheld: base.withheld, now: base.now, versionHashes: base.versionHashes, exports: [],
                            batesPrefix: base.batesPrefix, replacedVersions: base.replacedVersions, mergedIdentities: [])
        let rows = StatementComparisonExecutor.run(e).content.rows
        let asha = rows.first { $0.fields?["witness"] == "Asha Rao" && $0.detail?.contains("₹10,000") == true }
        let vikram = rows.first { $0.fields?["witness"] == "Vikram Rao" && $0.detail?.contains("INR 10,000") == true }
        #expect(asha != nil && vikram != nil && asha?.fields?["point"] == vikram?.fields?["point"], "the two accounts of the payment are not on one point")
        #expect(asha?.flags.contains { $0.hasPrefix("states the same amount as Vikram Rao (₹10,000; Vikram Rao writes INR 10,000)") } == true, "equivalent money expressions are not matched with both wordings kept")
        #expect(asha?.flags.contains { $0.hasPrefix("asserts what Vikram Rao denies") } == true && vikram?.flags.contains("denial") == true)
        #expect(asha?.fields?["comparison"] == "differs" && vikram?.fields?["comparison"] == "differs", "a denial and an assertion sharing a figure were called agreement")
        #expect(StatementComparisonExecutor.run(e).content.limitations.contains { $0.contains("not that they describe the same event") })
    }

    // MARK: Investigator workflow review 2026-10-30, I7

    @Test("Source map: a syndicated rewrite is a possible relationship, not 'independent'; an unrelated document sharing a standard notice is not grouped; nothing is called independent; a lineage decision needs its rationale")
    func sourceIndependenceIsNotClaimed() {
        let base = JobAcceptanceScenarioTests.evidence()
        func doc(_ n: String) -> StudioCaseDocument { StudioCaseDocument(objectID: UUID(), sourceVersionID: UUID(), name: n, date: nil) }
        let wire = doc("wire.txt"), rewrite = doc("rewrite.txt"), notice1 = doc("hr-memo.txt"), notice2 = doc("it-memo.txt"), notice3 = doc("legal-memo.txt")
        let footer = " This message is confidential and intended solely for the addressee; if you received it in error, notify the sender and delete it."
        var texts = base.texts
        texts[wire.objectID] = "The regulator confirmed on Tuesday that the refinery's licence had been suspended pending a safety review of the plant." + footer
        texts[rewrite.objectID] = "On Tuesday the regulator confirmed the refinery's licence was suspended pending a safety review of the plant, sources said." + footer
        texts[notice1.objectID] = "The staff picnic moves to the riverside park on Saturday because the hall is being repainted this month." + footer
        texts[notice2.objectID] = "Laptops must be returned to the service desk before the migration weekend so that disk images can be taken." + footer
        texts[notice3.objectID] = "Counsel will attend the board meeting to brief members on the new retention schedule and its exceptions." + footer
        let f = base.facts
        let extra = [wire, rewrite, notice1, notice2, notice3]
        let facts = StudioCaseFacts(caseTitle: f.caseTitle, parties: f.parties, dates: f.dates, amounts: f.amounts, identifiers: f.identifiers,
                                    documents: f.documents + extra, events: f.events, allFacts: f.allFacts, named: f.named, statedAmounts: f.statedAmounts, statedDates: f.statedDates)
        let e = JobEvidence(facts: facts, texts: texts, withheld: base.withheld, now: base.now, versionHashes: base.versionHashes, exports: [],
                            batesPrefix: base.batesPrefix, replacedVersions: base.replacedVersions, mergedIdentities: [])
        let r = SourceFamilyExecutor.run(e)
        func row(_ d: StudioCaseDocument) -> JobResultRow? { r.content.rows.first { $0.title == d.name } }
        // The rewrite shares no identical sentence with the wire, yet is a candidate relationship.
        #expect(row(wire)?.fields?["family"] == row(rewrite)?.fields?["family"] && row(wire)?.fields?["family"]?.hasSuffix(SourceFamilyExecutor.sharedText) == true)
        #expect(row(rewrite)?.flags.contains { $0.hasPrefix("similar wording to wire.txt") && $0.contains("possible rewrite") } == true)
        #expect(row(rewrite)?.flags.contains { $0.hasPrefix("repeats text of") } == false, "no identical sentence should be claimed")
        // The three memos share only the footer: excluded as boilerplate, so none is grouped with another.
        for d in [notice1, notice2, notice3] {
            #expect(row(d)?.fields?["family"] == SourceFamilyExecutor.unassessedFamily, "\(d.name) was grouped by a standard notice")
            #expect(row(d)?.flags.contains("1 boilerplate sentence(s) excluded from grouping") == true)
        }
        #expect(!r.content.rows.contains { $0.fields?["family"]?.lowercased().contains("independent") == true && $0.fields?["family"] != SourceFamilyExecutor.unassessedFamily })
        #expect(r.content.limitations.contains { $0.contains("does not establish independence") })
        // A lineage decision persists as the person's, with its rationale.
        var decided = row(wire)!; decided.decision = .accepted; decided.fields?["lineage"] = "same origin (wire, syndication)"
        #expect(JobFields.completionProblems(job: "jrn.source-map", rows: [decided]).contains { $0.contains("needs its rationale") })
        decided.note = "Both carry the agency's dateline; the rewrite credits 'sources' but adds nothing."
        #expect(!JobFields.completionProblems(job: "jrn.source-map", rows: [decided]).contains { $0.contains("needs its rationale") })
    }
}
