//
//  DeepDiveBatch5Tests.swift
//  KalsmritikoshTests
//
//  Deep dive 2026-11-14 batch 5 (case map and screen state) — one regression test per confirmed defect
//  (docs/SMART_MAP_DEFECT_LOG.md, "Deep dive 2026-11-14 batch 5"). Model-level: CaseMapWorkspaceModel, CaseMapService and
//  the graph rules, over synthetic projections or throwaway migrated ledgers. No model, no network, no GUI.
//

import Foundation
import Testing
@testable import Kalsmritikosh

private let dd5Root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

private enum DD5Error: Error, LocalizedError {
    case injected
    var errorDescription: String? { "injected read failure" }
}

@MainActor
private func dd5Defaults() -> UserDefaults {
    let name = "dd5.\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name) ?? .standard
    d.removePersistentDomain(forName: name)
    return d
}

@MainActor
private func dd5Model(_ caseID: UUID) -> CaseMapWorkspaceModel {
    CaseMapWorkspaceModel(caseID: caseID, workspace: CaseWorkspaceHolder(caseID: caseID, defaults: dd5Defaults()))
}

/// Show a synthetic projection in a model, as a load from the service would.
@MainActor
private func dd5Show(_ p: CaseMapProjection, in model: CaseMapWorkspaceModel) {
    let g = model.beginLoad()
    let load = CaseMapLoad(caseID: p.caseID, generation: g, scopeFingerprint: nil, fence: nil, projection: p,
                           placements: CaseMapLayout.placeNew(p, existing: [:]), views: [], state: .complete)
    _ = model.apply(load)
}

private func dd5Count(_ db: Database, _ sql: String, _ caseID: UUID) async throws -> Int {
    Int(try await db.query(sql, [.uuid(caseID)]).first?.int(0) ?? -1)
}

@MainActor
@Suite("Deep dive 2026-11-14 batch 5 — case map and screen state", .serialized)
struct DeepDiveBatch5Tests {

    // MARK: 1 — money bands

    @Test("1: amounts of 10^18 and 10^30 share a capped band (no trap), and zero and negative amounts have their own band")
    func moneyBandsNeverTrap() throws {
        let c = UUID()
        let huge = try #require(Decimal(string: "1000000000000000000"))
        let vast = try #require(Decimal(string: "1e30"))
        let farOut = Decimal(sign: .plus, exponent: 120, significand: 1)
        let nodes = [
            S3Synth.node(c, .moneyTransaction, "m1", .money, "1e18", money: CaseMapMoney(amount: huge, currency: "USD")),
            S3Synth.node(c, .moneyTransaction, "m2", .money, "1e30", money: CaseMapMoney(amount: vast, currency: "USD")),
            S3Synth.node(c, .moneyTransaction, "m3", .money, "refund", money: CaseMapMoney(amount: -500, currency: "USD")),
            S3Synth.node(c, .moneyTransaction, "m4", .money, "zero", money: CaseMapMoney(amount: 0, currency: "USD")),
            S3Synth.node(c, .moneyTransaction, "m5", .money, "small", money: CaseMapMoney(amount: 7, currency: "USD")),
            S3Synth.node(c, .moneyTransaction, "m6", .money, "hundreds", money: CaseMapMoney(amount: 999, currency: "USD")),
            S3Synth.node(c, .moneyTransaction, "m7", .money, "1e120", money: CaseMapMoney(amount: farOut, currency: "USD")),
        ]
        let p = S3Synth.projection(c, nodes, [])
        let bands = CaseMapDistribution.byAmount(p.nodes.map(\.id), in: p)
        func band(of id: String) -> CaseMapBucket? { bands.first { $0.members.contains(CaseMapNodeID(caseID: c, kind: .moneyTransaction, recordID: id)) } }
        let top = try #require(band(of: "m1"))
        #expect(top.label.hasSuffix("or more") && band(of: "m2") == top && band(of: "m7") == top, "\(top.label)")
        let nonPositive = try #require(band(of: "m3"))
        #expect(nonPositive.label == "USD: 0 or less" && band(of: "m4") == nonPositive && nonPositive.total == -500)
        #expect(band(of: "m5")?.label == "USD: 0–9" && band(of: "m6")?.label == "USD: 100–999")
        #expect(bands.first?.id == nonPositive.id && bands.last?.id == top.id, "the bands sort from the lowest")
        #expect(CaseMapDistribution.bandLabel(17).contains("–"), "the highest bounded band (10^17 to 10^18 − 1) fits an Int")
    }

