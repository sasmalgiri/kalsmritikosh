//
//  SyncTests.swift
//  KalsmritikoshTests
//
//  X-5 sync through a folder (crypto, store, two- and three-device runs on one temp folder)
//  and X-6 the replay the iPhone/iPad app reads.
//

import Foundation
import CryptoKit
import Testing
@testable import Kalsmritikosh

@Suite("X-5 Sync core: keys, sealing, signatures, store")
struct SyncCoreTests {
    @Test("A store opens with its passphrase only; the check refuses any other")
    func passphrase() throws {
        let root = try ParityFixture.tempFolder("store")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SyncStore.create(at: root, passphrase: "correct horse", rounds: 1_000)
        #expect(throws: SyncStore.Failure.alreadyAStore) { _ = try SyncStore.create(at: root, passphrase: "x", rounds: 1_000) }
        let again = try SyncStore.open(at: root, passphrase: "correct horse")
        #expect(again.info.storeID == store.info.storeID)
        #expect(throws: SyncCrypto.Failure.wrongPassphrase) { _ = try SyncStore.open(at: root, passphrase: "wrong") }
        #expect(throws: SyncCrypto.Failure.emptyPassphrase) { _ = try SyncStore.create(at: try ParityFixture.tempFolder("e"), passphrase: "", rounds: 1_000) }
        _ = try SyncStore.open(at: root, key: store.key)
        #expect(throws: SyncStore.Failure.notAStore) { _ = try SyncStore.open(at: try ParityFixture.tempFolder("n"), passphrase: "x") }
    }

    @Test("Blobs are sealed, content-addressed and verified")
    func blobs() throws {
        let root = try ParityFixture.tempFolder("store")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SyncStore.create(at: root, passphrase: "p", rounds: 1_000)
        let data = Data("contract text".utf8)
        let sha = try store.putBlob(data)
        #expect(sha == SyncCrypto.sha256Hex(data))
        #expect(try store.putBlob(data) == sha)                     // same bytes, same file
        #expect(try store.blob(sha) == data)
        let file = root.appendingPathComponent("blobs/\(sha).kblob")
        #expect(try Data(contentsOf: file).range(of: data) == nil)   // not stored in the clear
        var sealed = try Data(contentsOf: file)
        sealed[sealed.count - 1] ^= 0xFF
        try sealed.write(to: file)
        #expect(throws: SyncCrypto.Failure.unreadable) { _ = try store.blob(sha) }
    }

    @Test("A batch must be signed by its registered device and open under the store key")
    func batches() throws {
        let root = try ParityFixture.tempFolder("store")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SyncStore.create(at: root, passphrase: "p", rounds: 1_000)
        let key = Curve25519.Signing.PrivateKey()
        let batch = SyncBatch(device: "dev-a", seq: 1, createdAt: Date(), ops: [], files: [])
        #expect(throws: SyncStore.Failure.unknownDevice("dev-a")) {
            try store.write(batch, signingKey: key); _ = try store.readBatch(device: "dev-a", seq: 1)
        }
        try store.register(SyncDeviceInfo(id: "dev-a", name: "A", publicKey: key.publicKey.rawRepresentation.base64EncodedString(), platform: "test"))
        #expect(try store.readBatch(device: "dev-a", seq: 1).device == "dev-a")
        #expect(throws: SyncStore.Failure.batchExists(1)) { try store.write(batch, signingKey: key) }
        // Signed by someone else.
        try store.write(SyncBatch(device: "dev-a", seq: 2, createdAt: Date(), ops: [], files: []), signingKey: Curve25519.Signing.PrivateKey())
        #expect(throws: SyncCrypto.Failure.badSignature) { _ = try store.readBatch(device: "dev-a", seq: 2) }
        #expect(store.batchNumbers(of: "dev-a") == [1, 2])
        #expect(SyncFormat.seq(fromBatchName: SyncFormat.batchName(42)) == 42)
        #expect(SyncFormat.seq(fromBatchName: ".tmp-x") == nil)
    }

    @Test("A store written by a newer format is refused with a sentence")
    func newerFormat() throws {
        let root = try ParityFixture.tempFolder("store")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SyncStore.create(at: root, passphrase: "p", rounds: 1_000)
        var info = store.info
        info.format = SyncFormat.version + 1
        try SyncStore.encoder.encode(info).write(to: root.appendingPathComponent(SyncFormat.storeFile))
        #expect(throws: SyncStore.Failure.newerFormat(SyncFormat.version + 1)) { _ = try SyncStore.open(at: root, passphrase: "p") }
    }

    @Test("Clocks order by Lamport, then device")
    func clocks() {
        #expect(SyncClock(lamport: 1, device: "b") < SyncClock(lamport: 2, device: "a"))
        #expect(SyncClock(lamport: 2, device: "a") < SyncClock(lamport: 2, device: "b"))
        #expect(SyncObjectRef(encoded: "doc:abc:def") == SyncObjectRef(fileHash: "abc", contentHash: "def"))
        #expect(SyncObjectRef(encoded: "doc:abc:")?.contentHash == "")
        #expect(SyncObjectRef(encoded: "doc::x") == nil)
        #expect(SyncObjectRef(encoded: "abc") == nil)
    }
}

