//
//  TorrentSpeedTests.swift
//  KalsmritikoshTests
//
//  Speed torrent test phase (owner 2026-11-23): one focused suite per torrent row PERF-34 … PERF-40
//  (docs/SPEED_PROGRAM_2026-11-23.md, "Torrent-engine ideas"). Scripted providers only (nothing leaves the Mac), throwaway
//  ledgers and temporary folders only (never the owner's). No timing assertions except generous upper bounds; Vision is
//  never called (a cache hit is what is tested; a miss is shown by the key, not by running the recogniser).
//

import Foundation
import CoreGraphics
import CryptoKit
import os
import Testing
@testable import Kalsmritikosh

private func tempDir(_ name: String) throws -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("torrent-\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

private func sha256(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

private func count(_ db: Database, _ sql: String, _ b: [SQLValue] = []) async throws -> Int {
    Int(try await db.query(sql, b).first?.int(0) ?? -1)
}

// MARK: - PERF-34 · content-addressed result cache

/// An embedder that counts what it is really asked to embed.
private nonisolated final class CountingEmbedder: Embedder, @unchecked Sendable {
    let dimension = 4
    private let lock = NSLock()
    private var asked: [String] = []
    func embed(_ text: String) async -> [Float] {
        lock.withLock { asked.append(text) }
        return [Float(text.count), 1, 2, 3]
    }
    var calls: [String] { lock.withLock { asked } }
}

@Suite("Speed PERF-34 torrent — content-addressed result cache", .serialized)
struct TorrentContentCacheTests {

    @Test("OCR: a page image recognised before (same bytes, same reader version) comes from the cache — Vision is not called; another reader version or language set is a different key (recomputed)")
    func ocrCacheHit() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        let repo = ContentResultCacheRepository(database: db)
        let dir = try tempDir("ocr")
        defer { try? FileManager.default.removeItem(at: dir) }
        // Not a decodable image: if the recogniser ran, it would return no lines. Lines coming back prove the cache answered.
        let page = dir.appendingPathComponent("page-1.png")
        try Data("not really an image — the cache must answer for it".utf8).write(to: page)
        let copy = dir.appendingPathComponent("same-bytes-elsewhere.png")
        try FileManager.default.copyItem(at: page, to: copy)
        let ocr = VisionOCR()
        let digest = try #require(ContentFingerprint.file(page))
        let lines = [OCRLine(text: "INVOICE 2041", confidence: 0.93, boundingBox: CGRect(x: 0.1, y: 0.8, width: 0.5, height: 0.05)),
                     OCRLine(text: "Total INR 10,000", confidence: 0.88, boundingBox: CGRect(x: 0.1, y: 0.2, width: 0.6, height: 0.04))]
        await repo.store(digest: digest, kind: .ocr, producer: ocr.producerKey("lines"), payload: VisionOCR.encodeLines(lines))
        await repo.store(digest: digest, kind: .ocr, producer: ocr.producerKey("printed"),
                         payload: VisionOCR.encodeLines(lines.map { OCRLine(text: $0.text, confidence: -1, boundingBox: .zero) }))
        try await ContentResults.TestOverride.$store.withValue(repo) {
            // Same bytes under another name: the same fingerprint, the same lines (text, confidence, box).
            let got = await ocr.recognizeLines(at: copy)
            #expect(got == lines)
            #expect(await ocr.recognizePrinted(at: copy) == lines.map(\.text))
        }
        // The reader's key carries its version, its languages and its custom words: a change of any of them misses.
        #expect(ocr.producerKey("lines").contains(".v\(VisionOCR.producerVersion)|"))
        let other = [VisionOCR(recognitionLanguages: ["fr-FR"]), VisionOCR(customWords: ["Dalmia"])]
        for o in other {
            #expect(o.producerKey("lines") != ocr.producerKey("lines"))
            #expect(await repo.lookup(digest: digest, kind: .ocr, producer: o.producerKey("lines")) == nil)
        }
        let bumped = ocr.producerKey("lines").replacingOccurrences(of: ".v\(VisionOCR.producerVersion)|", with: ".v\(VisionOCR.producerVersion)9|")
        #expect(await repo.lookup(digest: digest, kind: .ocr, producer: bumped) == nil, "a new reader version recomputes")
        // Different bytes: a different fingerprint, nothing reused.
        try Data("another page".utf8).write(to: copy)
        #expect(ContentFingerprint.file(copy) != digest)
        // Round trip of the kept form.
        #expect(VisionOCR.decodeLines(VisionOCR.encodeLines(lines)) == lines)
    }

    @Test("Typed fields: candidates kept per block text are reused for a block with the same text (re-anchored to the new block, the same fields as a fresh extraction); a new extractor version recomputes")
    func typedFieldsReused() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        let repo = ContentResultCacheRepository(database: db)
        func block(_ text: String, _ sv: UUID, method: ExtractionMethod = .native, conf: Double = 1) -> EvidenceBlock {
            EvidenceBlock(documentID: UUID(), sourceVersionID: sv, ordinal: 0, kind: .paragraph, rawText: text,
                          locator: SourceLocator(page: 1, boundingBox: nil), extractionMethod: method, extractionConfidence: conf)
        }
        let text = "Contact: JANE.ROE@Example.COM\nMobile: +91 98765 43210\nInvoice INV-2041 dated 3 March 2024."
        // What the import does (IngestCoordinator typed fields): look up, extract with reuse, keep what was computed.
        func run(_ blocks: [EvidenceBlock], _ sv: UUID, _ ex: TypedFieldExtractor) async -> (fields: [TypedField], reused: Int, computed: Int) {
            let keys = blocks.compactMap(TypedFieldExtractor.cacheKey)
            var reuse: [String: [TypedFieldExtractor.Candidate]] = [:]
            for (k, p) in await repo.lookupMany(digests: keys, kind: .typedFields, producer: ex.cacheProducer) {
                if let c = TypedFieldExtractor.decode(p) { reuse[k] = c }
            }
            let (fields, computed) = ex.extract(blocks: blocks, sourceVersionID: sv, reuse: reuse)
            await repo.storeMany(computed.map { ($0.key, TypedFieldExtractor.encode($0.value)) }, kind: .typedFields, producer: ex.cacheProducer)
            return (fields, reuse.count, computed.count)
        }
        let ex = TypedFieldExtractor()
        let sv1 = UUID(), sv2 = UUID()
        let first = await run([block(text, sv1)], sv1, ex)
        #expect(first.reused == 0 && first.computed == 1 && !first.fields.isEmpty)
        // The same text in another document's block (OCR'd, so its confidence factor differs): reused, re-anchored.
        let b2 = block("Contact: JANE.ROE@Example.COM\r\nMobile: +91 98765 43210   \nInvoice INV-2041 dated 3 March 2024.\n", sv2, method: .ocr, conf: 0.9)
        let second = await run([b2], sv2, ex)
        #expect(second.reused == 1 && second.computed == 0, "the same normalised text is not extracted again")
        let fresh = ex.extract(blocks: [b2], sourceVersionID: sv2)
        func shape(_ fs: [TypedField]) -> [String] {
            fs.map { "\($0.evidenceBlockID)|\($0.fieldType.rawValue)|\($0.normalizedValue)|\(String(format: "%.6f", $0.confidence))|\($0.sourceVersionID)" }.sorted()
        }
        #expect(shape(second.fields) == shape(fresh), "reused fields equal a fresh extraction of the new block")
        #expect(second.fields.allSatisfy { $0.evidenceBlockID == b2.id && $0.sourceVersionID == sv2 })
        #expect(Set(second.fields.map(\.fieldType)).contains(.email))
        // A new extractor version is a different producer: nothing reused.
        let v2 = TypedFieldExtractor(producerVersion: "2")
        #expect(v2.cacheProducer != ex.cacheProducer)
        let third = await run([b2], sv2, v2)
        #expect(third.reused == 0 && third.computed == 1)
    }

    @Test("Vectors: a text embedded once is not embedded again (one batched lookup); another model id is a miss")
    func vectorsReused() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        let repo = EmbeddingCacheRepository(database: db)
        let inner = CountingEmbedder()
        let texts = ["Payment of INR 10,000 to Dalmia Traders.", "Invoice INV-2041.", "Statement 7718, March."]
        let a = CachedEmbedder(wrapping: inner, persistent: repo, modelID: "model-a")
        let v1 = await a.embedBatch(texts)
        #expect(inner.calls.count == 3)
        // A fresh embedder (empty memory tier) over the same ledger: every vector from the persistent cache.
        let again = CachedEmbedder(wrapping: inner, persistent: repo, modelID: "model-a")
        let v2 = await again.embedBatch(texts + [texts[0]])
        #expect(inner.calls.count == 3, "nothing embedded again: \(inner.calls)")
        #expect(Array(v2.prefix(3)) == v1 && v2[3] == v1[0])
        let hits = await repo.lookupMany(modelID: "model-a", textHashes: texts.map(EmbeddingCacheRepository.hash))
        #expect(hits.count == 3)
        // Another model: recomputed.
        let b = CachedEmbedder(wrapping: inner, persistent: repo, modelID: "model-b")
        _ = await b.embedBatch([texts[0]])
        #expect(inner.calls.count == 4)
    }

    /// One provider over one ledger's content cache; each case read is cleared for its own case.
    struct ReplyRig {
        let db: Database
        let repo: ContentResultCacheRepository
        let bodies = CaseReadBudgetTests.Bodies()
        let granted = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 1_000))
        let provider: OnlineCloudProvider
        let o = UUID(), v = UUID()

        init() async throws {
            let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
            self.db = db
            repo = ContentResultCacheRepository(database: db)
            let snapshot = OnlineSnapshot(cloudAllowed: true, kind: .anthropic, model: "claude-opus-5", apiKey: "test-key",
                                          confirmedDocumentTerms: OnlineProviderKind.anthropic.documentTermsVersion, dailyByteCap: nil)
            let bodies = self.bodies, granted = self.granted
            var seams = OnlineCloudProvider.Seams(settings: { snapshot }, consent: { _ in true },
                                                  transport: { req in bodies.add(req); return OutboundHTTPResponse(status: 200, body: CaseReadBudgetTests.reply) })
            seams.casePermission = { _, _ in true }
            seams.casePermissionGrantedAt = { _ in granted.withLock { $0 } }
            seams.ownKeyRefusal = { _ in nil }
            seams.ownKeyTally = { _, _ in }
            let status = await MainActor.run { OnlineStatus() }
            seams.status = { status }
            provider = OnlineCloudProvider(outboundLog: OutboundLogRepository(database: db), knownNames: { [] }, seams: seams)
        }

        func send(caseID: UUID, versions: [UUID]? = nil) async -> CaseReadSend {
            let o = self.o, vs = versions ?? [v]
            let binding = CloudScopeBinding(scopeID: caseID) { [o: Set(vs)] }
            let clearance = await CloudSourceGate(resolve: { _ in .resolved(ProtectionLabel(sensitivity: .internalLevel, privileged: false)) },
                                                  legacyPrivileged: { [] }).bound(to: binding).clear([o], purpose: "case.reading").clearance
            return CaseReadSend(caseID: caseID, prefix: [CaseReader.header, "[Document 1]\nOn March 3, 2021, the supplier was paid twice.\n\n" + CaseReader.footer],
                                suffix: CaseReader.questionSuffix("When was the supplier paid?"), ttl: .oneHour, purpose: "case.question", clearance: clearance)
        }
    }

    @Test("AI replies: reused only in the same case, for the same cleared documents and the same permission — another case, a changed permission or another document set sends again")
    func aiReplyScoped() async throws {
        let r = try await ReplyRig()
        let caseA = UUID(), caseB = UUID()
        try await ContentResults.TestOverride.$store.withValue(r.repo) {
            let first = try await r.provider.readCase(await r.send(caseID: caseA))
            #expect(r.bodies.all.count == 1)
            // The same request in the same case, documents and permission: answered from the kept reply, nothing sent.
            let again = try await r.provider.readCase(await r.send(caseID: caseA))
            #expect(r.bodies.all.count == 1, "the same case read was sent again")
            #expect(again.text == first.text && again.usage == nil)
            // Another case with the very same documents and question: never shared across cases.
            _ = try await r.provider.readCase(await r.send(caseID: caseB))
            #expect(r.bodies.all.count == 2)
            // The permission was withdrawn and given again (a new grant time): sent again.
            r.granted.withLock { $0 = Date(timeIntervalSince1970: 2_000) }
            _ = try await r.provider.readCase(await r.send(caseID: caseA))
            #expect(r.bodies.all.count == 3)
            // Another cleared document set (another version of the document): sent again.
            _ = try await r.provider.readCase(await r.send(caseID: caseA, versions: [UUID()]))
            #expect(r.bodies.all.count == 4)
            // Back to a scope answered before (case B under the first grant): reused.
            r.granted.withLock { $0 = Date(timeIntervalSince1970: 1_000) }
            _ = try await r.provider.readCase(await r.send(caseID: caseB))
            #expect(r.bodies.all.count == 4)
        }
        // Each kept reply carries its case (a case erasure deletes it).
        let rows = try await r.db.query("SELECT upper(case_id), COUNT(*) FROM content_result_cache WHERE kind = 'aiReply' GROUP BY upper(case_id);", [])
        let byCase = Dictionary(uniqueKeysWithValues: rows.compactMap { row -> (String, Int64)? in
            guard let c = row.string(0), let n = row.int(1) else { return nil }
            return (c, n)
        })
        #expect(byCase[caseA.uuidString.uppercased()] == 3 && byCase[caseB.uuidString.uppercased()] == 1)
        // Without a content cache (nil = nothing reused) every read is sent.
        _ = try await r.provider.readCase(await r.send(caseID: caseB))
        #expect(r.bodies.all.count == 5)
    }

    @Test("Erasure: a case erase removes the case's kept AI replies and the results derived from its exclusive documents (and their chunks' vectors); a shared document's and another case's stay; a person erase removes kept text naming them; a full erase empties both caches")
    func erasureClearsDerived() async throws {
        let f = try await CaseErasureTests.boot()
        defer { try? FileManager.default.removeItem(at: f.temp) }
        let repo = ContentResultCacheRepository(database: f.db)
        let vectors = EmbeddingCacheRepository(database: f.db)
        let exclusiveVersion = try #require(try await f.db.query("SELECT id FROM source_versions WHERE logical_source_id = ? LIMIT 1;",
                                                                 [.uuid(f.exclusiveFile)]).first?.uuid(0))
        await repo.store(digest: "ocr-exclusive", kind: .ocr, producer: "p", payload: "[]", origin: .init(fileID: f.exclusiveFile, sourceVersionID: nil))
        await repo.store(digest: "typed-exclusive", kind: .typedFields, producer: "p", payload: "[]", origin: .init(fileID: nil, sourceVersionID: exclusiveVersion))
        await repo.store(digest: "ocr-shared", kind: .ocr, producer: "p", payload: "[]", origin: .init(fileID: f.sharedFile, sourceVersionID: nil))
        await repo.store(digest: "reply-a", kind: .aiReply, producer: "online.case-read", scope: "s-a", caseID: f.caseA, payload: "Paid twice.")
        await repo.store(digest: "reply-b", kind: .aiReply, producer: "online.case-read", scope: "s-b", caseID: f.caseB, payload: "Paid once.")
        // A result the shared document reused later: the reuse is an origin too.
        _ = await repo.lookup(digest: "ocr-shared", kind: .ocr, producer: "p", origin: .init(fileID: f.sharedFile, sourceVersionID: nil))
        let chunk = try #require(try await f.db.query("""
            SELECT c.text, c.context_prefix FROM chunks c JOIN knowledge_objects k ON k.id = c.object_id WHERE k.file_id = ? LIMIT 1;
            """, [.uuid(f.exclusiveFile)]).first)
        let chunkText = try #require(chunk.string(0))
        for h in EmbeddingCacheRepository.hashes(chunkText: chunkText, contextPrefix: chunk.string(1)) {
            await vectors.store(modelID: "m", textHash: h, vector: [1, 2, 3])
        }
        await vectors.store(modelID: "m", textHash: EmbeddingCacheRepository.hash("unrelated text of no document"), vector: [4, 5, 6])

        let out = try await f.state.eraseCase(f.caseA, eraseExclusiveSources: true, reason: "Client request", legalBasis: nil, actor: "Tester")
        #expect(out.report.refused == nil, "\(out.report.refused ?? "")")
        func has(_ digest: String) async throws -> Bool { try await count(f.db, "SELECT COUNT(*) FROM content_result_cache WHERE digest = ?;", [.text(digest)]) > 0 }
        let gone = [try await has("ocr-exclusive"), try await has("typed-exclusive"), try await has("reply-a")]
        #expect(gone == [false, false, false], "derived from the erased document / case A: \(gone)")
        let kept = [try await has("ocr-shared"), try await has("reply-b")]
        #expect(kept == [true, true], "the shared document's result and case B's reply stay")
        #expect(try await count(f.db, "SELECT COUNT(*) FROM embedding_cache WHERE text_hash = ?;", [.text(EmbeddingCacheRepository.hash(chunkText))]) == 0)
        #expect(try await count(f.db, "SELECT COUNT(*) FROM embedding_cache WHERE text_hash = ?;",
                                [.text(EmbeddingCacheRepository.hash("unrelated text of no document"))]) == 1, "a vector of no erased document stays")

        // Person erase: a kept result whose text names the person goes.
        let row = try #require(try await f.db.query("SELECT id, value FROM entities WHERE kind = 'person' AND value LIKE '% %' LIMIT 1;", []).first)
        let personID = try #require(row.string(0).flatMap(UUID.init(uuidString:)))
        let name = try #require(row.string(1))
        await repo.store(digest: "reply-names", kind: .aiReply, producer: "online.case-read", scope: "s-b2", caseID: f.caseB, payload: "\(name) approved the payment.")
        await repo.store(digest: "ocr-names", kind: .ocr, producer: "p", payload: VisionOCR.encodeLines([OCRLine(text: "Signed: \(name)", confidence: 0.9, boundingBox: .zero)]))
        let person = try await f.state.erasePerson(personID, reason: "Subject request", legalBasis: nil, actor: "Tester")
        #expect(person.report.refused == nil)
        let named = [try await has("reply-names"), try await has("ocr-names")]
        #expect(named == [false, false], "kept text naming the person: \(named)")
        #expect(try await has("reply-b"), "a reply not naming them stays")

        // Full erase: both caches emptied.
        _ = await f.state.deleteAllData()
        #expect(try await count(f.db, "SELECT COUNT(*) FROM content_result_cache;") == 0)
        #expect(try await count(f.db, "SELECT COUNT(*) FROM content_result_origins;") == 0)
        #expect(try await count(f.db, "SELECT COUNT(*) FROM embedding_cache;") == 0)
    }
}

// MARK: - PERF-35 · piece map

@Suite("Speed PERF-35 torrent — piece map of a grown mailbox", .serialized)
struct TorrentPieceMapTests {

    static func mbox(messages range: Range<Int>, bodyBytes: Int) -> String {
        var s = ""
        for i in range {
            s += "From sender\(i)@example.com Mon Jan  1 00:00:00 2024\n"
            s += "From: Sender \(i) <sender\(i)@example.com>\nTo: Desk <desk@example.com>\nSubject: Message \(i)\n"
            s += "Date: Mon, 1 Jan 2024 10:\(String(format: "%02d", i % 60)):00 +0000\n\n"
            s += "Body of message number \(i).\n" + String(repeating: "payment detail line \(i % 97) for the ledger\n", count: bodyBytes / 40) + "\n"
        }
        return s
    }

    @Test("Piece map: an appended file keeps every old piece (and the old partial tail) as its proven prefix; a change in the middle shortens it to the pieces before the change")
    func deltaRules() throws {
        let dir = try tempDir("pieces")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("grow.bin")
        var bytes = Data((0..<10_500).map { UInt8($0 % 251) })
        try bytes.write(to: url)
        let old = try #require(PieceMap.compute(url, pieceBytes: 1_000))
        #expect(old.digests.count == 11 && old.partialTail == 10_000..<10_500)
        bytes.append(Data((0..<3_200).map { UInt8(($0 * 7) % 253) }))
        try bytes.write(to: url)
        let grown = try #require(PieceMap.compute(url, pieceBytes: 1_000, extraRange: old.partialTail))
        let d = try #require(grown.delta(from: old, previousVersionID: UUID(), previousRecordOffsets: []))
        #expect(d.appendedOnly && d.unchangedPrefixBytes == 10_500)
        #expect(d.changedPieces == Array(10..<14), "the piece holding the old tail and the new ones")
        // A byte changed inside piece 4: everything from piece 4 is unproven.
        bytes[4_321] ^= 0xFF
        try bytes.write(to: url)
        let edited = try #require(PieceMap.compute(url, pieceBytes: 1_000, extraRange: old.partialTail))
        let e = try #require(edited.delta(from: old, previousVersionID: UUID(), previousRecordOffsets: []))
        #expect(!e.appendedOnly && e.unchangedPrefixBytes == 4_000 && e.changedPieces.first == 4)
        // Message ranges are proven only when both ends (and the next separator) lie inside the prefix.
        let proven = PieceMap.provenRecords(PieceMap.Delta(previousVersionID: UUID(), unchangedPrefixBytes: 4_000, changedPieces: [],
                                                           appendedOnly: false, previousRecordOffsets: [0, 1_000, 3_998, 6_000]))
        #expect(proven == [0: 1_000])
    }

    @Test("A grown mbox (≥ 12 MiB): the new version's map proves the old bytes; the old messages' ranges come from the kept index (not scanned again) and give exactly the records of a full scan; only the new messages are found by the scan")
    func grownMailbox() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        let dir = try tempDir("mbox")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Inbox.mbox")
        let oldCount = 2_000, newCount = 120
        try Data(Self.mbox(messages: 0..<oldCount, bodyBytes: 6_800).utf8).write(to: url)
        let oldSize = Int64(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0)
        #expect(oldSize >= PieceMap.minimumFileBytes, "the mailbox is big enough for a map (\(oldSize) bytes)")
        let logical = UUID(), v1 = UUID(), v2 = UUID()
        let loader = EmailLoader()
        func stream(_ ctx: PieceMaps.Context?) async throws -> [KnowledgeObject] {
            var out: [KnowledgeObject] = []
            try await PieceMaps.$reading.withValue(ctx) {
                try await loader.streamMbox(at: url, budget: StreamBatchBudget(maxObjects: 64, maxContentBytes: .max), coalesce: false) { out += $0 }
            }
            return out
        }
        // Version 1: no earlier map; its message starts are kept with its map.
        let c1 = PieceMaps.Context()
        let first = await PieceMaps.prepare(database: db, fileAt: url, sizeBytes: oldSize, logicalSourceID: logical, sourceVersionID: v1,
                                            at: Date(timeIntervalSince1970: 100))
        #expect(first == nil)
        let v1Records = try await stream(c1)
        #expect(v1Records.count == oldCount && c1.recordOffsets.count == oldCount)
        await PieceMaps.finish(database: db, sourceVersionID: v1, context: c1)

        // The mailbox grows (new mail appended), as a watched mailbox does.
        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd()
        try h.write(contentsOf: Data(Self.mbox(messages: oldCount..<(oldCount + newCount), bodyBytes: 6_800).utf8))
        try h.close()
        let newSize = Int64(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0)
        let c2 = PieceMaps.Context()
        let delta = try #require(await PieceMaps.prepare(database: db, fileAt: url, sizeBytes: newSize, logicalSourceID: logical,
                                                         sourceVersionID: v2, at: Date(timeIntervalSince1970: 200)))
        #expect(delta.previousVersionID == v1 && delta.appendedOnly && delta.unchangedPrefixBytes == oldSize)
        #expect(delta.previousRecordOffsets.count == oldCount)
        let proven = PieceMap.provenRecords(delta)
        #expect(proven.count == oldCount - 1, "every old message but the last (its end is the first new byte) is proven")
        c2.setDelta(delta)
        let v2Records = try await stream(c2)
        // Identical documents: the grown version gives exactly the records a full scan gives, old messages unchanged.
        let reference = try await stream(nil)
        func fp(_ ko: KnowledgeObject) -> String {
            ko.content + "\u{1}" + ko.metadata.filter { $0.key != EmailLoader.structuredEntitiesMetaKey }.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ";")
        }
        #expect(v2Records.count == oldCount + newCount)
        #expect(v2Records.map(fp) == reference.map(fp))
        #expect(Array(v2Records.prefix(oldCount)).map(\.content) == v1Records.map(\.content), "the old messages are the same documents")
        await PieceMaps.finish(database: db, sourceVersionID: v2, context: c2)
        #expect(try await count(db, "SELECT COUNT(*) FROM source_piece_maps WHERE logical_source_id = ?;", [.uuid(logical)]) == 2)

        // The index really is what the loader used inside the proven prefix: an index that (wrongly) joins messages 0 and 1
        // yields one record fewer, so those ranges were taken from it, not scanned again.
        let o = delta.previousRecordOffsets
        let doctored = PieceMap.Delta(previousVersionID: v1, unchangedPrefixBytes: delta.unchangedPrefixBytes, changedPieces: delta.changedPieces,
                                      appendedOnly: true, previousRecordOffsets: [o[0]] + Array(o.dropFirst(2)))
        let c3 = PieceMaps.Context()
        c3.setDelta(doctored)
        #expect(try await stream(c3).count == oldCount + newCount - 1)
    }
}

// MARK: - PERF-36 · priority pieces

private nonisolated final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Int] = []
    func add(_ i: Int) { lock.withLock { items.append(i) } }
    var all: [Int] { lock.withLock { items } }
}

@Suite("Speed PERF-36 torrent — priority pieces first", .serialized)
struct TorrentPriorityTests {

    @Test("The open case's files and the cited documents go first (stable: each group keeps its order); nothing is dropped; clearing restores the plain order")
    func filesAndSignals() throws {
        defer { PriorityPieces.clear() }
        let dir = try tempDir("prio")
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = (0..<6).map { dir.appendingPathComponent("f\($0).txt") }
        let caseID = UUID(), sv = UUID(), ko = UUID(), cited = UUID()
        PriorityPieces.setOpenCase(caseID, sourceVersions: [sv], objects: [ko], files: [files[4], files[2]])
        #expect(PriorityPieces.orderedFiles(files) == [files[2], files[4], files[0], files[1], files[3], files[5]])
        PriorityPieces.setQuestion(objects: [cited])
        #expect(PriorityPieces.isPriority(object: ko) && PriorityPieces.isPriority(object: cited) && PriorityPieces.isPriority(sourceVersion: sv))
        #expect(PriorityPieces.current.caseID == caseID)
        PriorityPieces.setOpenCase(nil)
        #expect(!PriorityPieces.isPriority(object: ko) && PriorityPieces.isPriority(object: cited), "closing the case keeps the question's documents")
        PriorityPieces.clear()
        #expect(PriorityPieces.orderedFiles(files) == files)
    }

    @Test("Work-stealing: priority indices are at the front of the workers' segments (one worker runs them first); every index runs exactly once")
    func workStealingPriority() async {
        let order = WorkStealingQueue.priorityOrder(count: 10, workers: 2, isPriority: { [7, 9, 8].contains($0) })
        #expect(Set(order) == Set(0..<10) && order.count == 10)
        // Two segments of 5: each starts with priority work.
        #expect([7, 9, 8].contains(order[0]) && [7, 9, 8].contains(order[5]))
        let seen = Recorder()
        _ = await WorkStealingQueue.map(count: 10, workers: 1, priority: { [7, 9].contains($0) }) { i in seen.add(i); return i }
        #expect(Array(seen.all.prefix(2)) == [7, 9] && seen.all.sorted() == Array(0..<10))
    }

    @Test("Drains: an enrichment job of the open case's / question's document is claimed before older jobs; the rest stay oldest first")
    func enrichmentClaimsPriorityFirst() async throws {
        defer { PriorityPieces.clear() }
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        let jobs = EnrichmentJobRepository(database: db)
        let subjects = (0..<4).map { _ in UUID() }
        for s in subjects {
            _ = try await jobs.enqueue(subjectID: s, kind: .typedFacts)
            try await Task.sleep(for: .milliseconds(5))   // distinct created_at
        }
        PriorityPieces.setQuestion(objects: [subjects[2]])
        var claimed: [UUID] = []
        while let j = try await jobs.claimNext(kind: .typedFacts) { claimed.append(j.subjectID) }
        #expect(claimed == [subjects[2], subjects[0], subjects[1], subjects[3]])
    }
}

// MARK: - PERF-37 · endgame

private nonisolated final class Attempts: @unchecked Sendable {
    private let lock = NSLock()
    private var byItem: [Int: Int] = [:]
    private var cancelledLosers = 0
    func next(_ i: Int) -> Int { lock.withLock { byItem[i, default: 0] += 1; return byItem[i]! } }
    func count(_ i: Int) -> Int { lock.withLock { byItem[i, default: 0] } }
    func loserCancelled() { lock.withLock { cancelledLosers += 1 } }
    var losers: Int { lock.withLock { cancelledLosers } }
}

@Suite("Speed PERF-37 torrent — endgame duplicates", .serialized)
struct TorrentEndgameTests {

    @Test("A stuck local item is duplicated on an idle worker: the first result wins, the loser is cancelled, the caller commits each item once (no duplicate ledger rows)")
    func firstResultWins() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        let cache = ContentResultCacheRepository(database: db)
        let attempts = Attempts()
        let started = ContinuousClock.now
        let results = await Endgame.map(Array(0..<4), local: true, width: { 4 }, minimumSeconds: 0.3) { i, _ -> String in
            let a = attempts.next(i)
            // Idempotent work (an upsert of the same value under the same key, as the content cache does).
            await cache.store(digest: "page-\(i)", kind: .ocr, producer: "endgame-test", payload: "[\"page \(i)\"]")
            if i == 2 && a == 1 {
                do { try await Task.sleep(for: .seconds(30)) } catch { attempts.loserCancelled() }
                return "slow-\(i)"
            }
            return "page-\(i)-attempt-\(a)"
        }
        let elapsed = ContinuousClock.now - started
        #expect(results == ["page-0-attempt-1", "page-1-attempt-1", "page-2-attempt-2", "page-3-attempt-1"])
        #expect(attempts.count(2) == 2 && [0, 1, 3].allSatisfy { attempts.count($0) == 1 }, "only the stuck item was duplicated, once")
        #expect(elapsed < .seconds(20), "the stuck attempt did not hold the run up (\(elapsed))")
        // The loser is cancelled (its sleep ends at once).
        for _ in 0..<50 where attempts.losers == 0 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(attempts.losers == 1)
        // The caller commits the winners once: one row per item.
        for (i, r) in results.enumerated() {
            try await db.exec("INSERT INTO workspaces (id, title, created_at, updated_at) VALUES (?,?,?,?);",
                              [.uuid(TeamSwarmIDs.uuid(from: "endgame-\(i)")), .text(r ?? ""), .real(1), .real(1)])
        }
        #expect(try await count(db, "SELECT COUNT(*) FROM workspaces WHERE title LIKE 'page-%';") == 4)
        #expect(try await count(db, "SELECT COUNT(*) FROM content_result_cache WHERE producer = 'endgame-test';") == 4,
                "the duplicate's idempotent write is the same row")
    }

    @Test("Not local (AI or network work): never duplicated, the slow item simply finishes")
    func notLocalNeverDuplicated() async {
        let attempts = Attempts()
        let results = await Endgame.map(Array(0..<3), local: false, width: { 3 }, minimumSeconds: 0.1) { i, _ -> Int in
            _ = attempts.next(i)
            if i == 1 { try? await Task.sleep(for: .milliseconds(900)) }
            return i * 10
        }
        #expect(results == [0, 10, 20])
        #expect((0..<3).allSatisfy { attempts.count($0) == 1 })
    }
}

// MARK: - PERF-38 · per-volume read lanes

@Suite("Speed PERF-38 torrent — per-disk read lanes", .serialized)
struct TorrentVolumeLaneTests {

    @Test("Files are grouped by disk and dealt round-robin, the faster disk first in each round, each disk keeping its own order")
    func interleavedByVolume() throws {
        let dir = try tempDir("lanes")
        defer { try? FileManager.default.removeItem(at: dir) }
        let local = (0..<3).map { dir.appendingPathComponent("local-\($0).txt") }
        for u in local { try Data("x".utf8).write(to: u) }
        // A disk that is not mounted: its own (offline) lane.
        let gone = (0..<2).map { URL(fileURLWithPath: "/Volumes/kalsmritikosh-no-such-disk-\(UUID().uuidString)/away-\($0).txt") }
        #expect(VolumeReadLanes.profile(for: gone[0]).kind == .offline)
        #expect(!VolumeReadLanes.isReachable(gone[0]) && VolumeReadLanes.isReachable(local[0]))
        let localKind = VolumeReadLanes.profile(for: local[0]).kind
        #expect(localKind != .offline)
        let mixed = [gone[0], local[0], gone[1], local[1], local[2]]
        let dealt = VolumeReadLanes.interleaved(mixed)
        #expect(dealt == [local[0], gone[0], local[1], gone[1], local[2]], "\(dealt.map(\.lastPathComponent))")
        // One disk only: the order is untouched.
        #expect(VolumeReadLanes.interleaved(local.reversed()) == local.reversed())
    }

    @Test("Each kind of disk starts at its own width and cap; one lane widens while bytes/s rises and chokes when it falls, without touching another lane")
    func independentWidths() async throws {
        func lane(_ kind: VolumeKind, _ key: String) -> VolumeLane { VolumeLane(profile: VolumeProfile(key: key, kind: kind, name: key), cores: 10) }
        let ssd = lane(.internalDisk, "ssd"), usb = lane(.removable, "usb"), net = lane(.network, "net"), dvd = lane(.optical, "dvd")
        #expect((ssd.limit, ssd.cap) == (5, 10))
        #expect((usb.limit, usb.cap) == (2, 4) && (net.limit, net.cap) == (2, 6) && (dvd.limit, dvd.cap) == (1, 2))
        // Window 1 on the USB lane (2 reads, fast): the first window always widens.
        await usb.acquire(); await usb.acquire()
        usb.release(bytes: 4 << 20); usb.release(bytes: 4 << 20)
        #expect(usb.limit == 3)
        // Window 2 (3 reads, slow and small): bytes/s fell by far more than a quarter → choke by one.
        for _ in 0..<3 { await usb.acquire() }
        try await Task.sleep(for: .milliseconds(300))
        for _ in 0..<3 { usb.release(bytes: 1) }
        #expect(usb.limit == 2)
        #expect(ssd.limit == 5 && net.limit == 2 && dvd.limit == 1, "the other lanes are unchanged")
        // A full lane makes the next read wait until a slot is given back.
        await dvd.acquire()
        let waited = OSAllocatedUnfairLock(initialState: false)
        let t = Task { await dvd.acquire(); waited.withLock { $0 = true }; dvd.release(bytes: nil) }
        try await Task.sleep(for: .milliseconds(150))
        #expect(!waited.withLock { $0 }, "a second read on a one-wide lane waits")
        dvd.release(bytes: nil)
        await t.value
        #expect(waited.withLock { $0 })
    }

    @Test("A nested read of the same disk runs on the slot already held (an archive's members inside the archive's read): no deadlock even past the lane's width")
    func nestedReadsReuseTheSlot() async throws {
        let dir = try tempDir("nested")
        defer { try? FileManager.default.removeItem(at: dir) }
        let u = dir.appendingPathComponent("archive.zip")
        try Data(repeating: 1, count: 1024).write(to: u)
        func nest(_ depth: Int) async -> Int {
            await VolumeReadLanes.withRead(u) { depth == 0 ? 0 : 1 + (await nest(depth - 1)) }
        }
        let depth = VolumeReadLanes.lane(for: u).cap + 4
        #expect(await nest(depth) == depth)
    }
}

// MARK: - PERF-39 · fastest verified copy

@Suite("Speed PERF-39 torrent — fastest verified copy", .serialized)
struct TorrentFastestCopyTests {

    struct Rig { let db: Database; let vault: EvidenceVault; let intake: UniversalSourceIntakeCoordinator; let resolver: SourceVersionByteResolver; let dir: URL }

    static func rig() async throws -> Rig {
        let dir = try tempDir("fastest")
        let db = try Database(url: dir.appendingPathComponent("db.sqlite"))
        try await SchemaMigrations.migrate(db); try await db.exec("PRAGMA foreign_keys = ON;")
        let vault = EvidenceVault(root: dir.appendingPathComponent("vault", isDirectory: true))
        let intake = UniversalSourceIntakeCoordinator(repository: CanonicalSourceIntakeRepository(database: db, vault: vault))
        return Rig(db: db, vault: vault, intake: intake, resolver: SourceVersionByteResolver(database: db, vault: vault), dir: dir)
    }

    @Test("Order: the vault first when the original is missing or on an unplugged disk; on the same disk the original first only for a sealed vault copy or a referenced version")
    func order() async throws {
        let r = try await Self.rig()
        defer { try? FileManager.default.removeItem(at: r.dir) }
        let root = r.vault.rootURL
        #expect(FastestCopy.vaultFirst(original: nil, vaultRoot: root, vaultSealed: false, preferOriginalOnTie: true))
        let unplugged = URL(fileURLWithPath: "/Volumes/kalsmritikosh-unplugged-\(UUID().uuidString)/a.pdf")
        #expect(FastestCopy.vaultFirst(original: unplugged, vaultRoot: root, vaultSealed: true, preferOriginalOnTie: true))
        let here = r.dir.appendingPathComponent("here.txt")
        try Data("x".utf8).write(to: here)
        #expect(FastestCopy.vaultFirst(original: here, vaultRoot: root, vaultSealed: false, preferOriginalOnTie: false))
        #expect(!FastestCopy.vaultFirst(original: here, vaultRoot: root, vaultSealed: true, preferOriginalOnTie: false))
        #expect(!FastestCopy.vaultFirst(original: here, vaultRoot: root, vaultSealed: false, preferOriginalOnTie: true))
        // Only copies that exist are candidates.
        let hash = try await r.vault.store(Data("kept bytes".utf8))
        #expect(await FastestCopy.order(original: unplugged, vault: r.vault, address: hash, preferOriginalOnTie: true) == [.vault])
        #expect(await FastestCopy.order(original: here, vault: r.vault, address: String(repeating: "0", count: 64), preferOriginalOnTie: true) == [.original])
    }

    @Test("Every copy is hashed: the vault copy is used when the original is missing or changed; a copy whose SHA-256 does not match is never used")
    func verifiedCopies() async throws {
        let r = try await Self.rig()
        defer { try? FileManager.default.removeItem(at: r.dir) }
        let bytes = Data("the exact bytes the version recorded".utf8)
        let want = sha256(bytes)
        let original = r.dir.appendingPathComponent("statement.txt")
        try bytes.write(to: original)
        let address = try await r.vault.store(bytes)
        #expect(address.lowercased() == want)
        // Original changed on disk (same disk, the original would be tried first): rejected, the vault copy is used.
        try Data("someone edited the file afterwards".utf8).write(to: original)
        let got = try #require(await FastestCopy.verifiedURL(expectedSHA256: want, original: original, vault: r.vault, address: address,
                                                             filename: "statement.txt", preferOriginalOnTie: true))
        let gotBytes = try Data(contentsOf: got.url)
        #expect(got.origin == .vault && gotBytes == bytes)
        // Original gone: the vault copy.
        try FileManager.default.removeItem(at: original)
        #expect(await FastestCopy.verifiedURL(expectedSHA256: want, original: original, vault: r.vault, address: address,
                                              filename: nil, preferOriginalOnTie: true)?.origin == .vault)
        // The vault copy damaged too: nothing is substituted.
        let blob = try #require(await r.vault.url(for: address))
        try FileManager.default.removeItem(at: blob)
        try Data("damaged".utf8).write(to: blob)
        #expect(await FastestCopy.verifiedURL(expectedSHA256: want, original: original, vault: r.vault, address: address,
                                              filename: nil, preferOriginalOnTie: true) == nil)
        // A fingerprint that is not a SHA-256 is refused outright.
        #expect(await FastestCopy.verifiedURL(expectedSHA256: "abc", original: original, vault: r.vault, address: address,
                                              filename: nil, preferOriginalOnTie: true) == nil)
    }

    @Test("Reopen for upgrade/re-extraction: a managed version whose original changed reopens from the vault (recorded bytes); a referenced version whose bytes the vault also keeps reopens from the vault when its original changed; both copies wrong → hash mismatch")
    func resolverUsesTheVerifiedCopy() async throws {
        let r = try await Self.rig()
        defer { try? FileManager.default.removeItem(at: r.dir) }
        let bytes = Data("managed version bytes — synthetic".utf8)
        let url = r.dir.appendingPathComponent("m.txt")
        try bytes.write(to: url)
        let managed = try await r.intake.admit(url: url, custodyMode: .managed, now: Date())
        try Data("the original was edited later".utf8).write(to: url)
        let resolved = try await r.resolver.resolve(sourceVersionID: managed.sourceVersionID, at: Date())
        defer { try? FileManager.default.removeItem(at: resolved.cleanupDirectory) }
        #expect((try Data(contentsOf: resolved.snapshotURL)) == bytes)
        // A referenced version of the same bytes (another file): its original changed, the vault still holds the bytes.
        let other = r.dir.appendingPathComponent("r.txt")
        try bytes.write(to: other)
        let referenced = try await r.intake.admit(url: other, custodyMode: .referenced, now: Date())
        try Data("changed too".utf8).write(to: other)
        let viaVault = try await r.resolver.resolve(sourceVersionID: referenced.sourceVersionID, at: Date())
        defer { try? FileManager.default.removeItem(at: viaVault.cleanupDirectory) }
        #expect((try Data(contentsOf: viaVault.snapshotURL)) == bytes)
        // The vault copy damaged as well: the managed version is a hash mismatch, nothing substituted.
        let blob = try #require(await r.vault.url(for: managed.contentHash))
        try FileManager.default.removeItem(at: blob)
        try Data("damaged vault copy".utf8).write(to: blob)
        await #expect(throws: SourceUpgradeError.hashMismatch(managed.sourceVersionID)) {
            _ = try await r.resolver.resolve(sourceVersionID: managed.sourceVersionID, at: Date())
        }
    }
}

// MARK: - PERF-40 · team swarm (two simulated Macs)

@MainActor
@Suite("Speed PERF-40 torrent — team swarm over the shared folder (two simulated Macs)", .serialized)
struct TorrentSwarmTests {

    /// One simulated Mac: its own ledger and case (CaseTeamFolderTests.Mac), its own signing key and its own key-agreement key.
    struct SwarmMac {
        let mac: CaseTeamFolderTests.Mac
        let agreement = Curve25519.KeyAgreement.PrivateKey()
        let vault: EvidenceVault
        let name: String
        let actor = "Ada"   // the case owner on each simulated ledger (the fixture's case is Ada's)
        var caseID: UUID { mac.f.caseID }
        var db: Database { mac.f.db }

        static func make(_ name: String, dir: URL) async throws -> SwarmMac {
            let mac = try await CaseTeamFolderTests.Mac.make("Was the supplier paid twice? (\(name))")
            return SwarmMac(mac: mac, vault: EvidenceVault(root: dir.appendingPathComponent("vault-\(name)", isDirectory: true)), name: name)
        }

        func context(_ link: CaseTeamLink) async -> TeamSwarmContext {
            TeamSwarmContext(caseID: caseID, link: link, actor: actor, file: mac.f.file, main: db, ledgerURL: await db.url, vault: vault,
                             chunker: Chunker(), embedding: nil, intake: mac.intake, control: IngestControl())
        }
    }

    @Test("Two Macs, one team folder: per-case opt-in announced to every member; a signed manifest of files inside the folder; claims (oldest valid wins, the loser leaves at once, an expired claim is taken again, an endgame duplicate when every piece is claimed); each piece published encrypted for the members and signed; every Mac merges each piece once and both ledgers end with the same documents; a non-member cannot open a piece; a case erasure removes this Mac's swarm files and rows")
    func twoMacSwarm() async throws {
        let root = try tempDir("swarm")
        defer { try? FileManager.default.removeItem(at: root) }
        let ada = try await SwarmMac.make("Ada", dir: root), ben = try await SwarmMac.make("Ben", dir: root)
        let folderURL = root.appendingPathComponent("Shared import", isDirectory: true)
        let linkA = try await ada.mac.team.linkFolder(caseID: ada.caseID, folder: folderURL, create: true, name: "Shared import", purpose: .team,
                                                      displayName: "Ada", key: ada.mac.key, actor: "Ada")
        let linkB = try await ben.mac.team.linkFolder(caseID: ben.caseID, folder: folderURL, create: false, name: "Shared import", purpose: .team,
                                                      displayName: "Ben", key: ben.mac.key, actor: ben.actor)
        let la = try #require(try await ada.mac.f.file.teamLinks(caseID: ada.caseID).first { $0.id == linkA })
        let lb = try #require(try await ben.mac.f.file.teamLinks(caseID: ben.caseID).first { $0.id == linkB })
        let folder = try #require(TeamCase.open(folderURL))
        let teamCaseID = try #require(folder.teamCaseID)

        // 1. Opt-in per case, announced (signed) so every member sees who shares.
        for (m, l) in [(ada, la), (ben, lb)] {
            try await m.mac.f.file.setSwarmOptIn(caseID: m.caseID, linkID: l.id, enabled: true, actor: m.actor)
            try folder.publishAgreementKey(member: l.memberID, signing: m.mac.key, agreement: m.agreement)
            try folder.announceOptIn(caseLabel: l.folderLabel, on: true, member: l.memberID, key: m.mac.key)
            try await m.mac.f.file.markSwarmOptInAnnounced(caseID: m.caseID, linkID: l.id)
            #expect(try await m.mac.f.file.swarmOptIn(caseID: m.caseID, linkID: l.id)?.announced == true)
        }
        let optIns = folder.optIns(in: folder.verifiedEntries().entries)
        #expect(Set(optIns.filter(\.on).map(\.name)) == ["Ada", "Ben"])
        #expect(Set(folder.verifiedAgreementKeys().keys) == [la.memberID, lb.memberID])

        // 2. The shared files (already in the team folder) and the manifest.
        let evidence = folderURL.appendingPathComponent("evidence", isDirectory: true)
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        let texts = ["Invoice INV-2041 from Dalmia Traders for INR 10,000, dated 3 March 2024.",
                     "Bank statement 7718: 5 March 2024 debit INR 10,000 to Dalmia Traders, ref INV-2041.",
                     "Bank statement 7718: 9 March 2024 debit INR 10,000 to Dalmia Traders, ref INV-2041 again.",
                     "Email from Ravi to Ada on 10 March 2024: the supplier says it was paid once only."]
        var files: [URL] = []
        for (i, t) in texts.enumerated() {
            let u = evidence.appendingPathComponent("doc-\(i).txt")
            try Data(t.utf8).write(to: u)
            files.append(u)
        }
        let outside = root.appendingPathComponent("outside.txt")
        try Data("not in the folder".utf8).write(to: outside)
        #expect(throws: TeamSwarmError.notInFolder("outside.txt")) {
            _ = try folder.publishSwarm(id: "x", title: "x", pieces: [[outside]], member: la.memberID, key: ada.mac.key)
        }
        let swarmID = UUID().uuidString
        let note = try folder.publishSwarm(id: swarmID, title: "March statements", pieces: [[files[0], files[1]], [files[2], files[3]]],
                                           member: la.memberID, key: ada.mac.key)
        #expect(note.pieces == 2 && note.files == 4)
        let seen = folder.swarms(in: folder.verifiedEntries().entries)
        let s = try #require(seen.first { $0.note.id == swarmID })
        #expect(s.author == la.memberID && s.manifest.pieces.flatMap(\.files).allSatisfy { $0.path.hasPrefix("evidence/") })
        #expect(s.manifest.pieces.flatMap(\.files).map(\.sha256) == texts.map { sha256(Data($0.utf8)) })
        // A manifest changed after it was announced is not trusted.
        let manifestData = try Data(contentsOf: folder.swarmManifestURL(swarmID))
        try (manifestData + Data(" ".utf8)).write(to: folder.swarmManifestURL(swarmID))
        #expect(!folder.swarms(in: folder.verifiedEntries().entries).contains { $0.note.id == swarmID })
        try manifestData.write(to: folder.swarmManifestURL(swarmID))
        for (m, l) in [(ada, la), (ben, lb)] {
            try await m.mac.f.file.noteSwarm(caseID: m.caseID, linkID: l.id, id: swarmID, title: note.title, authoredHere: m.name == "Ada",
                                             authorMember: la.memberID, pieces: note.pieces, files: note.files, manifestSHA256: note.manifestSHA256)
        }

        // 3. Claims.
        let t0 = Date()
        #expect(folder.claim(swarmID: swarmID, piece: 0, member: la.memberID, key: ada.mac.key, now: t0))
        #expect(!folder.claim(swarmID: swarmID, piece: 0, member: lb.memberID, key: ben.mac.key, now: t0.addingTimeInterval(1)),
                "the oldest valid claim wins")
        #expect(folder.validClaims(swarmID: swarmID, piece: 0, now: t0.addingTimeInterval(2)).map(\.member) == [la.memberID],
                "the losing claim was removed at once")
        #expect(folder.claim(swarmID: swarmID, piece: 1, member: lb.memberID, key: ben.mac.key, now: t0.addingTimeInterval(2)))
        // An expired claim (a Mac that went away) does not hold a piece: after 30 minutes it is claimed again.
        #expect(folder.claim(swarmID: swarmID, piece: 9, member: la.memberID, key: ada.mac.key, now: t0))
        #expect(folder.claim(swarmID: swarmID, piece: 9, member: lb.memberID, key: ben.mac.key, now: t0.addingTimeInterval(31 * 60)))
        // A forged claim (signed with another key) is not valid.
        var forged = TeamSwarmClaim(swarmID: swarmID, piece: 8, member: la.memberID, claimedAt: t0.timeIntervalSince1970,
                                    expires: t0.timeIntervalSince1970 + 600, duplicate: false)
        forged.sig = try Curve25519.Signing.PrivateKey().signature(for: forged.canonical).base64EncodedString()
        try FileManager.default.createDirectory(at: folder.swarmClaimsDir(swarmID, piece: 8), withIntermediateDirectories: true)
        try JSONEncoder().encode(forged).write(to: folder.swarmClaimsDir(swarmID, piece: 8).appendingPathComponent("\(la.memberID).json"))
        #expect(folder.validClaims(swarmID: swarmID, piece: 8, now: t0).isEmpty)
        // Endgame: every piece claimed and at most two left → a free Mac takes ONE duplicate of a piece claimed by another.
        let next = try #require(AppState.nextPiece(s.manifest, notes: [:], published: [], folder: folder, me: la.memberID))
        #expect(next.0.index == 1 && next.1 == true)

        // 4. Each Mac reads its piece into a partial ledger and publishes it encrypted and signed.
        let ctxA = await ada.context(la), ctxB = await ben.context(lb)
        let shardA = try await AppState.processPiece(ctxA, folder: folder, key: ada.mac.key, teamCaseID: teamCaseID, swarmID: swarmID, piece: s.manifest.pieces[0])
        let shardB = try await AppState.processPiece(ctxB, folder: folder, key: ben.mac.key, teamCaseID: teamCaseID, swarmID: swarmID, piece: s.manifest.pieces[1])
        #expect(shardA.files == 2 && shardB.files == 2)
        for n in [shardA, shardB] {
            let published = folder.swarmShardsDir(swarmID).appendingPathComponent(n.file)
            let head = try FileHandle(forReadingFrom: published).readData(ofLength: 16)
            #expect(head != Data("SQLite format 3\u{0}".utf8), "a published piece is encrypted")
            let envelopes = try JSONDecoder().decode([String: SimulatedSharedCaseVault.WrappedKey].self,
                                                     from: Data(contentsOf: folder.swarmShardsDir(swarmID).appendingPathComponent(n.keysFile)))
            #expect(Set(envelopes.keys) == [la.memberID, lb.memberID], "its key is wrapped for every member")
        }
        let entries = folder.verifiedEntries().entries
        let notes = folder.shardNotes(swarmID: swarmID, in: entries)
        #expect(notes[0]?.first?.member == la.memberID && notes[1]?.first?.member == lb.memberID, "announced in each author's signed log")
        #expect(AppState.nextPiece(s.manifest, notes: notes, published: [], folder: folder, me: la.memberID) == nil, "nothing left to take")

        // 5. A non-member cannot open a piece: no envelope for it, and another member's envelope does not open with its key.
        let outsider = Curve25519.KeyAgreement.PrivateKey()
        let inbox = try tempDir("outsider")
        defer { try? FileManager.default.removeItem(at: inbox) }
        let winnerA = try #require(notes[0]?.first?.value)
        #expect(throws: TeamSwarmError.noEnvelope) {
            _ = try folder.fetchShard(winnerA, teamCaseID: teamCaseID, member: "outsider", agreement: outsider, into: inbox)
        }
        #expect(throws: (any Error).self) {
            _ = try folder.fetchShard(winnerA, teamCaseID: teamCaseID, member: lb.memberID, agreement: outsider, into: inbox)
        }

        // 6. Merge: every Mac joins each published piece once (its own piece too).
        var problems: [String] = []
        let mergedA = await AppState.mergePublished(ctxA, folder: folder, swarm: s.manifest, title: note.title, notes: notes, teamCaseID: teamCaseID,
                                                    agreement: ada.agreement, problems: &problems)
        let mergedB = await AppState.mergePublished(ctxB, folder: folder, swarm: s.manifest, title: note.title, notes: notes, teamCaseID: teamCaseID,
                                                    agreement: ben.agreement, problems: &problems)
        #expect(mergedA == 2 && mergedB == 2 && problems.isEmpty, "\(problems)")
        let hashes = texts.map { sha256(Data($0.utf8)) }
        let hashJSON = String(decoding: try JSONSerialization.data(withJSONObject: hashes), as: UTF8.self)
        func documents(_ db: Database) async throws -> Set<String> {
            Set(try await db.query("SELECT DISTINCT lower(content_hash) FROM source_versions WHERE lower(content_hash) IN (SELECT value FROM json_each(?));",
                                   [.text(hashJSON)]).compactMap { $0.string(0) })
        }
        let docsA = try await documents(ada.db), docsB = try await documents(ben.db)
        #expect(docsA == Set(hashes) && docsB == docsA, "both ledgers hold the same four documents")
        func rows(_ db: Database) async throws -> [Int] {
            [try await count(db, "SELECT COUNT(*) FROM source_versions;"), try await count(db, "SELECT COUNT(*) FROM knowledge_objects;"),
             try await count(db, "SELECT COUNT(*) FROM chunks;")]
        }
        let before = (try await rows(ada.db), try await rows(ben.db))
        // Merge once per Mac: a second pass joins nothing and adds no rows.
        let againA = await AppState.mergePublished(ctxA, folder: folder, swarm: s.manifest, title: note.title, notes: notes, teamCaseID: teamCaseID,
                                                   agreement: ada.agreement, problems: &problems)
        let againB = await AppState.mergePublished(ctxB, folder: folder, swarm: s.manifest, title: note.title, notes: notes, teamCaseID: teamCaseID,
                                                   agreement: ben.agreement, problems: &problems)
        #expect(againA == 0 && againB == 0)
        let afterA = try await rows(ada.db), afterB = try await rows(ben.db)
        #expect(afterA == before.0 && afterB == before.1)
        #expect(try await ada.mac.f.file.mergedSwarmPieces(swarmID: swarmID) == [0, 1])
        let progress = try #require(try await ben.mac.f.file.swarmProgress(caseID: ben.caseID).first)
        #expect(progress.merged == 2 && progress.doneByMe == 1 && progress.doneByOthers == 1, "\(progress.line)")

        // 7. Case erasure on Ada's Mac: its swarm files leave the folder (the manifest too: it started the swarm); Ben's stay.
        let footprint = try await ada.mac.f.file.swarmFootprint(caseID: ada.caseID)
        #expect(footprint.count == 1 && footprint[0].swarms == [swarmID] && footprint[0].authored == [swarmID])
        let residue = folder.eraseSwarmFiles(swarmIDs: footprint[0].swarms, authored: footprint[0].authored, member: la.memberID, key: ada.mac.key)
        #expect(residue.isEmpty)
        let shardFiles = try FileManager.default.contentsOfDirectory(atPath: folder.swarmShardsDir(swarmID).path)
        #expect(!shardFiles.contains { $0.contains(".\(la.memberID).") } && shardFiles.contains { $0.contains(".\(lb.memberID).") })
        #expect(!FileManager.default.fileExists(atPath: folder.swarmClaimsDir(swarmID, piece: 0).appendingPathComponent("\(la.memberID).json").path))
        #expect(FileManager.default.fileExists(atPath: folder.swarmClaimsDir(swarmID, piece: 1).appendingPathComponent("\(lb.memberID).json").path))
        #expect(!FileManager.default.fileExists(atPath: folder.swarmManifestURL(swarmID).path))
        #expect(folder.hasEntry(member: la.memberID, action: "swarm.erased", objectRef: swarmID))
        let report = try await CaseEraser(database: ada.db).erase(caseID: ada.caseID, sourceVersionIDs: [], eraseExclusiveSources: false,
                                                                  reason: "Client request", legalBasis: nil, actor: "Ada")
        #expect(report.refused == nil, "\(report.refused ?? "")")
        for t in ["case_team_swarm_optins", "case_team_swarms", "case_team_swarm_pieces"] {
            #expect(try await count(ada.db, "SELECT COUNT(*) FROM \(t) WHERE upper(case_id) = upper(?);", [.uuid(ada.caseID)]) == 0, "\(t) kept rows")
        }
        #expect(try await count(ben.db, "SELECT COUNT(*) FROM case_team_swarm_pieces WHERE case_id = ?;", [.uuid(ben.caseID)]) == 2,
                "the other Mac's ledger is untouched")
    }
}

// MARK: - Fix PERF-28 · every vector carries the embedder that made it

/// An embedding provider that fails its first `failFirst` calls (or always), then answers with `dims`-size vectors.
nonisolated final class ScriptedEmbeddingProvider: ModelProvider, @unchecked Sendable {
    let id = "provider.test.embed.\(UUID().uuidString)"
    let capabilities: Set<ModelCapability> = [.embedding]
    let manifest: ModelManifest
    private let lock = NSLock()
    private var calls = 0
    private var failFirst: Int
    let dims: Int
    init(dims: Int, failFirst: Int) {
        self.dims = dims; self.failFirst = failFirst
        manifest = ModelManifest(id: id, displayName: "Scripted embedder", capabilities: [.embedding], privacyLevel: .onDevice)
    }
    var callCount: Int { lock.withLock { calls } }
    func setFailFirst(_ n: Int) { lock.withLock { failFirst = n; calls = 0 } }
    func isAvailable() async -> Bool { true }
    func generate(prompt: String, options: GenerationOptions) async throws -> String { throw ModelProviderError.unavailable(providerID: id) }
    func embed(text: String) async throws -> [Float] { try await embedBatch(texts: [text]).first ?? [] }
    func embedBatch(texts: [String]) async throws -> [[Float]] {
        let fail: Bool = lock.withLock { calls += 1; return calls <= failFirst }
        if fail { throw ModelProviderError.unavailable(providerID: id) }
        return texts.map { t in (0..<dims).map { Float(($0 + t.count) % 7) + 1 } }
    }
}

@Suite("Fix PERF-28 — embedder labels: one embedder per label, no silent fallback", .serialized)
struct EmbedderLabelTests {

    static func registry(_ p: ScriptedEmbeddingProvider) async -> CapabilityRegistry {
        let hw = HardwareProfile(totalRAMBytes: 16 * 1_073_741_824, availableRAMBytes: 8 * 1_073_741_824,
                                 processorCount: 8, isAppleSilicon: true, chipName: "P28Chip-\(UUID().uuidString)", hasNeuralEngine: true)
        let r = CapabilityRegistry(hardware: hw, benchmark: PerformanceBenchmark(hardwareProfile: hw))
        await r.register(p)
        return r
    }

    @Test("A transient failure is retried with back-off (never the fallback): the vectors carry the primary's label and size")
    func transientRetried() async {
        let p = ScriptedEmbeddingProvider(dims: 8, failFirst: 2)
        let e = CapabilityResolvedEmbedder(capabilities: await Self.registry(p), primary: EmbeddingProducer(id: p.id, dimension: 8),
                                           batchTimeouts: [5, 5, 5], backoffBase: .milliseconds(1))
        let r = await e.embedBatchLabelled(["Invoice 2041", "Payment to Dalmia"])
        #expect(p.callCount == 3, "two failures, then the answer")
        #expect(!r.transientFailure && r.vectors.allSatisfy { $0.count == 8 })
        #expect(r.producers.allSatisfy { $0 == EmbeddingProducer(id: p.id, dimension: 8) })
        #expect(await e.state == .healthy)
    }

    @Test("Failing calls: first 'waiting' (nothing produced, retried later, a health line), then — genuinely unavailable — the fallback's vectors under the FALLBACK's label with a 'degraded' line; when the primary answers again it is healthy and the recovery epoch moves (deferred passages re-embedded)")
    func degradedIsRecorded() async {
        let p = ScriptedEmbeddingProvider(dims: 8, failFirst: .max)
        let primary = EmbeddingProducer(id: p.id, dimension: 8)
        let e = CapabilityResolvedEmbedder(capabilities: await Self.registry(p), primary: primary,
                                           batchTimeouts: [5], unavailableAfter: 2, reprobeSeconds: 0, backoffBase: .milliseconds(1))
        let first = await e.embedBatchLabelled(["Statement 7718"])
        #expect(first.transientFailure && first.vectors == [[]] && first.producers == [nil])
        guard case .retrying = await e.state else { Issue.record("expected retrying"); return }
        #expect(EmbeddingHealth.line(for: await e.state)?.contains("Nothing was stored with another embedder") == true)
        let second = await e.embedBatchLabelled(["Statement 7718"])
        #expect(!second.transientFailure)
        for (v, prod) in zip(second.vectors, second.producers) where !v.isEmpty {
            #expect(prod?.id == CapabilityResolvedEmbedder.fallbackProducerID && prod?.dimension == v.count && prod != primary)
        }
        guard case .degraded(let pid, let fid, _, _) = await e.state else { Issue.record("expected degraded"); return }
        #expect(pid == p.id && fid == CapabilityResolvedEmbedder.fallbackProducerID)
        #expect(EmbeddingHealth.line(for: await e.state)?.contains("degraded") == true)
        let epoch = EmbeddingHealth.recoveryEpoch
        p.setFailFirst(0)
        let back = await e.embedBatchLabelled(["Statement 7718"])
        #expect(back.producers == [primary] && back.vectors.first?.count == 8)
        #expect(await e.state == .healthy && EmbeddingHealth.recoveryEpoch > epoch)
    }

    @Test("The cache keys every vector by its producer: a fallback vector is never served for the primary")
    func cacheKeyedByProducer() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        let p = ScriptedEmbeddingProvider(dims: 8, failFirst: .max)
        let primary = EmbeddingProducer(id: p.id, dimension: 8)
        let inner = CapabilityResolvedEmbedder(capabilities: await Self.registry(p), primary: primary,
                                               batchTimeouts: [5], unavailableAfter: 1, reprobeSeconds: 3_600, backoffBase: .milliseconds(1))
        let cache = CachedEmbedder(wrapping: inner, persistent: EmbeddingCacheRepository(database: db), modelID: "legacy")
        let degraded = await cache.embedBatchLabelled(["Invoice 2041"])
        let fallbackVector = try #require(degraded.vectors.first)
        // The primary is back (a new embedder over the same ledger: the persistent cache only).
        p.setFailFirst(0)
        let healthy = CapabilityResolvedEmbedder(capabilities: await Self.registry(p), primary: primary)
        let again = CachedEmbedder(wrapping: healthy, persistent: EmbeddingCacheRepository(database: db), modelID: "legacy")
        let r = await again.embedBatchLabelled(["Invoice 2041"])
        #expect(r.producers == [primary] && r.vectors.first?.count == 8)
        #expect(fallbackVector.isEmpty || r.vectors.first != fallbackVector)
        #expect(p.callCount == 1, "the primary really embedded it (the fallback's kept vector was not served)")
    }

    @Test("The store: a vector goes under the embedder that made it; one of another size is refused; a query of another size is never compared; the index and DocumentSimilarity read one embedder's vectors; the repair moves mislabeled vectors to their real label (chunks kept) so they are re-embedded")
    func storeKeepsOneEmbedderPerLabel() async throws {
        let dir = try ParityFixture.tempFolder("p28")
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try await ParityFixture.database(in: dir)
        let doc = try await ParityFixture.document(db, name: "a", text: "one\n\ntwo\n\nthree\n\nfour\n\nfive")
        let c = doc.chunks
        let primary = EmbeddingProducer(id: "bge-small.v1", dimension: 8)
        let fallback = EmbeddingProducer(id: CapabilityResolvedEmbedder.fallbackProducerID, dimension: 5)
        let store = SQLiteVectorStore(database: db, modelID: primary.id, dimension: 8)
        let v8 = ParityFixture.vector(axis: 1), v5 = [Float](repeating: 0.3, count: 5)
        let w = try await store.upsertBatchLabelled([
            LabelledVector(chunkID: c[0], embedding: v8, producer: primary),
            LabelledVector(chunkID: c[1], embedding: v8, producer: nil),
            LabelledVector(chunkID: c[2], embedding: v5, producer: fallback),
            LabelledVector(chunkID: c[3], embedding: v5, producer: primary),     // size is not its producer's
            LabelledVector(chunkID: c[4], embedding: v5, producer: nil),         // size is not the label's
        ])
        #expect(Set(w.active) == [c[0], c[1]] && w.other == [c[2]] && Set(w.refused) == [c[3], c[4]])
        #expect(try await count(db, "SELECT COUNT(*) FROM chunk_embeddings WHERE model_id = ? AND chunk_id = ?;", [.text(fallback.id), .uuid(c[2])]) == 1)
        #expect(try await store.count() == 2)
        #expect(try await store.nearest(to: v5, limit: 5, candidateChunkIDs: nil).isEmpty, "a 5-d query is not compared with 8-d vectors")
        #expect(try await store.nearest(to: v8, limit: 5, candidateChunkIDs: nil).count == 2)

        // An older build's mislabeled row: a 5-d vector under the 8-d label.
        try await ParityFixture.embed(db, chunk: c[3], v5, model: primary.id)
        #expect(try await store.mislabeledCount() == 1)
        #expect(try await store.count() == 2)
        let ann = ANNIndexRepository(database: db, dimension: 8)
        #expect(try await ann.embeddingCount(for: primary.id) == 2)
        #expect(try await ann.embeddingPage(for: primary.id, afterRowid: 0, limit: 100).count == 2, "the index sees every vector of its embedder, no other")
        #expect(try await ann.embeddingsMissingPostings(for: primary.id, limit: 100).count == 2)
        let sim = DocumentSimilarity(database: db, modelID: primary.id, dimension: 8)
        #expect(try await sim.vector(for: doc.id)?.count == 8, "the document mean is taken over one embedder's vectors")

        let moved = try await store.removeMislabeledVectors(relabelTo: fallback)
        let left = try await store.mislabeledCount()
        #expect(moved == 1 && left == 0)
        #expect(try await count(db, "SELECT COUNT(*) FROM chunk_embeddings WHERE model_id = ? AND chunk_id = ?;", [.text(fallback.id), .uuid(c[3])]) == 1)
        #expect(try await count(db, "SELECT COUNT(*) FROM chunks WHERE object_id = ?;", [.uuid(doc.id)]) == 5, "chunks never deleted")
        let pending = try await ChunksRepository(database: db).findChunksMissingVector(inObjects: [doc.id], limit: 10, modelID: primary.id, excluding: [])
        #expect(Set(pending.map(\.id)) == [c[2], c[3], c[4]], "the drain re-embeds them with the primary")
    }
}
