//
//  SmartMapS12Tests.swift
//  KalsmritikoshTests
//
//  Smart-map S12 (milestone M5): onboarding, accessibility and guidance (HELP-01..11) and existing jobs, specialist data and
//  interoperability (ADAPT-01..09). On throwaway migrated ledgers — never the owner's. Dates that matter are written as
//  calendar days and read in an explicit time zone (UTC), so the suite gives the same result on a Mac set to any zone.
//

import Foundation
import Testing
@testable import Kalsmritikosh

private let s12Root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
private func s12Source(_ path: String) -> String { (try? String(contentsOf: s12Root.appendingPathComponent(path), encoding: .utf8)) ?? "" }

@MainActor
private func s12Defaults() -> UserDefaults {
    let d = UserDefaults(suiteName: "s12-\(UUID().uuidString)") ?? .standard
    return d
}

@Suite("Smart map S12 — guidance, accessibility, jobs and interoperability (M5)", .serialized)
@MainActor
struct SmartMapS12Tests {

    // MARK: HELP-01

    @Test("HELP-01: a case can start from its question in one short sheet; the title comes from the question; the question is the map's question")
    func firstCaseFromQuestion() async throws {
        #expect(FirstCaseEntry.Start.question.screensToCaseWork == 1)
        #expect(FirstCaseEntry.Start.question.screensToCaseWork < FirstCaseEntry.Start.documents.screensToCaseWork)
        #expect(FirstCaseEntry.title(question: "Who approved the second payment?\nMore detail", typed: "") == "Who approved the second payment")
        #expect(FirstCaseEntry.title(question: "Who approved it?", typed: "  Delta  ") == "Delta")
        #expect(FirstCaseEntry.title(question: "   ", typed: "") == "New case")
        // The sheet creates the case with the question as its purpose — the map's header question.
        let f = try await CaseFileTests.fixture()
        let q = "Who approved the second payment to Supplier ABC?"
        let c = try await f.cases.createCase(workspaceID: f.workspaceID, title: FirstCaseEntry.title(question: q, typed: ""), purpose: q, actor: "Ada", at: Date())
        let p = try #require(await caseMapLoad(f, caseID: c.id).projection)
        #expect(p.question == q)
        // Reachable from the first screen and from Cases; solo or team chosen without a wizard.
        let onboarding = s12Source("Kalsmritikosh/UI/OnboardingView.swift"), cases = s12Source("Kalsmritikosh/UI/CasesView.swift")
        let panel = s12Source("Kalsmritikosh/UI/CaseMapToolsPanel.swift")
        #expect(onboarding.contains("\"Start from a question\"") && onboarding.contains("FirstCaseEntry.pendingKey"))
        #expect(cases.contains("QuickCaseSheet") && cases.contains("\"Start from a question…\""))
        #expect(panel.contains("Text(\"Just me\")") && panel.contains("CaseMapWorkspaceMemoryHint.openTools(.people"))
    }

    // MARK: HELP-02

