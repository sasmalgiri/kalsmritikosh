//
//  GUIWalkDefectTests.swift
//  KalsmritikoshTests
//
//  The defects the agent GUI walk of c179485f found (docs/evidence/gui-walk-2026-11-13/README.md), each with its fix:
//  D1 a second window re-ran the app's boot (the acceptance fixture deleted and re-created the open ledger);
//  D2 the case map and the Evidence screen were laid out far taller than the window (split-view narrow sizing probe);
//  D3 a twin folder row doubled the run's plan, so the receipt said "not reached 10";
//  D4 a contradiction's highlight ended mid-word ("Invoice INV-2041 Dal");
//  D5 one failed scan had two technical labels ("parser — loaderFailure" / "metadataExtraction failed");
//  and the sidebar's "new files added" counted change notifications, not new documents.
//  Throwaway ledgers and folders only; no network, no model. These are unit and layout checks: the fixes still need
//  confirming on screen.
//

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Kalsmritikosh

@MainActor
private func guiWalkTemp(_ tag: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pj-guiwalk-\(tag)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

// MARK: - D1: boot once per process

@MainActor
@Suite("GUI walk D1 — boot once, a second window attaches", .serialized)
struct GUIWalkBootOnceTests {

    /// A marker written into the open ledger: it survives only if the ledger is never re-created.
    private func writeMarker(_ state: AppState) async throws -> UUID {
        let ws = Workspace(title: "D1 marker")
        try await WorkspaceRepository(database: try #require(state.database)).upsert(ws)
        return ws.id
    }

    private func markerExists(_ state: AppState, _ id: UUID) async throws -> Bool {
        let db = try #require(state.database)
        let rows = try await db.query("SELECT count(*) FROM workspaces WHERE id = ?;", [.uuid(id)])
        return (rows.first?.int(0) ?? 0) == 1
    }

    @Test("Calling boot twice runs startup once: the same ledger stays open and its data is kept")
    func bootTwiceRunsOnce() async throws {
        let dir = try guiWalkTemp("boot2")
        defer { try? FileManager.default.removeItem(at: dir) }
        let state = AppState(bookmarks: BookmarkStore(ephemeral: true))
        let url = dir.appendingPathComponent("d1.sqlite")
        await state.boot(databaseURL: url, suppressAutoReingest: true)
        guard case .ready = state.phase else { Issue.record("ledger did not boot"); return }
        let first = try #require(state.database)
        let marker = try await writeMarker(state)

        await state.boot(databaseURL: url, suppressAutoReingest: true)
        await state.boot(databaseURL: dir.appendingPathComponent("other.sqlite"), suppressAutoReingest: true)
        #expect(state.bootRunCount == 1)
        #expect(state.database === first, "a second boot must not open another ledger")
        #expect(try await markerExists(state, marker))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("other.sqlite").path), "no second ledger was created")
        await state.shutdown()
    }

    @Test("Concurrent boot calls await the same boot: one run, one ledger")
    func concurrentBootRunsOnce() async throws {
        let dir = try guiWalkTemp("bootc")
        defer { try? FileManager.default.removeItem(at: dir) }
        let state = AppState(bookmarks: BookmarkStore(ephemeral: true))
        let url = dir.appendingPathComponent("d1c.sqlite")
        async let a: Void = state.boot(databaseURL: url, suppressAutoReingest: true)
        async let b: Void = state.boot(databaseURL: url, suppressAutoReingest: true)
        async let c: Void = state.boot(databaseURL: url, suppressAutoReingest: true)
        _ = await (a, b, c)
        #expect(state.bootRunCount == 1)
        guard case .ready = state.phase else { Issue.record("ledger did not boot"); return }
        #expect(state.database != nil)
        await state.shutdown()
    }

    @Test("The launch sequence runs once however many windows open, and a window opened while it runs waits for it")
    func startOnceRunsStartupOnce() async {
        let state = AppState(bookmarks: BookmarkStore(ephemeral: true))
        var runs = 0
        var finished = false
        let startup: @MainActor () async -> Void = {
            runs += 1
            try? await Task.sleep(nanoseconds: 50_000_000)
            finished = true
        }
        async let w1: Void = state.startOnce(startup)
        async let w2: Void = state.startOnce(startup)
        _ = await (w1, w2)
        #expect(runs == 1)
        #expect(finished, "the second window returned only after the first window's launch finished")
        await state.startOnce(startup)   // File ▸ New Window later
        #expect(runs == 1)
    }

    #if DEBUG
    @Test("A second window under --acceptance-case does not delete or re-create the open ledger: the case data stays")
    func acceptanceFixtureNotRecreated() async throws {
        let dir = try guiWalkTemp("accept")
        defer { try? FileManager.default.removeItem(at: dir) }
        let state = AppState(bookmarks: BookmarkStore(ephemeral: true))
        await state.boot(databaseURL: dir.appendingPathComponent("d1a.sqlite"), suppressAutoReingest: true)
        guard case .ready = state.phase else { Issue.record("ledger did not boot"); return }
        let first = try #require(state.database)
        let marker = try await writeMarker(state)
        let fixtureDB = AcceptanceCaseGUIFixture.databaseURL
        let before = try? FileManager.default.attributesOfItem(atPath: fixtureDB.path)[.modificationDate] as? Date
        let rootsBefore = state.bookmarks.roots.count

        // What the second window's launch used to do.
        await state.startOnce { await AcceptanceCaseGUIFixture.boot(state) }
        await AcceptanceCaseGUIFixture.boot(state)

        #expect(state.database === first)
        #expect(state.bootRunCount == 1)
        #expect(try await markerExists(state, marker))
        #expect(state.bookmarks.roots.count == rootsBefore, "the fixture folder was not registered again")
        let after = try? FileManager.default.attributesOfItem(atPath: fixtureDB.path)[.modificationDate] as? Date
        #expect(before == after, "the fixture's ledger file was neither deleted nor re-created")
        await state.shutdown()
    }
    #endif
}

// MARK: - D2: the case map and Evidence fit the window

/// Sizes a SwiftUI view reports for a proposal, measured in an NSHostingController (never shown).
@MainActor
private func fitted<V: View>(_ view: V, width: CGFloat, height: CGFloat) -> CGSize {
    NSHostingController(rootView: view).sizeThatFits(in: CGSize(width: width, height: height))
}

/// Hosts `view` in an off-screen 1200×845 window (never ordered front) and lays it out; returns the hosting view's frame
/// and the minimum height its constraints demand.
@MainActor
private func hosted<V: View>(_ view: V, width: CGFloat = 1200, height: CGFloat = 845) -> (frame: NSRect, minHeight: CGFloat) {
    let frame = NSRect(x: 0, y: 0, width: width, height: height)
    let window = NSWindow(contentRect: frame, styleMask: [.titled, .resizable], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: view)
    window.contentView = host
    host.frame = frame
    host.layoutSubtreeIfNeeded()
    let minHeight = host.fittingSize.height
    let laidOut = host.frame
    window.contentView = nil
    window.close()
    return (laidOut, minHeight)
}

@MainActor
@Suite("GUI walk D2 — the case map and Evidence are laid out inside the window", .serialized)
struct GUIWalkLayoutTests {

    /// A case map with content (two documents, a contradiction, the question), as the walk had it.
    private func workspace() async throws -> (model: CaseFileModel, snapshot: CaseFileSnapshot, rig: CaseMapRig) {
        let rig = try await CaseMapRig.make()
        let name = "guiwalk.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name) ?? .standard
        defaults.removePersistentDomain(forName: name)
        let model = CaseFileModel(caseID: rig.f.caseID, workspaceID: rig.f.workspaceID, defaults: defaults)
        let snap = try #require(try await rig.f.svc.snapshot(caseID: rig.f.caseID, custody: [rig.a.version, rig.b.version].map {
            CustodyManifestEntry(sourceVersionID: $0, contentHash: nil, custodyEvents: [])
        }))
        model.snapshot = snap
        await model.map.refresh(CaseMapService(sources: caseMapSources(rig.f)))
        #expect(model.map.projection != nil && model.map.result != nil, "the map has items to draw")
        return (model, snap, rig)
    }

    @Test("The pinned case-map workspace fits 1200×845 and the split view's narrow sizing probes; unpinned it did not")
    func caseMapFitsWindow() async throws {
        let w = try await workspace()
        let env = AppState(bookmarks: BookmarkStore(ephemeral: true))
        let pinned = CaseMapWorkspaceView.pinned(model: w.model, s: w.snapshot).environment(env)
        let unpinned = CaseMapWorkspaceView(model: w.model, s: w.snapshot).environment(env)
        let probes: [(CGFloat, CGFloat)] = [(1200, 845), (850, 845), (210, 845), (0, 845), (0, 0)]
        for (pw, ph) in probes {
            let size = fitted(pinned, width: pw, height: ph)
            #expect(size.height <= max(ph, 1), "pinned map at \(pw)×\(ph) reports \(size)")
            #expect(size.width <= max(pw, 1), "pinned map at \(pw)×\(ph) reports \(size)")
        }
        // The cause, measured: at the narrow probe the unpinned workspace needs far more than the window's height.
        let narrow = fitted(unpinned, width: 210, height: 845)
        print("GUI walk D2: unpinned case map at a 210-pt probe reports \(narrow); at 1200×845 \(fitted(unpinned, width: 1200, height: 845))")
        #expect(narrow.height > 845, "the narrow probe is what drew the map outside the window (\(narrow))")
        // In a real (off-screen) window: the hosting view keeps the window's size and asks for no more height.
        let h = hosted(pinned)
        #expect(h.frame.size == NSSize(width: 1200, height: 845))
        #expect(h.minHeight <= 845, "minimum height \(h.minHeight)")
    }

    @Test("The case file's header above the pinned map still fits: the whole case column stays within 845 pt")
    func caseColumnFits() async throws {
        let w = try await workspace()
        let env = AppState(bookmarks: BookmarkStore(ephemeral: true))
        let column = VStack(spacing: 0) {
            HStack { Text("Dalmia Traders payment").font(.title3.bold()); Spacer(); Toggle("Case map (preview)", isOn: .constant(true)) }
                .padding(12)
            Divider()
            CaseMapWorkspaceView.pinned(model: w.model, s: w.snapshot)
        }
        .environment(env)
        for (pw, ph) in [(CGFloat(1200), CGFloat(845)), (210, 845), (0, 0)] {
            let size = fitted(column, width: pw, height: ph)
            #expect(size.height <= max(ph, 60), "case column at \(pw)×\(ph) reports \(size)")
        }
        let h = hosted(column)
        #expect(h.frame.size == NSSize(width: 1200, height: 845) && h.minHeight <= 845, "\(h)")
    }

    @Test("The pinned Evidence screen fits 1200×845 and the narrow probes")
    func evidenceFitsWindow() async throws {
        let env = AppState(bookmarks: BookmarkStore(ephemeral: true))
        let evidence = ViewportPinned { EvidenceAreaView(section: .sources, onNavigate: { _ in }) }.environment(env)
        for (pw, ph) in [(CGFloat(1200), CGFloat(845)), (210, 845), (0, 0)] {
            let size = fitted(evidence, width: pw, height: ph)
            #expect(size.height <= max(ph, 1), "pinned Evidence at \(pw)×\(ph) reports \(size)")
        }
        let h = hosted(evidence)
        #expect(h.frame.size == NSSize(width: 1200, height: 845) && h.minHeight <= 845, "\(h)")
    }
}

