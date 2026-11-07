//
//  CaseMapAccessibilityTests.swift
//  KalsmritikoshTests
//
//  Living case map M9 (plan §4.5, §10, §11 M9; scope §10 "Accessibility"), model level — the UI itself is not
//  driven here (no GUI run; that stays NOT RUN in docs/CASE_MAP_EXECUTION_MATRIX.md):
//  • every map command has a list-path equivalent whose controls exist in the UI sources, and the surfaces that
//    hold them (header, strip, inspector, footer) are rendered in list mode too;
//  • in list mode the model does the same work: select, view strip, Back, hide, pin, Reset view, history and
//    Return to current;
//  • "Reset view" resets geometry and filters only — never content (records, links, saved views, decisions);
//  • VoiceOver text for items, links, header counts and the view strip carries the state, not only the drawing;
//  • Reduce Motion gives no animation; narrow widths make the inspector a drawer;
//  • list paging reaches every record; empty states name the next action; a failed save keeps the work and
//    "Try again" repeats it.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@MainActor
private func a11yDefaults() -> UserDefaults {
    let name = "casemap.a11y.\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name) ?? .standard
    d.removePersistentDomain(forName: name)
    return d
}

private let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
private func source(_ path: String) -> String { (try? String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)) ?? "" }

@MainActor
@Suite("Case map M9 — keyboard, list path, VoiceOver, motion, narrow layouts, reset", .serialized)
struct CaseMapAccessibilityTests {