/// One simulated device: its own ledger, notes and intake, sharing one sync folder.
private struct Device {
    let name: String
    let dir: URL
    let db: Database
    let notes: NotesStore
    let intake: URL
    let engine: SyncEngine

    static func make(_ name: String, store: SyncStore) async throws -> Device {
        let dir = try ParityFixture.tempFolder("dev-\(name)")
        let db = try await ParityFixture.database(in: dir)
        let notes = NotesStore(base: dir)
        let intake = dir.appendingPathComponent("Intake", isDirectory: true)
        try FileManager.default.createDirectory(at: intake, withIntermediateDirectories: true)
        let engine = SyncEngine(database: db, store: store, deviceID: "device-\(name)", deviceName: name,
                                signingKey: Curve25519.Signing.PrivateKey(), notes: notes, intakeFolder: intake,
                                saveIntake: { data, fileName, _ in
                                    var target = intake.appendingPathComponent(fileName)
                                    if FileManager.default.fileExists(atPath: target.path) {
                                        target = intake.appendingPathComponent("\(UUID().uuidString)-\(fileName)")
                                    }
                                    try data.write(to: target)
                                    return CaptureIntake.Saved(file: target, sha256: SyncCrypto.sha256Hex(data))
                                })
        return Device(name: name, dir: dir, db: db, notes: notes, intake: intake, engine: engine)
    }

    func scalar(_ sql: String, _ binds: [SQLValue] = []) async throws -> String? {
        try await db.query(sql, binds).first?.values.first.map { v -> String? in
            switch v { case .text(let s): return s; case .integer(let i): return String(i); case .real(let d): return String(d); default: return nil }
        } ?? nil
    }
}

@Suite("X-5 Sync between devices", .serialized)
struct SyncEngineTests {
    private func pair() async throws -> (SyncStore, URL, Device, Device) {
        let root = try ParityFixture.tempFolder("sync")
        let store = try SyncStore.create(at: root, passphrase: "pass", rounds: 1_000)
        return (store, root, try await Device.make("A", store: store), try await Device.make("B", store: store))
    }

    private func cleanup(_ urls: URL...) { for u in urls { try? FileManager.default.removeItem(at: u) } }

    @Test("Tags, groups, members and highlights made on one Mac appear on the other, on its own copy of the document")
    func userLayerTravels() async throws {
        let (store, root, a, b) = try await pair()
        defer { cleanup(root, a.dir, b.dir) }
        let text = "Lease between Ada and Bo.\n\nRent is monthly."
        let docA = try await ParityFixture.document(a.db, name: "lease.txt", text: text, fileHash: "filehash-1").id
        let docB = try await ParityFixture.document(b.db, name: "lease.txt", text: text, fileHash: "filehash-1").id
        #expect(docA != docB)                         // each ledger has its own id

        let tags = TagsRepository(database: a.db)
        let tag = try await tags.tag(named: "Contract")
        try await tags.attach(tagID: tag, to: .object, docA)
        let groups = GroupRepository(database: a.db)
        let g = try await groups.create(name: "Cases")
        try await groups.add(docA, to: g)
        _ = try await AnnotationsRepository(database: a.db).add(objectID: docA, sourceURL: nil, quote: "Rent is monthly", note: "due 1st")

        let sentA = try await a.engine.sync()
        #expect(sentA.batchesWritten == 1 && sentA.changesSent >= 4)
        let gotB = try await b.engine.sync()
        #expect(gotB.batchesRead == 1)
        #expect(gotB.changesWaiting == 0)
        #expect(try await TagsRepository(database: b.db).tags(for: .object, docB).map(\.name) == ["Contract"])
        #expect(try await GroupRepository(database: b.db).groups(containing: docB).map(\.name) == ["Cases"])
        #expect(try await b.scalar("SELECT note FROM annotations WHERE object_id = ?;", [.uuid(docB)]) == "due 1st")
        // B applied without echoing A's changes back as its own.
        #expect(gotB.changesSent == 0)
        // Idempotent: nothing new on either side.
        let quietA = try await a.engine.sync(), quietB = try await b.engine.sync()
        #expect(quietA.changesApplied == 0 && quietA.batchesWritten == 0)
        #expect(quietB.changesApplied == 0 && quietB.batchesWritten == 0)
        _ = store
    }