    // MARK: 2 — a failed frame layout read

    @Test("2: a frame whose stored positions cannot be read is placed for now, nothing is saved over its positions and pins, and the error is said")
    func frameLayoutReadFailureKeepsPins() async throws {
        let rig = try await CaseFramesRig.make()
        let f = rig.f, c = f.caseID
        let service = CaseMapService(sources: caseMapSources(f))
        let p = try await rig.projection()
        let anchor = rig.node(.report, rig.report)
        let opened = try #require(await service.openFrame(caseID: c, anchor: anchor, in: p))
        #expect(opened.problem == nil)
        let member = try #require(opened.frame.memberIDs.first)
        let key = CaseMapFrames.key(anchor)
        let pinned = CaseMapPlacement(point: CaseMapPoint(x: 999, y: -333), pinned: true)
        try await service.repository.savePlacements(caseID: c, frame: key, [member: pinned])

        var bad = caseMapSources(f)
        let repo = service.repository
        bad.layoutRead = { caseID, frame in
            if frame.isEmpty { return try await repo.layout(caseID: caseID) }
            throw DD5Error.injected
        }
        let badService = CaseMapService(sources: bad)
        let again = try #require(await badService.openFrame(caseID: c, anchor: anchor, in: p))
        #expect(again.problem?.contains("could not be read") == true)
        #expect(try await repo.layout(caseID: c, frame: key)[member] == pinned, "the saved pin and position survive")

        // Through the model: the frame opens, the error is shown.
        let model = rig.model(dd5Defaults())
        await model.refresh(badService)
        await model.openFrame(anchor, service: badService)
        #expect(model.frame?.anchor == anchor && model.error?.contains("saved positions could not be read") == true)
        #expect(try await repo.layout(caseID: c, frame: key)[member] == pinned)
    }

    // MARK: 3 — a failed views read

    @Test("3: a failed saved-views read keeps the stored layout and the open saved view, and says so")
    func viewsReadFailureKeepsLayoutAndView() async throws {
        let rig = try await CaseFramesRig.make()
        let f = rig.f
        let service = CaseMapService(sources: caseMapSources(f))
        let model = rig.model(dd5Defaults())
        await model.refresh(service)
        let id = try #require(await model.saveCurrentView(named: "Mine", repository: service.repository, actor: "Ada"))
        #expect(model.view == .saved(id))
        let item = try #require(model.placements.keys.sorted().first)
        await model.togglePin(item, repository: service.repository)
        let pinnedAt = try #require(model.placements[item])
        #expect(pinnedAt.pinned)

        var bad = caseMapSources(f)
        bad.viewsRead = { _ in throw DD5Error.injected }
        let badService = CaseMapService(sources: bad)
        await model.refresh(badService)
        #expect(model.view == .saved(id), "the open saved view is kept")
        #expect(model.savedViews.contains { $0.id == id })
        #expect(model.error?.contains("saved views could not be read") == true)
        #expect(model.placements[item] == pinnedAt, "the stored layout is kept, not placed afresh")
        let load = await badService.load(caseID: f.caseID, generation: 99)
        #expect(load.viewsProblem != nil && load.placements[item] == pinnedAt)
    }

    // MARK: 4 — folds in a cycle