    @Test("Every map command has a list-path equivalent: its controls exist in the UI sources and none needs the spatial map")
    func commandTable() {
        let ui = HelpRegistryTests.uiSources
        #expect(Set(CaseMapCommand.allCases.map(\.rawValue)).isSuperset(of: ["review", "link", "request", "chronology", "report", "openSource", "viewStrip",
                                                                             "back", "resetView", "history", "returnToCurrent"]))
        for c in CaseMapCommand.allCases {
            #expect(!c.mapOnly, "\(c) needs the map")
            #expect(!c.controls.isEmpty, "\(c)")
            for name in c.controls {
                #expect(ui.contains("\"\(name)") || ui.contains("\(name)\""), "\(c): control “\(name)” not found in the UI sources")
            }
        }
        // The surfaces holding them are outside the map/list switch: the header, strip, inspector and footer are drawn
        // whichever is shown, and the inspector is the same view for both.
        let view = source("Kalsmritikosh/UI/CaseMapWorkspaceView.swift")
        let content = view.components(separatedBy: "@ViewBuilder private func mainArea").first ?? ""
        #expect(content.contains("header") && content.contains("strip") && content.contains("footer"))
        #expect(view.contains("CaseMapList(map: map") && view.contains("CaseMapCanvas(map: map"))
        #expect(view.components(separatedBy: "CaseMapInspector(").count == 2, "one inspector for map and list")
        // Keyboard: the strip, Back, Return to current, details drawer.
        for key in [".keyboardShortcut(.leftArrow, modifiers: [.command, .control])", ".keyboardShortcut(.rightArrow, modifiers: [.command, .control])",
                    ".keyboardShortcut(\"[\", modifiers: [.command, .control])", ".keyboardShortcut(.escape, modifiers: [.command])",
                    ".keyboardShortcut(\"i\", modifiers: [.command, .control])"] {
            #expect(view.contains(key), "\(key)")
        }
        // The pin is in the inspector too (so the list path can pin).
        #expect(source("Kalsmritikosh/UI/CaseMapInspector.swift").contains("Button(pinned ? \"Unpin\" : \"Pin\")"))
    }

    @Test("In list mode the model does the map's work: select, view strip, Back, hide, pin, Reset view, history, Return to current")
    func listPathRunsTheSameCommands() async throws {
        let rig = try await CaseMapRig.make()
        let f = rig.f
        let service = CaseMapService(sources: caseMapSources(f))
        let history = CaseHistoryService(database: f.db, map: service)
        let model = CaseMapWorkspaceModel(caseID: f.caseID, workspace: CaseWorkspaceHolder(caseID: f.caseID, defaults: a11yDefaults()))
        await model.refresh(service)
        model.listMode = true
        let c = rig.node(.contradiction, rig.contradictionID)
        model.select(.node(c))
        #expect(model.selection == .node(c))
        model.step(1)
        #expect(model.view == .builtIn(.questions))
        model.goBack()
        #expect(model.view == .builtIn(.overview) && model.selection == .node(c))
        await model.togglePin(c, repository: service.repository)
        #expect(try await service.repository.layout(caseID: f.caseID)[c]?.pinned == true)
        await model.hide(c, repository: service.repository, actor: "Ada")
        #expect(model.memory.hidden?[model.view.key]?.contains(c) == true)
        await model.resetView(repository: service.repository, service: service)
        #expect(model.memory.hidden?[model.view.key] == nil)
        let cp = try await history.record(caseID: f.caseID, kind: .manual, actor: "Ada")
        model.openHistory(try await history.open(id: cp.id, caseID: f.caseID))
        #expect(model.isHistorical && model.listMode)
        model.returnToCurrent()
        #expect(!model.isHistorical && model.listMode, "the list stays the list across history")
    }

    @Test("Reset view resets geometry and filters only: records, links, saved views, decisions and the case log are unchanged")
    func resetViewNeverChangesContent() async throws {
        let rig = try await CaseMapRig.make()
        let f = rig.f
        let allegation = try await f.file.addAllegation(caseID: f.caseID, text: "Paid twice", actor: "Ada")
        try await f.svc.linkEvidence(caseID: f.caseID, allegationID: allegation, evidenceRef: rig.a.version.uuidString, label: "a", stance: .supports, note: nil,
                                     passage: StudioEvidenceRef(sourceVersionID: rig.a.version, objectID: rig.a.object, quote: "The invoice total was 500 dollars."), actor: "Ada")
        let person = try await f.file.addPerson(caseID: f.caseID, name: "Ann Lee", role: .witness, entityID: nil, contact: nil, notes: nil, actor: "Ada")
        _ = try await CaseMapRepository(database: f.db).addLink(caseID: f.caseID, type: .attributedTo, from: rig.node(.person, person),
                                                                 to: rig.node(.allegation, allegation), rationale: "She reported it", actor: "Ada")
        let service = CaseMapService(sources: caseMapSources(f))
        let model = CaseMapWorkspaceModel(caseID: f.caseID, workspace: CaseWorkspaceHolder(caseID: f.caseID, defaults: a11yDefaults()))
        await model.refresh(service)
        _ = await model.saveCurrentView(named: "Payments", repository: service.repository, actor: "Ada")
        model.go(to: .builtIn(.overview))

        func snapshot() async throws -> [String] {
            let p = try #require(await caseMapLoad(f).projection)
            var out = p.nodes.map { "\($0.id.key)|\($0.revision ?? "")|\($0.review.rawValue)|\($0.status.text)" }
            out += p.links.map { "\($0.id)|\($0.review.rawValue)" }
            out += try await service.repository.views(caseID: f.caseID).map { "view:\($0.id)|\($0.name)" }
            out += try await service.repository.links(caseID: f.caseID).map { "link:\($0.id)|\($0.isActive)" }
            for table in ["case_journal", "case_allegations", "case_allegation_evidence", "case_people", "case_actions", "contradictions"] {
                let n = (try? await f.db.query("SELECT COUNT(*) FROM \(table);").first?.int(0)) ?? -1
                out.append("\(table)=\(n)")
            }
            return out.sorted()
        }
        let before = try await snapshot()
        // Geometry and filters: zoom, a moved and pinned item, hidden, collapsed, find words, waiting only.
        let c = rig.node(.contradiction, rig.contradictionID)
        model.setViewport(CaseMapViewport(scale: 2.5, originX: 400, originY: -300))
        await model.move(c, to: CaseMapPoint(x: 5_000, y: 5_000), repository: service.repository)
        await model.togglePin(c, repository: service.repository)
        await model.hide(rig.node(.person, person), repository: service.repository, actor: "Ada")
        await model.toggleCollapse("group:question", repository: service.repository, actor: "Ada")
        model.search = "invoice"
        model.awaitingOnly = true
        await model.resetView(repository: service.repository, service: service)

        #expect(!model.hasStoredViewport && model.search.isEmpty && !model.awaitingOnly && model.kindFocus == nil)
        #expect(model.memory.hidden?[model.view.key] == nil && model.memory.collapsed?[model.view.key] == nil)
        #expect(model.placements[c]?.pinned != true && model.placements[c]?.point != CaseMapPoint(x: 5_000, y: 5_000))
        #expect(!model.canUndo && model.notice == "The view was reset. No case record was changed.")
        #expect(try await snapshot() == before, "Reset view changed case content")
        #expect(model.savedViews.map(\.name) == ["Payments"])
    }

    @Test("VoiceOver text carries the state: items, links, header counts and the view strip")
    func spokenText() async throws {
        let rig = try await CaseMapRig.make()
        let p = try #require(await caseMapLoad(rig.f).projection)
        let c = try #require(p.node(rig.node(.contradiction, rig.contradictionID)))
        #expect(CaseMapSpoken.nodeLabel(c).hasPrefix("Contradiction: "))
        let value = CaseMapSpoken.nodeValue(c, pinned: true, selected: true)
        #expect(value.contains(c.status.kind.label) && value.contains(c.review.label) && value.contains("pinned") && value.contains("selected"))
        let l = try #require(p.links.first)
        let label = CaseMapSpoken.linkLabel(l, in: p)
        #expect(label.hasPrefix("Link: ") && label.contains(l.type.label))
        #expect(CaseMapSpoken.linkValue(l, selected: false).contains(l.assertedBy.label))
        #expect(CaseMapSpoken.stripLabel("Overview") == "View: Overview")
        #expect(CaseMapSpoken.stripValue(index: 0, count: 6, selected: true) == "1 of 6, current view")
        // The views use them (canvas children for items, links and groups; list rows; header counts; strip buttons).
        let canvas = source("Kalsmritikosh/UI/CaseMapCanvas.swift"), view = source("Kalsmritikosh/UI/CaseMapWorkspaceView.swift")
        #expect(canvas.contains("CaseMapSpoken.nodeValue") && canvas.contains("CaseMapSpoken.linkLabel") && canvas.contains("item(s), collapsed"))
        #expect(view.contains(".accessibilityValue(String(n))") && view.contains("CaseMapSpoken.stripValue"))
    }

    @Test("Reduce Motion gives no animation; below the threshold the inspector is a drawer sized from the window")
    func motionAndNarrowLayout() {
        #expect(CaseMapMotion.animation(reduceMotion: true) == nil)
        #expect(CaseMapMotion.animation(reduceMotion: false) != nil)
        #expect(CaseMapWorkspaceLayout.inspectorIsDrawer(width: 700))
        #expect(CaseMapWorkspaceLayout.inspectorIsDrawer(width: CaseMapWorkspaceLayout.drawerThreshold - 1))
        #expect(!CaseMapWorkspaceLayout.inspectorIsDrawer(width: CaseMapWorkspaceLayout.drawerThreshold))
        #expect(!CaseMapWorkspaceLayout.inspectorIsDrawer(width: 1400))
        #expect(CaseMapWorkspaceLayout.drawerWidth(for: 300) == 255 && CaseMapWorkspaceLayout.drawerWidth(for: 800) == CaseMapWorkspaceLayout.inspectorWidth)
        let view = source("Kalsmritikosh/UI/CaseMapWorkspaceView.swift")
        #expect(view.contains("t.disablesAnimations = true") && view.contains("CaseMapMotion.animation(reduceMotion: reduceMotion)"))
        #expect(view.contains("GeometryReader { geo in") && view.contains(".frame(width: geo.size.width, height: geo.size.height)"),
                "the workspace pins its width and height to the GeometryReader (macOS 26 split-view sizing)")
        #expect(!view.contains("withAnimation(.") , "no animation that ignores Reduce Motion")
    }

    @Test("The list pages long sections and every record stays reachable")
    func listPaging() async throws {
        let rig = try await CaseMapRig.make()
        let f = rig.f
        for i in 0..<(CaseMapListPaging.pageSize + 20) {
            _ = try await f.file.addJournal(caseID: f.caseID, kind: .chronology, text: "Entry \(i)", eventDate: Date(), evidenceRef: rig.a.version.uuidString,
                                            quote: nil, actor: "Ada")
        }
        let p = try #require(await caseMapLoad(f).projection)
        let all = CaseMapViewFilter.apply(p, view: .overview, filter: CaseMapFilter(collapsed: []))
        let sections = CaseMapListPaging.sections(p, result: all)
        let events = try #require(sections.first { $0.title == CaseMapNodeKind.event.plural })
        #expect(events.ids.count == CaseMapListPaging.pageSize + 20)
        let one = CaseMapListPaging.visible(events.ids, pages: 1)
        #expect(one.rows.count == CaseMapListPaging.pageSize && one.remaining == 20)
        #expect(CaseMapListPaging.pagesToReachAll(events.ids.count) == 2)
        var reached = Set<CaseMapNodeID>()
        for s in sections { reached.formUnion(CaseMapListPaging.visible(s.ids, pages: CaseMapListPaging.pagesToReachAll(s.ids.count)).rows) }
        #expect(reached == Set(p.nodes.map(\.id)))
        #expect(sections.flatMap(\.ids).count == p.nodes.count, "each record in exactly one section")
    }

    @Test("Empty states name the next action; a view holding only collapsed groups is not empty")
    func emptyStates() {
        func counts(shown: Int, collapsed: Int = 0, filtered: Int = 0, hidden: Int = 0) -> CaseMapCounts {
            CaseMapCounts(total: shown + collapsed + filtered + hidden, shown: shown, collapsed: collapsed, filtered: filtered, hidden: hidden, notLoaded: [])
        }
        #expect(CaseMapEmptyState.viewEmpty(counts(shown: 3), view: .overview) == nil)
        #expect(CaseMapEmptyState.viewEmpty(counts(shown: 0, collapsed: 5), view: .overview) == nil)
        #expect(CaseMapEmptyState.viewEmpty(counts(shown: 0, filtered: 4), view: .questions)?.next.contains("Reset view") == true)
        #expect(CaseMapEmptyState.viewEmpty(counts(shown: 0, hidden: 4), view: .questions)?.next.contains("nothing was removed") == true)
        #expect(CaseMapEmptyState.viewEmpty(counts(shown: 0, filtered: 4), view: .changes)?.next.contains("What changed") == true)
        let view = source("Kalsmritikosh/UI/CaseMapWorkspaceView.swift")
        #expect(view.contains("\"Next: record the question this case is to answer"))
        #expect(source("Kalsmritikosh/UI/CaseMapInspector.swift").contains("Choose an item or a link on the map or in the list"))
    }

    @Test("A failed save keeps the work on screen and names one next action; Try again repeats it; a lock clears it")
    func failedSaveKeepsWork() async throws {
        let rig = try await CaseMapRig.make()
        let f = rig.f
        let service = CaseMapService(sources: caseMapSources(f))
        let model = CaseMapWorkspaceModel(caseID: f.caseID, workspace: CaseWorkspaceHolder(caseID: f.caseID, defaults: a11yDefaults()))
        await model.refresh(service)
        let c = rig.node(.contradiction, rig.contradictionID)
        // A repository for a case that is not in the ledger refuses the write (the same refusal a late write after an erase gets).
        let elsewhere = try await CaseFileTests.fixture()
        let broken = CaseMapRepository(database: elsewhere.db)
        let target = CaseMapPoint(x: 777, y: 333)
        await model.move(c, to: target, repository: broken)
        #expect(model.placements[c]?.point == target, "the moved position stays on screen")
        #expect(model.error?.contains("Try again") == true)
        guard case .placements(let pending)? = model.retry else { Issue.record("no retry kept"); return }
        #expect(pending[c]?.point == target)
        await model.retryLast(repository: service.repository, service: service, feedService: nil, actor: "Ada")
        #expect(model.retry == nil && model.error == nil)
        #expect(try await service.repository.layout(caseID: f.caseID)[c]?.point == target)
        // A view name that failed to save is kept for Try again.
        _ = await model.saveCurrentView(named: "Late view", repository: broken, actor: "Ada")
        #expect(model.retry == .saveView("Late view") && model.error?.contains("Late view") == true)
        model.closeOut()
        #expect(model.retry == nil)
    }

    @Test("The first-use explanation shows once and names items, links, review state and what changed")
    func firstUse() {
        let d = a11yDefaults()
        #expect(CaseMapFirstUse.shouldShow(d))
        CaseMapFirstUse.dismiss(d)
        #expect(!CaseMapFirstUse.shouldShow(d))
        for word in ["Items", "link", "review state", "What changed"] { #expect(CaseMapFirstUse.text.contains(word), "\(word)") }
    }
}

