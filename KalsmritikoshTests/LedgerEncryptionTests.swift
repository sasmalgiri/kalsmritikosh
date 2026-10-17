//
//  LedgerEncryptionTests.swift
//  KalsmritikoshTests
//
//  W2-7 — the ledger is encrypted at rest with SQLCipher. These prove it from the bytes on
//  disk, not from the code: a marker written into the ledger never appears in the file; the
//  wrong key or no key cannot read it; a plaintext ledger is converted with every row kept;
//  an interrupted conversion is finished or undone; backups stay encrypted.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("W2-7 ledger encryption", .serialized)
struct LedgerEncryptionTests {
    private func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("enc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// Every byte of the database and its WAL, so a marker cannot hide in either.
    private func rawBytes(_ url: URL) -> Data {
        var d = Data()
        for p in [url.path, url.path + "-wal"] { if let b = FileManager.default.contents(atPath: p) { d.append(b) } }
        return d
    }

    private let marker = "SECRET-MARKER-91374-patent-grant"

    @Test func cipherIsLinkedAndTestsUseTheirOwnKeychainItem() {
        #expect(AppState.cipherVersion != nil, "SQLCipher is not the SQLite this app runs on")
        #expect(LedgerKeychain.usesMemoryStore, "tests must never touch the Keychain (person's key, CI hang)")
    }

    /// Export compliance rests on this: SQLCipher must do its cryptography through Apple's own
    /// CommonCrypto, not a bundled crypto library (release/HOLD2_SCRIPT.md §10, SHIP_DECISIONS).
    @Test func encryptionUsesApplesCommonCrypto() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let db = try Database(url: dir.appendingPathComponent("p.sqlite"), key: LedgerKey.random())
        let rows = try await db.query("PRAGMA cipher_provider;", [])
        let provider = rows.first?.string(0) ?? ""
        let version = try await db.query("PRAGMA cipher_provider_version;", []).first?.string(0) ?? ""
        Attachment.record("cipher_provider=\(provider)\ncipher_provider_version=\(version)\n", named: "cipher-provider.txt")
        #expect(provider == "commoncrypto", "SQLCipher crypto provider is \(provider)")
        await db.close()
    }

    @Test func aKeyedLedgerIsEncryptedOnDisk() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("ledger.sqlite")
        let key = LedgerKey.random()
        let db = try Database(url: url, key: key)
        try await db.exec("CREATE TABLE t(x TEXT);")
        try await db.exec("INSERT INTO t VALUES ('\(marker)');")
        try await db.checkpointWAL()
        await db.close()

        #expect(LedgerFileState.of(url) == .encrypted)
        #expect(rawBytes(url).range(of: Data(marker.utf8)) == nil, "the marker is readable in the file")

