//
//  UnifiedPathNewFeatureTests.swift
//  KalsmritikoshTests
//
//  Test phase T2 (2026-11-22) — the "not built" rows of the unified-path program that were built in round 1
//  (docs/UNIFIED_PATH_PROGRAM_2026-11-22.md §3): TIME-11 undated order, GRAPH-13 deeper links, HISTORY-10 multi-topic
//  stories, SEARCH-16 follow-ups, SEARCH-17 the reference shelf, SRC-11 Shimcache. Ephemeral ledgers only; no network.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Unified path — new features", .serialized)
struct UnifiedPathNewFeatureTests {

    static func scratch(_ tag: String) throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("us-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    @MainActor
    static func booted(_ dir: URL) async -> AppState {
        let state = AppState(bookmarks: BookmarkStore(ephemeral: true))
        await state.boot(databaseURL: dir.appendingPathComponent("ledger.sqlite"))
        return state
    }

    // MARK: - TIME-11

    @Test("TIME-11: undated events are ordered from explicit references, then passage order in one source, then version order — no date is invented; no evidence = not placed")
    func undatedOrder() {
        let src = UUID(), v1 = 100.0, v2 = 200.0
        let items = [
            UndatedOrder.Item(id: "approve", text: "After the site meeting the invoice was approved", documentKey: nil),
            UndatedOrder.Item(id: "meeting", text: "Site meeting held with the contractor", documentKey: nil),
            UndatedOrder.Item(id: "p2", text: "The crates were counted", documentKey: .init(sourceID: src, versionRecordedAt: v1, position: 40)),
            UndatedOrder.Item(id: "p1", text: "The truck arrived", documentKey: .init(sourceID: src, versionRecordedAt: v1, position: 10)),
            UndatedOrder.Item(id: "later", text: "The note was amended", documentKey: .init(sourceID: src, versionRecordedAt: v2, position: 5)),
            UndatedOrder.Item(id: "lone", text: "Somebody called", documentKey: nil),
            UndatedOrder.Item(id: "audit", text: "Before the shipment inspection, the auditor visited", documentKey: nil)]
        let anchors = [UndatedOrder.Anchor(id: "dated", text: "Shipment inspection at the port", date: Date(timeIntervalSince1970: 1_700_000_000))]
        let r = UndatedOrder.order(undated: items, dated: anchors)
        let rank = Dictionary(uniqueKeysWithValues: r.placed.map { ($0.id, $0.rank) })
        #expect((rank["meeting"] ?? 99) < (rank["approve"] ?? 0), "an explicit 'after' reference")
        #expect((rank["p1"] ?? 99) < (rank["p2"] ?? 0), "passage order in one source")
        #expect((rank["p2"] ?? 99) < (rank["later"] ?? 0), "a later version comes after")
        #expect(r.placed.first { $0.id == "audit" }?.beforeAnchor?.contains("Shipment inspection") == true, "tied to the dated event, without its date")
        #expect(r.notPlaced == ["lone"], "no order evidence: not placed (\(r.notPlaced))")
        #expect(r.placed.allSatisfy { !$0.reasons.isEmpty }, "every placement says why")
        #expect(UndatedOrder.Result.label == "order only (no date)")
    }

    // MARK: - GRAPH-13

    @Test("GRAPH-13: a link four steps away is not found within two steps but is found by 'Search deeper' with its path; the node cap is reported")
    @MainActor
    func deeperLinks() async throws {
        let dir = try Self.scratch("graph")
        defer { try? FileManager.default.removeItem(at: dir) }
        let state = await Self.booted(dir)
        let db = try #require(state.database)
        let src = UUID(), fileID = UUID()
        try await db.exec("INSERT INTO files (id, url, source_type) VALUES (?, '/tmp/chain.txt', 'txt');", [.uuid(fileID)])
        try await db.exec("INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at) VALUES (?, ?, 'txt', 'chain', 0, 0);",
                          [.uuid(src), .uuid(fileID)])
        let names = ["Asha Rao", "Vikram Shah", "Dev Malhotra", "Priya Nair", "Meera Iyer"]
        var ids: [UUID] = []
        for n in names {
            let id = UUID(); ids.append(id)
            try await db.exec("INSERT INTO entities (id, kind, value, normalized, source_object_id, confidence) VALUES (?, 'person', ?, ?, ?, 0.9);",
                              [.uuid(id), .text(n), .text(n.lowercased()), .uuid(src)])
        }
        for (a, b) in zip(ids, ids.dropFirst()) {
            try await db.exec("INSERT INTO relationships (id, kind, from_entity_id, to_entity_id, source_object_id) VALUES (?, 'worksWith', ?, ?, ?);",
                              [.uuid(UUID()), .uuid(a), .uuid(b), .uuid(src)])
        }
        let near = await state.connectionSearch(from: ids[0], to: ids[4], maxHops: 2, nodeCap: 3_000)
        #expect(near.connection == nil && near.maxHops == 2 && near.nodesReached >= 3, "not within two steps")
        let deep = await state.connectionSearch(from: ids[0], to: ids[4], maxHops: 8, nodeCap: 3_000)
        let path = try #require(deep.connection)
        #expect(path.nodes.map(\.name) == names, "the path is shown: \(path.nodes.map(\.name))")
        #expect(path.hops.count == 4 && path.hops.allSatisfy { $0.evidenceObjectID == src })
        let capped = await state.connectionSearch(from: ids[0], to: ids[4], maxHops: 8, nodeCap: 3)
        #expect(capped.connection == nil && capped.stoppedAtCap, "the cap is stated, so 'no link' says what was searched")
        await state.shutdown()
    }

    // MARK: - HISTORY-10

    @Test("HISTORY-10: a story question joining several subjects yields each exact name phrase (no guessed subjects)")
    func multiTopicNames() {
        // The caller keeps only phrases that exactly equal an entity, so the whole run is offered beside its parts.
        let two = MultiTopicStory.namePhrases(in: "Tell the story of Asha Rao and Dalmia Traders")
        #expect(two.contains("Asha Rao") && two.contains("Dalmia Traders"), "\(two)")
        let bank = MultiTopicStory.namePhrases(in: "What happened between Bank of Baroda and Vikram Shah?")
        #expect(bank.contains("Bank of Baroda") && bank.contains("Vikram Shah") && !bank.contains("Bank"), "\(bank)")
        #expect(MultiTopicStory.namePhrases(in: "Tell the story of Johnson and Johnson").contains("Johnson and Johnson"))
        #expect(MultiTopicStory.namePhrases(in: "What is the history?").isEmpty)
    }

    // MARK: - SEARCH-16

    @Test("SEARCH-16: follow-up suggestions come from the cited documents' people and events (at most 4, never the question again)")
    @MainActor
    func followUps() async throws {
        #expect(FollowUpSuggester.suggestions({ var i = FollowUpSuggester.Input(question: "Who paid?")
            i.conflicts = ["the payment date"]; i.people = ["Asha Rao", "Vikram Shah", "Dev Malhotra"]; i.events = ["Invoice approved"]
            i.unreadDocuments = ["scan.pdf"]; i.missingEvidence = ["the payer"]; return i }()).count == FollowUpSuggester.maximum)
        var asked = FollowUpSuggester.Input(question: "What else do the documents say about Asha Rao?")
        asked.people = ["Asha Rao"]
        #expect(!FollowUpSuggester.suggestions(asked).contains("What else do the documents say about Asha Rao?"))
        let dir = try Self.scratch("follow")
        defer { try? FileManager.default.removeItem(at: dir) }
        let state = await Self.booted(dir)
        let ingest = try #require(state.ingest)
        let file = dir.appendingPathComponent("f.txt")
        try Data("Statement of Asha Rao, 3 March 2026. Asha Rao approved invoice INV-2041 for Dalmia Traders on 3 March 2026.".utf8).write(to: file)
        let r = try await ingest.ingest(fileAt: file)
        let answer = VerifiedAnswer(body: "Approved.", answerText: "Approved.", citations: [.init(objectID: r.object.id, snippet: "approved")], confidence: Confidence(0.8))
        let s = await state.followUpSuggestions(question: "Who approved the invoice?", answer: answer, caseID: nil)
        #expect(!s.isEmpty && s.count <= FollowUpSuggester.maximum)
        #expect(s.contains { $0.contains("Asha Rao") } || s.contains("Show the timeline of these events"), "\(s)")
        await state.shutdown()
    }

    // MARK: - SEARCH-17

    @Test("SEARCH-17: a reference shelf folder is read and searched; its passages are labelled reference, never a case document number")
    @MainActor
    func referenceShelf() async throws {
        let dir = try Self.scratch("shelf")
        defer { try? FileManager.default.removeItem(at: dir) }
        let state = await Self.booted(dir)
        let folder = dir.appendingPathComponent("Manuals", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("Customs Manual\n\nSection 4. Demurrage is charged when a container stays at the port beyond the free days allowed by the terminal.".utf8)
            .write(to: folder.appendingPathComponent("customs-manual.txt"))
        let report = try #require(await state.addReferenceShelfFolder(folder))
        #expect(report.read == 1, "\(report)")
        let block = try #require(await state.referenceShelfBlock(question: "demurrage free days"))
        #expect(block.hasPrefix(ReferenceShelfLane.label) && block.contains("free days"), "\(block)")
        let tool = await state.shelfToolLines("demurrage")
        #expect(tool.contains("From your reference shelf (reference, not evidence)") && !tool.contains("[D"), "\(tool)")
        // In the case briefing: its own section, after the case's own lines, never numbered.
        var m = CaseLedgerBriefing.Material()
        let d = UUID()
        m.entities = [.init(id: UUID(), kind: "person", value: "Asha Rao", tier: "T1", source: d, confidence: 0.9, aliases: [])]
        m.shelf = [.init(title: "customs-manual", passages: 2)]
        let b = CaseLedgerBriefing.build(m, number: [d: 1])
        #expect(b.text.contains("## Your reference shelf (reference material, NOT case evidence; never cite it as [D<n>])\n- customs-manual (2 passages)"))
        let reread = try #require(await state.rereadReferenceShelf())
        #expect(reread.read == 0, "unchanged files are not read again")
        await state.shutdown()
    }

    // MARK: - SRC-11

    @Test("SRC-11: a Windows 10 Shimcache value decodes to its paths and times; a bad entry stops decoding and says where")
    func shimcacheDecode() throws {
        func le32(_ v: UInt32) -> [UInt8] { withUnsafeBytes(of: v.littleEndian, Array.init) }
        func le16(_ v: UInt16) -> [UInt8] { withUnsafeBytes(of: v.littleEndian, Array.init) }
        func le64(_ v: UInt64) -> [UInt8] { withUnsafeBytes(of: v.littleEndian, Array.init) }
        func entry(_ path: String, filetime: UInt64) -> [UInt8] {
            let p = Array(path.utf16).flatMap { le16($0) }
            let body = le16(UInt16(p.count)) + p + le64(filetime) + le32(0)
            return Array("10ts".utf8) + le32(0) + le32(UInt32(body.count)) + body
        }
        // 2021-01-01T00:00:00Z as a FILETIME (100 ns since 1601).
        let ft: UInt64 = (1_609_459_200 + 11_644_473_600) * 10_000_000
        var data = le32(0x34) + [UInt8](repeating: 0, count: 0x34 - 4)
        data += entry("C:\\Windows\\System32\\cmd.exe", filetime: ft) + entry("C:\\Tools\\psexec.exe", filetime: ft)
        guard case .decoded(let entries, let stopped) = ShimcacheDecoder.decode(Data(data)) else { Issue.record("not decoded"); return }
        #expect(entries.map(\.path) == ["C:\\Windows\\System32\\cmd.exe", "C:\\Tools\\psexec.exe"] && stopped == nil)
        #expect(entries.first?.fileLastModified == Date(timeIntervalSince1970: 1_609_459_200))
        guard case .decoded(let partial, let why) = ShimcacheDecoder.decode(Data(data + Array("XXXX".utf8) + [UInt8](repeating: 0, count: 12))) else {
            Issue.record("not decoded"); return
        }
        #expect(partial.count == 2 && (why ?? "").contains("signature"))
        guard case .notDecoded = ShimcacheDecoder.decode(Data([1, 2, 3])) else { Issue.record("a short value must not decode"); return }
        #expect(ShimcacheDecoder.isShimcacheValue(path: "HKLM\\SYSTEM\\ControlSet001\\Control\\Session Manager\\AppCompatCache", name: "AppCompatCache"))
    }
}