// MARK: - D3: one row per folder, one count per file

@MainActor
@Suite("GUI walk D3 — duplicate folder rows and the batch receipt", .serialized)
struct GUIWalkFolderTests {

    @Test("Registering the same folder twice (also by a non-standard path) keeps one row")
    func registerTwiceKeepsOneRow() throws {
        let dir = try guiWalkTemp("roots")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = BookmarkStore(ephemeral: true)
        try store.register(url: dir)
        try store.register(url: dir)
        try store.register(url: URL(fileURLWithPath: dir.path + "/./"))
        #expect(store.roots.count == 1)
        let other = try guiWalkTemp("roots2")
        defer { try? FileManager.default.removeItem(at: other) }
        try store.register(url: other)
        #expect(store.roots.count == 2, "a different folder is still added")
    }

    @Test("Duplicate rows left by an earlier build merge into the first; unresolvable rows are kept; nothing else changes")
    func mergeKeepsFirstRow() {
        let a1 = BookmarkStore.Root(displayName: "docs", bookmarkData: Data([1]))
        let a2 = BookmarkStore.Root(displayName: "docs", bookmarkData: Data([2]))
        let b = BookmarkStore.Root(displayName: "other", bookmarkData: Data([3]))
        let gone = BookmarkStore.Root(displayName: "gone", bookmarkData: Data([4]))
        let paths: [Data: String] = [Data([1]): "/tmp/docs", Data([2]): "/tmp/docs", Data([3]): "/tmp/other"]
        let kept = BookmarkStore.mergedRoots([a1, a2, b, gone]) { paths[$0.bookmarkData] }
        #expect(kept.map(\.id) == [a1.id, b.id, gone.id])
    }

