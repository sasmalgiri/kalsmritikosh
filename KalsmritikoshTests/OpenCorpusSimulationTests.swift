//
//  OpenCorpusSimulationTests.swift
//  KalsmritikoshTests
//
//  The X-1…X-6 workflows run end to end on real, openly licensed material
//  (Fixtures/OpenCorpus — see OPENCORPUS_SOURCES.md): Wikipedia articles in four known
//  categories, two Wikipedia pages as the browser serves them, a U.S. Supreme Court slip
//  opinion (PDF) and The Federalist No. 1. Each test states what a person doing that job
//  expects the app to produce, and checks it.
//

import Foundation
import AppKit
import PDFKit
import CryptoKit
import Testing
@testable import Kalsmritikosh

final class OpenCorpusMarker {}

enum OpenCorpus {
    static let bundle = Bundle(for: OpenCorpusMarker.self)

    /// A fixture by file name (the test bundle may keep or flatten the folder structure).
    static func url(_ name: String) throws -> URL {
        let root = try #require(bundle.resourceURL)
        if let direct = bundle.url(forResource: (name as NSString).deletingPathExtension,
                                   withExtension: (name as NSString).pathExtension) { return direct }
        let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let u = e?.nextObject() as? URL { if u.lastPathComponent == name { return u } }
        throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: name])
    }

    struct Article: Decodable {
        let file: String
        let category: String
        let title: String
    }

    static func articles() throws -> [Article] {
        try JSONDecoder().decode([Article].self, from: Data(contentsOf: url("opencorpus-wikipedia.json")))
    }

    /// Either embedder the app can use: the bundled model (when this build has it) or Apple's.
    static func embedder(_ which: String) async -> (id: String, embed: @Sendable (String) async -> [Float])? {
        switch which {
        case "bge-small.v1":
            let coreML = CoreMLEmbedderProvider()
            guard await coreML.isAvailable() else { return nil }
            return ("bge-small.v1", { (try? await coreML.embed(text: $0)) ?? [] })
        default:
            let nl = NLEmbedder()
            guard !(await nl.embed("probe")).isEmpty else { return nil }
            return ("apple.nl.v1", { await nl.embed($0) })
        }
    }
}

@Suite("Open corpus — real material through each workflow", .serialized)
struct OpenCorpusSimulationTests {

    // MARK: X-1 + X-2 — a researcher files 20 articles

    /// A researcher drops 20 articles from four subjects (plus one off-topic) into the archive,
    /// files two per subject into a group, and asks where the rest belong and what is alike.
    @Test("X-1/X-2: See Also stays on subject; filing suggests the right group; off-topic gets no suggestion",
          .timeLimit(.minutes(10)), arguments: ["bge-small.v1", "apple.nl.v1"])
    func researcherFilesArticles(model: String) async throws {
        guard let (modelID, embed) = await OpenCorpus.embedder(model) else { return }   // that embedder is not in this build
        let dir = try ParityFixture.tempFolder("oc-filing")
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try await ParityFixture.database(in: dir)

        var docs: [(id: UUID, article: OpenCorpus.Article)] = []
        for article in try OpenCorpus.articles() {
            let text = try String(contentsOf: try OpenCorpus.url(article.file), encoding: .utf8)
            let d = try await ParityFixture.document(db, name: article.file, text: text)
            for (i, chunk) in d.chunks.enumerated() {
                let passage = text.components(separatedBy: "\n\n").filter { !$0.isEmpty }[i]
                let v = await embed(passage)
                if !v.isEmpty { try await ParityFixture.embed(db, chunk: chunk, v, model: modelID) }
            }
            docs.append((d.id, article))
        }
        let engine = DocumentSimilarity(database: db, modelID: modelID)
        let categorised = docs.filter { $0.article.category != "Offtopic" }

        // See Also: of each article's top three, how many share its subject?
        var onSubject = 0, shown = 0
        for d in categorised {
            guard case .results(let r) = try await engine.seeAlso(d.id, limit: 3) else { continue }
            for hit in r {
                shown += 1
                if docs.first(where: { $0.id == hit.objectID })?.article.category == d.article.category { onSubject += 1 }
            }
        }
        let precision = Double(onSubject) / Double(max(shown, 1))
        #expect(shown >= 40, "See Also showed only \(shown) results for 20 articles")
        #expect(precision >= 0.8, "See Also top-3 on-subject rate \(precision) (\(onSubject)/\(shown)) with \(modelID)")

        // Filing: two per subject go in a group; the other three should be suggested that group.
        let groups = GroupRepository(database: db)
        var groupOf: [String: UUID] = [:]
        for category in Set(categorised.map(\.article.category)).sorted() {
            let g = try await groups.create(name: category)
            groupOf[category] = g
            for d in categorised.filter({ $0.article.category == category }).prefix(2) { try await groups.add(d.id, to: g) }
        }
        var stats: [String] = []
        for d in categorised + docs.filter({ $0.article.category == "Offtopic" }) {
            stats.append("\(d.article.title): " + (try await engine.groupScores(d.id)).map { "\($0.name)=\(String(format: "%.3f", $0.score))" }.joined(separator: ","))
        }
        Attachment.record(stats.joined(separator: "\n"), named: "calibration-\(modelID).txt")
        let chess = try #require(docs.first { $0.article.category == "Offtopic" })
        guard DocumentSimilarity.filingThresholds[modelID] != nil else {
            // Not calibrated for this embedder (see DocumentSimilarity.filingThresholds): no guesses.
            guard case .notCalibrated = try await engine.suggestFiling(chess.id) else {
                Issue.record("filing must stay off for the uncalibrated \(modelID)"); return
            }
            return
        }
        var right = 0, asked = 0
        for category in groupOf.keys.sorted() {
            for d in categorised.filter({ $0.article.category == category }).dropFirst(2) {
                asked += 1
                if case .results(let s) = try await engine.suggestFiling(d.id), s.first?.name == category { right += 1 }
            }
        }
        #expect(Double(right) / Double(asked) >= 0.8, "filing suggested the right group for \(right) of \(asked) with \(modelID)")

        // Off-topic: no group is a confident home for an article about chess.
        if case .results(let s) = try await engine.suggestFiling(chess.id) {
            Issue.record("off-topic article got suggestions \(s.map { "\($0.name) \($0.score)" }) with \(modelID)")
        }
    }