        let again = try Database(url: url, key: key)
        #expect(try await again.query("SELECT x FROM t;", []).first?.string(0) == marker)
        await again.close()
    }

    @Test func theWrongKeyOrNoKeyCannotReadIt() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("ledger.sqlite")
        let db = try Database(url: url, key: LedgerKey.random())
        try await db.exec("CREATE TABLE t(x TEXT); INSERT INTO t VALUES ('\(marker)');")
        await db.close()

        #expect(throws: LedgerEncryptionError.self) { _ = try Database(url: url, key: LedgerKey.random()) }
        // Without a key the file is not even a database: opening fails at the first statement.
        #expect(throws: DatabaseError.self) { _ = try Database(url: url) }
        #expect(Database.quickCheck(fileAt: url) != nil)
    }

    @Test func aPlaintextLedgerIsConvertedWithEveryRowKept() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("knowledge.sqlite")
        let plain = try Database(url: url)
        try await SchemaMigrations.migrate(plain)
        try await plain.exec("PRAGMA foreign_keys = OFF;")
        try await plain.exec("""
            INSERT INTO files(id, url, source_type) VALUES ('f1', 'file:///a.txt', 'text');
            INSERT INTO knowledge_objects(id, file_id, source_type, content, created_at, updated_at)
              VALUES ('k1', 'f1', 'text', '\(marker)', 0, 0);
            INSERT INTO chunks(id, object_id, ordinal, text, char_start, char_end, created_at)
              VALUES ('c1', 'k1', 0, '\(marker) examiner Meera Iyer', 0, 10, 0);
            """)
        let version = try await plain.currentUserVersion()
        await plain.close()
        #expect(LedgerFileState.of(url) == .plaintext)
        #expect(rawBytes(url).range(of: Data(marker.utf8)) != nil)        // the fixture really is plaintext

        let key = LedgerKey.random()
        let report = try #require(try LedgerEncryptionMigrator.encryptIfPlaintext(at: url, key: key))
        #expect(report.tables > 0 && report.rows >= 3)
        #expect(LedgerFileState.of(url) == .encrypted)
        #expect(rawBytes(url).range(of: Data(marker.utf8)) == nil)
        for leftover in [LedgerEncryptionMigrator.pendingURL(url), LedgerEncryptionMigrator.stagingURL(url)] {
            #expect(!FileManager.default.fileExists(atPath: leftover.path))
        }

        let enc = try Database(url: url, key: key)
        #expect(try await enc.currentUserVersion() == version)
        #expect(try await enc.query("SELECT content FROM knowledge_objects WHERE id='k1';", []).first?.string(0) == marker)
        // Full-text search survives the conversion.
        let hits = try await enc.query("SELECT c.id FROM chunks_fts JOIN chunks c ON c.rowid = chunks_fts.rowid WHERE chunks_fts MATCH 'examiner';", [])
        #expect(hits.compactMap { $0.string(0) } == ["c1"])
        await enc.close()
        // A second call is a no-op on an already encrypted ledger.
        #expect(try LedgerEncryptionMigrator.encryptIfPlaintext(at: url, key: key) == nil)
    }

    @Test func anInterruptedSwapIsUndoneOrFinished() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("knowledge.sqlite")
        let plain = try Database(url: url)
        try await plain.exec("CREATE TABLE t(x TEXT); INSERT INTO t VALUES ('kept');")
        try await plain.checkpointWAL()
        await plain.close()
        let pending = LedgerEncryptionMigrator.pendingURL(url)

        // Stopped after moving the plaintext aside, before the encrypted file arrived: undo.
        try FileManager.default.moveItem(at: url, to: pending)
        LedgerEncryptionMigrator.recoverInterruptedSwap(at: url)
        #expect(LedgerFileState.of(url) == .plaintext)
        #expect(!FileManager.default.fileExists(atPath: pending.path))

        // Stopped after the encrypted file arrived, before the plaintext was removed: finish.
        try FileManager.default.copyItem(at: url, to: pending)
        let key = LedgerKey.random()
        try FileManager.default.removeItem(at: url)
        let enc = try Database(url: url, key: key)
        try await enc.exec("CREATE TABLE t(x TEXT);")
        await enc.close()
        LedgerEncryptionMigrator.recoverInterruptedSwap(at: url)
        #expect(LedgerFileState.of(url) == .encrypted)
        #expect(!FileManager.default.fileExists(atPath: pending.path))
    }

    @Test func theRecoveryKeyRoundTrips() throws {
        let key = LedgerKey.random()
        let text = key.recoveryText
        #expect(text.count == 64 + 15)
        #expect(text.split(separator: "-").count == 16)
        #expect(LedgerKey(recoveryText: text) == key)
        #expect(LedgerKey(recoveryText: text.lowercased().replacingOccurrences(of: "-", with: " ")) == key)
        #expect(LedgerKey(recoveryText: "hello") == nil)
        #expect(LedgerKey(recoveryText: String(text.dropLast())) == nil)
        #expect(LedgerKey(recoveryText: "ZZZZ" + text.dropFirst(4)) == nil)   // not hex
    }

    @Test func backupCopiesStayEncrypted() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let key = LedgerKey.random()
        let db = try Database(url: dir.appendingPathComponent("live.sqlite"), key: key)
        try await db.exec("CREATE TABLE t(x TEXT); INSERT INTO t VALUES ('\(marker)');")
        let copy = dir.appendingPathComponent("backup.sqlite")
        try await db.backupSnapshot(to: copy)
        await db.close()
        #expect(LedgerFileState.of(copy) == .encrypted)
        #expect(rawBytes(copy).range(of: Data(marker.utf8)) == nil)
        #expect(Database.quickCheck(fileAt: copy, key: key) == nil)
        #expect(Database.quickCheck(fileAt: copy) != nil)
        #expect(Database.quickCheck(fileAt: copy, key: LedgerKey.random()) != nil)
    }

    @Test func bootCreatesConvertsAndAsksForTheRecoveryKey() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        // A new ledger opens encrypted with the (test) Keychain key.
        let fresh = dir.appendingPathComponent("fresh.sqlite")
        guard case .opened(let db) = try LedgerOpener.open(at: fresh, recoveryKey: nil) else {
            Issue.record("a new ledger did not open"); return
        }
        try await db.exec("CREATE TABLE t(x TEXT);")
        await db.close()
        #expect(LedgerFileState.of(fresh) == .encrypted)
        let thisMac = try #require(LedgerKeychain.load())

        // A ledger made on "another Mac" asks for its recovery key; the right one opens and is kept.
        let other = dir.appendingPathComponent("other.sqlite")
        let otherKey = LedgerKey.random()
        let o = try Database(url: other, key: otherKey)
        try await o.exec("CREATE TABLE t(x TEXT); INSERT INTO t VALUES ('\(marker)');")
        await o.close()
        guard case .needsRecoveryKey = try LedgerOpener.open(at: other, recoveryKey: nil) else {
            Issue.record("a ledger with another key opened without asking"); return
        }
        guard case .needsRecoveryKey = try LedgerOpener.open(at: other, recoveryKey: LedgerKey.random()) else {
            Issue.record("a wrong recovery key was accepted"); return
        }
        guard case .opened(let unlocked) = try LedgerOpener.open(at: other, recoveryKey: otherKey) else {
            Issue.record("the right recovery key did not open the ledger"); return
        }
        #expect(try await unlocked.query("SELECT x FROM t;", []).first?.string(0) == marker)
        await unlocked.close()
        #expect(LedgerKeychain.load() == otherKey)
        try LedgerKeychain.store(thisMac)          // leave the test item as it was
    }
}
