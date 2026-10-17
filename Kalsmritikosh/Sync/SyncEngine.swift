//
//  SyncEngine.swift
//  Kalsmritikosh
//
//  X-5 — one device's side of sync through a folder. A sync is "read the others, then write
//  mine": every other device's unseen batches are verified, decrypted and applied in order;
//  then this device's own changes since the last sync (rows the v150 triggers marked, notes
//  and files added in the app) go out as one signed, encrypted batch.
//
//  Merge rules (identical on every device, so all devices converge):
//   * each synced field keeps the value with the latest clock (Lamport, then device id);
//     a losing value that differs from the winner is listed as a conflict, never dropped;
//   * a note changed on two devices at once keeps BOTH texts: the one that ends up current is
//     the later edit, the other is saved as one of the note's versions, and it is listed;
//   * a change about a document this device does not have yet waits (sync_pending) and is
//     applied once the document arrives;
//   * a batch that fails verification is quarantined and reported; the rest continues;
//   * applying a batch twice changes nothing (cursor per device + clocks).
//

import Foundation
import CryptoKit
import os

actor SyncEngine {
    private let database: Database
    private let store: SyncStore
    let deviceID: String
    private let deviceName: String
    private let signingKey: Curve25519.Signing.PrivateKey
    private let notes: NotesStore
    private let intakeFolder: URL
    private let saveIntake: @Sendable (Data, String, String) throws -> CaptureIntake.Saved

    struct Summary: Sendable, Equatable {
        var batchesRead = 0
        var changesApplied = 0
        var changesWaiting = 0
        var conflicts = 0
        var quarantined = 0
        var batchesWritten = 0
        var changesSent = 0
        var filesSent = 0
        var filesReceived = 0
        /// Notes this device wrote or replaced, to be read in.
        var notesChanged: [URL] = []
        /// True when intake files arrived and the intake should be read.
        var intakeChanged = false
    }

    init(database: Database, store: SyncStore, deviceID: String, deviceName: String,
         signingKey: Curve25519.Signing.PrivateKey, notes: NotesStore, intakeFolder: URL,
         saveIntake: @escaping @Sendable (Data, String, String) throws -> CaptureIntake.Saved = CaptureIntake.save) {
        self.database = database
        self.store = store
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.signingKey = signingKey
        self.notes = notes
        self.intakeFolder = intakeFolder
        self.saveIntake = saveIntake
    }

    /// Make this device known to the store (its public key verifies its batches).
    func register() throws {
        try store.register(SyncDeviceInfo(id: deviceID, name: deviceName,
                                          publicKey: signingKey.publicKey.rawRepresentation.base64EncodedString(),
                                          platform: "macOS"))
    }

    func sync() async throws -> Summary {
        try register()
        var summary = Summary()
        try await importAll(into: &summary)
        try await exportPending(into: &summary)
        try await setState("last_sync", String(Date().timeIntervalSince1970))
        return summary
    }

    // MARK: - State

    private func state(_ key: String) async throws -> String? {
        try await database.query("SELECT value FROM sync_state WHERE key = ?;", [.text(key)]).first?.string(0)
    }

    private func setState(_ key: String, _ value: String) async throws {
        try await database.exec("""
            INSERT INTO sync_state (key, value) VALUES (?, ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value;
            """, [.text(key), .text(value)])
    }

    private func lamport() async throws -> Int64 { Int64(try await state("lamport") ?? "0") ?? 0 }

    // MARK: - Document references

    /// The portable reference of a local document; nil when its source file has no hash.
    static func ref(of objectID: String, _ db: isolated Database) throws -> SyncObjectRef? {
        guard let row = try db.query("""
            SELECT f.content_hash, ko.content FROM knowledge_objects ko JOIN files f ON f.id = ko.file_id WHERE ko.id = ?;
            """, [.text(objectID)]).first, let fileHash = row.string(0), !fileHash.isEmpty else { return nil }
        return SyncObjectRef(fileHash: fileHash, contentHash: SyncCrypto.sha256Hex(Data((row.string(1) ?? "").utf8)))
    }

    /// The local document for a portable reference: the exact text first; otherwise the only
    /// document read from that file. nil when this device does not have it (yet).
    static func resolve(_ ref: SyncObjectRef, _ db: isolated Database) throws -> String? {
        let rows = try db.query("""
            SELECT ko.id, ko.content FROM knowledge_objects ko JOIN files f ON f.id = ko.file_id
            WHERE f.content_hash = ? ORDER BY ko.created_at, ko.id;
            """, [.text(ref.fileHash)])
        if let exact = rows.first(where: { SyncCrypto.sha256Hex(Data(($0.string(1) ?? "").utf8)) == ref.contentHash }) {
            return exact.string(0)
        }
        return rows.count == 1 ? rows[0].string(0) : nil
    }

    // MARK: - Export

    private func exportPending(into summary: inout Summary) async throws {
        let seq = (Int(try await state("my_seq") ?? "0") ?? 0) + 1
        let clock = try await lamport() + 1
        let me = deviceID
        // Rows marked by the triggers → ops (one savepoint: read, then clear what was sent).
        let exported: ([SyncOp], [String: String]) = try await database.withSavepoint("sync_export_rows") { db in
            var out: [SyncOp] = []
            var titles: [String: String] = [:]
            let dirty = try db.query("SELECT tbl, row_key FROM sync_dirty ORDER BY changed_at, tbl, row_key;", [])
            for d in dirty {
                guard let tbl = d.string(0), let key = d.string(1) else { continue }
                defer { try? db.exec("DELETE FROM sync_dirty WHERE tbl = ? AND row_key = ?;", [.text(tbl), .text(key)]) }
                guard let spec = SyncTable.named(tbl) else { continue }
                let parts = key.split(separator: SyncTable.keySeparator, omittingEmptySubsequences: false).map(String.init)
                guard parts.count == spec.keyColumns.count else { continue }
                var sql = "SELECT \(spec.columns.joined(separator: ", ")) FROM \(spec.name) WHERE "
                sql += spec.keyColumns.map { "\($0) = ?" }.joined(separator: " AND ")
                if let filter = spec.rowFilter { sql += " AND (\(filter))" }
                guard let row = try db.query(sql + ";", parts.map { .text($0) }).first else { continue }
                var fields: [String: SyncValue] = [:]
                var portable = true
                for (i, column) in spec.columns.enumerated() {
                    var value = SyncValue(row.values.indices.contains(i) ? row.values[i] : .null)
                    if spec.objectColumns.contains(column), let local = value.text {
                        guard let ref = try Self.ref(of: local, db) else { portable = false; break }
                        value = .text(ref.encoded)
                        if let url = try db.query("""
                            SELECT f.url FROM knowledge_objects ko JOIN files f ON f.id = ko.file_id WHERE ko.id = ?;
                            """, [.text(local)]).first?.string(0) {
                            titles[ref.encoded] = URL(string: url)?.lastPathComponent ?? (url as NSString).lastPathComponent
                        }
                    }
                    fields[column] = value
                }
                guard portable else {
                    KalsmritikoshLog.app.notice("Sync: a \(tbl, privacy: .public) row refers to a document without a file hash; kept on this device")
                    continue
                }
                let portableKey = spec.keyColumns.map { fields[$0]?.text ?? fields[$0].map { $0.display } ?? "" }
                    .joined(separator: String(SyncTable.keySeparator))
                for column in spec.nonKeyColumns {
                    // The value as it stands here (local ids), remembered as the last synced one.
                    let local = SyncValue(row.values.indices.contains(spec.columns.firstIndex(of: column) ?? -1)
                                          ? row.values[spec.columns.firstIndex(of: column)!] : .null)
                    try db.exec("""
                        INSERT INTO sync_field_clocks (tbl, row_key, field, lamport, device, synced_value) VALUES (?, ?, ?, ?, ?, ?)
                        ON CONFLICT (tbl, row_key, field) DO UPDATE SET lamport = excluded.lamport, device = excluded.device,
                            synced_value = excluded.synced_value;
                        """, [.text(tbl), .text(key), .text(column), .integer(clock), .text(me), .text(Self.encodeValue(local))])
                }
                out.append(SyncOp(table: tbl, key: portableKey, fields: fields, lamport: clock, device: me))
            }
            return (out, titles)
        }
        let ops = exported.0
        let files = try await exportFiles(clock: clock)
        guard !ops.isEmpty || !files.isEmpty else { return }
        let batch = SyncBatch(device: me, seq: seq, createdAt: Date(), ops: ops, files: files,
                              titles: exported.1.isEmpty ? nil : exported.1)
        try store.write(batch, signingKey: signingKey)
        try await setState("my_seq", String(seq))
        try await setState("lamport", String(clock))
        for f in files {
            try await recordFile(kind: f.kind, name: f.name, sha: f.sha256, clock: SyncClock(lamport: clock, device: me), trashed: f.trashed)
        }
        summary.batchesWritten += 1
        summary.changesSent += ops.count
        summary.filesSent += files.count
    }

    private struct FileRecord { let sha: String; let lamport: Int64; let device: String; let trashed: Bool }

    private func fileRecord(_ kind: SyncFileOp.Kind, _ name: String) async throws -> FileRecord? {
        guard let r = try await database.query(
            "SELECT sha256, lamport, device, trashed FROM sync_files WHERE kind = ? AND name = ?;",
            [.text(kind.rawValue), .text(name)]).first, let sha = r.string(0) else { return nil }
        return FileRecord(sha: sha, lamport: r.int(1) ?? 0, device: r.string(2) ?? "", trashed: (r.int(3) ?? 0) != 0)
    }

    private func recordFile(kind: SyncFileOp.Kind, name: String, sha: String, clock: SyncClock, trashed: Bool) async throws {
        try await database.exec("""
            INSERT INTO sync_files (kind, name, sha256, lamport, device, trashed) VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT (kind, name) DO UPDATE SET sha256 = excluded.sha256, lamport = excluded.lamport,
                device = excluded.device, trashed = excluded.trashed;
            """, [.text(kind.rawValue), .text(name), .text(sha), .integer(clock.lamport), .text(clock.device), .bool(trashed)])
    }

    /// Notes and intake files that are new or changed since they were last synced.
    private func exportFiles(clock: Int64) async throws -> [SyncFileOp] {
        var out: [SyncFileOp] = []
        let fm = FileManager.default
        for note in notes.list() {
            guard let data = try? Data(contentsOf: note.url) else { continue }
            let sha = SyncCrypto.sha256Hex(data)
            let name = note.url.lastPathComponent
            let record = try await fileRecord(.note, name)
            guard record?.sha != sha || record?.trashed == true else { continue }
            try store.putBlob(data)
            out.append(SyncFileOp(kind: .note, name: name, sha256: sha, origin: nil, trashed: false,
                                  baseSHA256: record?.trashed == true ? nil : record?.sha, lamport: clock, device: deviceID))
        }
        for trashed in notes.trashed() {
            let name = trashed.url.lastPathComponent
            guard let record = try await fileRecord(.note, name), !record.trashed,
                  !fm.fileExists(atPath: notes.notesFolder.appendingPathComponent(name).path) else { continue }
            out.append(SyncFileOp(kind: .note, name: name, sha256: record.sha, origin: nil, trashed: true,
                                  baseSHA256: record.sha, lamport: clock, device: deviceID))
        }
        for file in intakeFiles() {
            let rel = String(file.path.dropFirst(intakeFolder.standardizedFileURL.path.count + 1))
            guard try await fileRecord(.intake, rel) == nil, let data = try? Data(contentsOf: file) else { continue }
            let sha = SyncCrypto.sha256Hex(data)
            try store.putBlob(data)
            out.append(SyncFileOp(kind: .intake, name: rel, sha256: sha, origin: "added on \(deviceName)",
                                  trashed: false, baseSHA256: nil, lamport: clock, device: deviceID))
        }
        return out
    }

    private func intakeFiles() -> [URL] {
        let root = intakeFolder.standardizedFileURL
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
                                                     options: [.skipsHiddenFiles]) else { return [] }
        return e.compactMap { $0 as? URL }
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .map(\.standardizedFileURL)
            .sorted { $0.path < $1.path }
    }

    // MARK: - Import

    private func importAll(into summary: inout Summary) async throws {
        try await retryPending(into: &summary)
        for device in store.loggedDevices() where device != deviceID {
            let cursor = Int(try await state("cursor.\(device)") ?? "0") ?? 0
            for seq in store.batchNumbers(of: device) where seq > cursor {
                if try await isQuarantined(device, seq) { continue }
                let batch: SyncBatch
                do {
                    batch = try store.readBatch(device: device, seq: seq)
                } catch {
                    KalsmritikoshLog.app.error("Sync: change \(seq, privacy: .public) from \(device, privacy: .public) refused: \(error.localizedDescription, privacy: .public)")
                    try await quarantine(device, seq, error.localizedDescription)
                    summary.quarantined += 1
                    continue
                }
                try await apply(batch, into: &summary)
                try await setState("cursor.\(device)", String(seq))
                summary.batchesRead += 1
            }
        }
    }

    private func isQuarantined(_ device: String, _ seq: Int) async throws -> Bool {
        !(try await database.query("SELECT 1 FROM sync_quarantine WHERE device = ? AND seq = ?;",
                                   [.text(device), .integer(Int64(seq))]).isEmpty)
    }

    private func quarantine(_ device: String, _ seq: Int, _ reason: String) async throws {
        try await database.exec("""
            INSERT INTO sync_quarantine (device, seq, reason, seen_at) VALUES (?, ?, ?, ?)
            ON CONFLICT (device, seq) DO UPDATE SET reason = excluded.reason, seen_at = excluded.seen_at;
            """, [.text(device), .integer(Int64(seq)), .text(reason), .date(Date())])
    }

    enum ApplyOutcome: Sendable, Equatable { case applied(conflicts: Int), waiting(String), ignored }

    private func apply(_ batch: SyncBatch, into summary: inout Summary) async throws {
        let order = Dictionary(uniqueKeysWithValues: SyncTable.all.enumerated().map { ($1.name, $0) })
        let ops = batch.ops.sorted { (order[$0.table] ?? 99, $0.lamport) < (order[$1.table] ?? 99, $1.lamport) }
        let maxClock = (batch.ops.map(\.lamport) + batch.files.map(\.lamport)).max() ?? 0
        let outcomes: [ApplyOutcome] = try await database.withSavepoint("sync_apply") { db in
            try db.exec("INSERT INTO sync_state (key, value) VALUES ('applying', '1') ON CONFLICT (key) DO UPDATE SET value = '1';", [])
            defer { try? db.exec("DELETE FROM sync_state WHERE key = 'applying';", []) }
            var out: [ApplyOutcome] = []
            for op in ops {
                let outcome = try Self.applyOp(op, db)
                if case .waiting(let reason) = outcome {
                    let json = String(data: try JSONEncoder().encode(op), encoding: .utf8) ?? "{}"
                    try db.exec("INSERT INTO sync_pending (id, op_json, reason, first_seen) VALUES (?, ?, ?, ?);",
                                [.text(UUID().uuidString), .text(json), .text(reason), .date(Date())])
                }
                out.append(outcome)
            }
            return out
        }
        for o in outcomes {
            switch o {
            case .applied(let c): summary.changesApplied += 1; summary.conflicts += c
            case .waiting: summary.changesWaiting += 1
            case .ignored: break
            }
        }
        for f in batch.files.sorted(by: { $0.lamport < $1.lamport }) { try await applyFile(f, into: &summary) }
        let now = try await lamport()
        if maxClock > now { try await setState("lamport", String(maxClock)) }
    }

    private func retryPending(into summary: inout Summary) async throws {
        let rows = try await database.query("SELECT id, op_json FROM sync_pending WHERE applied_at IS NULL ORDER BY first_seen;", [])
        guard !rows.isEmpty else { return }
        let decoded: [(String, SyncOp)] = rows.compactMap { r in
            guard let id = r.string(0), let json = r.string(1)?.data(using: .utf8),
                  let op = try? JSONDecoder().decode(SyncOp.self, from: json) else { return nil }
            return (id, op)
        }
        let results: [ApplyOutcome] = try await database.withSavepoint("sync_retry") { db in
            try db.exec("INSERT INTO sync_state (key, value) VALUES ('applying', '1') ON CONFLICT (key) DO UPDATE SET value = '1';", [])
            defer { try? db.exec("DELETE FROM sync_state WHERE key = 'applying';", []) }
            var out: [ApplyOutcome] = []
            for (id, op) in decoded {
                let outcome = try Self.applyOp(op, db)
                if case .waiting = outcome {
                    try db.exec("UPDATE sync_pending SET attempts = attempts + 1 WHERE id = ?;", [.text(id)])
                } else {
                    try db.exec("UPDATE sync_pending SET applied_at = ? WHERE id = ?;", [.date(Date()), .text(id)])
                }
                out.append(outcome)
            }
            return out
        }
        for o in results {
            if case .applied(let c) = o { summary.changesApplied += 1; summary.conflicts += c }
        }
    }

    /// Apply one row change. Synchronous inside the caller's savepoint.
    static func applyOp(_ op: SyncOp, _ db: isolated Database) throws -> ApplyOutcome {
        guard let spec = SyncTable.named(op.table) else { return .ignored }
        // Make document references local again.
        var fields = op.fields
        for column in spec.objectColumns {
            guard let encoded = fields[column]?.text, let ref = SyncObjectRef(encoded: encoded) else { continue }
            guard let local = try resolve(ref, db) else { return .waiting("document not on this device yet") }
            fields[column] = .text(local)
        }
        let keyValues = spec.keyColumns.map { fields[$0] ?? .null }
        let localKey = keyValues.map { $0.text ?? $0.display }.joined(separator: String(SyncTable.keySeparator))
        let incoming = SyncClock(lamport: op.lamport, device: op.device)

        var keySQL = spec.keyColumns.map { "\($0) = ?" }.joined(separator: " AND ")
        if keySQL.isEmpty { keySQL = "0" }
        let existing = try db.query("SELECT \(spec.nonKeyColumns.joined(separator: ", ")) FROM \(spec.name) WHERE \(keySQL);",
                                    keyValues.map(\.sql)).first
        var conflicts = 0
        var winners: [String: SyncValue] = [:]
        // A row changed here and not yet sent: its changed fields are kept (they go out next,
        // with a later clock, so every device ends with them) and the incoming value is listed.
        let dirtyRows = try db.query("SELECT 1 FROM sync_dirty WHERE tbl = ? AND row_key = ?;",
                                     [.text(spec.name), .text(localKey)])
        let dirtyHere = existing != nil && !dirtyRows.isEmpty
        for (i, column) in spec.nonKeyColumns.enumerated() {
            guard let value = fields[column] else { continue }
            let clockRow = try db.query("SELECT lamport, device, synced_value FROM sync_field_clocks WHERE tbl = ? AND row_key = ? AND field = ?;",
                                        [.text(spec.name), .text(localKey), .text(column)]).first
            let local = clockRow.map { SyncClock(lamport: $0.int(0) ?? 0, device: $0.string(1) ?? "") }
            let current = existing.map { SyncValue($0.values.indices.contains(i) ? $0.values[i] : .null) }
            let lastSynced = clockRow?.string(2).flatMap(Self.decodeValue)
            let changedHere = dirtyHere && (lastSynced == nil || current != lastSynced)
            if changedHere, let current, current != value {
                conflicts += 1
                try db.exec("""
                    INSERT INTO sync_conflicts (id, tbl, row_key, field, kept_value, other_value, other_device, detected_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?);
                    """, [.text(UUID().uuidString), .text(spec.name), .text(localKey), .text(column),
                          .text(current.display), .text(value.display), .text(op.device), .date(Date())])
                continue
            }
            if local == nil || incoming > local! {
                winners[column] = value
            } else if let current, current != value, local!.device != op.device {
                conflicts += 1
                try db.exec("""
                    INSERT INTO sync_conflicts (id, tbl, row_key, field, kept_value, other_value, other_device, detected_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?);
                    """, [.text(UUID().uuidString), .text(spec.name), .text(localKey), .text(column),
                          .text(current.display), .text(value.display), .text(op.device), .date(Date())])
            }
        }
        if existing == nil {
            var all = fields
            for (k, v) in winners { all[k] = v }
            let columns = spec.columns.filter { all[$0] != nil }
            do {
                try insert(spec, columns: columns, values: columns.map { all[$0]! }, db)
            } catch {
                // A live name already taken here (two devices made a tag or group with the same
                // name): keep both, the incoming one renamed, and say so.
                guard spec.columns.contains("name"), let name = all["name"]?.text else {
                    return .waiting("could not be stored yet: \(error.localizedDescription)")
                }
                let renamed = "\(name) (from another device)"
                all["name"] = .text(renamed)
                do {
                    try insert(spec, columns: columns, values: columns.map { all[$0]! }, db)
                } catch {
                    return .waiting("could not be stored yet: \(error.localizedDescription)")
                }
                conflicts += 1
                try db.exec("""
                    INSERT INTO sync_conflicts (id, tbl, row_key, field, kept_value, other_value, other_device, detected_at)
                    VALUES (?, ?, ?, 'name', ?, ?, ?, ?);
                    """, [.text(UUID().uuidString), .text(spec.name), .text(localKey), .text(renamed), .text(name),
                          .text(op.device), .date(Date())])
            }
        } else if !winners.isEmpty {
            let sets = winners.keys.sorted()
            do {
                try db.exec("UPDATE \(spec.name) SET \(sets.map { "\($0) = ?" }.joined(separator: ", ")) WHERE \(keySQL);",
                            sets.map { winners[$0]!.sql } + keyValues.map(\.sql))
            } catch {
                return .waiting("could not be stored yet: \(error.localizedDescription)")
            }
        }
        for (column, value) in winners {
            try db.exec("""
                INSERT INTO sync_field_clocks (tbl, row_key, field, lamport, device, synced_value) VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT (tbl, row_key, field) DO UPDATE SET lamport = excluded.lamport, device = excluded.device,
                    synced_value = excluded.synced_value;
                """, [.text(spec.name), .text(localKey), .text(column), .integer(op.lamport), .text(op.device),
                      .text(encodeValue(value))])
        }
        return .applied(conflicts: conflicts)
    }

    static func encodeValue(_ v: SyncValue) -> String {
        (try? String(data: JSONEncoder().encode(v), encoding: .utf8)) ?? "null"
    }

    static func decodeValue(_ s: String) -> SyncValue? {
        try? JSONDecoder().decode(SyncValue.self, from: Data(s.utf8))
    }

    private static func insert(_ spec: SyncTable, columns: [String], values: [SyncValue], _ db: isolated Database) throws {
        let marks = Array(repeating: "?", count: columns.count).joined(separator: ", ")
        try db.exec("INSERT INTO \(spec.name) (\(columns.joined(separator: ", "))) VALUES (\(marks));", values.map(\.sql))
    }

    // MARK: - Files

    private func applyFile(_ f: SyncFileOp, into summary: inout Summary) async throws {
        let clock = SyncClock(lamport: f.lamport, device: f.device)
        switch f.kind {
        case .intake:
            if try await fileRecord(.intake, f.name) != nil { return }
            let known = try await database.query("SELECT 1 FROM sync_files WHERE kind = 'intake' AND sha256 = ? LIMIT 1;", [.text(f.sha256)])
            guard known.isEmpty else { try await recordFile(kind: .intake, name: f.name, sha: f.sha256, clock: clock, trashed: false); return }
            let data = try store.blob(f.sha256)
            let saved = try saveIntake(data, (f.name as NSString).lastPathComponent,
                                       "Synced from another device (\(f.origin ?? "sync"))")
            let localRel = String(saved.file.standardizedFileURL.path.dropFirst(intakeFolder.standardizedFileURL.path.count + 1))
            try await recordFile(kind: .intake, name: f.name, sha: f.sha256, clock: clock, trashed: false)
            try await recordFile(kind: .intake, name: localRel, sha: f.sha256, clock: clock, trashed: false)
            summary.filesReceived += 1
            summary.intakeChanged = true
        case .note:
            let url = notes.notesFolder.appendingPathComponent(f.name)
            let local = (try? Data(contentsOf: url)).map(SyncCrypto.sha256Hex)
            let record = try await fileRecord(.note, f.name)
            if f.trashed {
                if local != nil, local == f.sha256 || local == record?.sha {
                    try notes.delete(url)
                    summary.filesReceived += 1
                }
                try await recordFile(kind: .note, name: f.name, sha: f.sha256, clock: clock, trashed: true)
                return
            }
            if local == f.sha256 {
                try await recordFile(kind: .note, name: f.name, sha: f.sha256, clock: clock, trashed: false)
                return
            }
            let data = try store.blob(f.sha256)
            if local == nil {
                if let record, record.trashed, SyncClock(lamport: record.lamport, device: record.device) > clock { return }
                summary.notesChanged.append(try notes.adopt(name: f.name, data: data))
            } else if local == record?.sha || local == f.baseSHA256 {
                // Unchanged here since the version the other device edited: take its text.
                try notes.replace(url, with: data)
                summary.notesChanged.append(url)
            } else {
                // Edited here AND there: keep this device's text current (it will be sent with a
                // later clock, so every device ends with it), keep the other text as a version.
                try notes.addVersion(data, to: url)
                try await database.exec("""
                    INSERT INTO sync_conflicts (id, tbl, row_key, field, kept_value, other_value, other_device, detected_at)
                    VALUES (?, 'note', ?, 'text', 'this device''s text', 'kept as an earlier version', ?, ?);
                    """, [.text(UUID().uuidString), .text(f.name), .text(f.device), .date(Date())])
                summary.conflicts += 1
                return   // not recorded: this device's text still has to go out
            }
            try await recordFile(kind: .note, name: f.name, sha: f.sha256, clock: clock, trashed: false)
            summary.filesReceived += 1
        }
    }
}