    // MARK: X-3 — a lawyer marks up a Supreme Court opinion

    @Test("X-3: highlight, strike out and annotate a real court opinion; export a marked copy; the original is untouched",
          .timeLimit(.minutes(5)))
    @MainActor func lawyerMarksUpOpinion() async throws {
        let original = try OpenCorpus.url("Loper-Bright-v-Raimondo-22-451.pdf")
        let before = try Data(contentsOf: original)
        let pdf = try #require(PDFDocument(url: original))
        #expect(pdf.pageCount > 10)
        // The holding the lawyer is looking for.
        let hits = pdf.findString("Chevron is overruled", withOptions: [.caseInsensitive])
        let hit = try #require(hits.first, "the opinion's holding was not found by text search")
        let page = try #require(hit.pages.first)
        let pageIndex = pdf.index(for: page)

        let dir = try ParityFixture.tempFolder("oc-marks")
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try await ParityFixture.database(in: dir)
        let docID = try await ParityFixture.document(db, name: "opinion.pdf", text: page.string ?? "opinion").id
        let repo = PDFMarksRepository(database: db)
        let rects = hit.selectionsByLine().map { $0.bounds(for: page) }
        _ = try await repo.add(objectID: docID, sourceURL: original.absoluteString, page: pageIndex, kind: .highlight,
                               rects: rects, quote: hit.string, contents: "Holding — cite in brief")
        _ = try await repo.add(objectID: docID, sourceURL: original.absoluteString, page: 0, kind: .note,
                               rects: [CGRect(x: 40, y: 700, width: 22, height: 22)], quote: nil, contents: "Decided June 28, 2024")
        let marks = try await repo.marks(for: docID)
        #expect(marks.count == 2)
        // The highlight is also in Highlights, as a plain note on the exact words.
        let highlight = try await db.query("SELECT quote, note, stance FROM annotations WHERE object_id = ?;", [.uuid(docID)]).first
        #expect(highlight?.string(0)?.localizedCaseInsensitiveContains("Chevron is overruled") == true)
        #expect(highlight?.string(2) == "note")

        let out = try ParityFixture.tempFolder("oc-export")
        defer { try? FileManager.default.removeItem(at: out) }
        let r = try PDFMarksController.exportAnnotatedCopy(of: original, marks: marks, into: out)
        #expect(r.originalUnchanged)
        #expect(try Data(contentsOf: original) == before)
        let copy = try #require(PDFDocument(url: r.pdf))
        #expect(copy.pageCount == pdf.pageCount)
        #expect(copy.page(at: pageIndex)?.annotations.contains { $0.type == "Highlight" } == true)
        let md = try String(contentsOf: r.summary, encoding: .utf8)
        #expect(md.contains("Page \(pageIndex + 1) · Highlight"))
        #expect(md.contains("Holding — cite in brief"))
    }

    // MARK: X-3 — a historian keeps rich-text notes on a primary source

