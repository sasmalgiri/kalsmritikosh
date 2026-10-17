//
//  SyncLibrary.swift
//  KalsmritikoshViewer
//
//  X-6 — the iPhone/iPad side of "Sync through a folder". Open the same sync folder your Mac
//  uses (iCloud Drive, Dropbox… through the Files app) with the same passphrase; read your
//  documents, notes, tags, groups and highlights; write notes, tag, file into groups,
//  highlight and scan. Each edit is written into the folder as this device's own signed,
//  encrypted batch; the Mac applies it on its next sync. No network: the folder's service
//  moves the files. Questions are answered on the Mac (this app keeps no ledger).
//

import Foundation
import CryptoKit
import Security
import PDFKit
import UIKit

@MainActor
@Observable
final class SyncLibrary {
    private(set) var store: SyncStore?
    private(set) var replay = SyncReplay()
    var problem: String?
    var busy = false
    var needsPassphrase = false
    private var folder: URL?

    static let folderKey = "kalsmritikosh.viewer.sync.folder"

    var isOpen: Bool { store != nil }

    // MARK: - Opening

    /// Re-open the folder chosen earlier, with the key saved earlier.
    func restore() async {
        guard store == nil, let data = UserDefaults.standard.data(forKey: Self.folderKey) else { return }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale) else { return }
        folder = url
        guard let key = ViewerKeychain.load(ViewerKeychain.storeKey).map({ SymmetricKey(data: $0) }) else {
            needsPassphrase = true; return
        }
        await open(url, with: .key(key))
    }

    enum Credential { case passphrase(String), key(SymmetricKey) }

    func choose(_ url: URL) {
        folder = url
        _ = url.startAccessingSecurityScopedResource()
        if let bookmark = try? url.bookmarkData() { UserDefaults.standard.set(bookmark, forKey: Self.folderKey) }
        needsPassphrase = true
    }

    func unlock(_ passphrase: String) async {
        guard let folder else { return }
        await open(folder, with: .passphrase(passphrase))
    }

    private func open(_ url: URL, with credential: Credential) async {
        busy = true
        defer { busy = false }
        _ = url.startAccessingSecurityScopedResource()
        do {
            let opened: SyncStore = try await Task.detached {
                switch credential {
                case .passphrase(let p): return try SyncStore.open(at: url, passphrase: p)
                case .key(let k): return try SyncStore.open(at: url, key: k)
                }
            }.value
            try ViewerKeychain.save(opened.key.withUnsafeBytes { Data($0) }, ViewerKeychain.storeKey)
            try opened.register(SyncDeviceInfo(id: Self.deviceID, name: UIDevice.current.name,
                                               publicKey: try Self.signingKey().publicKey.rawRepresentation.base64EncodedString(),
                                               platform: UIDevice.current.userInterfaceIdiom == .pad ? "iPadOS" : "iOS"))
            store = opened
            needsPassphrase = false
            problem = nil
            await refresh()
        } catch {
            problem = error.localizedDescription
            needsPassphrase = true
        }
    }

    func refresh() async {
        guard let store else { return }
        busy = true
        defer { busy = false }
        replay = await Task.detached { SyncReplay.replay(store) }.value
        if !replay.problems.isEmpty { problem = "Some changes could not be read: " + replay.problems.prefix(3).joined(separator: "; ") }
    }

    func disconnect() {
        store = nil
        replay = SyncReplay()
        ViewerKeychain.delete(ViewerKeychain.storeKey)
        UserDefaults.standard.removeObject(forKey: Self.folderKey)
        folder?.stopAccessingSecurityScopedResource()
        folder = nil
    }

    // MARK: - Reading

    func data(of doc: SyncReplay.Document) throws -> Data? {
        guard let sha = doc.blobSHA, let store else { return nil }
        return try store.blob(sha)
    }

    func text(of note: SyncFileOp) -> String {
        guard let store, let data = try? store.blob(note.sha256) else { return "" }
        if note.name.lowercased().hasSuffix(".rtf"),
           let a = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) {
            return a.string
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// A temporary copy of a document's bytes for Quick Look.
    func previewFile(for doc: SyncReplay.Document) -> URL? {
        guard let data = try? data(of: doc) else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(doc.title)
        try? data.write(to: url, options: .atomic)
        return url
    }

    /// Case-insensitive search over titles, note text, highlights and the text of files in the folder.
    func search(_ query: String) -> (docs: [SyncReplay.Document], notes: [SyncFileOp]) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return (replay.documents, replay.liveNotes) }
        let docs = replay.documents.filter { d in
            if d.title.localizedCaseInsensitiveContains(q) { return true }
            if replay.highlights(of: d).contains(where: { $0.quote.localizedCaseInsensitiveContains(q) || ($0.note ?? "").localizedCaseInsensitiveContains(q) }) { return true }
            if let data = try? data(of: d), let s = String(data: data, encoding: .utf8) { return s.localizedCaseInsensitiveContains(q) }
            if let data = try? data(of: d), let pdf = PDFDocument(data: data), let s = pdf.string { return s.localizedCaseInsensitiveContains(q) }
            return false
        }
        let notes = replay.liveNotes.filter { $0.name.localizedCaseInsensitiveContains(q) || text(of: $0).localizedCaseInsensitiveContains(q) }
        return (docs, notes)
    }

    // MARK: - Writing (each edit = one batch from this device)

    private func send(ops: [SyncOp] = [], files: [SyncFileOp] = []) async {
        guard let store else { return }
        do {
            let storeID = store.info.storeID
            let d = UserDefaults.standard
            let lamport = max(Int64(d.integer(forKey: "sync.lamport.\(storeID)")), replay.maxLamport) + 1
            let seq = max(d.integer(forKey: "sync.seq.\(storeID)"), store.batchNumbers(of: Self.deviceID).last ?? 0) + 1
            let me = Self.deviceID
            let batch = SyncBatch(device: me, seq: seq, createdAt: Date(),
                                  ops: ops.map { var o = $0; o.lamport = lamport; o.device = me; return o },
                                  files: files.map { var f = $0; f.lamport = lamport; f.device = me; return f })
            try store.write(batch, signingKey: try Self.signingKey())
            d.set(Int(lamport), forKey: "sync.lamport.\(storeID)")
            d.set(seq, forKey: "sync.seq.\(storeID)")
            await refresh()
        } catch {
            problem = error.localizedDescription
        }
    }

    private static func now() -> SyncValue { .real(Date().timeIntervalSince1970) }

    func tag(_ doc: SyncReplay.Document, with rawName: String) async {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        var ops: [SyncOp] = []
        let tagID: String
        if let existing = replay.liveTags.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            tagID = existing.id
        } else {
            tagID = UUID().uuidString
            ops.append(SyncOp(table: "user_tags", key: tagID, fields: [
                "id": .text(tagID), "name": .text(name), "color": .null, "created_at": Self.now(),
                "retired_at": .null, "merged_into": .null], lamport: 0, device: ""))
        }
        let ref = SyncReplay.reference(for: doc)
        ops.append(SyncOp(table: "user_tag_links", key: "\(tagID)|object|\(ref)", fields: [
            "tag_id": .text(tagID), "subject_kind": .text("object"), "subject_id": .text(ref),
            "created_at": Self.now(), "removed_at": .null], lamport: 0, device: ""))
        await send(ops: ops)
    }

    func untag(_ doc: SyncReplay.Document, _ tagName: String) async {
        guard let tag = replay.liveTags.first(where: { $0.name == tagName }) else { return }
        let links = replay.rows("user_tag_links").filter { _, r in
            r.text("tag_id") == tag.id && SyncReplay.refers(r.text("subject_id"), to: doc) && !r.isRemoved
        }
        let ops = links.map { key, r in
            SyncOp(table: "user_tag_links", key: key, fields: ["tag_id": .text(tag.id), "subject_kind": .text("object"),
                "subject_id": r.fields["subject_id"] ?? .null, "created_at": r.fields["created_at"] ?? Self.now(),
                "removed_at": Self.now()], lamport: 0, device: "")
        }
        await send(ops: ops)
    }

    func file(_ doc: SyncReplay.Document, into groupID: String) async {
        let ref = SyncReplay.reference(for: doc)
        await send(ops: [SyncOp(table: "user_group_members", key: "\(groupID)|\(ref)", fields: [
            "group_id": .text(groupID), "object_id": .text(ref), "added_at": Self.now(), "removed_at": .null],
            lamport: 0, device: "")])
    }

    func highlight(_ doc: SyncReplay.Document, quote: String, note: String) async {
        let q = quote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        let id = UUID().uuidString
        let n = note.trimmingCharacters(in: .whitespacesAndNewlines)
        await send(ops: [SyncOp(table: "annotations", key: id, fields: [
            "id": .text(id), "object_id": .text(SyncReplay.reference(for: doc)), "quote": .text(q),
            "note": n.isEmpty ? .null : .text(n), "color": .text("yellow"), "stance": .text("note"),
            "created_at": Self.now(), "removed_at": .null], lamport: 0, device: "")])
    }

    /// Save a Markdown note (new or edited).
    func saveNote(name rawName: String, text: String, editing existing: SyncFileOp?) async {
        guard let store else { return }
        var name = existing?.name ?? rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        name = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        if existing == nil, !name.lowercased().hasSuffix(".md") { name += ".md" }
        do {
            let sha = try store.putBlob(Data(text.utf8))
            if sha == existing?.sha256 { return }
            await send(files: [SyncFileOp(kind: .note, name: name, sha256: sha, origin: nil, trashed: false,
                                          baseSHA256: existing?.sha256, lamport: 0, device: "")])
        } catch { problem = error.localizedDescription }
    }

    /// A scanned document (pages from the camera) as one PDF, added to the archive.
    func addScan(_ images: [UIImage]) async {
        guard let store, !images.isEmpty else { return }
        let pdf = PDFDocument()
        for (i, image) in images.enumerated() { if let page = PDFPage(image: image) { pdf.insert(page, at: i) } }
        guard let data = pdf.dataRepresentation() else { problem = "The scan could not be made into a PDF."; return }
        do {
            let sha = try store.putBlob(data)
            let stamp = Date().formatted(.iso8601.year().month().day().dateSeparator(.dash).time(includingFractionalSeconds: false).timeSeparator(.omitted))
            await send(files: [SyncFileOp(kind: .intake, name: "Scan from \(UIDevice.current.name) \(stamp).pdf", sha256: sha,
                                          origin: "scanned on \(UIDevice.current.name)", trashed: false, baseSHA256: nil,
                                          lamport: 0, device: "")])
        } catch { problem = error.localizedDescription }
    }

    // MARK: - This device

    static var deviceID: String {
        let d = UserDefaults.standard
        if let id = d.string(forKey: "kalsmritikosh.viewer.deviceID") { return id }
        let id = UUID().uuidString
        d.set(id, forKey: "kalsmritikosh.viewer.deviceID")
        return id
    }

    static func signingKey() throws -> Curve25519.Signing.PrivateKey {
        if let raw = ViewerKeychain.load(ViewerKeychain.deviceKey), let k = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) {
            return k
        }
        let k = Curve25519.Signing.PrivateKey()
        try ViewerKeychain.save(k.rawRepresentation, ViewerKeychain.deviceKey)
        return k
    }
}

enum ViewerKeychain {
    static let storeKey = "ecosanskritiinnovation.Kalsmritikosh.viewer.sync-store-key"
    static let deviceKey = "ecosanskritiinnovation.Kalsmritikosh.viewer.sync-device-key"

    struct Failure: Error, LocalizedError {
        let status: OSStatus
        var errorDescription: String? { "The sync key could not be saved on this device (error \(status))." }
    }

    static func load(_ service: String) -> Data? {
        var out: CFTypeRef?
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: "sync", kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
    }

    static func save(_ data: Data, _ service: String) throws {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: "sync"]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let rc = SecItemAdd(add as CFDictionary, nil)
        guard rc == errSecSuccess else { throw Failure(status: rc) }
    }

    static func delete(_ service: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                       kSecAttrAccount as String: "sync"] as CFDictionary)
    }
}
