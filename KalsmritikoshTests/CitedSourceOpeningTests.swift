//
//  CitedSourceOpeningTests.swift
//  KalsmritikoshTests
//
//  Smart-map S2 (2026-11-08):
//   • IN-02 — originals are kept by default, SEALED in the vault: the bytes on disk are not the original, the
//     kept copy reopens exactly (under its own file name), a wrong/missing key or a damaged/truncated copy never
//     yields wrong bytes, older plain copies still open, and removing a copy removes its opened copy.
//   • SRC-01 / SRC-08 — a citation that names only a document is pinned to the version that document was read
//     from: once that version is superseded it opens the kept copy (labelled) or is labelled unavailable — never
//     the newer file; an unreadable file is "access denied", not a silent fallback.
//   • SRC-09 — opening a source from inside a frame and coming back keeps the frame stack, selection, viewport
//     and saved view, and the source position (identifiers only), across re-creating the workspace.
//

import Foundation
import CryptoKit
import Testing
@testable import Kalsmritikosh

@Suite("Cited source opening (smart-map S2)")
struct CitedSourceOpeningTests {

    static func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("s2open-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func hash(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    // MARK: IN-02

    @Test("Kept originals are sealed on disk and reopen byte-for-byte under their own name; no key, the wrong key, damage or truncation never yields bytes")
    func sealedVaultRoundTrip() async throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("EvidenceVault", isDirectory: true)
        let key = LedgerKey.random().derivedKey(for: EvidenceVault.sealPurpose)
        let vault = EvidenceVault(root: root, sealKey: key)
        // More than one sealing chunk, with a recognisable phrase inside.
        var original = Data("CONFIDENTIAL settlement: the payment of 66,800 was approved by R. Mehta. ".utf8)
        while original.count < (1 << 20) + 5000 { original.append(contentsOf: Data("filler line for the second chunk. ".utf8)) }
        let file = dir.appendingPathComponent("statement.pdf")
        try original.write(to: file)

        let address = try await vault.storeStreaming(contentsOf: file)
        #expect(address == Self.hash(original), "the content address is the ORIGINAL bytes' SHA-256")
        #expect(await vault.isSealed(address))
        // On disk: not the original, and the phrase is not readable in it.
        let sealedFile = root.appendingPathComponent(String(address.prefix(2))).appendingPathComponent(address + ".sealed")
        let onDisk = try Data(contentsOf: sealedFile)
        #expect(onDisk != original)
        #expect(onDisk.range(of: Data("CONFIDENTIAL settlement".utf8)) == nil, "the kept copy is not plaintext")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(String(address.prefix(2))).appendingPathComponent(address).path))

        // Reopens exactly, under the version's name, outside the vault folder.
        let opened = try #require(await vault.url(for: address, filename: "statement.pdf"))
        #expect(opened.lastPathComponent == "statement.pdf")
        #expect(!opened.path.hasPrefix(root.path + "/"), "opened copies are never inside the vault (a vault copy carries no plaintext)")
        #expect(try Data(contentsOf: opened) == original)
        #expect(await vault.data(for: address) == original)
        // Storing the same bytes again is a no-op (dedup) and does not re-seal.
        #expect(try await vault.store(original) == address)

        // No key / another ledger's key: nothing opens (never guessed).
        let noKey = EvidenceVault(root: root)
        #expect(await noKey.url(for: address) == nil)
        #expect(await noKey.data(for: address) == nil)
        let otherKey = EvidenceVault(root: root, sealKey: LedgerKey.random().derivedKey(for: EvidenceVault.sealPurpose))
        #expect(await otherKey.data(for: address) == nil)
        #expect(await otherKey.contains(address), "the copy is still there — it is just not openable without its key")

        // Removing the copy removes the opened copy too.
        try await vault.remove(address)
        #expect(await vault.contains(address) == false)
        #expect(!FileManager.default.fileExists(atPath: opened.path))
    }