    @Test("Folders are read once: twins and a folder inside another are dropped, so the plan counts each file once")
    func distinctFoldersCountOnce() throws {
        let dir = try guiWalkTemp("plan")
        defer { try? FileManager.default.removeItem(at: dir) }
        let sub = dir.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        for i in 0..<9 { try "doc \(i)".write(to: dir.appendingPathComponent("d\(i).txt"), atomically: true, encoding: .utf8) }
        try "nested".write(to: sub.appendingPathComponent("n.txt"), atomically: true, encoding: .utf8)
        let other = try guiWalkTemp("plan2")
        defer { try? FileManager.default.removeItem(at: other) }

        let listed = [dir, URL(fileURLWithPath: dir.path + "/"), sub, other, dir]
        #expect(BookmarkStore.distinctFolderIndices(listed) == [0, 3])
        let state = AppState(bookmarks: BookmarkStore(ephemeral: true))
        #expect(state.countRegularFiles(in: BookmarkStore.distinctFolders(listed)) == 10)
        #expect(state.countRegularFiles(in: [dir, dir]) == 20, "without the de-duplication the plan doubled (the walk's 20)")
    }

    @Test("A batch that selected every planned file says nothing about files not reached")
    func receiptWithoutPhantomNotReached() {
        let lines = (0..<10).map { i in
            IntakeBatchLine(path: "/tmp/acceptance-case-documents/f\(i).md", state: "done", outcome: i < 4 ? .received : .alreadyHeld,
                            channel: .folderImport, sourceVersionID: UUID(), intakeOutcome: nil, error: nil)
        }
        let receipt = IntakeBatchReceipt(id: UUID(), channel: .folderImport, startedAt: Date(timeIntervalSince1970: 1_763_000_000),
                                         status: "completed", planned: 10, lines: lines)
        #expect(receipt.notReached == 0 && receipt.reconciles)
        #expect(receipt.summaryLine == "Selected 10: received 4, already held 6, duplicates 0, failed 0")
    }
}