    @Test("A change to a document the other Mac does not have waits, then applies when it arrives")
    func pendingUntilDocumentArrives() async throws {
        let (_, root, a, b) = try await pair()
        defer { cleanup(root, a.dir, b.dir) }
        let docA = try await ParityFixture.document(a.db, name: "memo.txt", text: "Memo text", fileHash: "memo-hash").id
        let tags = TagsRepository(database: a.db)
        try await tags.attach(tagID: try await tags.tag(named: "Hot"), to: .object, docA)
        _ = try await a.engine.sync()
        let first = try await b.engine.sync()
        #expect(first.changesWaiting == 1)                         // the link; the tag itself applied
        let docB = try await ParityFixture.document(b.db, name: "memo.txt", text: "Memo text", fileHash: "memo-hash").id
        let second = try await b.engine.sync()
        #expect(second.changesApplied == 1)
        #expect(try await TagsRepository(database: b.db).tags(for: .object, docB).map(\.name) == ["Hot"])
    }

    @Test("The same field changed on both Macs: one value wins everywhere, the other is listed")
    func fieldConflict() async throws {
        let (_, root, a, b) = try await pair()
        defer { cleanup(root, a.dir, b.dir) }
        let groups = GroupRepository(database: a.db)
        let g = try await groups.create(name: "Draft")
        _ = try await a.engine.sync(); _ = try await b.engine.sync()
        try await groups.rename(g, to: "From A")
        try await GroupRepository(database: b.db).rename(g, to: "From B")
        _ = try await a.engine.sync()          // A sends first
        let bSync = try await b.engine.sync()  // B receives A's (older) rename, keeps its own, sends it
        #expect(bSync.conflicts >= 1)
        _ = try await a.engine.sync()          // A receives B's later rename
        let nameA = try await a.scalar("SELECT name FROM user_groups WHERE id = ?;", [.uuid(g)])
        let nameB = try await b.scalar("SELECT name FROM user_groups WHERE id = ?;", [.uuid(g)])
        #expect(nameA == nameB)
        #expect(nameA == "From B")
        #expect(try await b.scalar("SELECT COUNT(*) FROM sync_conflicts;") != "0")
    }

    @Test("Two Macs make a tag with the same name: both kept, the incoming one renamed and listed")
    func sameNameTags() async throws {
        let (_, root, a, b) = try await pair()
        defer { cleanup(root, a.dir, b.dir) }
        _ = try await TagsRepository(database: a.db).tag(named: "Urgent")
        _ = try await TagsRepository(database: b.db).tag(named: "Urgent")
        _ = try await a.engine.sync()
        let s = try await b.engine.sync()
        #expect(s.conflicts == 1)
        let names = try await TagsRepository(database: b.db).allTags().map(\.name).sorted()
        #expect(names == ["Urgent", "Urgent (from another device)"])
    }

    @Test("A note edited on both Macs keeps both texts; the later one ends up current everywhere")
    func noteConflict() async throws {
        let (_, root, a, b) = try await pair()
        defer { cleanup(root, a.dir, b.dir) }
        let note = try a.notes.create(title: "Plan")
        try a.notes.save("v1", to: note)
        _ = try await a.engine.sync()
        let gotB = try await b.engine.sync()
        #expect(gotB.notesChanged.count == 1)
        let noteB = b.notes.notesFolder.appendingPathComponent("Plan.md")
        #expect(try b.notes.read(noteB) == "v1")

        try a.notes.save("A's edit", to: note)
        try b.notes.save("B's edit", to: noteB)
        _ = try await a.engine.sync()                  // A sends its edit
        let bSync = try await b.engine.sync()          // B: concurrent → keeps its own, keeps A's as a version, sends its own
        #expect(bSync.conflicts == 1)
        #expect(try b.notes.read(noteB) == "B's edit")
        _ = try await a.engine.sync()                  // A: unchanged since it sent → takes B's
        #expect(try a.notes.read(note) == "B's edit")
        let versionsA = try a.notes.versions(of: note).map { try String(contentsOf: $0.url, encoding: .utf8) }
        let versionsB = try b.notes.versions(of: noteB).map { try String(contentsOf: $0.url, encoding: .utf8) }
        #expect(versionsA.contains("A's edit"))
        #expect(versionsB.contains("A's edit"))
    }

