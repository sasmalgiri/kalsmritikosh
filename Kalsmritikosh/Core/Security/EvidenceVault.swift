//
//  EvidenceVault.swift
//  Kalsmritikosh
//
//  EV-005 — optional managed evidence mode. Two honest modes (05_CANONICAL_EVIDENCE
//  LEDGER §9):
//
//   • Reference mode (default): the source stays in its original location; we keep a
//     bookmark + hash + derived evidence. Old bytes may become unavailable if the file
//     is externally replaced — derived snapshots still read, but reopening the exact
//     original bytes may fail.
//   • Managed mode: the app makes a local, content-addressed, IMMUTABLE copy, so every
//     source version can always be reopened (recommended for investigations/legal).
//
//  This is the vault store for managed mode: a content-addressed file store under the
//  app container, keyed by the SHA-256 the ingest pipeline already computes. Writing the
//  same bytes twice is a no-op (same address), so dedup is free. Deletion is explicit and
//  logged (never a silent cascade) — the caller owns the audit record.
//
//  Disk-only: no schema, no DB rows. Safe to add without a migration.
//
//  IN-02 (smart-map S2, 2026-11-08) — SEALED copies. When the vault is given a seal key (the app derives it
//  from the ledger key: `LedgerKey.derivedKey(for: EvidenceVault.sealPurpose)`), every new copy is stored
//  AES-GCM sealed as `<hash>.sealed`: a header, then 1 MiB chunks each sealed with its index as authenticated
//  data, then a sealed trailer holding the total length — so a truncated, reordered or foreign blob fails to
//  open instead of yielding wrong bytes. The content address stays the SHA-256 of the ORIGINAL bytes. To be
//  viewed, a sealed copy is opened into `<vault>-open/` (owner-only; its SHA-256 re-checked against the
//  address); those opened copies are removed at launch, by erasure and by `remove`. Copies stored by an older
//  build (plain `<hash>`) still open; a sealed copy without the key does not open (never guessed).
//

import Foundation
import CryptoKit
import OSLog