// MARK: - D4: highlights end on word boundaries

@Suite("GUI walk D4 — a highlight never ends or starts inside a word")
struct GUIWalkHighlightTests {

    static let email = "Subject: FW: Invoice INV-2041 Dalmia Traders\nFrom: accounts@dalmia.example\nDate: Wed, 4 Mar 2026 09:12:00 +0530\n\nPlease find the invoice attached."

    private func marked(_ quote: String, in text: String) -> String? {
        guard let r = CitedPassageLocator.locate(quote, in: text), let range = Range(r, in: text) else { return nil }
        return String(text[range])
    }

    @Test("The walk's statement highlights \"Invoice INV-2041 Dalmia Traders\", not \"Invoice INV-2041 Dal\"")
    func statementHighlightsWholeWords() {
        let statement = "Invoice INV-2041 Dalmia Traders on Mar 4, 2026 was sent for the first time by the accounts desk"
        #expect(marked(statement, in: Self.email) == "Invoice INV-2041 Dalmia Traders")
    }

    @Test("A quote starting or ending inside a word is widened to the whole words; an exact quote is unchanged")
    func widenedToWords() {
        #expect(marked("voice INV-2041 Dalmia Trad", in: Self.email) == "Invoice INV-2041 Dalmia Traders")
        #expect(marked("Please find the invoice attached.", in: Self.email) == "Please find the invoice attached.")
        #expect(marked("nothing like this appears anywhere", in: Self.email) == nil)
    }
}