    @Test("X-3: a rich-text note on The Federalist No. 1 keeps its formatting, its versions and its words")
    func historianRichNote() throws {
        let source = try String(contentsOf: try OpenCorpus.url("Federalist-No-1.txt"), encoding: .utf8)
        let base = try ParityFixture.tempFolder("oc-notes")
        defer { try? FileManager.default.removeItem(at: base) }
        let store = NotesStore(base: base)
        let note = try store.create(title: "Federalist 1 — reading notes", format: .richText)
        let body = NSMutableAttributedString(attributedString: try store.readRich(note))
        let quote = "whether societies of men are really capable or not of establishing good government from reflection and choice"
        #expect(source.replacingOccurrences(of: "\n", with: " ").contains(quote))
        let start = body.length
        body.append(NSAttributedString(string: "Key question: \(quote).\n"))
        body.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 13), range: NSRange(location: start, length: 13))
        try store.saveRich(body, to: note)
        body.append(NSAttributedString(string: "Hamilton, 27 October 1787.\n"))
        try store.saveRich(body, to: note)
        let back = try store.readRich(note)
        #expect(back.string.contains(quote))
        #expect(back.string.contains("Hamilton, 27 October 1787."))
        let bold = back.attribute(.font, at: start + 2, effectiveRange: nil) as? NSFont
        #expect(bold.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } == true)
        #expect(store.versions(of: note).count == 2)
        // What ingestion reads: the RTF parses to the same words.
        let parsed = try NSAttributedString(data: Data(contentsOf: note), options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        #expect(parsed.string.contains("Key question"))
    }

    // MARK: X-4 — clipping real pages

    @Test("X-4: clipping real Wikipedia pages — page, selection and Markdown — gives readable, attributed copies",
          .timeLimit(.minutes(5)))
    @MainActor func clipRealPages() throws {
        for name in ["Lease.html", "Sourdough.html"] {
            let html = try String(contentsOf: try OpenCorpus.url(name), encoding: .utf8)
            let title = (name as NSString).deletingPathExtension
            let url = "https://en.wikipedia.org/wiki/\(title)"
            let page = try ClipRequest(kind: .page, title: "\(title) - Wikipedia", url: url, html: html, text: "").payload()
            let saved = String(decoding: page.data, as: UTF8.self)
            #expect(saved.contains("kalsmritikosh-source\" content=\"\(url)\""))
            #expect(page.data.count >= html.utf8.count)               // nothing of the page is dropped
            let md = HTMLMarkdown.markdown(fromHTML: html, title: title, sourceURL: url)
            #expect(md.hasPrefix("# \(title)"))
            #expect(md.count > 2_000, "\(name): Markdown copy too short (\(md.count))")
            #expect(!md.contains("<script"))
            #expect(!md.lowercased().contains("function("))
            #expect(md.contains("](http"), "\(name): links were lost")
            #expect(md.localizedCaseInsensitiveContains(title))
        }
        // A selection from the Lease page.
        let sel = try ClipRequest(kind: .selection, title: "Lease - Wikipedia", url: "https://en.wikipedia.org/wiki/Lease",
                                  html: "<p>A <b>lease</b> is a contractual arrangement.</p>", text: "A lease is a contractual arrangement.").payload()
        #expect(String(decoding: sel.data, as: UTF8.self).contains("<b>lease</b>"))
    }

    // MARK: X-5 + X-6 — a two-Mac household and a phone

    /// Two Macs share real documents; work on each (tags, groups, highlights, notes) meets on
    /// both; the phone sees it and adds its own; a tampered change is refused.
    @Test("X-5/X-6: two Macs and a phone working on the same real documents end with the same work",
          .timeLimit(.minutes(5)))
    func householdSync() async throws {
        let root = try ParityFixture.tempFolder("oc-sync")
        let store = try SyncStore.create(at: root, passphrase: "a long household passphrase", rounds: 5_000)
        defer { try? FileManager.default.removeItem(at: root) }
        func mac(_ name: String) async throws -> (db: Database, notes: NotesStore, engine: SyncEngine, dir: URL) {
            let dir = try ParityFixture.tempFolder("oc-\(name)")
            let db = try await ParityFixture.database(in: dir)
            let notes = NotesStore(base: dir)
            let intake = dir.appendingPathComponent("Intake", isDirectory: true)
            try FileManager.default.createDirectory(at: intake, withIntermediateDirectories: true)
            let engine = SyncEngine(database: db, store: store, deviceID: "mac-\(name)", deviceName: name,
                                    signingKey: Curve25519.Signing.PrivateKey(), notes: notes, intakeFolder: intake,
                                    saveIntake: { data, file, _ in
                                        let t = intake.appendingPathComponent(file); try data.write(to: t)
                                        return CaptureIntake.Saved(file: t, sha256: SyncCrypto.sha256Hex(data)) })
            return (db, notes, engine, dir)
        }
        let a = try await mac("Studio"), b = try await mac("Laptop")
        defer { try? FileManager.default.removeItem(at: a.dir); try? FileManager.default.removeItem(at: b.dir) }

        // Both Macs have the same five articles (the same files, read by each).
        var idsA: [String: UUID] = [:], idsB: [String: UUID] = [:]
        for article in try OpenCorpus.articles().filter({ $0.category == "Law" }) {
            let data = try Data(contentsOf: try OpenCorpus.url(article.file))
            let text = String(decoding: data, as: UTF8.self)
            let hash = SyncCrypto.sha256Hex(data)
            idsA[article.title] = try await ParityFixture.document(a.db, name: article.file, text: text, fileHash: hash).id
            idsB[article.title] = try await ParityFixture.document(b.db, name: article.file, text: text, fileHash: hash).id
        }
        // Studio: tags and a group; Laptop: highlights and a note.
        let tagsA = TagsRepository(database: a.db)
        let contract = try await tagsA.tag(named: "Contract law")
        for t in ["Contract", "Lease"] { try await tagsA.attach(tagID: contract, to: .object, idsA[t]!) }
        let groupsA = GroupRepository(database: a.db)
        let course = try await groupsA.create(name: "Law course")
        for id in idsA.values { try await groupsA.add(id, to: course) }
        _ = try await AnnotationsRepository(database: b.db).add(objectID: idsB["Negligence"]!, sourceURL: nil,
                                                                 quote: "duty of care", note: "exam topic")
        let noteB = try b.notes.create(title: "Week 1")
        try b.notes.save("# Week 1\n\nRead Contract and Tort.", to: noteB)

        for _ in 0..<2 { _ = try await a.engine.sync(); _ = try await b.engine.sync() }

        #expect(try await TagsRepository(database: b.db).tags(for: .object, idsB["Lease"]!).map(\.name) == ["Contract law"])
        #expect(try await GroupRepository(database: b.db).members(of: course).count == 5)
        #expect(try await a.db.query("SELECT note FROM annotations WHERE object_id = ?;", [.uuid(idsA["Negligence"]!)]).first?.string(0) == "exam topic")
        #expect(try a.notes.read(a.notes.notesFolder.appendingPathComponent("Week 1.md")).contains("Read Contract and Tort."))

        // The phone reads the same picture …
        let replay = SyncReplay.replay(store)
        #expect(replay.problems.isEmpty)
        let lease = try #require(replay.documents.first { $0.title.contains("Lease") })
        #expect(replay.tags(of: lease) == ["Contract law"])
        #expect(replay.groups(of: lease) == ["Law course"])
        #expect(replay.liveNotes.map(\.name) == ["Week 1.md"])
        // … and adds a tag of its own, written exactly as the phone writes it.
        let phone = Curve25519.Signing.PrivateKey()
        try store.register(SyncDeviceInfo(id: "phone", name: "iPhone", publicKey: phone.publicKey.rawRepresentation.base64EncodedString(), platform: "iOS"))
        let tagID = UUID().uuidString, ref = SyncReplay.reference(for: lease), now = SyncValue.real(Date().timeIntervalSince1970)
        try store.write(SyncBatch(device: "phone", seq: 1, createdAt: Date(), ops: [
            SyncOp(table: "user_tags", key: tagID, fields: ["id": .text(tagID), "name": .text("Read on train"), "color": .null,
                                                           "created_at": now, "retired_at": .null, "merged_into": .null], lamport: replay.maxLamport + 1, device: "phone"),
            SyncOp(table: "user_tag_links", key: "\(tagID)|object|\(ref)", fields: ["tag_id": .text(tagID), "subject_kind": .text("object"),
                                                                                  "subject_id": .text(ref), "created_at": now, "removed_at": .null], lamport: replay.maxLamport + 1, device: "phone")
        ], files: []), signingKey: phone)
        _ = try await a.engine.sync(); _ = try await b.engine.sync()
        #expect(Set(try await TagsRepository(database: a.db).tags(for: .object, idsA["Lease"]!).map(\.name)) == ["Contract law", "Read on train"])
        #expect(Set(try await TagsRepository(database: b.db).tags(for: .object, idsB["Lease"]!).map(\.name)) == ["Contract law", "Read on train"])

        // Someone edits a batch file in the shared folder: it is refused on both Macs.
        let forged = root.appendingPathComponent("log/phone/\(SyncFormat.batchName(2))")
        try SyncStore.encoder.encode(SyncEnvelope(device: "phone", seq: 2, sealed: Data("not sealed".utf8).base64EncodedString(),
                                                  signature: "AAAA")).write(to: forged)
        let ra = try await a.engine.sync(), rb = try await b.engine.sync()
        #expect(ra.quarantined == 1 && rb.quarantined == 1)
    }
}