    @Test("A note moved to the trash on one Mac goes to the trash on the other")
    func noteTrash() async throws {
        let (_, root, a, b) = try await pair()
        defer { cleanup(root, a.dir, b.dir) }
        let note = try a.notes.create(title: "Old")
        _ = try await a.engine.sync(); _ = try await b.engine.sync()
        #expect(b.notes.list().count == 1)
        try a.notes.delete(note)
        _ = try await a.engine.sync(); _ = try await b.engine.sync()
        #expect(b.notes.list().isEmpty)
        #expect(b.notes.trashed().map(\.title) == ["Old"])
    }

    @Test("A file added inside the app on one Mac arrives on the other, once")
    func intakeFiles() async throws {
        let (_, root, a, b) = try await pair()
        defer { cleanup(root, a.dir, b.dir) }
        let day = a.intake.appendingPathComponent("2026-10-17", isDirectory: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        try Data("clipped page".utf8).write(to: day.appendingPathComponent("Page.html"))
        _ = try await a.engine.sync()
        let s = try await b.engine.sync()
        #expect(s.filesReceived == 1 && s.intakeChanged)
        let arrived = try FileManager.default.contentsOfDirectory(atPath: b.intake.path)
        #expect(arrived == ["Page.html"])
        // Not sent back, not received twice.
        let back = try await b.engine.sync()
        #expect(back.filesSent == 0)
        let again = try await a.engine.sync()
        #expect(again.filesReceived == 0)
    }

    @Test("A changed batch is refused and reported; the others still apply")
    func quarantine() async throws {
        let (_, root, a, b) = try await pair()
        defer { cleanup(root, a.dir, b.dir) }
        _ = try await TagsRepository(database: a.db).tag(named: "One")
        _ = try await a.engine.sync()
        _ = try await TagsRepository(database: a.db).tag(named: "Two")
        _ = try await a.engine.sync()
        let file = root.appendingPathComponent("log/device-A/\(SyncFormat.batchName(1))")
        var env = try SyncStore.decoder.decode(SyncEnvelope.self, from: Data(contentsOf: file))
        var sealed = try #require(Data(base64Encoded: env.sealed))
        sealed[sealed.count / 2] ^= 0x01
        env.sealed = sealed.base64EncodedString()
        try SyncStore.encoder.encode(env).write(to: file)
        let s = try await b.engine.sync()
        #expect(s.quarantined == 1)
        #expect(try await TagsRepository(database: b.db).allTags().map(\.name) == ["Two"])
        #expect(try await b.scalar("SELECT COUNT(*) FROM sync_quarantine;") == "1")
        let again = try await b.engine.sync()
        #expect(again.quarantined == 0)               // reported once, not re-read every time
    }

    @Test("Three devices converge on the same groups")
    func threeDevices() async throws {
        let root = try ParityFixture.tempFolder("sync3")
        let store = try SyncStore.create(at: root, passphrase: "pass", rounds: 1_000)
        let a = try await Device.make("A", store: store), b = try await Device.make("B", store: store), c = try await Device.make("C", store: store)
        defer { cleanup(root, a.dir, b.dir, c.dir) }
        _ = try await GroupRepository(database: a.db).create(name: "From A")
        _ = try await GroupRepository(database: b.db).create(name: "From B")
        _ = try await GroupRepository(database: c.db).create(name: "From C")
        for _ in 0..<2 { for d in [a, b, c] { _ = try await d.engine.sync() } }
        for d in [a, b, c] {
            #expect(try await GroupRepository(database: d.db).all().map(\.name).sorted() == ["From A", "From B", "From C"])
        }
    }
}

@Suite("X-6 What the iPhone/iPad app reads, and what it writes")
struct SyncReplayTests {
    @Test("The replay shows a Mac's tags, groups and highlights on a document it names")
    func replayShowsMacWork() async throws {
        let root = try ParityFixture.tempFolder("replay")
        let store = try SyncStore.create(at: root, passphrase: "pass", rounds: 1_000)
        let mac = try await Device.make("Mac", store: store)
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: mac.dir) }
        let doc = try await ParityFixture.document(mac.db, name: "lease.pdf", text: "Lease text", fileHash: "lease-hash").id
        let tags = TagsRepository(database: mac.db)
        try await tags.attach(tagID: try await tags.tag(named: "Contract"), to: .object, doc)
        let g = try await GroupRepository(database: mac.db).create(name: "Cases")
        try await GroupRepository(database: mac.db).add(doc, to: g)
        _ = try await AnnotationsRepository(database: mac.db).add(objectID: doc, sourceURL: nil, quote: "Lease", note: nil)
        _ = try await mac.engine.sync()