    @Test("4: two folded anchors under each other keep one deterministic fold card, and Reset view clears the folds")
    func foldCycleKeepsACard() async {
        let c = UUID()
        let a = S3Synth.node(c, .report, "a", .evidence, "Report A")
        let b = S3Synth.node(c, .reportPoint, "b", .evidence, "Point B")
        let x = S3Synth.node(c, .journal, "x", .event, "Entry X")
        // B is taken from A; A is placed in B's frame; X is taken from B — A and B each hang under the other.
        let links = [S3Synth.link(c, .derivedFrom, b.id, a.id), S3Synth.link(c, .placedIn, b.id, a.id), S3Synth.link(c, .derivedFrom, x.id, b.id)]
        let p = S3Synth.projection(c, [a, b, x], links)
        for order in [[a.id, b.id], [b.id, a.id]] {
            let folds = CaseMapFolds.apply(order, in: p, changed: [])
            #expect(folds.summaries.count == 1 && folds.summaries[a.id] != nil, "one card, on the first in record order")
            #expect(!folds.held.contains(a.id) && folds.held.isSuperset(of: [b.id, x.id]))
            #expect(folds.summaries[a.id]?.held == 2)
        }
        // An outer fold that holds the cycle still holds both: no extra card.
        let root = S3Synth.node(c, .caseFile, c.uuidString, .question, "Case")
        let p2 = S3Synth.projection(c, [root, a, b, x], links + [S3Synth.link(c, .derivedFrom, a.id, root.id)])
        let outer = CaseMapFolds.apply([root.id, a.id, b.id], in: p2, changed: [])
        #expect(Set(outer.summaries.keys) == [root.id] && outer.held.isSuperset(of: [a.id, b.id, x.id]))

        let model = dd5Model(c)
        dd5Show(p, in: model)
        var m = model.memory
        m.folded = [model.view.key: [a.id, b.id]]
        m.collapsed = [model.view.key: []]
        model.memory = m
        let r = model.result
        #expect(r?.shown.contains(a.id) == true && r?.folds[a.id] != nil)
        await model.resetView(repository: nil, service: nil)
        #expect(model.memory.folded == nil)
        #expect(model.result?.folds.isEmpty == true)
    }

    // MARK: 5 — brief panel writing

    @Test("5: the brief panel clears what was typed only after the change is recorded")
    func briefWritingKeptOnFailure() async throws {
        var cleared = false
        let failure = await CaseBriefPanelWrite.perform({ throw DD5Error.injected }, onSuccess: { cleared = true })
        #expect(failure == "injected read failure" && !cleared)
        let ok = await CaseBriefPanelWrite.perform({}, onSuccess: { cleared = true })
        #expect(ok == nil && cleared)
        // Source audit: each of the three fields is cleared only in its onSuccess closure.
        let src = try String(contentsOf: dd5Root.appendingPathComponent("Kalsmritikosh/UI/CaseMapBriefPanel.swift"), encoding: .utf8)
        #expect(src.contains("onSuccess: { draft = CaseBriefText() }") && src.components(separatedBy: "draft = CaseBriefText()").count == 3)
        #expect(src.contains("onSuccess: { newBriefingTitle = \"\" }") && src.components(separatedBy: "newBriefingTitle = \"\"").count == 3)
        #expect(src.contains("onSuccess: { noteText = \"\" }") && src.components(separatedBy: "noteText = \"\"").count == 3)
    }

    // MARK: 6 — whose "What changed"

    @Test("6: the feed is read against this person's seen position from the first read, not the last person who marked it seen")
    func feedReadsThisPerson() async throws {
        let rig = try await CaseMapRig.make()
        let f = rig.f
        let service = CaseMapService(sources: caseMapSources(f))
        let feeds = CaseChangeFeedService(database: f.db)
        let ada = dd5Model(f.caseID)
        ada.adoptViewer("Ada")
        await ada.refresh(service)
        await ada.refreshFeed(feeds)
        #expect(!(ada.feed?.newChanges.isEmpty ?? true))
        await ada.markSeen(feeds, actor: "Ada")
        #expect(try await feeds.seenPosition(caseID: f.caseID)?.seenBy == "Ada")

        // Ben has never marked anything seen: everything is new to him.
        let ben = dd5Model(f.caseID)
        ben.adoptViewer("Ben")
        #expect(ben.feedViewer == "Ben")
        await ben.refresh(service)
        await ben.refreshFeed(feeds)
        #expect(!(ben.feed?.newChanges.isEmpty ?? true), "Ben's feed is not Ada's")
        // adoptViewer never replaces a viewer already chosen.
        ben.adoptViewer("Ada")
        #expect(ben.feedViewer == "Ben")
        // The source: the workspace adopts the person before its first read.
        let src = try String(contentsOf: dd5Root.appendingPathComponent("Kalsmritikosh/UI/CaseMapWorkspaceView.swift"), encoding: .utf8)
        let start = try #require(src.range(of: "private func start() async {"))
        let adopt = try #require(src.range(of: "map.adoptViewer(model.actor)"))
        let reload = try #require(src.range(of: "await reload()", range: start.upperBound..<src.endIndex))
        #expect(adopt.lowerBound < reload.lowerBound)
    }