    @Test("A damaged or truncated sealed copy fails closed; a plain copy from an older build still opens; opened copies are removed at launch")
    func sealedVaultFailures() async throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("EvidenceVault", isDirectory: true)
        let key = LedgerKey.random().derivedKey(for: EvidenceVault.sealPurpose)
        let vault = EvidenceVault(root: root, sealKey: key)
        let original = Data("The invoice total was 500 dollars.".utf8)
        let address = try await vault.store(original)
        let sealedFile = root.appendingPathComponent(String(address.prefix(2))).appendingPathComponent(address + ".sealed")
        let good = try Data(contentsOf: sealedFile)
        func replace(with data: Data) throws {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sealedFile.path)
            try data.write(to: sealedFile)
        }
        // A flipped byte inside the sealed data.
        var flipped = good; flipped[flipped.count / 2] ^= 0xFF
        try replace(with: flipped)
        #expect(await vault.data(for: address) == nil)
        #expect(await vault.url(for: address, filename: "invoice.txt") == nil)
        // Truncated: the trailer is missing.
        try replace(with: good.prefix(good.count - 10))
        #expect(await vault.data(for: address) == nil)
        // Restored intact: opens again.
        try replace(with: good)
        #expect(await vault.data(for: address) == original)

        // An older build's plain copy (no seal) opens with or without a key.
        let legacy = Data("A letter kept by an older build.".utf8)
        let legacyAddress = try await EvidenceVault(root: root).store(legacy)
        #expect(await vault.isSealed(legacyAddress) == false)
        #expect(await vault.data(for: legacyAddress) == legacy)
        let named = try #require(await vault.url(for: legacyAddress, filename: "letter.txt"))
        #expect(named.lastPathComponent == "letter.txt")
        #expect(try Data(contentsOf: named) == legacy)

        // Launch clean-up: every opened copy goes, the kept copies stay.
        _ = await vault.url(for: address, filename: "invoice.txt")
        #expect(FileManager.default.fileExists(atPath: vault.openedCopiesRoot.path))
        await vault.removeOpenedCopies()
        #expect(!FileManager.default.fileExists(atPath: vault.openedCopiesRoot.path))
        #expect(await vault.contains(address))
        #expect(await vault.contains(legacyAddress))
    }

    @Test("Keeping originals is the default; an explicit choice to turn it off is kept")
    func managedCustodyIsTheDefault() {
        let key = "kalsmritikosh.feature.managedEvidenceMode.enabled"
        let before = AppDefaults.store.object(forKey: key)
        defer { if let before { AppDefaults.store.set(before, forKey: key) } else { AppDefaults.store.removeObject(forKey: key) } }
        AppDefaults.store.removeObject(forKey: key)
        #expect(FeatureFlags.managedEvidenceModeValue() == true, "unset = keep originals")
        AppDefaults.store.set(false, forKey: key)
        #expect(FeatureFlags.managedEvidenceModeValue() == false, "the person's choice is honoured")
    }

    // MARK: SRC-01 / SRC-08

    struct Doc { let object: UUID; let version: UUID }

    /// A document (knowledge object) read from version `v1` of `file`, with one passage.
    static func seedDocument(_ db: Database, file: URL, bytes: Data, filename: String) async throws -> Doc {
        let fileID = UUID(), ko = UUID(), version = UUID(), logical = UUID(), block = UUID(), chunk = UUID()
        try await db.exec("INSERT INTO files (id, url, source_type, availability, content_hash) VALUES (?,?,?,?,?);",
                          [.uuid(fileID), .text(file.absoluteString), .text("txt"), .text("available"), .text(hash(bytes))])
        try await db.exec("INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at) VALUES (?,?,?,?,?,?);",
                          [.uuid(ko), .uuid(fileID), .text("txt"), .text(String(decoding: bytes, as: UTF8.self)), .real(0), .real(0)])
        try await db.exec("""
            INSERT INTO source_versions (id, logical_source_id, content_hash, valid_from, is_current, original_url, created_at, filename,
                                         custody_mode, preservation_status)
            VALUES (?,?,?,?,1,?,?,?,'referenced','referenceRecorded');
            """, [.uuid(version), .uuid(logical), .text(hash(bytes)), .real(1), .text(file.absoluteString), .real(1), .text(filename)])
        try await db.exec("""
            INSERT INTO evidence_blocks (id, document_id, source_version_id, ordinal, kind, raw_text, normalized_text, extraction_method, extraction_confidence)
            VALUES (?,?,?,0,'paragraph',?,?,'native',1.0);
            """, [.uuid(block), .uuid(UUID()), .uuid(version), .text("The fee is 10,000."), .text("the fee is 10,000.")])
        try await db.exec("INSERT INTO evidence_block_objects (evidence_block_id, knowledge_object_id, linked_at) VALUES (?,?,?);",
                          [.uuid(block), .uuid(ko), .real(0)])
        try await db.exec("INSERT INTO chunks (id, object_id, ordinal, text, char_start, char_end, created_at, evidence_block_id, source_version_id) VALUES (?,?,0,?,0,18,0,?,?);",
                          [.uuid(chunk), .uuid(ko), .text("The fee is 10,000."), .uuid(block), .uuid(version)])
        return Doc(object: ko, version: version)
    }

    @Test("A citation naming only the document is pinned to the version it was read from: superseded → kept copy (labelled) or 'unavailable', never the newer file")
    func objectOnlyCitationIsPinned() async throws {
        let f = try await CitedSourceResolverTests.fixture()
        defer { try? FileManager.default.removeItem(at: f.dir) }
        let file = f.dir.appendingPathComponent("contract.txt")
        let cited = Data("The fee is 10,000.".utf8)
        try cited.write(to: file)
        let doc = try await Self.seedDocument(f.db, file: file, bytes: cited, filename: "contract.txt")
        // While current and unchanged: the file itself (verified by hash).
        #expect(try await CitedSourceResolver.resolve(sourceVersionID: nil, objectID: doc.object, database: f.db, ledgerURL: f.ledger) == .open(file, note: nil))

        // The document is re-read: a newer version replaces it, and the file now holds the newer words.
        try Data("The fee is 12,500.".utf8).write(to: file)
        try await f.db.exec("UPDATE source_versions SET is_current = 0 WHERE id = ?;", [.uuid(doc.version)])
        #expect(try await CitedSourceResolver.resolve(sourceVersionID: nil, objectID: doc.object, database: f.db, ledgerURL: f.ledger) == .unavailable(.superseded),
                "before S2 an unpinned citation opened the newer file")

        // With the cited bytes kept (sealed) in the vault: they open, labelled, under the version's name.
        let vault = EvidenceVault(root: f.dir.appendingPathComponent("EvidenceVault", isDirectory: true),
                                  sealKey: LedgerKey.random().derivedKey(for: EvidenceVault.sealPurpose))
        _ = try await vault.store(cited)
        guard case .open(let url, let note) = try await CitedSourceResolver.resolve(sourceVersionID: nil, objectID: doc.object, database: f.db,
                                                                                    ledgerURL: f.ledger, vault: vault) else {
            Issue.record("the kept copy was not opened"); return
        }
        #expect(note == CitedSourceResolver.newerVersionNote && url.lastPathComponent == "contract.txt")
        #expect(try Data(contentsOf: url) == cited, "the cited words, not the newer document")
        // The same vault without its key cannot open the sealed copy: labelled, not substituted.
        #expect(try await CitedSourceResolver.resolve(sourceVersionID: nil, objectID: doc.object, database: f.db, ledgerURL: f.ledger,
                                                      vault: EvidenceVault(root: f.dir.appendingPathComponent("EvidenceVault", isDirectory: true))) == .unavailable(.superseded))
    }

    @Test("An unreadable file is 'access denied' with a remedy — not opened, not replaced by another file")
    func accessDenied() async throws {
        let f = try await CitedSourceResolverTests.fixture()
        let file = f.dir.appendingPathComponent("memo.txt")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
            try? FileManager.default.removeItem(at: f.dir)
        }
        let bytes = Data("Memo: meet on Friday.".utf8)
        try bytes.write(to: file)
        let doc = try await Self.seedDocument(f.db, file: file, bytes: bytes, filename: "memo.txt")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        guard !FileManager.default.isReadableFile(atPath: file.path) else { return }   // running as root: nothing to prove
        #expect(try await CitedSourceResolver.resolve(sourceVersionID: doc.version, objectID: doc.object, database: f.db, ledgerURL: f.ledger) == .unavailable(.accessDenied))
        #expect(CitedSourceResolver.Unavailable.accessDenied.label.contains("Add the folder again"))
    }

    // MARK: SRC-09

    @MainActor
    @Test("Checking a source from inside a frame and coming back keeps the frame stack, selection, viewport and the source position — also after re-creating the workspace")
    func sourceInspectionReturn() async throws {
        let rig = try await CaseMapRig.make()
        let name = "s2return.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let service = CaseMapService(sources: caseMapSources(rig.f))
        var model = CaseMapWorkspaceModel(caseID: rig.f.caseID, workspace: CaseWorkspaceHolder(caseID: rig.f.caseID, defaults: defaults))
        await model.refresh(service)
        let c = rig.node(.contradiction, rig.contradictionID)
        await model.openFrame(c, service: service)
        let doc = try #require(model.projection?.nodes.first { $0.id.kind == .document }?.id)
        model.select(.node(doc))
        model.setViewport(CaseMapViewport(scale: 1.75, originX: -40, originY: 300))
        let stack = model.frameStack
        #expect(stack.map(\.anchor) == [c])

        // What the workspace's open(source) records before the sheet appears: identifiers only.
        model.workspace.state.lastSource = CaseSourcePosition(objectID: rig.a.object, origin: nil, revision: rig.a.version)

        // The source sheet closes — or the app is quit while it is open — and the case is opened again.
        model = CaseMapWorkspaceModel(caseID: rig.f.caseID, workspace: CaseWorkspaceHolder(caseID: rig.f.caseID, defaults: defaults))
        await model.refresh(service)
        #expect(model.frameStack == stack, "the branch is not rediscovered: same frame")
        #expect(model.selection == .node(doc))
        #expect(model.viewport() == CaseMapViewport(scale: 1.75, originX: -40, originY: 300), "same zoom and scroll on the map")
        #expect(model.workspace.state.lastSource == CaseSourcePosition(objectID: rig.a.object, origin: nil, revision: rig.a.version))
        // And Back from the frame restores the level it was opened from.
        await model.returnToFrame(depth: 0, service: service)
        #expect(model.frameStack.isEmpty)
    }
}