    @Test("HELP-02: the Smart Map Guide walks report → point → question → action → result → deeper point, then brief, search, money and history; manual, replayable, sample only")
    func smartMapGuide() async {
        let ids = HelpTutorial.smartMapSteps.map(\.id)
        #expect(ids == ["sm-open", "sm-report", "sm-point", "sm-question", "sm-action", "sm-result", "sm-deeper", "sm-brief", "sm-search", "sm-money", "sm-history", "sm-finish"])
        for s in HelpTutorial.smartMapSteps { #expect(!s.instruction.isEmpty && !s.expect.isEmpty && !s.controls.isEmpty, "\(s.id)") }
        #expect(HelpTutorial.steps(for: .smartMap) == HelpTutorial.smartMapSteps)
        let ui = HelpRegistryTests.uiSources
        for name in HelpTutorial.smartMapSteps.flatMap(\.controls) {
            #expect(ui.contains("\"\(name)") || ui.contains("\(name)\""), "control “\(name)” not in the UI sources")
        }
        let p = HelpTutorial.progress
        p.stop()
        p.start(.smartMap)
        #expect(p.isRunning && p.index == 0 && p.path == .smartMap)
        p.set(3)
        #expect(p.index == 3, "nothing advances by itself; only Back/Next move it")
        p.set(99)
        #expect(p.index == HelpTutorial.smartMapSteps.count - 1)
        p.stop()
        #expect(!p.isRunning && p.path == .caseToReport)
        #expect(s12Source("Kalsmritikosh/KalsmritikoshApp.swift").contains("HelpTutorial.replay(.smartMap)"))
        #expect(s12Source("Kalsmritikosh/UI/GuideView.swift").contains("HelpTutorial.replay(.smartMap)"))
        #expect(HelpDocsRenderer.manual().contains("## The Smart Map Guide"))
    }

    // MARK: HELP-03

    @Test("HELP-03: the legend explains collapsed groups, folded branches, what changed and certainty, with the same terms as Help")
    func legendExtras() {
        let titles = CaseMapLegendExtras.lines.map(\.title)
        for t in ["Collapsed group", "Folded branch", "What changed", "Certainty of a link"] { #expect(titles.contains(t), "\(t)") }
        let changed = CaseMapLegendExtras.lines.first { $0.title == "What changed" }?.text ?? ""
        #expect(changed.contains("Mark as seen") && changed.contains("not reviewing"))
        #expect(HelpRegistry.topic("task-case-map-first-use")?.searchText.contains("what changed") == true)
        let view = s12Source("Kalsmritikosh/UI/CaseMapWorkspaceView.swift")
        #expect(view.contains("CaseMapLegendExtras.lines"))
    }

    // MARK: HELP-04

    @Test("HELP-04: every new control has a purpose and a consequence, in plain words, on hover and on keyboard focus; the tools say what they are for in text")
    func controlHelp() {
        let ui = HelpRegistryTests.uiSources
        let names = CaseMapControlHelp.entries.map(\.control)
        #expect(Set(names).count == names.count, "one entry per control")
        #expect(names.count >= 50)
        for e in CaseMapControlHelp.entries {
            #expect(ui.contains("\"\(e.control)") || ui.contains("\(e.control)\""), "“\(e.control)” not in the UI sources")
            #expect(e.purpose.hasSuffix(".") && e.consequence.hasSuffix("."), "\(e.control)")
            let text = e.text.lowercased()
            for word in CaseMapControlHelp.jargon { #expect(text.range(of: "\\b\(word)\\b", options: .regularExpression) == nil, "jargon “\(word)” in \(e.control)") }
        }
        // Every control the tools panel names through caseMapControlHelp has an entry (a missing one would be an empty hint).
        let panel = s12Source("Kalsmritikosh/UI/CaseMapToolsPanel.swift")
        let re = try? NSRegularExpression(pattern: #"caseMapControlHelp\("([^"]+)"\)"#)
        let ns = panel as NSString
        let used = (re?.matches(in: panel, range: NSRange(location: 0, length: ns.length)) ?? []).map { ns.substring(with: $0.range(at: 1)) }
        #expect(used.count >= 15)
        for u in used { #expect(CaseMapControlHelp.entry(u) != nil, "no help entry for “\(u)”") }
        // The modifier sets both the tooltip and the VoiceOver hint (heard on keyboard focus).
        let helpFile = s12Source("Kalsmritikosh/UI/Help/CaseMapControlHelp.swift")
        #expect(helpFile.contains("self.help(t).accessibilityHint(t)"))
        // Each tool's purpose is text above its controls, not a tooltip.
        for t in CaseMapTool.allCases { #expect(t.purpose.count > 40, "\(t)") }
        #expect(panel.contains("Text(tool.purpose)"))
        // The control list is in the manual.
        #expect(HelpRegistry.topic("concept-case-map-controls")?.steps.count == CaseMapControlHelp.entries.count)
    }

    // MARK: HELP-05

    @Test("HELP-05: empty, failed AI, absent access, blocked work and read failures each name one next action")
    func statesNameNextAction() {
        let denied = CaseToolState.from(CaseAccessError.denied(operation: .work, who: "Ben", reason: "Ben is a viewer", remedy: "Ask the owner"), doing: "recording money")
        guard case .accessDenied(_, let n1) = denied else { Issue.record("not an access state: \(denied)"); return }
        #expect(n1.contains("owner") && n1.contains("People and roles"))
        let ai = CaseToolState.from(CaseAIAssistError.off(1), doing: "running the assistant")
        guard case .aiFailed(_, let n2) = ai else { Issue.record("not an AI state: \(ai)"); return }
        #expect(n2.contains("by hand"))
        let closed = CaseToolState.from(CaseFileError.caseClosed, doing: "recording")
        guard case .blocked(_, let n3) = closed else { Issue.record("not a blocked state: \(closed)"); return }
        #expect(n3.contains("Reopen"))
        let other = CaseToolState.from(CaseMoneyError.badRate, doing: "recording")
        guard case .failed = other else { Issue.record("not a failure state: \(other)"); return }
        for s in [denied, ai, closed, other, .empty(what: "Nothing is queued.", next: "Wait.")] {
            let m = s.message
            #expect(m != nil && !(m?.next.isEmpty ?? true) && !(m?.title.lowercased().contains("something went wrong") ?? true))
        }
        #expect(CaseToolState.loading.message == nil && CaseToolState.ready.message == nil)
        // Every tool shows an empty state with its next action (counted in the source).
        let panel = s12Source("Kalsmritikosh/UI/CaseMapToolsPanel.swift")
        #expect(panel.components(separatedBy: "state: .empty(what:").count - 1 >= CaseMapTool.allCases.count)
    }

    // MARK: HELP-07 / HELP-08 / HELP-09 / HELP-10

    @Test("HELP-07: create, assign, frames and the case tools are commands with controls and keys; no gesture is needed")
    func keyboardCommands() {
        for c: CaseMapCommand in [.create, .assign, .openFrame, .upFrame, .tools] {
            #expect(!c.controls.isEmpty && !c.mapOnly, "\(c)")
        }
        #expect(CaseMapCommand.tools.shortcut == "⌃⌘T" && CaseMapCommand.openFrame.shortcut == "⌃⌘↩")
        #expect(CaseMapKeyboard.lines.contains { $0.contains("⌃⌘T") })
        let view = s12Source("Kalsmritikosh/UI/CaseMapWorkspaceView.swift")
        #expect(view.contains(".keyboardShortcut(\"t\", modifiers: [.command, .control])") && view.contains("ForEach(CaseMapTool.allCases)"))
        let commands = s12Source("Kalsmritikosh/UI/CaseMapWorkCommands.swift")
        #expect(commands.contains(".keyboardShortcut(.return, modifiers: [.command, .control])"))
    }

    @Test("HELP-08: the new screens label their parts for VoiceOver and use text styles that scale (no fixed point sizes)")
    func voiceOverAndTextSize() {
        let panel = s12Source("Kalsmritikosh/UI/CaseMapToolsPanel.swift"), help = s12Source("Kalsmritikosh/UI/Help/CaseMapControlHelp.swift")
        for src in [panel, help] { #expect(!src.contains(".font(.system(size:"), "fixed point size") }
        for id in ["case.tools.list", "case.tools.detail"] { #expect(panel.contains("accessibilityIdentifier(\"\(id)\")"), "\(id)") }
        #expect(help.contains("accessibilityIdentifier(\"case.tools.state\")") && help.contains(".accessibilityElement(children: .combine)"))
        #expect(panel.contains(".accessibilityLabel(\"Tool: \\(t.title)\")"))
        // Supplied summaries and proposals are read as one element each, with their label (supplied / AI) first.
        #expect(panel.contains("Text(s.label)") && panel.contains("Text(p.label)"))
    }

    @Test("HELP-09: switching views, stepping the strip and reading the case again never move the viewport; nothing pans on its own")
    func noAutoPan() async throws {
        let rig = try await CaseMapRig.make()
        let f = rig.f
        let service = CaseMapService(sources: caseMapSources(f))
        let model = CaseMapWorkspaceModel(caseID: f.caseID, workspace: CaseWorkspaceHolder(caseID: f.caseID, defaults: s12Defaults()))
        await model.refresh(service)
        let set = CaseMapViewport(scale: 1.7, originX: 120, originY: -40)
        model.setViewport(set)
        let overviewKey = model.viewportKey
        let before = model.memory.viewports ?? [:]
        model.step(1)
        model.go(to: .builtIn(.people))
        await model.refresh(service)
        #expect((model.memory.viewports ?? [:]) == before, "a view switch or a reload wrote no viewport")
        model.goBack(); model.goBack()
        #expect(model.viewportKey == overviewKey && model.viewport() == set, "the overview is exactly where it was left")
        #expect(CaseMapMotion.animation(reduceMotion: true) == nil)
    }

    @Test("HELP-10: every tool is reached in place from the map header and opens its full Help topic; specialist records are one step from the default view")
    func depthIsDiscoverable() {
        for t in CaseMapTool.allCases {
            #expect(HelpRegistry.topic(t.helpTopic) != nil, "\(t): help topic \(t.helpTopic)")
            #expect(!t.title.isEmpty)
        }
        let view = s12Source("Kalsmritikosh/UI/CaseMapWorkspaceView.swift")
        let header = view.components(separatedBy: "private var header: some View").last?.components(separatedBy: "private func countButton").first ?? ""
        #expect(header.contains("ForEach(CaseMapTool.allCases)"), "the tools are in the always-visible header")
        #expect(HelpRegistry.search("case tools").contains { $0.id == "task-case-tools" })
    }

    // MARK: HELP-11

    @Test("HELP-11: original scripts, names and date forms survive intake, the map and the exchange file unchanged; a written date is never re-read")
    func originalScriptsPreserved() async throws {
        let f = try await CaseFileTests.fixture()
        let hindi = "राजेश कुमार ने १५ मार्च २०२४ को ₹२,५०,००० का भुगतान स्वीकृत किया।", hindiDate = "१५ मार्च २०२४"
        let arabic = "محمد علي", chinese = "李小龍 (Lee Siu-lung)"
        let doc = """
        {"format":"ime-case-exchange","version":1,"sourceSystem":"field-office","records":[
          {"id":"e1","kind":"event","text":"\(hindi)","date":"\(hindiDate)","sources":[]},
          {"id":"p1","kind":"person","text":"\(arabic)","role":"witness","sources":[]},
          {"id":"p2","kind":"person","text":"\(chinese)","role":"subject","sources":[]}],"relationships":[]}
        """
        let r = try await f.file.importExchange(caseID: f.caseID, data: Data(doc.utf8), actor: "Ada")
        #expect(r.created.sorted() == ["e1", "p1", "p2"])
        #expect(r.limitations.contains { $0.contains(hindiDate) && $0.contains("kept as written") })
        let entry = try #require(try await f.file.journal(caseID: f.caseID, kind: .chronology).first)
        #expect(entry.text == hindi && entry.dateText == hindiDate && entry.eventDate == nil, "never re-read into a different date")
        #expect(Set(try await f.file.people(caseID: f.caseID).map(\.name)) == [arabic, chinese])
        let p = try #require(await caseMapLoad(f).projection)
        #expect(p.nodes.contains { $0.title.contains("राजेश कुमार") } && p.nodes.contains { $0.title == arabic })
        #expect(p.nodes.contains { $0.dateLabel == "“\(hindiDate)” (as written; not placed in order)" }, "the map shows the date as written")
        let out = try await f.file.exchangeDocument(caseID: f.caseID)
        #expect(out.records.contains { $0.text == hindi && $0.date == hindiDate } && out.records.contains { $0.text == chinese })
        let text = String(decoding: try CaseExchange.encode(out), as: UTF8.self)
        #expect(text.contains(hindi) && text.contains(arabic), "written as the characters, not escaped or transliterated")
    }

    // MARK: ADAPT-01 / ADAPT-03

    @Test("ADAPT-01: every catalogue job resolves to canonical destinations (or is itself a canonical record); each destination has its control and its table")
    func everyJobHasAnAdapter() async throws {
        let coverage = JobResultMapAdapter.coverage()
        #expect(coverage.count == PersonaJobCatalogComposer.allJobs.count && coverage.count >= 160)
        for c in coverage { #expect(!c.destinations.isEmpty || c.canonical != nil, "\(c.job.id) has no adapter") }
        for k in PersonaJobKind.allCases { #expect(!JobResultMapAdapter.destinations(for: k).isEmpty || JobResultMapAdapter.canonicalOutput(for: k) != nil, "\(k)") }
        let ui = HelpRegistryTests.uiSources
        let f = try await CaseFileTests.fixture()
        for d in JobResultDestination.allCases {
            #expect(ui.contains("\"\(d.control)"), "\(d.control)")
            #expect(try await MigrationFixtureBuilder.tableExists(f.db, d.canonicalTable), "\(d.canonicalTable)")
        }
        // No parallel store: the carry targets are the case's own tables.
        #expect(Set(JobResultDestination.allCases.map(\.canonicalTable)).allSatisfy { $0.hasPrefix("case_") })
    }

    @Test("ADAPT-03: a profession's words name the map's kinds through the frozen terminology; the record, its state and links are the same")
    func personaLabels() async throws {
        #expect(CaseMapPersonaLabels.label(.finding, persona: GenealogistPersonaPackage.applicationID) == "Fact or report item")
        #expect(CaseMapPersonaLabels.label(.finding, persona: InvestigatorPersonaPackage.applicationID) == "Finding or report item")
        #expect(CaseMapPersonaLabels.label(.finding, persona: nil) == CaseMapNodeKind.finding.label)
        #expect(CaseMapPersonaLabels.label(.person, persona: GenealogistPersonaPackage.applicationID) == CaseMapNodeKind.person.label)
        for k in CaseMapNodeKind.allCases {
            for pkg in [GenealogistPersonaPackage.applicationID, JournalistPersonaPackage.applicationID, LawyerPersonaPackage.applicationID] {
                #expect(!CaseMapPersonaLabels.label(k, persona: pkg).trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        // The same case loaded twice is identical whatever profession reads it: labels are applied in the view only.
        let rig = try await CaseMapRig.make()
        let a = try #require(await caseMapLoad(rig.f).projection), b = try #require(await caseMapLoad(rig.f).projection)
        #expect(a.nodes.map(\.id) == b.nodes.map(\.id) && a.nodes.map(\.status) == b.nodes.map(\.status))
        #expect(s12Source("Kalsmritikosh/UI/CaseMapInspector.swift").contains("CaseMapPersonaLabels.label(n.kind, persona: PersonaJobsModel.rememberedPersona(for: model.caseID))"))
    }

    // MARK: ADAPT-02

    @Test("ADAPT-02: a reviewed row carries into money (unclassified, in no figure) and into a new open question, with origin, revision and review state; repeats are refused unless distinct")
    func carryToMoneyAndQuestion() async throws {
        let f = try await CaseFileTests.fixture()
        let doc = try await CaseFileTestSources.seedPassage(f.db, cases: f.cases, caseID: f.caseID, name: "ledger.txt",
                                                            text: "On 2026-03-03 the company paid USD 1,200 to Kestrel Supplies.")
        let quote = "On 2026-03-03 the company paid USD 1,200 to Kestrel Supplies."
        let results = JobResultRepository(database: f.db)
        var paid = JobResultRow(title: "Payment to Kestrel Supplies", detail: nil, date: "2026-03-03",
                                refs: [StudioEvidenceRef(sourceVersionID: doc.version, objectID: doc.object, quote: quote)], fields: ["amounts": "USD 1,200"])
        paid.decision = .accepted
        let open = JobResultRow(title: "Who authorised the Kestrel payment?", refs: [StudioEvidenceRef(sourceVersionID: doc.version, quote: quote)])
        var rejected = JobResultRow(title: "Duplicate payment", refs: [StudioEvidenceRef(sourceVersionID: doc.version, quote: quote)], fields: ["amounts": "USD 1,200"])
        rejected.decision = .rejected; rejected.note = "Same payment"
        _ = try await results.save(caseID: f.caseID, jobID: "fa.fund-flow", family: .monetaryWorkpapers, state: .draft,
                                   content: JobResultContent(rows: [paid, open, rejected]), actor: "Ada")
        let record = try #require(try await results.latest(caseID: f.caseID, jobID: "fa.fund-flow"))
        let money = try await JobResultHandoff.addToMoney(record, row: 0, results: results, caseFiles: f.svc, actor: "Ada")
        let ledger = try await f.file.moneyLedger(caseID: f.caseID)
        let r = try #require(ledger.records.first { $0.id == money })
        #expect(r.kind == .unclassified && r.amountText == "USD 1,200" && r.date == "2026-03-03" && r.sourceVersionID == doc.version)
        #expect(ledger.outcomes().byCurrency.values.allSatisfy { $0.grossPaid.records.isEmpty }, "a proposal enters no figure until classified")
        await #expect(throws: CaseFileError.alreadyCarried("That money record")) {
            _ = try await JobResultHandoff.addToMoney(record, row: 0, results: results, caseFiles: f.svc, actor: "Ada")
        }
        let distinct = try await JobResultHandoff.addToMoney(record, row: 0, results: results, caseFiles: f.svc, allowDuplicate: true, actor: "Ada")
        #expect(distinct != money)
        await #expect(throws: CaseFileError.rejectedRowNotEvidence) {
            _ = try await JobResultHandoff.addToMoney(record, row: 2, results: results, caseFiles: f.svc, actor: "Ada")
        }
        await #expect(throws: JobResultHandoffError.noAmount) {
            _ = try await JobResultHandoff.addToMoney(record, row: 1, results: results, caseFiles: f.svc, actor: "Ada")
        }
        let q = try await JobResultHandoff.addToQuestion(record, row: 1, results: results, caseFiles: f.svc, actor: "Ada")
        #expect(try await f.file.allegations(caseID: f.caseID).first { $0.id == q }?.text == "Who authorised the Kestrel payment?")
        await #expect(throws: CaseFileError.alreadyCarried("That question")) {
            _ = try await JobResultHandoff.addToQuestion(record, row: 1, results: results, caseFiles: f.svc, actor: "Ada")
        }
        let carried = try await f.file.carriedRecords(caseID: f.caseID)
        let digest = try #require(try await results.payloadSHA256(id: record.id))
        let origin0 = JobResultHandoff.origin(jobID: "fa.fund-flow", resultID: record.id, row: 0)
        #expect(carried.filter { $0.origin == origin0 && $0.targetKind == .moneyRecord }.count == 2)
        #expect(carried.filter { $0.origin == origin0 }.allSatisfy { $0.originDigest == digest && $0.reviewState == "accepted" })
        #expect(carried.contains { $0.targetKind == .question && $0.targetID == q && $0.reviewState == "undecided" && !$0.distinct })
        // The carried question is on the map as an open question.
        let p = try #require(await caseMapLoad(f).projection)
        #expect(p.nodes.contains { $0.kind == .question && $0.title.contains("Kestrel payment") })
        // The carry record is fixed.
        await #expect(throws: (any Error).self) { try await f.db.exec("UPDATE case_carried_records SET target_id = 'x';") }
    }

    // MARK: ADAPT-05

    @Test("ADAPT-05: a summary supplied for an unread original is attached, labelled as supplied, never the document's words; withdraw-only")
    func suppliedSummary() async throws {
        let f = try await CaseFileTests.fixture()
        let doc = try await CaseFileTestSources.seedPassage(f.db, cases: f.cases, caseID: f.caseID, name: "mailbox.pst", text: "x")
        let id = try await f.file.addSuppliedSummary(caseID: f.caseID, sourceVersionID: doc.version, objectID: doc.object, sourceName: "mailbox.pst",
                                                     summary: "Forty emails between the buyer and Kestrel, March 2026.", suppliedBy: "Custodian (IT)",
                                                     basis: "covering letter of 4 April", actor: "Ada")
        let s = try #require(try await f.file.suppliedSummaries(caseID: f.caseID).first { $0.id == id })
        #expect(s.label.contains("Supplied summary by Custodian (IT)") && s.label.contains("not read from the document"))
        await #expect(throws: CaseInteropError.noOriginal) {
            _ = try await f.file.addSuppliedSummary(caseID: f.caseID, sourceVersionID: nil, objectID: nil, sourceName: nil, summary: "x", suppliedBy: "y", basis: nil, actor: "Ada")
        }
        await #expect(throws: (any Error).self) {
            _ = try await f.file.addSuppliedSummary(caseID: f.caseID, sourceVersionID: UUID(), objectID: nil, sourceName: nil, summary: "x", suppliedBy: "y", basis: nil, actor: "Ada")
        }
        await #expect(throws: (any Error).self) { try await f.db.exec("UPDATE case_supplied_summaries SET summary = 'changed';") }
        await #expect(throws: (any Error).self) { try await f.file.withdrawSuppliedSummary(caseID: f.caseID, id: id, reason: " ", actor: "Ada") }
        try await f.file.withdrawSuppliedSummary(caseID: f.caseID, id: id, reason: "The original was read after all", actor: "Ada")
        #expect(try await f.file.suppliedSummaries(caseID: f.caseID).first { $0.id == id }?.isActive == false)
        #expect(s12Source("Kalsmritikosh/UI/CaseMapWorkCommands.swift").contains("CaseSuppliedSummaryBlock(caseID: model.caseID"))
    }

    // MARK: ADAPT-06

    @Test("ADAPT-06: a case exported as a structured exchange and imported elsewhere keeps its records, sources and links with stable ids; re-import matches; unsupported fields are named")
    func exchangeRoundTrip() async throws {
        let f = try await CaseFileTests.fixture(title: "Source case")
        let doc = try await CaseFileTestSources.seedPassage(f.db, cases: f.cases, caseID: f.caseID, name: "minutes.txt",
                                                            text: "The board approved the change on 2 May 2024.")
        let q = try await f.file.addAllegation(caseID: f.caseID, text: "Who approved the change?", actor: "Ada")
        let person = try await f.file.addPerson(caseID: f.caseID, name: "Maria Lopez", role: .witness, entityID: nil, contact: nil, notes: nil, actor: "Ada")
        let entry = try await f.file.addJournal(caseID: f.caseID, kind: .chronology, text: "Board approval", eventDate: nil, evidenceRef: doc.version.uuidString,
                                                quote: "The board approved the change on 2 May 2024.", datePrecision: .day, dateText: "2024-05-02", actor: "Ada")
        let maps = CaseMapRepository(database: f.db)
        let node = { (k: CaseMapRecordKind, id: UUID) in CaseMapNodeID(caseID: f.caseID, kind: k, recordID: id.uuidString.lowercased()) }
        _ = try await maps.addLink(caseID: f.caseID, type: .mentions, from: node(.journal, entry), to: node(.allegation, q), rationale: "The minutes record the approval", actor: "Ada")
        _ = try await maps.addLink(caseID: f.caseID, type: .attributedTo, from: node(.journal, entry), to: node(.person, person), rationale: "She signed the minutes",
                                   certainty: .probable, actor: "Ada")
        let exported = try await f.file.exchangeDocument(caseID: f.caseID, sourceSystem: "office-a")
        #expect(exported.records.count == 3 && exported.relationships.count == 2)
        // A second case in the same ledger, with the same document in its scope.
        let other = try await f.cases.createCase(workspaceID: f.workspaceID, title: "Receiving case", actor: "Ada", at: Date())
        let header = try await f.cases.fetch(caseID: other.id)?.caseHeader
        _ = try await f.cases.includeSource(caseID: other.id, expectedRevision: header?.revision ?? 1, sourceRef: doc.version.uuidString, sourceKind: .sourceVersion, actor: "Ada", at: Date())
        let data = try CaseExchange.encode(exported)
        let r1 = try await f.file.importExchange(caseID: other.id, data: data, actor: "Ada")
        #expect(r1.created.count == 5 && r1.matched.isEmpty && r1.skipped.isEmpty && r1.unsupportedFields.isEmpty, "\(r1)")
        // Round trip: the receiving case exports the same meanings under the same ids.
        let back = try await f.file.exchangeDocument(caseID: other.id, sourceSystem: "office-a")
        func meaning(_ d: CaseExchange.Document) -> [String] {
            d.records.map { "\($0.id)|\($0.kind)|\($0.text)|\($0.date ?? "")|\($0.role ?? "")|\($0.sources.map { "\($0.sourceVersionID)~\($0.quote ?? "")" })" }.sorted()
        }
        func links(_ d: CaseExchange.Document) -> [String] { d.relationships.map { "\($0.type)|\($0.from)|\($0.to)|\($0.rationale ?? "")|\($0.certainty ?? "")" }.sorted() }
        #expect(meaning(back) == meaning(exported))
        #expect(links(back) == links(exported))
        // Importing the same file again matches everything; nothing is duplicated.
        let r2 = try await f.file.importExchange(caseID: other.id, data: data, actor: "Ada")
        #expect(r2.created.isEmpty && r2.matched.count == 5)
        let qs = try await f.file.allegations(caseID: other.id).count, ps = try await f.file.people(caseID: other.id).count
        #expect(qs == 1 && ps == 1)
        // Receipts are kept and fixed.
        #expect(try await f.file.exchangeImports(caseID: other.id).count == 2)
        await #expect(throws: (any Error).self) { try await f.db.exec("UPDATE case_exchange_imports SET created_count = 99;") }
        // Unsupported fields are reported by name.
        var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["vendorExtension"] = ["x": 1]
        var recs = try #require(json["records"] as? [[String: Any]])
        recs[0]["confidence"] = 0.9
        json["records"] = recs
        let parsed = try CaseExchange.parse(try JSONSerialization.data(withJSONObject: json))
        #expect(parsed.unsupportedFields.contains("vendorExtension") && parsed.unsupportedFields.contains("records[0].confidence"))
    }

    // MARK: ADAPT-07

    @Test("ADAPT-07: an enrichment result keeps no-match apart from denied, failed and partial, with origin, time, scope, page and restrictions")
    func enrichmentStatuses() {
        let at = Date(timeIntervalSince1970: 1_700_000_000)
        let entry = SanctionsLists.Entry(list: .ofacSDN, reference: "12345", name: "KESTREL SUPPLIES", detail: "SDGT")
        let hit = CaseEnrichmentAdapters.sanctions(query: "Kestrel Supplies", matches: [SanctionsLists.Match(entry: entry, exact: false)], searched: [.ofacSDN, .unConsolidated], failedLists: [], at: at)
        #expect(hit.status == .matches && hit.candidates.first?.identifiers == ["12345"] && hit.retrievedAt == at && !hit.restrictions.isEmpty)
        let none = CaseEnrichmentAdapters.sanctions(query: "Nobody", matches: [], searched: [.ofacSDN], failedLists: [], at: at)
        #expect(none.status == .noMatch && none.summary.contains("No match"))
        let partial = CaseEnrichmentAdapters.sanctions(query: "Nobody", matches: [], searched: [.ofacSDN], failedLists: [.unConsolidated], at: at)
        #expect(partial.status == .partial && partial.summary.contains("not a “no match”"))
        let failed = CaseEnrichmentAdapters.sanctions(query: "Nobody", matches: [], searched: [], failedLists: [.ofacSDN], at: at)
        #expect(failed.status == .failed)
        let denied = CaseEnrichmentAdapters.registry(source: .gleif, query: "Kestrel", outcome: .failure(.offline), at: at)
        #expect(denied.status == .denied && denied.summary.contains("Not searched"))
        let http = CaseEnrichmentAdapters.registry(source: .courtListener, query: "Kestrel", outcome: .failure(.http(503)), at: at)
        #expect(http.status == .failed)
        let paged = CaseEnrichmentAdapters.registry(source: .gleif, query: "Kestrel",
                                                    outcome: .success([RegistryLookups.Record(source: .gleif, title: "Kestrel Ltd", detail: "LEI", link: "https://example.invalid/1")]),
                                                    page: 1, hasMore: true, at: at)
        #expect(paged.status == .partial && paged.page == 1 && paged.hasMore)
        // Paid providers are prerequisites, recorded as blocked.
        #expect(InteropContracts.connectors.filter { $0.status.hasPrefix("BLOCKED") }.allSatisfy { $0.prerequisite.contains("subscription") || $0.prerequisite.contains("paid") })
    }

    // MARK: ADAPT-08

    @Test("ADAPT-08: changed versions, wrong format, bad encodings, missing columns, duplicates and invalid ids are refused or accounted for; a partial import never changes an existing record")
    func adapterFailureModes() async throws {
        func doc(_ body: String, version: Int = 1, format: String = "ime-case-exchange") -> Data {
            Data(#"{"format":"\#(format)","version":\#(version),"sourceSystem":"lab","records":[\#(body)],"relationships":[]}"#.utf8)
        }
        #expect(throws: CaseInteropError.unsupportedVersion(2)) { _ = try CaseExchange.parse(doc("", version: 2)) }
        #expect(throws: CaseInteropError.wrongFormat("other")) { _ = try CaseExchange.parse(doc("", format: "other")) }
        #expect(throws: CaseInteropError.notJSON) { _ = try CaseExchange.parse(Data("id,kind\n1,person".utf8)) }
        let utf16 = try #require(String(decoding: doc(""), as: UTF8.self).data(using: .utf16))
        #expect(throws: CaseInteropError.notUTF8) { _ = try CaseExchange.parse(utf16) }
        #expect(throws: CaseInteropError.missingField("sourceSystem")) { _ = try CaseExchange.parse(Data(#"{"format":"ime-case-exchange","version":1,"records":[]}"#.utf8)) }
        var bom = Data([0xEF, 0xBB, 0xBF]); bom.append(doc(""))
        #expect(try CaseExchange.parse(bom).document.records.isEmpty, "a UTF-8 byte-order mark is tolerated")
        let body = #"""
        {"id":"a","kind":"person","text":"Ann"},
        {"id":"a","kind":"person","text":"Ann again"},
        {"kind":"person","text":"No id"},
        {"id":"b\u202Ex","kind":"person","text":"Direction trick"},
        {"id":"c","kind":"vehicle","text":"Blue van"},
        {"id":"d","kind":"question"},
        {"id":"e","kind":"event","text":"Visit","sources":[{"quote":"no version"},{"sourceVersionID":"not-a-uuid"}]}
        """#
        let parsed = try CaseExchange.parse(doc(body))
        #expect(parsed.document.records.map(\.id) == ["a", "e"])
        for reason in ["same id appears earlier", "no id", "invalid id", "“vehicle” is not supported", "no text", "no sourceVersionID"] {
            #expect(parsed.skipped.contains { $0.contains(reason) }, "\(reason) in \(parsed.skipped)")
        }
        // A partial import is accounted for, and a later file cannot change what is already in the case.
        let f = try await CaseFileTests.fixture()
        let r = try await f.file.importExchange(caseID: f.caseID, data: doc(body), actor: "Ada")
        #expect(r.created == ["a", "e"] && r.skipped.count >= 6 && r.limitations.contains { $0.contains("not-a-uuid") })
        let changed = try await f.file.importExchange(caseID: f.caseID, data: doc(#"{"id":"a","kind":"person","text":"Someone else"}"#), actor: "Ada")
        #expect(changed.matched == ["a"] && changed.created.isEmpty)
        #expect(try await f.file.people(caseID: f.caseID).map(\.name) == ["Ann"], "a matched identity is never overwritten")
        // A relationship to an unknown record or of a type a person cannot draw is skipped, not guessed.
        let rels = Data(#"{"format":"ime-case-exchange","version":1,"sourceSystem":"lab","records":[{"id":"a","kind":"person","text":"Ann"}],"relationships":[{"id":"r1","type":"mentions","from":"a","to":"zzz"},{"id":"r2","type":"placedIn","from":"a","to":"a"}]}"#.utf8)
        let rr = try await f.file.importExchange(caseID: f.caseID, data: rels, actor: "Ada")
        #expect(rr.skipped.contains { $0.hasPrefix("r1") } && rr.skipped.contains { $0.hasPrefix("r2") })
        // Statement rows: a missing column, a line whose columns do not match, or a row without an amount refuses the whole import.
        let acct = try await f.file.addMoneyAccount(caseID: f.caseID, identifier: "ACC-1", actor: "Ada")
        let st = try await f.file.addMoneyStatement(caseID: f.caseID, accountID: acct, periodStart: "2026-01-01", periodEnd: "2026-01-31", opening: nil, closing: nil, currency: "EUR", actor: "Ada")
        await #expect(throws: (any Error).self) {
            _ = try await f.file.importStatementRows(caseID: f.caseID, statementID: st, text: "Date,Description,Amount\n2026-01-05,Payment,100", actor: "Ada")
        }
        await #expect(throws: (any Error).self) {
            _ = try await f.file.importStatementRows(caseID: f.caseID, statementID: st, text: "Date,Description,Debit,Credit\n2026-01-05,Payment,100,\n2026-01-06,Fee,1,000.00,", actor: "Ada")
        }
        await #expect(throws: CaseMoneyError.rowHasNoAmount(2)) {
            _ = try await f.file.importStatementRows(caseID: f.caseID, statementID: st, text: "Date,Description,Debit,Credit\n2026-01-05,Payment,100,\n2026-01-06,Note,,", actor: "Ada")
        }
        #expect(try await f.file.moneyLedger(caseID: f.caseID).records.isEmpty, "nothing of a refused statement was written")
        let ok = try await f.file.importStatementRows(caseID: f.caseID, statementID: st, text: "Statement for January\nDate,Description,Debit,Credit\n2026-01-05,Payment,100,\nEnd of statement", actor: "Ada")
        #expect(ok.count == 1, "title and footer lines without columns are not rows")
    }

    // MARK: ADAPT-04 / ADAPT-09

    @Test("ADAPT-04/09: every adapter states its versions, fields and version rule and names real tests; named products without integration say None")
    func interopContracts() throws {
        let tests = try FileManager.default.contentsOfDirectory(at: s12Root.appendingPathComponent("KalsmritikoshTests"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }.map { (try? String(contentsOf: $0, encoding: .utf8)) ?? "" }.joined(separator: "\n")
        for a in InteropContracts.adapters {
            #expect(!a.testedVersions.isEmpty && !a.fields.isEmpty && !a.versionRule.isEmpty && !a.limits.isEmpty, "\(a.name)")
            for t in a.tests {
                let parts = t.split(separator: ".").map(String.init)
                #expect(parts.count == 2 && tests.contains("struct \(parts[0])") && tests.contains("func \(parts[1])("), "\(a.name): test \(t) not found")
            }
        }
        let md = InteropContracts.markdown()
        #expect(md.contains("not universal compatibility") || md.contains("is not universal compatibility"))
        for p in InteropContracts.products where p.support == "None" { #expect(p.note.contains("No") || p.note.contains("no"), "\(p.product)") }
        #expect(!md.lowercased().contains("fully compatible") && !md.lowercased().contains("parity with"))
    }

    // MARK: Schema

    @Test("v188 from a v187 ledger: the carry, supplied-summary and import-receipt tables exist and are fixed; the erasure inventory lists them")
    func migrationV188() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 187)
        try await SchemaMigrations.migrate(db)
        #expect(try await db.currentUserVersion() >= 188)
        for t in ["case_carried_records", "case_supplied_summaries", "case_exchange_imports"] {
            #expect(try await MigrationFixtureBuilder.tableExists(db, t), "\(t)")
            #expect(CaseDataInventory.entries.contains { $0.table == t }, "\(t) inventoried for erasure")
        }
        try await db.exec("INSERT INTO case_supplied_summaries (id, case_id, object_id, summary, supplied_by, recorded_by, recorded_at) VALUES ('s', 'c', 'o', 'x', 'y', 'z', 1);")
        await #expect(throws: (any Error).self) {
            try await db.exec("INSERT INTO case_supplied_summaries (id, case_id, summary, supplied_by, recorded_by, recorded_at) VALUES ('t', 'c', 'x', 'y', 'z', 1);")
        }
        await #expect(throws: (any Error).self) { try await db.exec("UPDATE case_supplied_summaries SET withdrawn_at = 2;") }
        try await db.exec("UPDATE case_supplied_summaries SET withdrawn_by = 'z', withdrawn_at = 2, withdrawn_reason = 'read after all';")
        #expect(try await MigrationFaultHarness.integrityOK(db))
    }
}