// MARK: - D5: one plain-words reason

@Suite("GUI walk D5 — one plain-words reason for an unreadable scan")
struct GUIWalkUnreadReasonTests {

    private func failedSnapshot() -> SourceReadinessSnapshot {
        let sv = UUID(), at = Date(timeIntervalSince1970: 1_763_000_000)
        let dims = SourceReadinessDimension.ordered.map { d -> SourceReadinessDimensionRecord in
            // As the walk's scan: preserved; metadata (named first, as in the walk) and text extraction failed.
            let failed: Set<SourceReadinessDimension> = [.metadataExtraction, .textExtraction]
            var state: SourceReadinessDimensionState = failed.contains(d) ? .failed : .notStarted
            if d == .preservation { state = .ready }
            return SourceReadinessDimensionRecord(sourceVersionID: sv, dimension: d, state: state, applicability: .required, condition: nil,
                                                  completedUnits: nil, totalUnits: nil, producerID: "test", producerVersion: "1",
                                                  basis: nil, detail: nil, revision: 1, updatedAt: at)
        }
        return SourceReadinessEvaluator.evaluate(sourceVersionID: sv, aggregateRevision: 1, dimensions: dims, updatedAt: at)
    }

    @Test("The Evidence screen's failed attempt and the Add-sources sheet's readiness give the same plain words")
    func sameReasonBothScreens() throws {
        let evidence = UnreadSourceReason.failureReason(stage: "parser", detail: "loaderFailure(\"pdf\", \"empty(no text layer)\")")
        #expect(evidence == "reading failed (no text could be read from it)")
        let snapshot = failedSnapshot()
        try #require(snapshot.completionState == .failed, "the scan's readiness is failed (\(snapshot.completionState))")
        #expect(UnreadSourceReason.text(snapshot: snapshot) == evidence)
        #expect(snapshot.limitations.first?.dimension == .metadataExtraction, "the first limitation is the one the sheet used to name")
        #expect(!evidence.contains("loaderFailure") && !UnreadSourceReason.text(snapshot: snapshot).contains("metadataExtraction"))
    }

    @Test("Other failures keep their plain meaning")
    func otherFailures() {
        #expect(UnreadSourceReason.failureReason(stage: "ingest", detail: "IngestTimeout()") == "reading failed (it took longer than the time allowed)")
        #expect(UnreadSourceReason.failureReason(stage: "router", detail: "no plugin owns xyz") == "reading failed (this kind of file is not supported)")
        #expect(UnreadSourceReason.failureReason(stage: "parser", detail: "Vision OCR failed") == "reading failed (text recognition (OCR) failed)")
        #expect(UnreadSourceReason.failureDetail(dimension: .metadataExtraction) == UnreadSourceReason.noTextRead)
    }
}

// MARK: - The sidebar's "new files added"

@MainActor
@Suite("GUI walk — the sidebar counts new documents, once each")
struct GUIWalkNewFilesBadgeTests {

    @Test("Repeated change notifications for the same file count it once")
    func newFilesCountedOnce() {
        let state = AppState(bookmarks: BookmarkStore(ephemeral: true))
        state.noteDiscoveredFiles(["/tmp/a.md", "/tmp/b.md"])
        state.noteDiscoveredFiles(["/tmp/a.md"])
        state.noteDiscoveredFiles([])
        #expect(state.newFilesSinceLaunch == 2)
    }
}