public actor EvidenceVault {
    /// Root directory of the vault (e.g. <container>/EvidenceVault).
    private let root: URL
    private let fm = FileManager.default
    /// IN-02 — AES-GCM key for sealed copies (nil: copies are stored as plain files, the older behaviour).
    private let sealKey: SymmetricKey?

    /// The HKDF purpose under which the app derives the vault key from the ledger key.
    public nonisolated static let sealPurpose = "evidence-vault"

    public init(root: URL, sealKey: SymmetricKey? = nil) {
        self.root = root
        self.sealKey = sealKey
    }

    /// Where sealed copies are opened for viewing: beside the vault, never inside it (so a vault copy or
    /// backup never carries plaintext), owner-only, emptied at launch and by erasure.
    public nonisolated var openedCopiesRoot: URL {
        root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent + "-open", isDirectory: true)
    }

    /// Speed PERF-39 torrent (owner 2026-11-23) — not tested yet: where the vault lives (its disk decides how fast it reads).
    public nonisolated var rootURL: URL { root }

    /// True when new copies are stored sealed.
    public nonisolated var seals: Bool { sealKey != nil }

    /// K11 — copies made before owner-only permissions (0444 files, default folders) are tightened
    /// once: files 0400, folders 0700. A marker records that the pass completed.
    public func protectExisting() {
        let marker = root.appendingPathComponent(".owner-only-v1")
        guard fm.fileExists(atPath: root.path), !fm.fileExists(atPath: marker.path) else { return }
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey])
        while let url = e?.nextObject() as? URL {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            do { try fm.setAttributes([.posixPermissions: isDir ? 0o700 : 0o400], ofItemAtPath: url.path) }
            catch { KalsmritikoshLog.storage.error("Vault permission not tightened: \(error.localizedDescription, privacy: .public)"); return }
        }
        fm.createFile(atPath: marker.path, contents: nil, attributes: [.posixPermissions: 0o400])
    }

    /// Lower-case hex SHA-256 of `data` — the content address.
    public nonisolated static func address(for data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Sharded path for an address: <root>/ab/abcdef… (avoids one huge flat directory).
    private nonisolated func location(for hash: String) -> URL {
        let shard = String(hash.prefix(2))
        return root.appendingPathComponent(shard, isDirectory: true)
                   .appendingPathComponent(hash, isDirectory: false)
    }

    /// Sealed copy path: <root>/ab/abcdef….sealed
    private nonisolated func sealedLocation(for hash: String) -> URL {
        let plain = location(for: hash)
        return plain.deletingLastPathComponent().appendingPathComponent(plain.lastPathComponent + ".sealed", isDirectory: false)
    }

    /// Store `data` immutably, returning its content address. Idempotent: identical bytes
    /// map to the same path, and an existing entry is left untouched (immutable). The file
    /// is marked read-only so an accidental write can't mutate stored evidence.
    @discardableResult
    public func store(_ data: Data) throws -> String {
        let hash = Self.address(for: data)
        if contains(hash) { return hash }   // already vaulted (dedup, sealed or plain)
        let dest = sealKey == nil ? location(for: hash) : sealedLocation(for: hash)
        try fm.createDirectory(at: dest.deletingLastPathComponent(),
                               withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let key = sealKey {
            var sealer = try ChunkSealer(key: key)
            var out = Data(Self.sealedMagic)
            var offset = 0
            repeat {
                let end = min(offset + Self.sealChunk, data.count)
                out.append(try sealer.seal(data.subdata(in: offset..<end)))
                offset = end
            } while offset < data.count
            out.append(try sealer.trailer())
            try out.write(to: dest, options: .atomic)
        } else {
            try data.write(to: dest, options: .atomic)
        }
        // Best-effort immutability: read-only perms. Not a security boundary, a guard.
        try? fm.setAttributes([.posixPermissions: 0o400], ofItemAtPath: dest.path)
        return hash
    }

    /// Copy a file at `url` into the vault, returning its content address.
    @discardableResult
    public func store(contentsOf url: URL) throws -> String {
        try store(Data(contentsOf: url, options: [.mappedIfSafe]))
    }

    /// USF-001.1 — stream a file into the vault in ONE verified pass: the bytes written to
    /// a temp file are the SAME bytes fed to the SHA-256, so the derived content address
    /// always matches the stored content (no second unhashed copy). The source's size +
    /// modification time are snapshotted before and after; if they change mid-copy the copy
    /// fails rather than storing bytes under a mismatched address. Commits atomically to the
    /// content-addressed path and marks the blob read-only. Returns the content address —
    /// which the caller compares against the recorded source-version hash before accepting
    /// `managedCopyStored`.
    @discardableResult
    public func storeStreaming(contentsOf url: URL,
                               availableCapacity: @Sendable (URL) -> Int64? = { DiskSpaceCheck.availableCapacity(at: $0) }) throws -> String {
        let chunkSize = 1 << 20
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        // Deep dive 2026-11-14 batch 1 — this runs off the main thread (S17), where a URL's cached resource values are
        // never flushed: each read takes a fresh copy with its cache cleared (as SourceByteCapture does), so the free-space
        // check sees the current size and a rewrite during the copy is seen.
        func fresh() -> URLResourceValues? {
            var u = url
            u.removeAllCachedResourceValues()
            return try? u.resourceValues(forKeys: keys)
        }
        let pre = fresh()
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw SourceIntakeError.inputNotAccessible(url)
        }
        defer { try? handle.close() }

        // Stage into a unique temp file while hashing the SAME bytes in one pass.
        let stagingDir = root.appendingPathComponent("staging", isDirectory: true)
        try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // S14 (PERF-08) — a stored copy that would not fit is refused before a byte is staged (the staging copy and the
        // committed copy need room together, plus a margin), so a nearly full disk never leaves a half-written original.
        // The caller records the version as "managed copy failed" with this reason; nothing is dropped silently.
        if let size = pre?.fileSize, let available = availableCapacity(stagingDir),
           let needed = DiskSpaceCheck.shortfall(writing: Int64(size), available: available) {
            throw SourceIntakeError.managedCopyFailed(reason: "not enough free space to keep a copy (needs \(needed) bytes, \(available) available)")
        }
        let tmp = stagingDir.appendingPathComponent("tmp-\(UUID().uuidString)")
        fm.createFile(atPath: tmp.path, contents: nil)
        guard let out = try? FileHandle(forWritingTo: tmp) else {
            throw SourceIntakeError.managedCopyFailed(reason: "cannot open vault temp")
        }
        var hasher = SHA256()
        do {
            // IN-02 — with a seal key the SAME chunks are hashed (plaintext address) and sealed in one pass.
            var sealer = try sealKey.map { try ChunkSealer(key: $0) }
            if sealer != nil { try out.write(contentsOf: Self.sealedMagic) }
            while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
                hasher.update(data: chunk)
                if sealer != nil { try out.write(contentsOf: try sealer!.seal(chunk)) } else { try out.write(contentsOf: chunk) }
            }
            if sealer != nil { try out.write(contentsOf: try sealer!.trailer()) }
            try out.close()
        } catch {
            try? out.close(); try? fm.removeItem(at: tmp)
            throw SourceIntakeError.managedCopyFailed(reason: "vault write failed: \(error)")
        }
        // Reject if the source changed while we were copying it.
        let post = fresh()
        if let pre, let post, pre.fileSize != post.fileSize || pre.contentModificationDate != post.contentModificationDate {
            try? fm.removeItem(at: tmp)
            throw SourceIntakeError.sourceChangedDuringCapture(url)
        }
        let hash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        let dest = sealKey == nil ? location(for: hash) : sealedLocation(for: hash)
        if contains(hash) { try? fm.removeItem(at: tmp); return hash }   // dedup (sealed or plain)
        do {
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fm.moveItem(at: tmp, to: dest)
            try? fm.setAttributes([.posixPermissions: 0o400], ofItemAtPath: dest.path)
        } catch {
            try? fm.removeItem(at: tmp)
            if fm.fileExists(atPath: dest.path) { return hash }   // a concurrent writer won the race
            throw SourceIntakeError.managedCopyFailed(reason: "vault commit failed: \(error)")
        }
        guard fm.fileExists(atPath: dest.path) else {
            throw SourceIntakeError.managedCopyFailed(reason: "vault address missing after commit")
        }
        return hash
    }

    /// Speed PERF-24 (owner 2026-11-23) — not tested yet. Vault the intake's OWN immutable snapshot, whose bytes were
    /// hashed as they were written (`knownHash`, `knownSize`): already vaulted → nothing is read; a plain vault →
    /// an APFS clone of the snapshot (no read, no second hash), accepted only when the clone's size is the
    /// captured size; a sealed vault → the one-pass seal + hash of `storeStreaming` (the address is re-proven).
    /// The returned address is compared with the captured hash by the caller, as before.
    @discardableResult
    public func storeSnapshot(at snapshot: URL, knownHash: String, knownSize: Int64) throws -> String {
        let hash = knownHash.lowercased()
        guard hash.count == 64, hash.allSatisfy(\.isHexDigit) else { return try storeStreaming(contentsOf: snapshot) }
        if contains(hash) { return hash }
        guard sealKey == nil else { return try storeStreaming(contentsOf: snapshot) }
        func size(_ u: URL) -> Int64? { (try? fm.attributesOfItem(atPath: u.path)[.size] as? NSNumber)?.int64Value }
        guard size(snapshot) == knownSize else { return try storeStreaming(contentsOf: snapshot) }
        let stagingDir = root.appendingPathComponent("staging", isDirectory: true)
        try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let tmp = stagingDir.appendingPathComponent("tmp-\(UUID().uuidString)")
        do {
            try fm.copyItem(at: snapshot, to: tmp)   // clonefile on APFS; a byte copy elsewhere
        } catch {
            KalsmritikoshLog.storage.error("EvidenceVault: snapshot clone failed, streaming instead: \(error.localizedDescription, privacy: .public)")
            try? fm.removeItem(at: tmp)
            return try storeStreaming(contentsOf: snapshot)
        }
        guard size(tmp) == knownSize else {
            try? fm.removeItem(at: tmp)
            return try storeStreaming(contentsOf: snapshot)
        }
        let dest = location(for: hash)
        do {
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fm.moveItem(at: tmp, to: dest)
            try? fm.setAttributes([.posixPermissions: 0o400], ofItemAtPath: dest.path)
        } catch {
            try? fm.removeItem(at: tmp)
            if fm.fileExists(atPath: dest.path) { return hash }   // a concurrent writer won the race
            throw SourceIntakeError.managedCopyFailed(reason: "vault commit failed: \(error)")
        }
        return hash
    }

    public func contains(_ hash: String) -> Bool {
        fm.fileExists(atPath: location(for: hash).path) || fm.fileExists(atPath: sealedLocation(for: hash).path)
    }

    /// True when the copy for `hash` is stored sealed.
    public func isSealed(_ hash: String) -> Bool {
        fm.fileExists(atPath: sealedLocation(for: hash).path)
    }

    /// ALCOA ALC-05 — what an open found when it re-hashed the bytes it was about to return.
    public nonisolated enum OpenCheck: String, Sendable, Equatable {
        /// The bytes hash to the address (returned).
        case verified
        /// The bytes do NOT hash to the address: refused (a damaged or altered copy; an altered opened copy is removed).
        case mismatch
        /// Not in the vault.
        case notVaulted
        /// In the vault but could not be opened (no or wrong key, unreadable, damaged seal).
        case notOpenable
    }

    /// Lower-case hex SHA-256 of a file, read in 1 MiB chunks (nil when unreadable).
    nonisolated static func sha256(fileAt url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        do {
            while let chunk = try h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        } catch {
            KalsmritikoshLog.storage.error("EvidenceVault: a copy could not be read to re-check: \(error.localizedDescription, privacy: .private)")
            return nil
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Reopen the exact original bytes for a stored version, or nil if not vaulted (or sealed and the key is
    /// missing or wrong, or the bytes no longer hash to the address).
    public func data(for hash: String) -> Data? { checkedData(for: hash).data }

    /// ALCOA ALC-05 — `data(for:)` with what the re-check found: a plain copy is re-hashed before it is returned (a
    /// mismatch is refused), as a sealed one always was.
    public func checkedData(for hash: String) -> (data: Data?, check: OpenCheck) {
        let plain = location(for: hash)
        if fm.fileExists(atPath: plain.path) {
            guard let d = try? Data(contentsOf: plain, options: [.mappedIfSafe]) else { return (nil, .notOpenable) }
            guard Self.address(for: d) == hash.lowercased() else {
                KalsmritikoshLog.storage.error("EvidenceVault: plain copy \(hash.prefix(12), privacy: .public)… does not hash to its address; refused")
                return (nil, .mismatch)
            }
            return (d, .verified)
        }
        return sealedData(for: hash)
    }

    private func sealedData(for hash: String) -> (data: Data?, check: OpenCheck) {
        let sealed = sealedLocation(for: hash)
        guard fm.fileExists(atPath: sealed.path) else { return (nil, .notVaulted) }
        guard let key = sealKey else {
            KalsmritikoshLog.storage.error("EvidenceVault: sealed copy \(hash.prefix(12), privacy: .public)… cannot be opened without the vault key")
            return (nil, .notOpenable)
        }
        do {
            // Speed PERF-24 (owner 2026-11-23) — not tested yet: the plaintext is hashed WHILE it is unsealed (one pass),
            // not hashed again afterwards; the check is unchanged — the bytes returned must hash to the address.
            var out = Data()
            if let size = (try? fm.attributesOfItem(atPath: sealed.path)[.size] as? NSNumber)?.intValue { out.reserveCapacity(size) }
            var hasher = SHA256()
            try Self.unseal(fileAt: sealed, key: key) { chunk in
                hasher.update(data: chunk)
                out.append(chunk)
            }
            guard hasher.finalize().map({ String(format: "%02x", $0) }).joined() == hash.lowercased() else {
                KalsmritikoshLog.storage.error("EvidenceVault: sealed copy \(hash.prefix(12), privacy: .public)… does not hash to its address")
                return (nil, .mismatch)
            }
            return (out, .verified)
        } catch {
            KalsmritikoshLog.storage.error("EvidenceVault: sealed copy \(hash.prefix(12), privacy: .public)… did not open: \(String(describing: error), privacy: .public)")
            return (nil, .notOpenable)
        }
    }

    /// A file URL holding exactly the original bytes: the plain copy itself, or — for a sealed copy — an
    /// owner-only opened copy beside the vault, verified against the address. nil when not vaulted or not
    /// openable (missing/wrong key, damaged or tampered copy): the caller labels it, never substitutes.
    ///
    /// `filename` (the version's own file name) names the opened copy, so a viewer sees the original name and
    /// type (a PDF opens as a PDF): `<vault>-open/<hash>/<filename>`. A plain copy is then linked under that name.
    public func url(for hash: String, filename: String? = nil) -> URL? { checkedURL(for: hash, filename: filename).url }

    /// ALCOA ALC-05 — a copy about to be returned is re-hashed: a mismatch is refused (an altered opened copy is removed,
    /// so the next open makes it again from the verified original).
    private func recheck(_ url: URL, _ hash: String, removable: Bool) -> Bool {
        guard Self.sha256(fileAt: url) == hash.lowercased() else {
            KalsmritikoshLog.storage.error("EvidenceVault: copy \(hash.prefix(12), privacy: .public)… does not hash to its address; refused")
            if removable {
                try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                do { try fm.removeItem(at: url) } catch {
                    KalsmritikoshLog.storage.error("EvidenceVault: altered opened copy not removed: \(error.localizedDescription, privacy: .public)")
                }
            }
            return false
        }
        return true
    }

    private func sameFile(_ a: URL, _ b: URL) -> Bool {
        func number(_ u: URL) -> UInt64? { (try? fm.attributesOfItem(atPath: u.path)[.systemFileNumber] as? NSNumber)?.uint64Value }
        guard let x = number(a), let y = number(b) else { return false }
        return x == y
    }

    /// `url(for:filename:)` with what the re-check found (ALCOA ALC-05): the plain copy and any already-opened copy are
    /// re-hashed before they are returned; opened copies are read-only (0400).
    public func checkedURL(for hash: String, filename: String? = nil) -> (url: URL?, check: OpenCheck) {
        let u = location(for: hash)
        let name = Self.safeOpenedName(filename)
        if fm.fileExists(atPath: u.path) {
            guard recheck(u, hash, removable: false) else { return (nil, .mismatch) }
            guard let name else { return (u, .verified) }
            let named = openedCopiesRoot.appendingPathComponent(hash.lowercased(), isDirectory: true).appendingPathComponent(name)
            if fm.fileExists(atPath: named.path) {
                // A hard link IS the plain copy (just re-checked); a separate copy is re-checked itself.
                if sameFile(named, u) || recheck(named, hash, removable: true) { return (named, .verified) }
                return (nil, .mismatch)
            }
            do {
                try fm.createDirectory(at: named.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                do { try fm.linkItem(at: u, to: named) } catch {
                    try fm.copyItem(at: u, to: named)
                    try? fm.setAttributes([.posixPermissions: 0o400], ofItemAtPath: named.path)
                }
                return (named, .verified)
            } catch {
                KalsmritikoshLog.storage.error("EvidenceVault: named copy not made, the plain copy is used: \(error.localizedDescription, privacy: .public)")
                return (u, .verified)
            }
        }
        let sealed = sealedLocation(for: hash)
        guard fm.fileExists(atPath: sealed.path) else { return (nil, .notVaulted) }
        guard let key = sealKey else {
            KalsmritikoshLog.storage.error("EvidenceVault: sealed copy \(hash.prefix(12), privacy: .public)… cannot be opened without the vault key")
            return (nil, .notOpenable)
        }
        let folder = openedCopiesRoot.appendingPathComponent(hash.lowercased(), isDirectory: true)
        let opened = folder.appendingPathComponent(name ?? hash.lowercased(), isDirectory: false)
        if fm.fileExists(atPath: opened.path) {
            guard recheck(opened, hash, removable: true) else { return (nil, .mismatch) }
            return (opened, .verified)
        }
        do {
            try fm.createDirectory(at: openedCopiesRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let tmp = folder.appendingPathComponent("tmp-\(UUID().uuidString)")
            fm.createFile(atPath: tmp.path, contents: nil, attributes: [.posixPermissions: 0o600])
            let out = try FileHandle(forWritingTo: tmp)
            var hasher = SHA256()
            do {
                try Self.unseal(fileAt: sealed, key: key) { chunk in
                    hasher.update(data: chunk)
                    try out.write(contentsOf: chunk)
                }
                try out.close()
            } catch {
                try? out.close(); try? fm.removeItem(at: tmp)
                throw error
            }
            guard hasher.finalize().map({ String(format: "%02x", $0) }).joined() == hash.lowercased() else {
                try? fm.removeItem(at: tmp)
                KalsmritikoshLog.storage.error("EvidenceVault: sealed copy \(hash.prefix(12), privacy: .public)… does not hash to its address; not opened")
                return (nil, .mismatch)
            }
            if fm.fileExists(atPath: opened.path) { try? fm.removeItem(at: tmp); return (opened, .verified) }
            try fm.moveItem(at: tmp, to: opened)
            try? fm.setAttributes([.posixPermissions: 0o400], ofItemAtPath: opened.path)
            return (opened, .verified)
        } catch {
            KalsmritikoshLog.storage.error("EvidenceVault: sealed copy \(hash.prefix(12), privacy: .public)… did not open: \(String(describing: error), privacy: .public)")
            return (nil, .notOpenable)
        }
    }

    /// Owner-writable files (0600) and traversable folders (0700) under `dir`, so removal can proceed.
    private func makeRemovable(_ dir: URL) {
        guard let e = fm.enumerator(at: dir, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        for case let f as URL in e {
            let isDir = (try? f.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            try? fm.setAttributes([.posixPermissions: isDir ? 0o700 : 0o600], ofItemAtPath: f.path)
        }
    }

    /// A file name safe to create inside the opened-copies folder (no path, no leading dot), or nil.
    nonisolated static func safeOpenedName(_ filename: String?) -> String? {
        guard let raw = filename?.split(separator: "/").last.map(String.init) else { return nil }
        var name = raw.replacingOccurrences(of: ":", with: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        guard !name.isEmpty, !name.hasPrefix("tmp-") else { return nil }
        if name.utf8.count > 200 {
            let ext = (name as NSString).pathExtension
            name = String(name.prefix(150)) + (ext.isEmpty ? "" : "." + ext)
        }
        return name
    }

    /// Remove every opened (plaintext) copy of sealed originals — at launch and by erasure.
    public func removeOpenedCopies() {
        guard fm.fileExists(atPath: openedCopiesRoot.path) else { return }
        makeRemovable(openedCopiesRoot)
        do { try fm.removeItem(at: openedCopiesRoot) } catch {
            KalsmritikoshLog.storage.error("EvidenceVault: opened copies not removed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Sealed format (IN-02)

    nonisolated static let sealedMagic = Data("IMEVAULT-SEALED-1\n".utf8)
    nonisolated static let sealChunk = 1 << 20

    public nonisolated enum SealError: Error, Equatable { case notSealed, truncated, damaged, lengthMismatch }

    /// Seals consecutive chunks: each record is a 4-byte big-endian length + AES-GCM combined box, with the
    /// chunk index (and a final flag for the trailer) as authenticated data.
    nonisolated struct ChunkSealer {
        let key: SymmetricKey
        var index: UInt64 = 0
        var total: UInt64 = 0
        init(key: SymmetricKey) throws { self.key = key }
        mutating func seal(_ chunk: Data) throws -> Data {
            defer { index += 1; total += UInt64(chunk.count) }
            return try EvidenceVault.record(chunk, key: key, index: index, final: false)
        }
        func trailer() throws -> Data {
            var t = total.bigEndian
            return try EvidenceVault.record(Data(bytes: &t, count: 8), key: key, index: index, final: true)
        }
    }

    nonisolated static func aad(index: UInt64, final: Bool) -> Data {
        var i = index.bigEndian
        return Data(bytes: &i, count: 8) + Data([final ? 1 : 0])
    }

    nonisolated static func record(_ plain: Data, key: SymmetricKey, index: UInt64, final: Bool) throws -> Data {
        guard let box = try AES.GCM.seal(plain, using: key, authenticating: aad(index: index, final: final)).combined else {
            throw SealError.damaged
        }
        var len = UInt32(box.count).bigEndian
        return Data(bytes: &len, count: 4) + box
    }

    /// Stream the original bytes of a sealed copy to `sink`, failing on any missing, reordered, altered or
    /// foreign record (and on a length that does not match the trailer).
    // MARK: - ALCOA ALC-21: re-seal every copy under a rotated key

    nonisolated static let resealSuffix = ".next"

    /// Every sealed copy under `root` re-sealed with `newKey` beside it (`<hash>.sealed.next`, owner-only), each checked by
    /// opening it with the new key and hashing it to its address before it counts. The originals are not touched (a
    /// crash leaves them openable with the old key; `promoteResealed` swaps them in). Returns how many were re-sealed.
    nonisolated static func reseal(root: URL, from oldKey: SymmetricKey, to newKey: SymmetricKey) throws -> Int {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return 0 }
        var count = 0
        let e = fm.enumerator(at: root, includingPropertiesForKeys: nil)
        while let url = e?.nextObject() as? URL {
            guard url.pathExtension == "sealed" else { continue }
            let hash = url.deletingPathExtension().lastPathComponent.lowercased()
            var sealer = try ChunkSealer(key: newKey)
            var out = Data(sealedMagic)
            var hasher = SHA256()
            try unseal(fileAt: url, key: oldKey) { chunk in
                hasher.update(data: chunk)
                var offset = 0
                repeat {
                    let end = min(offset + sealChunk, chunk.count)
                    out.append(try sealer.seal(chunk.subdata(in: offset..<end)))
                    offset = end
                } while offset < chunk.count
            }
            guard hasher.finalize().map({ String(format: "%02x", $0) }).joined() == hash else { throw SealError.truncated }
            out.append(try sealer.trailer())
            let next = URL(fileURLWithPath: url.path + resealSuffix)
            try? fm.removeItem(at: next)
            try out.write(to: next, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: next.path)
            var check = SHA256()
            try unseal(fileAt: next, key: newKey) { check.update(data: $0) }
            guard check.finalize().map({ String(format: "%02x", $0) }).joined() == hash else { throw SealError.truncated }
            count += 1
        }
        return count
    }

    /// Swap every re-sealed copy in (`.sealed.next` → `.sealed`, read-only again). Returns how many were swapped.
    @discardableResult
    nonisolated static func promoteResealed(root: URL) throws -> Int {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return 0 }
        var n = 0
        let e = fm.enumerator(at: root, includingPropertiesForKeys: nil)
        var nexts: [URL] = []
        while let url = e?.nextObject() as? URL { if url.lastPathComponent.hasSuffix(".sealed" + resealSuffix) { nexts.append(url) } }
        for next in nexts {
            let target = URL(fileURLWithPath: String(next.path.dropLast(resealSuffix.count)))
            if fm.fileExists(atPath: target.path) {
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
                _ = try fm.replaceItemAt(target, withItemAt: next)
            } else {
                try fm.moveItem(at: next, to: target)
            }
            try fm.setAttributes([.posixPermissions: 0o400], ofItemAtPath: target.path)
            n += 1
        }
        return n
    }

    /// Remove re-sealed copies left by an interrupted rotation (the originals still open with the old key).
    nonisolated static func discardResealed(root: URL) {
        let fm = FileManager.default
        let e = fm.enumerator(at: root, includingPropertiesForKeys: nil)
        var nexts: [URL] = []
        while let url = e?.nextObject() as? URL { if url.lastPathComponent.hasSuffix(".sealed" + resealSuffix) { nexts.append(url) } }
        for next in nexts {
            do { try fm.removeItem(at: next) } catch {
                KalsmritikoshLog.storage.error("EvidenceVault: an interrupted re-seal copy was not removed: \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    nonisolated static func unseal(fileAt url: URL, key: SymmetricKey, sink: (Data) throws -> Void) throws {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        guard try h.read(upToCount: sealedMagic.count) == sealedMagic else { throw SealError.notSealed }
        var index: UInt64 = 0
        var total: UInt64 = 0
        while true {
            guard let lenData = try h.read(upToCount: 4), lenData.count == 4 else { throw SealError.truncated }
            let len = lenData.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard len >= 28, len <= UInt32(sealChunk + 64), let boxData = try h.read(upToCount: Int(len)), boxData.count == Int(len) else {
                throw SealError.truncated
            }
            let box = try AES.GCM.SealedBox(combined: boxData)
            if let plain = try? AES.GCM.open(box, using: key, authenticating: aad(index: index, final: false)) {
                try sink(plain)
                total += UInt64(plain.count)
                index += 1
                continue
            }
            // Not a data chunk at this position: it must be the trailer, and nothing may follow it.
            guard let t = try? AES.GCM.open(box, using: key, authenticating: aad(index: index, final: true)), t.count == 8 else {
                throw SealError.damaged
            }
            guard t.reduce(UInt64(0), { ($0 << 8) | UInt64($1) }) == total else { throw SealError.lengthMismatch }
            guard (try h.read(upToCount: 1))?.isEmpty ?? true else { throw SealError.damaged }
            return
        }
    }

    /// Total bytes currently stored — shown to the user before/after copying.
    public func totalBytes() -> Int64 {
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in e {
            total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    /// Estimate the bytes a copy would add — 0 if already vaulted (dedup). Lets the UI
    /// show storage impact BEFORE copying, per the spec.
    public nonisolated func estimatedAddedBytes(for data: Data) async -> Int64 {
        await contains(Self.address(for: data)) ? 0 : Int64(data.count)
    }

    /// Explicit, audited deletion (the caller records the audit event). Removing the
    /// content-addressed copy means that version's original bytes can no longer be
    /// reopened — the derived evidence is unaffected. No-op if absent.
    public func remove(_ hash: String) throws {
        // The opened (plaintext / named) copies of this original go with it.
        let opened = openedCopiesRoot.appendingPathComponent(hash.lowercased(), isDirectory: true)
        if fm.fileExists(atPath: opened.path) {
            makeRemovable(opened)
            try fm.removeItem(at: opened)
        }
        let candidates = [location(for: hash), sealedLocation(for: hash)].filter { fm.fileExists(atPath: $0.path) }
        guard !candidates.isEmpty else { return }
        for u in candidates {
            try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: u.path)  // allow removal
            try fm.removeItem(at: u)
        }
        KalsmritikoshLog.storage.notice("EvidenceVault: removed \(hash.prefix(12), privacy: .public)… (explicit user action)")
    }
}