@Suite("Case map — Fit all on a map too large for the smallest zoom")
struct CaseMapFitAllTests {
    @Test("A collapsed group's card sits on one of its own member slots, nearest the centre, so it cannot cover a visible item")
    func groupCardOnAMemberSlot() {
        // Members spread around an empty middle where another group's visible item sits (the walk's overlap).
        let members = [CaseMapPoint(x: 0, y: 0), CaseMapPoint(x: 400, y: 0), CaseMapPoint(x: 0, y: 300), CaseMapPoint(x: 380, y: 290)]
        let visibleOther = CaseMapPoint(x: 200, y: 150)   // the old card position: the bounds' centre
        let card = CaseMapLayout.groupCardPoint(members)
        #expect(card.map { members.contains($0) } == true)
        #expect(card != visibleOther)
        #expect(CaseMapLayout.groupCardPoint([]) == nil)
        #expect(CaseMapLayout.groupCardPoint(members) == CaseMapLayout.groupCardPoint(members.reversed()), "deterministic")
    }

    @Test("Bounds larger than the smallest zoom can show: Fit all shows the start of the map, not its empty middle")
    func oversizedFitShowsStart() {
        // A map whose corner items sit far apart, with nothing in the middle (like the grouped stress layout).
        let corners = [CaseMapPoint(x: 0, y: 0), CaseMapPoint(x: 200_000, y: 150_000)]
        let b = CaseMapLayout.bounds(of: corners)!
        let vp = CaseMapLayout.fit(b, width: 1440, height: 900)
        #expect(vp.scale == CaseMapViewport.minScale)
        let visible = vp.worldRect(width: 1440, height: 900)
        #expect(visible.contains(corners[0]), "the first item is on screen")
        // A map that fits keeps being centred on its bounds.
        let small = CaseMapLayout.bounds(of: [CaseMapPoint(x: 0, y: 0), CaseMapPoint(x: 800, y: 400)])!
        let fitted = CaseMapLayout.fit(small, width: 1440, height: 900)
        let shown = fitted.worldRect(width: 1440, height: 900)
        #expect(shown.contains(CaseMapPoint(x: 0, y: 0)) && shown.contains(CaseMapPoint(x: 800, y: 400)))
    }
}

