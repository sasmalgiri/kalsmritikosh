//
//  SyncReplay.swift
//  SyncCore
//
//  X-6 — the whole sync store replayed in memory, for a device that keeps no ledger (the
//  iPhone/iPad app): every verified batch from every device applied in clock order with the
//  same rules the Mac uses (each field keeps its latest-clock value; the latest note text is
//  current). The result is a small read model: documents, notes, tags, groups, highlights.
//

import Foundation

nonisolated struct SyncReplay {
    struct Row: Hashable {
        var fields: [String: SyncValue] = [:]
        var clocks: [String: SyncClock] = [:]

        func text(_ f: String) -> String? { fields[f]?.text }
        var isRemoved: Bool {
            for f in ["removed_at", "retired_at"] { if let v = fields[f], v != .null { return true } }
            return false
        }
    }

    struct Document: Hashable, Identifiable {
        /// The portable reference ops use ("doc:<file hash>:<text hash>"), or the intake file's hash.
        let id: String
        let title: String
        /// SHA-256 of bytes kept in the store (files added in the app); nil for files that live
        /// only on a Mac (their marks and tags still show, the file opens on the Mac).
        let blobSHA: String?
        let fileHash: String
    }

    private(set) var tables: [String: [String: Row]] = [:]
    private(set) var notes: [String: SyncFileOp] = [:]
    private(set) var intake: [String: SyncFileOp] = [:]
    private(set) var titles: [String: String] = [:]
    private(set) var maxLamport: Int64 = 0
    private(set) var problems: [String] = []

    /// Read and apply every batch in the store, oldest clock first.
    static func replay(_ store: SyncStore) -> SyncReplay {
        var r = SyncReplay()
        var batches: [SyncBatch] = []
        for device in store.loggedDevices() {
            for seq in store.batchNumbers(of: device) {
                do { batches.append(try store.readBatch(device: device, seq: seq)) }
                catch { r.problems.append("\(device.prefix(8)) #\(seq): \(error.localizedDescription)") }
            }
        }
        batches.sort { ($0.ops.map(\.lamport) + $0.files.map(\.lamport)).min() ?? 0 < ($1.ops.map(\.lamport) + $1.files.map(\.lamport)).min() ?? 0 }
        for b in batches { r.apply(b) }
        return r
    }

    mutating func apply(_ batch: SyncBatch) {
        for (k, v) in batch.titles ?? [:] { titles[k] = v }
        for op in batch.ops {
            maxLamport = max(maxLamport, op.lamport)
            let incoming = SyncClock(lamport: op.lamport, device: op.device)
            var row = tables[op.table]?[op.key] ?? Row()
            for (field, value) in op.fields {
                if let current = row.clocks[field], current >= incoming { continue }
                row.fields[field] = value
                row.clocks[field] = incoming
            }
            tables[op.table, default: [:]][op.key] = row
        }
        for f in batch.files {
            maxLamport = max(maxLamport, f.lamport)
            let incoming = SyncClock(lamport: f.lamport, device: f.device)
            switch f.kind {
            case .note:
                if let current = notes[f.name], SyncClock(lamport: current.lamport, device: current.device) >= incoming { continue }
                notes[f.name] = f
            case .intake:
                if intake.values.contains(where: { $0.sha256 == f.sha256 }) { continue }
                intake[f.name] = f
            }
        }
    }

    // MARK: - Read model

    func rows(_ table: String) -> [(key: String, row: Row)] {
        (tables[table] ?? [:]).map { ($0.key, $0.value) }.sorted { $0.key < $1.key }
    }

    /// Notes that are not in the trash, by name.
    var liveNotes: [SyncFileOp] { notes.values.filter { !$0.trashed }.sorted { $0.name < $1.name } }

    /// Every document known: files added in the app (with bytes) and documents marks/tags refer to.
    var documents: [Document] {
        var out: [String: Document] = [:]
        for f in intake.values {
            out[f.sha256] = Document(id: f.sha256, title: (f.name as NSString).lastPathComponent, blobSHA: f.sha256, fileHash: f.sha256)
        }
        var refs = Set<String>()
        for (table, rows) in tables {
            guard let spec = SyncReplay.objectColumns[table] else { continue }
            for row in rows.values { for c in spec { if let t = row.text(c), t.hasPrefix("doc:") { refs.insert(t) } } }
        }
        for ref in refs {
            guard let parsed = SyncObjectRef(encoded: ref) else { continue }
            if out[parsed.fileHash] != nil { continue }      // already listed as a file with bytes
            out[ref] = Document(id: ref, title: titles[ref] ?? "Document on your Mac", blobSHA: nil, fileHash: parsed.fileHash)
        }
        return out.values.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// Does this op's document reference point at `doc`?
    static func refers(_ value: String?, to doc: Document) -> Bool {
        guard let value else { return false }
        if value == doc.id { return true }
        return SyncObjectRef(encoded: value)?.fileHash == doc.fileHash
    }

    var liveTags: [(id: String, name: String)] {
        rows("user_tags").compactMap { k, r in r.isRemoved ? nil : (k, r.text("name") ?? "") }.sorted { $0.name < $1.name }
    }

    var liveGroups: [(id: String, name: String, parent: String?)] {
        rows("user_groups").compactMap { k, r in r.isRemoved ? nil : (k, r.text("name") ?? "", r.text("parent_id")) }
            .sorted { $0.name < $1.name }
    }

    func tags(of doc: Document) -> [String] {
        let names = Dictionary(uniqueKeysWithValues: liveTags.map { ($0.id, $0.name) })
        return rows("user_tag_links").compactMap { _, r in
            guard !r.isRemoved, Self.refers(r.text("subject_id"), to: doc), let t = r.text("tag_id") else { return nil }
            return names[t]
        }.sorted()
    }

    func groups(of doc: Document) -> [String] {
        let names = Dictionary(uniqueKeysWithValues: liveGroups.map { ($0.id, $0.name) })
        return rows("user_group_members").compactMap { _, r in
            guard !r.isRemoved, Self.refers(r.text("object_id"), to: doc), let g = r.text("group_id") else { return nil }
            return names[g]
        }.sorted()
    }

    func highlights(of doc: Document) -> [(quote: String, note: String?)] {
        rows("annotations").compactMap { _, r in
            guard !r.isRemoved, Self.refers(r.text("object_id"), to: doc) else { return nil }
            return (r.text("quote") ?? "", r.text("note"))
        }
    }

    /// The portable reference to use when this device makes a new mark on `doc`.
    static func reference(for doc: Document) -> String {
        doc.id.hasPrefix("doc:") ? doc.id : "doc:\(doc.fileHash):"
    }

    static let objectColumns: [String: [String]] = [
        "user_tag_links": ["subject_id"], "user_group_members": ["object_id"], "annotations": ["object_id"],
        "pdf_marks": ["object_id"], "review_codes": ["object_id"], "case_issue_links": ["subject_id"]
    ]
}
