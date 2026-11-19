//
//  NavigationMergeTests.swift
//  KalsmritikoshTests
//
//  Navigation merge (Core and Add-On Scope 2026-11-06, §3 and §9.5–9.6): four areas — Cases, Evidence,
//  Search, Outputs — with Settings and Help as utilities and every other screen under More tools and ⌘K.
//  These pin: the old → new mapping for every destination the app shipped (none lost, none blank); palette,
//  menu, deep-link and saved-history routing; Ask in the case's context; Search defaulting to the active case
//  with widening only by choice; the Evidence context label; a switched-off pack explaining itself; the
//  simplified sidebar and the keyboard map.
//

import Foundation
import SwiftUI
import Testing
@testable import Kalsmritikosh

@Suite("Navigation merge — Cases, Evidence, Search, Outputs")
struct NavigationMergeTests {

    static let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    static func source(_ path: String) -> String {
        (try? String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)) ?? ""
    }

    /// The mapping table (old destination → the area it opens in). Every destination the app shipped before
    /// the merge is listed; the test fails if one is dropped, renamed or lands somewhere else.
    static let expectedHome: [String: NavHome] = [
        // Cases: start and resume (Home is the start page), projects and the caseload.
        "home": .cases, "cases": .cases, "workspaces": .cases, "caseload": .cases,
        // Evidence: intake and review.
        "sources": .evidence, "library": .evidence, "completeness": .evidence, "live": .evidence,
        // Search, with Ask inside it.
        "search": .search, "ask": .search,
        // Outputs.
        "answers": .outputs, "saved": .outputs, "notebook": .outputs, "handoff": .outputs,
        // Utilities.
        "settings": .settings, "guide": .help,
        // More tools: case analysis views, professional workspaces, records and checks, archive analysis.
        "timeline": .moreTools, "history": .moreTools, "story": .moreTools, "dossier": .moreTools, "explore": .moreTools,
        "connections": .moreTools, "findings": .moreTools, "assertions": .moreTools, "hypotheses": .moreTools,
        "review": .moreTools, "insights": .moreTools, "changes": .moreTools, "matrix": .moreTools, "compareDocs": .moreTools,
        "fundFlow": .moreTools, "emailThreads": .moreTools, "transcripts": .moreTools,
        "work": .moreTools, "workCenter": .moreTools, "registers": .moreTools, "dataLab": .moreTools, "reasoning": .moreTools,
        "hrStudio": .moreTools, "privilegeStudio": .moreTools, "siuStudio": .moreTools, "faStudio": .moreTools,
        "jnStudio": .moreTools, "rsStudio": .moreTools, "gnStudio": .moreTools, "ccStudio": .moreTools,
        "inStudio": .moreTools, "dsStudio": .moreTools,
        "audit": .moreTools, "verifyReceipt": .moreTools, "authenticity": .moreTools, "citations": .moreTools,
        "redaction": .moreTools, "convert": .moreTools,
        "knowledge": .moreTools, "trends": .moreTools, "freshness": .moreTools, "query": .moreTools,
        "sutra": .moreTools, "sopBoard": .moreTools
    ]

    // MARK: Mapping table

    @Test("Every destination the app shipped routes to a new home, and none lands on a blank screen")
    func everyOldDestinationHasAHome() {
        #expect(NavigationCompat.legacyRawValues.count == 60)
        #expect(Set(NavigationCompat.legacyRawValues) == Set(Self.expectedHome.keys))
        for raw in NavigationCompat.legacyRawValues {
            let dest = try? #require(NavigationCompat.destination(raw: raw), "\(raw) no longer resolves")
            guard let dest else { continue }
            #expect(dest.home == Self.expectedHome[raw], "\(raw) → \(dest.home), expected \(String(describing: Self.expectedHome[raw]))")
            // What the detail shows: an area on the old screen's own section, or the screen itself.
            switch dest.surface {
            case .evidence(let s): #expect(s?.destination == dest, "\(raw) opens Evidence on another section")
            case .outputs(let s): #expect(s?.destination == dest, "\(raw) opens Outputs on another section")
            case .search(let m): #expect((m == .ask) == (dest == .ask), "\(raw) opens Search in the wrong mode")
            case .moreTools: Issue.record("\(raw) became the More tools list")
            case .screen: break
            }
            // Never blank: it has a screen topic, or (pack off) its own explanation.
            if let pack = dest.requiredPack, !ProductModuleFlags.isEnabled(pack) {
                #expect(PackNotice.text(for: dest) != nil, "\(raw)")
            } else {
                #expect(HelpRegistry.screenTopic(for: dest) != nil, "\(raw) has no screen topic")
            }
            // Its area is a sidebar row.
            #expect((Destination.primaries + Destination.utilities).contains { $0.home == dest.home }, "\(raw)")
        }
        // The new destinations are the areas' own screens.
        #expect(Destination.evidence.surface == .evidence(nil) && Destination.outputs.surface == .outputs(nil))
        #expect(Destination.moreTools.surface == .moreTools && Destination.allCases.count == 63)
    }

    @Test("The rendered router has a case for every surface kind (source check: the four hosts are wired)")
    func routerWiresTheAreas() {
        let root = Self.source("Kalsmritikosh/UI/RootView.swift")
        for needle in ["case .ask, .search:", "SearchAreaView(mode:", "case .evidence, .sources, .library, .completeness, .live:",
                       "EvidenceAreaView(section:", "case .outputs, .answers, .saved, .notebook, .handoff:", "OutputsAreaView(section:",
                       "case .moreTools:    MoreToolsView(", "PackGatedScreen(dest: .ccStudio)", "private let simpleMode = true"] {
            #expect(root.contains(needle), "RootView misses \(needle)")
        }
    }

    // MARK: Palette, menu, deep links, saved history

    @Test("Palette and menu entries route to the destination, inside its area")
    func paletteRouting() {
        let entries = PaletteCatalog.entries()
        for dest in Destination.allCases {
            let entry = entries.first { $0.id == "go.\(dest.rawValue)" }
            #expect(entry?.target == .screen(dest), "\(dest.rawValue)")
            #expect(NavigationCompat.destination(raw: "go.\(dest.rawValue)") == dest)
        }
        // The new areas are found by their names, first.
        for dest in [Destination.evidence, .outputs, .moreTools, .cases, .search] {
            #expect(PaletteCatalog.matches(query: dest.title, in: entries).first?.target == .screen(dest), "\(dest.title)")
        }
        // Old names still find their screen (now inside an area).
        #expect(PaletteCatalog.matches(query: "Sources", in: entries).first?.target == .screen(.sources))
        #expect(PaletteCatalog.matches(query: "Ask", in: entries).first?.target == .screen(.ask))
        // Menu items post palette ids; each one resolves.
        let app = Self.source("Kalsmritikosh/KalsmritikoshApp.swift")
        let ids = Set(entries.map(\.id))
        for id in ["act.addFolder", "act.ingestAll", "act.deleteAllData"] {
            #expect(app.contains("postPaletteEntry(\"\(id)\")") && ids.contains(id), "\(id)")
        }
        #expect(ids.contains("set.modules"), "the pack notice's remedy targets Settings ▸ Modules")
        // An unknown stored name opens nothing (the window stays where it is), never a blank screen.
        #expect(NavigationCompat.destination(raw: "go.noSuchScreen") == nil && NavigationCompat.destination(raw: "") == nil)
    }

    @Test("Saved Back/Forward history and the persona shortcuts migrate: raw values are unchanged")
    func savedHistoryMigrates() {
        var h = AppNavigationHistory()
        for raw in ["home", "sources", "ask", "answers", "timeline"] {
            h.navigate(to: AppNavigationEntry(destination: .home, contextKind: "surface", contextID: raw))
        }
        let restored = h.entries.compactMap { $0.contextID.flatMap(Destination.init(rawValue:)) }
        #expect(restored == [.home, .sources, .ask, .answers, .timeline])
        #expect(restored.map(\.home) == [.cases, .evidence, .search, .outputs, .moreTools])
        // The fixed persona shortcuts were Professional Jobs, Cases, Review, Guide; Cases and Help are now rows.
        #expect(NavigationCompat.personaShortcuts(permanent: Set(Destination.primaries + Destination.utilities)) == [.work, .review])
        // The active case preference is the one Cases writes.
        #expect(ActiveCaseContext.key == CasesView.lastOpenKey)
    }

    @Test("Deep links, Spotlight and Shortcuts open a passage over the current screen; none navigates")
    func deepLinksKeepTheContext() throws {
        let id = UUID()
        let url = try #require(DeepLink.document(id: id, quote: "invoice 432").url)
        #expect(DeepLink(url: url) == .document(id: id, quote: "invoice 432"))
        #expect(DeepLink(url: URL(string: "kalsmritikosh://screen/evidence")!) == nil, "a link cannot switch screens")
        // The handlers set the passage sheet only; they never change the screen or the open case.
        for path in ["Kalsmritikosh/App/DeepLink.swift", "Kalsmritikosh/App/SpotlightIndexer.swift", "Kalsmritikosh/App/Intents/KalsmritikoshIntents.swift"] {
            let src = Self.source(path)
            #expect(!src.isEmpty, "\(path)")
            for forbidden in ["SurfaceOpener", "kalsmritikoshNavigate", "lastOpen"] { #expect(!src.contains(forbidden), "\(path) uses \(forbidden)") }
        }
        // The menu bar's Ask/Search land in Search, whose scope follows the open case.
        #expect(Destination.ask.surface == .search(.ask) && Destination.search.surface == .search(.find))
    }

    // MARK: Search scope and Ask in the case

    @Test("Search defaults to the active case; the whole library only when chosen; a new case starts from that case")
    func searchDefaultScope() {
        let a = UUID(), b = UUID()
        var s = SearchAreaState(activeCase: a)
        #expect(s.scope == .activeCase(a))
        #expect(s.askCase(mode: .ask) == a && s.askCase(mode: .find) == nil)
        s.widen()
        #expect(s.scope == .library && s.askCase(mode: .ask) == nil)
        s.caseChanged(a)                       // the same case: the choice stands
        #expect(s.scope == .library)
        s.narrow()
        #expect(s.scope == .activeCase(a))
        s.widen(); s.caseChanged(b)            // another case opened: back to that case
        #expect(s.scope == .activeCase(b))
        s.caseChanged(nil)                     // no case open: the library, said so
        #expect(s.scope == .library)
        s.narrow()
        #expect(s.scope == .library, "nothing to narrow to without a case")
        #expect(SearchAreaState(activeCase: nil).scope == .library)
        // The words name the scope.
        #expect(ContextLabel.searchDetail(.activeCase(a), mode: .find, caseTitle: "Delta").contains("only the documents in “Delta”"))
        #expect(ContextLabel.searchDetail(.activeCase(a), mode: .ask, caseTitle: "Delta").contains("“Whole library”"))
        #expect(ContextLabel.searchDetail(.library, mode: .find, caseTitle: nil).contains("every document in the library"))
        // Case scope runs the case search (CaseSearchService) embedded; library scope runs the archive search.
        let areas = Self.source("Kalsmritikosh/UI/NavigationAreas.swift")
        #expect(areas.contains("case (.activeCase(let id), .find):") && areas.contains("CaseSearchPanel(caseID: id"))
        #expect(areas.contains("case (.library, .find):\n            SearchView()"))
    }

    @Test("Ask is in the case's context: the area, the case file button, and no outside lanes for a case question")
    func askInCaseContext() {
        #expect(Destination.ask.home == .search && !Destination.primaries.contains(.ask))
        let scope = AskCaseScope(caseID: UUID(), workspaceID: UUID(), title: "Delta")
        #expect(!AskCaseScope.extraLanesAllowed(scope) && AskCaseScope.extraLanesAllowed(nil))
        #expect(scope.access.scope.workspaceID == scope.workspaceID && !scope.access.scope.permitsPrivilegedMaterial)
        let failed = AskCaseScope.failure("the ledger isn't ready yet.")
        #expect(failed.refused && failed.citations.isEmpty && failed.body.contains("Nothing was guessed"))
        #expect(Self.source("Kalsmritikosh/UI/CaseFileView.swift").contains("SurfaceOpener.open(.ask)"))
        #expect(Self.source("Kalsmritikosh/UI/AskView.swift").contains("answer = await appState.answerInCase(caseScope, question: q)"))
    }

    @Test("A question asked in a case cites only that case's documents", .timeLimit(.minutes(5)))
    func caseQuestionStaysInTheCase() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("navmerge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let state = await AppState(bookmarks: BookmarkStore(ephemeral: true))
        await state.boot(databaseURL: temp.appendingPathComponent("nav.sqlite"))
        defer { try? FileManager.default.removeItem(at: temp) }
        guard case .ready = await state.phase, let ingest = await state.ingest, let db = await state.database,
              let sources = await state.workspaceSourceCoordinator, let cases = await state.investigationCases,
              let intake = await state.investigationWorkspaceIntake else {
            Issue.record("AppState did not boot"); await state.shutdown(); return
        }
        var files: [UUID] = []
        for name in ["investigator-press-release.txt", "lawyer-decision.txt"] {
            let dst = temp.appendingPathComponent(name)
            try FileManager.default.copyItem(at: try InvestigationCasePacks.url(name), to: dst)
            files.append(try await ingest.ingest(fileAt: dst).fileRecord.id)
        }
        let now = Date()
        let ws = UUID()
        try await db.exec("INSERT INTO workspaces (id, title, created_at, updated_at) VALUES (?,?,?,?);",
                          [.uuid(ws), .text("Press release only"), .real(now.timeIntervalSince1970), .real(now.timeIntervalSince1970)])
        try await sources.addSources([files[0]], to: ws, at: now)
        let c = try await cases.createCase(workspaceID: ws, title: "Press release only", actor: "Tester", at: now)
        _ = try await intake.includeWorkspaceSources(caseID: c.id, actor: "Tester", at: now)
        let inCase = Set(try await db.query("SELECT id FROM knowledge_objects WHERE file_id = ?;", [.uuid(files[0])]).compactMap { $0.uuid(0) })
        let outside = Set(try await db.query("SELECT id FROM knowledge_objects WHERE file_id = ?;", [.uuid(files[1])]).compactMap { $0.uuid(0) })
        #expect(!inCase.isEmpty && !outside.isEmpty)

        // The Evidence label reads the open case from the ledger: its title and documents in scope.
        let model = await ActiveCaseModel()
        await model.load(state, raw: c.id.uuidString)
        let facts = await model.facts
        #expect(facts == ContextLabel.CaseFacts(title: "Press release only", inScope: 1, excluded: 0))
        #expect(await model.workspaceID == ws)

        // A question whose answer is only in the document outside the case.
        let scope = AskCaseScope(caseID: c.id, workspaceID: ws, title: "Press release only")
        let answer = await state.answerInCase(scope, question: "Who was the Collector of Internal Revenue in Corporation of America v. McLaughlin?")
        let cited = Set(answer.citations.map(\.objectID))
        #expect(cited.isDisjoint(with: outside), "a case question cited a document outside the case")
        #expect(cited.isSubset(of: inCase))
        #expect(!answer.body.contains("McLaughlin, Collector"))

        // An unknown or erased case: the library, said so.
        await model.load(state, raw: UUID().uuidString)
        let gone = await (model.facts, model.missing)
        #expect(gone.0 == nil && gone.1)
        await model.load(state, raw: "")
        let none = await (model.facts, model.missing)
        #expect(none.0 == nil && !none.1)
        await state.shutdown()
    }

    // MARK: Evidence label, pack notice, keyboard

    @Test("Evidence says whether it is in a case or the whole library, and excluded sources stay excluded")
    func evidenceLabel() {
        let c = ContextLabel.CaseFacts(title: "Delta", inScope: 8, excluded: 2)
        #expect(ContextLabel.caseHeadline(c) == "Active case: Delta")
        #expect(ContextLabel.evidenceDetail(c) == "8 documents in this case; 2 excluded, and they stay excluded. The lists below cover the whole library; the case's own evidence is in the case file.")
        #expect(ContextLabel.evidenceDetail(.init(title: "One", inScope: 1, excluded: 0)).hasPrefix("1 document in this case. "))
        #expect(ContextLabel.caseHeadline(.init(title: "Old", inScope: 0, excluded: 0, closed: true)) == "Active case: Old (closed)")
        #expect(ContextLabel.libraryHeadline == "Whole library — no case is open")
        // Opening the case's own Evidence section: the tab is remembered for that case and the case becomes active.
        let suite = "navmerge-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = UUID()
        ActiveCaseContext.prepareOpen(caseID: id, tab: CaseFileTab.evidence.rawValue, defaults: defaults)
        #expect(ActiveCaseContext.caseID(defaults: defaults) == id)
        #expect(CaseWorkspaceStore.load(caseID: id, defaults: defaults).tab == CaseFileTab.evidence.rawValue)
    }

    @Test("A destination of a switched-off pack explains itself and names Settings ▸ Modules")
    func disabledPackExplains() {
        let off = PackNotice.text(for: .ccStudio, isEnabled: { _ in false })
        #expect(off?.contains("“\(ProductModule.contentCreatorPersona.title)” is switched off") == true)
        #expect(off?.hasSuffix("Turn on in Settings ▸ Modules.") == true)
        #expect(PackNotice.text(for: .ccStudio, isEnabled: { _ in true }) == nil)
        for dest in Destination.allCases where dest != .ccStudio {
            #expect(PackNotice.text(for: dest, isEnabled: { _ in false }) == nil, "\(dest.rawValue) has no pack")
        }
        // The notice's button posts the Modules anchor, which the palette router opens.
        #expect(PaletteCatalog.entries().first { $0.id == "set.modules" }?.target == .settingsAnchor(.modules))
        #expect(Self.source("Kalsmritikosh/UI/NavigationAreas.swift").contains("object: \"set.modules\""))
    }

    @Test("⌘1–⌘4 are the four areas; ⌘5–⌘9 are documented; each shortcut is unique and in the palette")
    func keyboardMap() {
        let keys = Destination.quickShortcuts.map { String($0.key.character) }
        #expect(keys == ["1", "2", "3", "4", "5", "6", "7", "8", "9"])
        #expect(Destination.quickShortcuts.prefix(4).map(\.dest) == Destination.primaries)
        #expect(Destination.quickShortcuts.map(\.dest) == [.cases, .evidence, .search, .outputs, .ask, .moreTools, .timeline, .live, .settings])
        #expect(Set(Destination.quickShortcuts.map(\.dest)).count == 9)
        #expect(Destination.ask.shortcutHint == "⌘5" && Destination.cases.shortcutHint == "⌘1")
        let help = HelpRegistry.topic("task-find-your-way")?.searchText ?? ""
        for word in ["cases (⌘1)", "evidence (⌘2)", "search (⌘3)", "outputs (⌘4)", "⌘5", "more tools (⌘6)", "⌘7", "⌘8", "⌘9", "before this change"] {
            #expect(help.contains(word), "help does not document \(word)")
        }
    }

    @Test("The tutorials name the new places, and every step's screen resolves to an area")
    func tutorialsUseTheNewPlaces() {
        for step in HelpTutorial.steps + HelpTutorial.caseMapSteps {
            if let d = step.destination { #expect(NavHome.allCases.contains(d.home), "\(step.id)") }
        }
        let ask = HelpTutorial.steps.first { $0.id == "ask" }
        #expect(ask?.instruction.contains("“Ask about this case”") == true && ask?.destination == .ask)
        #expect(HelpTutorial.steps.first { $0.id == "open-sample" }?.instruction.contains("Evidence ▸ Sources") == true)
        #expect(HelpRegistry.getStarted.steps.first?.contains("Open Evidence ▸ Sources") == true)
    }
}