    // MARK: 7 — the backups choice after a relaunch

    @Test("7: the latest erasure's backups-made-before choice is read from the register and the backup list beside the ledger")
    func erasureBackupsChoiceAfterRelaunch() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dd5-erasure-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let ledger = dir.appendingPathComponent("ledger.sqlite")
        #expect(AppState.pendingErasureBackups(besideLedgerAt: ledger) == nil, "nothing erased: nothing offered")
        let erasedAt = 1_800_000_000.0
        #expect(BackupLog.record(folder: dir.appendingPathComponent("Backup early"), kind: .ledger, createdAt: erasedAt - 3_600, besideLedgerAt: ledger) == nil)
        #expect(BackupLog.record(folder: dir.appendingPathComponent("Backup late"), kind: .ledger, createdAt: erasedAt + 60, besideLedgerAt: ledger) == nil)
        try ErasureRegister.record(.init(kind: .case, idHash: ErasureRegister.hash(UUID()), eraseSources: false, erasedAt: erasedAt - 7_200), besideLedgerAt: ledger)
        try ErasureRegister.record(.init(kind: .case, idHash: ErasureRegister.hash(UUID()), eraseSources: false, erasedAt: erasedAt), besideLedgerAt: ledger)
        // A "relaunch": nothing in memory, only the files beside the ledger.
        let pending = try #require(AppState.pendingErasureBackups(besideLedgerAt: ledger))
        #expect(pending.erasedAt == erasedAt && pending.problem == nil)
        #expect(pending.backups.map(\.name) == ["Backup early"])
        // An unreadable register is said, never "nothing was erased".
        try Data("{".utf8).write(to: ErasureRegister.url(besideLedgerAt: ledger))
        #expect(AppState.pendingErasureBackups(besideLedgerAt: ledger)?.problem != nil)
        // The screens: Settings ▸ Backups offers it; the erase button is off once erased.
        let settings = try String(contentsOf: dd5Root.appendingPathComponent("Kalsmritikosh/UI/SettingsView.swift"), encoding: .utf8)
        #expect(settings.contains("ErasureBackupsChoice(pending: pending)") && settings.contains("appState.pendingErasureBackups()"))
        let caseFile = try String(contentsOf: dd5Root.appendingPathComponent("Kalsmritikosh/UI/CaseFileView.swift"), encoding: .utf8)
        #expect(caseFile.contains(".disabled(reason: eraseBlocked") && caseFile.contains("if erasedHere { return \"This case was erased.\" }"))
    }

    // MARK: 8 — a new action with a missing question

    @Test("8: creating an action that serves a question not in the case writes nothing — no cancelled task with a live contract or links")
    func createActionMissingQuestionLeavesNothing() async throws {
        let rig = try await CaseFramesRig.make()
        let f = rig.f, c = f.caseID
        let point = try await f.svc.addPoint(caseID: c, reportID: rig.report, kind: .finding, statement: "The seal was intact",
                                             quote: "The seal on bag 7 was intact on arrival.", actor: "Ada")
        let real = try await f.file.addAllegation(caseID: c, text: "Was the seal intact?", actor: "Ada")
        let tasks = "SELECT COUNT(*) FROM case_task_links WHERE case_id = ?;"
        let contracts = "SELECT COUNT(*) FROM case_action_contracts WHERE case_id = ?;"
        let liveLinks = "SELECT COUNT(*) FROM case_work_links WHERE case_id = ? AND withdrawn_at IS NULL;"
        let before = (try await dd5Count(f.db, tasks, c), try await dd5Count(f.db, contracts, c), try await dd5Count(f.db, liveLinks, c))
        await #expect(throws: CaseWorkError.self) {
            _ = try await f.svc.createAction(caseID: c, .init(title: "Examine the seal", purpose: "Whether it was intact", deliverable: "A note",
                                                               fromPoint: point, servesQuestions: [real, UUID()]), actor: "Ada")
        }
        let after = (try await dd5Count(f.db, tasks, c), try await dd5Count(f.db, contracts, c), try await dd5Count(f.db, liveLinks, c))
        #expect(after == before, "\(before) → \(after)")
        // With the real question only, it is created with its contract and both links.
        let ok = try await f.svc.createAction(caseID: c, .init(title: "Examine the seal", purpose: "Whether it was intact", deliverable: "A note",
                                                                fromPoint: point, servesQuestions: [real]), actor: "Ada")
        let ledger = try await f.file.reportLedger(caseID: c)
        #expect(ledger.contract(ok) != nil && ledger.workLinks.filter { $0.isActive && $0.workID == ok }.count == 2)
    }

    // MARK: 9 — Undo across a frame change

    @Test("9: opening a saved view into its frames clears Undo, so Undo never writes root positions into a frame")
    func goToSavedViewClearsUndo() async {
        let c = UUID()
        let a = S3Synth.node(c, .report, "a", .evidence, "Report A")
        let b = S3Synth.node(c, .reportPoint, "b", .evidence, "Point B")
        let p = S3Synth.projection(c, [a, b], [S3Synth.link(c, .derivedFrom, b.id, a.id)])
        let model = dd5Model(c)
        dd5Show(p, in: model)
        await model.move(a.id, to: CaseMapPoint(x: 5, y: 5), repository: nil)
        #expect(model.canUndo)
        var filter = CaseMapFilter()
        filter.frames = [a.id]
        let view = CaseMapSavedView(id: UUID(), caseID: c, name: "Into A", base: .overview, filter: filter, ordinal: 0,
                                    createdBy: "Ada", createdAt: Date(), updatedAt: Date())
        model.savedViews = [view]
        model.go(to: .saved(view.id))
        #expect(model.frameStack.map(\.anchor) == [a.id])
        #expect(!model.canUndo, "the root's Undo step does not follow into the frame")
        // A view change that keeps the frames as they are keeps Undo.
        await model.returnToFrame(depth: 0, service: nil)
        await model.move(a.id, to: CaseMapPoint(x: 9, y: 9), repository: nil)
        model.go(to: .builtIn(.questions))
        #expect(model.canUndo)
    }

    // MARK: 10 — reveal inside a frame

    @Test("10: reveal inside a frame clears the Find words and unhides the record, so what is said to be shown is drawn")
    func revealInsideFrameDraws() async {
        let c = UUID()
        let a = S3Synth.node(c, .report, "a", .evidence, "Report A")
        let b = S3Synth.node(c, .reportPoint, "b", .evidence, "Point Bravo")
        let p = S3Synth.projection(c, [a, b], [S3Synth.link(c, .derivedFrom, b.id, a.id)])
        let model = dd5Model(c)
        dd5Show(p, in: model)
        await model.openFrame(a.id, service: nil)
        model.search = "zzz"
        #expect(model.result?.shown.contains(b.id) == false)
        #expect(model.reveal(b.id))
        #expect(model.frameStack.count == 1 && model.result?.shown.contains(b.id) == true && model.selection == .node(b.id))
        #expect(model.notice?.contains("cleared the Find words") == true)
        await model.hide(b.id, repository: nil, actor: "Ada")
        #expect(model.result?.shown.contains(b.id) == false)
        #expect(model.reveal(b.id))
        #expect(model.frameStack.count == 1 && model.result?.shown.contains(b.id) == true)
        #expect(model.notice?.contains("showed it again in this frame") == true)
    }

    // MARK: 11 — Show on map before the first read

    @Test("11: Search ▸ Show on map before the map was ever read waits for the first read, then reveals the document")
    func showOnMapBeforeFirstLoad() async throws {
        let rig = try await CaseFramesRig.make()
        let f = rig.f
        let model = rig.model(dd5Defaults())
        #expect(model.liveProjection == nil)
        model.showDocumentOnMap(object: rig.doc.object)
        #expect(model.pendingRevealObject == rig.doc.object)
        #expect(model.notice?.contains("not on this case's map") == false)
        await model.refresh(CaseMapService(sources: caseMapSources(f)))
        #expect(model.pendingRevealObject == nil)
        guard case .node(let id)? = model.selection else { Issue.record("nothing selected"); return }
        #expect(id.kind == .document && model.projection?.node(id)?.sources.contains { $0.objectID == rig.doc.object } == true)
        // A document not in the case, once the map is read, is said so at once.
        model.showDocumentOnMap(object: UUID())
        #expect(model.pendingRevealObject == nil && model.notice?.contains("not on this case's map") == true)
    }

    // MARK: 13 — reveal past the list's first page

    @Test("13: reveal of a row past the list's first 500 opens the page that holds it")
    func revealOpensListPage() throws {
        let c = UUID()
        let nodes = (0..<620).map { S3Synth.node(c, .journal, String(format: "e%04d", $0), .event, "Entry \($0)") }
        let p = S3Synth.projection(c, nodes, [])
        let model = dd5Model(c)
        dd5Show(p, in: model)
        model.listMode = true
        let target = CaseMapNodeID(caseID: c, kind: .journal, recordID: "e0610")
        #expect(model.reveal(target))
        let r = try #require(model.result)
        let section = try #require(CaseMapListPaging.sections(p, result: r).first { $0.ids.contains(target) })
        #expect(section.ids.count > CaseMapListPaging.pageSize)
        let page = CaseMapListPaging.visible(section.ids, pages: model.listPages[section.title] ?? 1)
        #expect(page.rows.contains(target), "the revealed row is drawn")
        // The list reads its pages from the model.
        let src = try String(contentsOf: dd5Root.appendingPathComponent("Kalsmritikosh/UI/CaseMapCanvas.swift"), encoding: .utf8)
        #expect(src.contains("private var pages: [String: Int] { map.listPages }"))
    }

    // MARK: 14 — the spinner after a close-out

    @Test("14: after a close-out (erase or lock) a load or a feed read never leaves the spinner on")
    func noSpinnerAfterCloseOut() {
        let c = UUID()
        let p = S3Synth.projection(c, [S3Synth.node(c, .journal, "e", .event, "Entry")], [])
        let model = dd5Model(c)
        let g0 = model.beginLoad()
        _ = model.beginFeedLoad()
        model.closeOut()
        #expect(!model.loading && !model.feedLoading)
        let g = model.beginLoad()
        let fg = model.beginFeedLoad()
        #expect(!model.loading && !model.feedLoading)
        let load = CaseMapLoad(caseID: c, generation: g, scopeFingerprint: nil, fence: nil, projection: p, placements: [:], views: [], state: .complete)
        #expect(!model.apply(load) && !model.loading && model.projection == nil)
        #expect(!model.applyFeed(.failed(c, fg, "x")) && !model.feedLoading)
        // A late answer of a load started before the close-out also leaves it off.
        let late = CaseMapLoad(caseID: c, generation: g0, scopeFingerprint: nil, fence: nil, projection: p, placements: [:], views: [], state: .complete)
        #expect(!model.apply(late) && !model.loading)
    }

    // MARK: 15 — ⌘[ bound once

    @Test("15: ⌘[ is bound once (the window's Back); the case's Cases button has its own shortcut, listed on the shortcut card and in Help")
    func commandBracketBoundOnce() throws {
        let ui = dd5Root.appendingPathComponent("Kalsmritikosh/UI")
        var bindings: [String] = []
        let files = FileManager.default.enumerator(at: ui, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let n = text.components(separatedBy: ".keyboardShortcut(\"[\", modifiers: .command)").count - 1
            for _ in 0..<n { bindings.append(file.lastPathComponent) }
        }
        #expect(bindings == ["RootView.swift"], "\(bindings)")
        let caseFile = try String(contentsOf: ui.appendingPathComponent("CaseFileView.swift"), encoding: .utf8)
        #expect(caseFile.contains(".keyboardShortcut(\"[\", modifiers: [.command, .option])"))
        let root = try String(contentsOf: ui.appendingPathComponent("RootView.swift"), encoding: .utf8)
        #expect(root.contains("shortcutRow(\"⌥⌘[\", \"In an open case: back to the list of cases\")"))
        #expect(HelpRegistry.tasks.first { $0.id == "task-find-your-way" }?.notes.contains { $0.contains("“Cases” (⌥⌘[)") } == true)
    }
}