        let replay = SyncReplay.replay(store)
        #expect(replay.problems.isEmpty)
        let d = try #require(replay.documents.first)
        #expect(d.title == "lease.pdf")
        #expect(d.blobSHA == nil)                         // the file lives on the Mac
        #expect(replay.tags(of: d) == ["Contract"])
        #expect(replay.groups(of: d) == ["Cases"])
        #expect(replay.highlights(of: d).map(\.quote) == ["Lease"])
    }

    @Test("An edit written the way the phone writes it is applied on the Mac")
    func phoneEditReachesMac() async throws {
        let root = try ParityFixture.tempFolder("phone")
        let store = try SyncStore.create(at: root, passphrase: "pass", rounds: 1_000)
        let mac = try await Device.make("Mac", store: store)
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: mac.dir) }
        let doc = try await ParityFixture.document(mac.db, name: "scan.pdf", text: "Scanned page", fileHash: "scan-hash").id
        // The phone: its own key and device id; a tag + a link on the document by file hash only.
        let phoneKey = Curve25519.Signing.PrivateKey()
        try store.register(SyncDeviceInfo(id: "phone", name: "iPhone", publicKey: phoneKey.publicKey.rawRepresentation.base64EncodedString(), platform: "iOS"))
        let tagID = UUID().uuidString
        let ref = SyncReplay.reference(for: SyncReplay.Document(id: "scan-hash", title: "scan.pdf", blobSHA: "scan-hash", fileHash: "scan-hash"))
        #expect(ref == "doc:scan-hash:")
        let now = SyncValue.real(Date().timeIntervalSince1970)
        let batch = SyncBatch(device: "phone", seq: 1, createdAt: Date(), ops: [
            SyncOp(table: "user_tags", key: tagID, fields: ["id": .text(tagID), "name": .text("From phone"), "color": .null,
                                                           "created_at": now, "retired_at": .null, "merged_into": .null], lamport: 5, device: "phone"),
            SyncOp(table: "user_tag_links", key: "\(tagID)|object|\(ref)", fields: ["tag_id": .text(tagID), "subject_kind": .text("object"),
                                                                                  "subject_id": .text(ref), "created_at": now, "removed_at": .null], lamport: 5, device: "phone")
        ], files: [])
        try store.write(batch, signingKey: phoneKey)
        let s = try await mac.engine.sync()
        #expect(s.changesApplied == 2)
        #expect(try await TagsRepository(database: mac.db).tags(for: .object, doc).map(\.name) == ["From phone"])
    }

    @Test("Notes: the latest clock is current; a trashed note is not live")
    func replayNotes() {
        var r = SyncReplay()
        r.apply(SyncBatch(device: "a", seq: 1, createdAt: Date(), ops: [], files: [
            SyncFileOp(kind: .note, name: "N.md", sha256: "s1", lamport: 1, device: "a")]))
        r.apply(SyncBatch(device: "b", seq: 1, createdAt: Date(), ops: [], files: [
            SyncFileOp(kind: .note, name: "N.md", sha256: "s2", lamport: 3, device: "b")]))
        r.apply(SyncBatch(device: "a", seq: 2, createdAt: Date(), ops: [], files: [
            SyncFileOp(kind: .note, name: "N.md", sha256: "s0", lamport: 2, device: "a")]))   // older: ignored
        #expect(r.liveNotes.map(\.sha256) == ["s2"])
        r.apply(SyncBatch(device: "a", seq: 3, createdAt: Date(), ops: [], files: [
            SyncFileOp(kind: .note, name: "N.md", sha256: "s2", trashed: true, lamport: 4, device: "a")]))
        #expect(r.liveNotes.isEmpty)
    }
}
