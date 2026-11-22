//
//  BackupService.swift
//  Kalsmritikosh
//
//  G2/Stage-11 / AT-15 — the thin I/O layer on top of the pure
//  BackupManifest core. It copies the database and the named original
//  sources into a backup folder, records each file's real size + sha256 in
//  a manifest.json, and restores by validating that manifest against what is
//  actually present before copying anything back. HONEST: a restore whose
//  manifest lists originals that are missing is refused with the missing
//  files named — never a silent partial restore.
//
//  Deterministic file set (caller supplies the URLs); no network; no app
//  singletons — testable against a temp directory.
//

import Foundation
import CryptoKit
import SQLCipher
import os

public struct BackupService: Sendable {
    public init() { self.failPromotionAfter = nil; self.simulateCrashAfter = nil; self.failAfterSwap = false }

    public static let manifestName = "manifest.json"

    public enum BackupError: Error, Sendable {
        case manifestMissing
        case restoreIncomplete(missing: [String])
        case notADatabaseBackup
        /// F19 — a manifest path that is unsafe, duplicated, or a symlink.
        case unsafeEntry(String)
        /// F19 — entries whose bytes do not match the manifest (in the backup or the staged copy).
        case damaged([String])
        /// F19 — the staged database failed SQLite's integrity check.
        case databaseUnusable(String)
        /// F19 — promotion stopped part-way; everything was rolled back.
        case promotionFailed(String)
        /// W2-7 — the backup's ledger is encrypted with a key this Mac does not hold.
        case encryptedWithAnotherKey
        /// T2 — the destination volume does not have room for the backup (nothing was written).
        case insufficientSpace(needed: Int64, available: Int64)
        /// T2 — the backup was made by a newer version of the app (a newer ledger schema).
        case newerSchema(backup: Int, supported: Int)
        /// S11 (RECOVERY-07) — the manifest's signature does not match: it was changed after the backup was made.
        case manifestAltered
    }

    // MARK: - S11 (RECOVERY-07) manifest signature

    public static let signatureName = "signature.json"
    static let signaturePurpose = "backup-manifest"

    struct Signature: Codable { var version = 1; var algorithm = "HMAC-SHA256"; var keyPurpose = BackupService.signaturePurpose; var mac: String }

    /// HMAC-SHA256 of the manifest's exact bytes with a key derived from the ledger key (the recovery key opens it on any Mac).
    static func mac(_ manifestData: Data, key: LedgerKey) -> String {
        Data(HMAC<SHA256>.authenticationCode(for: manifestData, using: key.derivedKey(for: signaturePurpose))).map { String(format: "%02x", $0) }.joined()
    }

    static func writeSignature(manifestData: Data, key: LedgerKey?, in folder: URL) throws {
        guard let key else { return }
        try JSONEncoder().encode(Signature(mac: mac(manifestData, key: key))).write(to: folder.appendingPathComponent(signatureName), options: .atomic)
    }

    static func signatureState(in folder: URL, manifestData: Data, key: LedgerKey?) -> BackupSignatureState {
        let url = folder.appendingPathComponent(signatureName)
        guard FileManager.default.fileExists(atPath: url.path) else { return .absent }
        guard let key else { return .notChecked }
        let sig: Signature
        do { sig = try JSONDecoder().decode(Signature.self, from: Data(contentsOf: url)) } catch {
            KalsmritikoshLog.storage.error("Backup signature unreadable: \(error.localizedDescription, privacy: .private)")
            return .invalid
        }
        return sig.mac.lowercased() == mac(manifestData, key: key) ? .valid : .invalid
    }

    // MARK: - S11 (RECOVERY-09) interrupted restores

    static let journalName = "restore-journal.json"
    struct Journal: Codable { var paths: [String] }

    /// A restore that stopped part-way (the app quit or crashed while files were being promoted) leaves its aside folder
    /// ".<ledger folder>.previous-<token>" with a journal of the paths it was promoting. Put every displaced file back, remove
    /// what was promoted where nothing was before, and remove leftover staging folders: the ledger is exactly as it was before
    /// that restore, and the still-scheduled restore runs again from the start (deterministic retry). Returns what was done.
    @discardableResult
    public static func recoverInterruptedRestores(ledgerFolder target: URL) -> [String] {
        let fm = FileManager.default
        let parent = target.deletingLastPathComponent()
        let name = target.lastPathComponent
        var notes: [String] = []
        let siblings: [URL]
        do { siblings = try fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil) } catch { return [] }
        for dir in siblings where dir.lastPathComponent.hasPrefix(".\(name).restore-") {
            do { try fm.removeItem(at: dir) } catch { KalsmritikoshLog.storage.error("Restore staging not removed: \(error.localizedDescription, privacy: .private)") }
        }
        for aside in siblings where aside.lastPathComponent.hasPrefix(".\(name).previous-") {
            let journalURL = aside.appendingPathComponent(journalName)
            let paths: [String]
            do { paths = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: journalURL)).paths } catch {
                KalsmritikoshLog.storage.error("Interrupted restore has no readable journal: \(error.localizedDescription, privacy: .private)")
                notes.append("An interrupted restore left files aside in “\(aside.lastPathComponent)” without a readable journal; they were kept there.")
                continue
            }
            var restored = 0, removed = 0
            for rel in paths where RestoreValidator.isSafeRelativePath(rel) {
                let t = target.appendingPathComponent(rel), saved = aside.appendingPathComponent(rel)
                do {
                    if fm.fileExists(atPath: saved.path) {
                        if fm.fileExists(atPath: t.path) { try fm.removeItem(at: t) }
                        try fm.createDirectory(at: t.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try fm.moveItem(at: saved, to: t); restored += 1
                    } else if fm.fileExists(atPath: t.path) {
                        try fm.removeItem(at: t); removed += 1
                    }
                } catch {
                    KalsmritikoshLog.storage.error("Interrupted restore not fully undone: \(error.localizedDescription, privacy: .private)")
                    notes.append("A file of an interrupted restore could not be put back (\(rel)); “\(aside.lastPathComponent)” is kept.")
                    continue
                }
            }
            if !notes.contains(where: { $0.contains(aside.lastPathComponent) }) {
                do { try fm.removeItem(at: aside) } catch { KalsmritikoshLog.storage.error("Restore aside not removed: \(error.localizedDescription, privacy: .private)") }
            }
            notes.append("A restore that was interrupted was undone: \(restored) file(s) put back, \(removed) partly restored file(s) removed. Your ledger is as it was before that restore.")
        }
        return notes
    }

    /// Copy the database + originals into `destination`, writing a manifest.
    /// Returns the manifest actually written. `relativePath` for each file is
    /// its last path component (stable, no absolute paths leak into the backup).
    @discardableResult
    public func createBackup(
        databaseURL: URL,
        originalURLs: [URL],
        destination: URL,
        schemaVersion: Int,
        nowEpoch: Double,
        coverage: BackupCoverage = .ledgerOnly,
        signingKey: LedgerKey? = nil
    ) throws -> BackupManifest {
        try Self.checkSpace(for: [databaseURL] + originalURLs, at: destination)
        return try Self.staged(destination) { staging in
            try writeBackup(databaseURL: databaseURL, originalURLs: originalURLs, destination: staging,
                            schemaVersion: schemaVersion, nowEpoch: nowEpoch, coverage: coverage, signingKey: signingKey)
        }
    }

    private func writeBackup(
        databaseURL: URL,
        originalURLs: [URL],
        destination: URL,
        schemaVersion: Int,
        nowEpoch: Double,
        coverage: BackupCoverage,
        signingKey: LedgerKey?
    ) throws -> BackupManifest {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)

        var usedNames = Self.reservedNames
        // F17 — a UNIQUE relative path per entry: two originals named "letter.txt" used to share
        // one backup path, so the second overwrote the first and the manifest listed it twice.
        // NOTE: the `-wal` / `-shm` sidecars are NOT added here. The caller
        // passes them in `originalURLs` (see SettingsView), so adding them
        // again would write two manifest entries with the same relativePath.
        // The connection runs in WAL mode, so those sidecars matter — the
        // caller also checkpoints first (`Database.checkpointWAL`) so the main
        // file is self-contained and the copy cannot catch a torn state.
        let plan: [(src: URL, name: String, kind: BackupEntry.Kind)] = ([(databaseURL, BackupEntry.Kind.database)] + originalURLs.map { ($0, .originalSource) })
            .map { (src: $0.0, name: Self.uniqueName(for: $0.0.lastPathComponent, taken: &usedNames), kind: $0.1) }
        // Speed PERF-25 (owner 2026-11-23) — not tested yet. Copy + hash in one pass (8 MB buffers), files in parallel with
        // work stealing, each finished file logged so an interrupted backup resumes.
        let log = CopyResumeLog(folder: destination)
        let results = try Self.copyAll(plan.map { ($0.src, $0.name) }, into: destination, log: log)
        let entries = plan.indices.map { i in
            BackupEntry(relativePath: plan[i].name, byteSize: results[i].byteSize, sha256: results[i].sha256, kind: plan[i].kind)
        }
        log.remove()

        let manifest = BackupPlanner.manifest(schemaVersion: schemaVersion,
                                              createdAtEpoch: nowEpoch, entries: entries, coverage: coverage)
        let json = try JSONEncoder().encode(manifest)
        try json.write(to: destination.appendingPathComponent(Self.manifestName))
        try Self.writeSignature(manifestData: json, key: signingKey, in: destination)
        return manifest
    }

    // MARK: - T2 — a backup write that fails never damages the backup already there

    /// Write the backup into a staging folder beside `destination` and move it into place only when
    /// every file and the manifest are written. A failure part-way (a full disk, an unreadable file)
    /// removes the staging folder and leaves whatever was at `destination` exactly as it was.
    static func staged(_ destination: URL, _ write: (URL) throws -> BackupManifest) throws -> BackupManifest {
        let fm = FileManager.default
        let parent = destination.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let token = UUID().uuidString
        // Speed PERF-25 (owner 2026-11-23) — not tested yet. The staging folder has a fixed name per destination and is
        // KEPT when a write fails (with its resume log), so the next backup to the same place copies only what is missing.
        let staging = parent.appendingPathComponent(".\(destination.lastPathComponent).writing-resume", isDirectory: true)
        let aside = parent.appendingPathComponent(".\(destination.lastPathComponent).replaced-\(token)", isDirectory: true)
        var succeeded = false
        defer {
            let hasLog = fm.fileExists(atPath: staging.appendingPathComponent(CopyResumeLog.fileName).path)
            if succeeded || !hasLog { try? fm.removeItem(at: staging) }
        }
        let manifest = try write(staging)
        Self.pruneUnlisted(in: staging, keeping: Set(manifest.entries.map(\.relativePath)))
        succeeded = true
        let hadPrevious = fm.fileExists(atPath: destination.path)
        if hadPrevious { try fm.moveItem(at: destination, to: aside) }
        do { try fm.moveItem(at: staging, to: destination) } catch {
            if hadPrevious { try? fm.moveItem(at: aside, to: destination) }   // put the previous backup back
            throw error
        }
        if hadPrevious { try? fm.removeItem(at: aside) }
        return manifest
    }

    /// Refuse before writing anything when the destination volume cannot hold the backup.
    static func checkSpace(for inputs: [URL], at destination: URL) throws {
        let needed = inputs.reduce(Int64(0)) { sum, url in
            sum + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        var probe = destination
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 { probe.deleteLastPathComponent() }
        guard let available = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
        else { return }   // capacity unknown: the staged write still protects the previous backup
        try requireSpace(needed: needed, available: available)
    }

    static func requireSpace(needed: Int64, available: Int64) throws {
        // Room for the copies plus the manifest and a margin.
        let margin = max(Int64(1 << 20), needed / 20)
        if available < needed + margin { throw BackupError.insufficientSpace(needed: needed + margin, available: available) }
    }

    /// Validate a backup folder against its manifest WITHOUT copying — the
    /// honest pre-restore check the UI shows before touching anything.
    public func inspect(backupFolder: URL, ledgerKey: LedgerKey? = nil) throws -> (manifest: BackupManifest, verdict: RestoreVerdict) {
        let r = try inspect(backupFolder: backupFolder, ledgerKey: ledgerKey, stagingInto: nil)
        return (r.manifest, r.verdict)
    }

    /// `inspect`; with `stagingInto`, each entry is COPIED into that folder while it is hashed (one read of the backup
    /// instead of a verify pass and then a copy pass), so the staged copies carry exactly the bytes that were verified.
    /// Symlinked entries are never copied and come back in `symlinks`.
    /// Speed PERF-25 (owner 2026-11-23) — not tested yet: entries hashed in parallel with work stealing, 8 MB reads.
    func inspect(backupFolder: URL, ledgerKey: LedgerKey?, stagingInto staging: URL?) throws
        -> (manifest: BackupManifest, verdict: RestoreVerdict, symlinks: [String]) {
        let fm = FileManager.default
        let manifestURL = backupFolder.appendingPathComponent(Self.manifestName)
        guard let data = try? Data(contentsOf: manifestURL) else { throw BackupError.manifestMissing }
        let manifest = try JSONDecoder().decode(BackupManifest.self, from: data)
        let signature = Self.signatureState(in: backupFolder, manifestData: data, key: ledgerKey)
        // F17 — verify CONTENT: stream-hash every entry that exists (never following an unsafe path
        // out of the backup folder) and compare size + SHA-256 with the manifest.
        let safe = manifest.entries.filter { RestoreValidator.isSafeRelativePath($0.relativePath) }
        let observedBox = OSAllocatedUnfairLock(initialState: [String: ObservedBackupFile]())
        let linksBox = OSAllocatedUnfairLock(initialState: [String]())
        try WorkStealingQueue.perform(count: safe.count, workers: WorkStealingQueue.copyWidth()) { i in
            let entry = safe[i]
            let url = backupFolder.appendingPathComponent(entry.relativePath)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { return }
            if let staging {
                if (try? fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeSymbolicLink {
                    linksBox.withLock { $0.append(entry.relativePath) }
                    return
                }
                let dst = staging.appendingPathComponent(entry.relativePath)
                do {
                    try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let m = try StreamingFileCopy.copyAndHash(from: url, to: dst)
                    observedBox.withLock { $0[entry.relativePath] = ObservedBackupFile(byteSize: m.byteSize, sha256: m.sha256) }
                } catch {
                    KalsmritikoshLog.storage.error("Restore: a backup file could not be staged: \(error.localizedDescription, privacy: .private)")
                }
                return
            }
            do {
                let measured = try Self.measure(url)
                observedBox.withLock { $0[entry.relativePath] = measured }
            } catch {
                KalsmritikoshLog.storage.error("Backup inspect: a file could not be read: \(error.localizedDescription, privacy: .private)")
            }
        }
        var verdict = RestoreValidator.validate(manifest: manifest, observed: observedBox.withLock { $0 })
        verdict.signature = signature
        return (manifest, verdict, linksBox.withLock { $0 })
    }

    /// F17 — size + SHA-256 of a file, streamed. Speed PERF-25 (owner 2026-11-23) — not tested yet: 8 MB reads.
    static func measure(_ url: URL) throws -> ObservedBackupFile {
        let m = try StreamingFileCopy.hash(url)
        return ObservedBackupFile(byteSize: m.byteSize, sha256: m.sha256)
    }

    /// Speed PERF-25 (owner 2026-11-23) — not tested yet. Copy every (source, relative path) into `folder`, hashing in the
    /// same pass, files in parallel with work stealing (big and small files balance out); results in input order. The
    /// first failure stops the rest and is thrown (files already done stay logged for a resume).
    static func copyAll(_ items: [(src: URL, rel: String)], into folder: URL, log: CopyResumeLog) throws -> [StreamingFileCopy.Measured] {
        let results = OSAllocatedUnfairLock(initialState: [StreamingFileCopy.Measured?](repeating: nil, count: items.count))
        try WorkStealingQueue.perform(count: items.count, workers: WorkStealingQueue.copyWidth()) { i in
            let m = try log.copy(items[i].src, to: folder, relativePath: items[i].rel)
            results.withLock { $0[i] = m }
        }
        return try results.withLock { r in
            try r.map { m in
                guard let m else { throw StreamingFileCopy.CopyError.write(EIO) }
                return m
            }
        }
    }

    /// Speed PERF-25 (owner 2026-11-23) — not tested yet. As `copyAll`, but a file that cannot be read is nil (logged)
    /// and the others go on.
    static func copyEach(_ items: [(src: URL, rel: String)], into folder: URL, log: CopyResumeLog) -> [StreamingFileCopy.Measured?] {
        let results = OSAllocatedUnfairLock(initialState: [StreamingFileCopy.Measured?](repeating: nil, count: items.count))
        do {
            try WorkStealingQueue.perform(count: items.count, workers: WorkStealingQueue.copyWidth()) { i in
                do {
                    let m = try log.copy(items[i].src, to: folder, relativePath: items[i].rel)
                    results.withLock { $0[i] = m }
                } catch {
                    KalsmritikoshLog.storage.error("Backup: a file not copied: \(error.localizedDescription, privacy: .private)")
                }
            }
        } catch {
            KalsmritikoshLog.storage.error("Backup: copy workers stopped: \(error.localizedDescription, privacy: .private)")
        }
        return results.withLock { $0 }
    }

    /// Speed PERF-25 (owner 2026-11-23) — not tested yet. Files a resumed staging folder still holds from an earlier
    /// attempt that this backup does not list are removed (our own temporary copies, never a user's file), so the backup
    /// folder holds exactly its manifest's entries and control files.
    static func pruneUnlisted(in staging: URL, keeping listed: Set<String>) {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: staging, includingPropertiesForKeys: [.isRegularFileKey]) else { return }
        let base = staging.standardizedFileURL.path
        for case let file as URL in en {
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let rel = String(file.standardizedFileURL.path.dropFirst(base.count + 1))
            if listed.contains(rel) || reservedNames.contains(rel.lowercased()) || rel == sourcesMapName { continue }
            do { try fm.removeItem(at: file) } catch {
                KalsmritikoshLog.storage.error("Backup staging: a leftover copy not removed: \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    /// "letter.txt", then "letter-2.txt", "letter-3.txt", … in input order (deterministic).
    /// `taken` holds lowercased names: the backup folder usually sits on a case-insensitive
    /// volume, where "Letter.txt" and "letter.txt" are the same file.
    static func uniqueName(for name: String, taken: inout Set<String>) -> String {
        if taken.insert(name.lowercased()).inserted { return name }
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        var n = 2
        while true {
            let candidate = ext.isEmpty ? "\(stem)-\(n)" : "\(stem)-\(n).\(ext)"
            if taken.insert(candidate.lowercased()).inserted { return candidate }
            n += 1
        }
    }

    /// Control files a backup or signed snapshot writes beside the copied files. An original
    /// with one of these names is renamed ("manifest-2.json") so it can never replace — or be
    /// replaced by — the manifest, the signature or the sources map. Lowercased.
    static let reservedNames: Set<String> = [manifestName.lowercased(), "signature.json", "kalsnapshot-sources.json"]

    /// F19 — test hook: throw after this many files have been promoted (simulates a mid-restore
    /// failure such as a full disk). nil in production.
    let failPromotionAfter: Int?
    init(failPromotionAfter: Int?) { self.failPromotionAfter = failPromotionAfter; self.simulateCrashAfter = nil; self.failAfterSwap = false }
    /// S11 (RECOVERY-09) — test hook: stop promotion after this many files WITHOUT rolling back (the process died). nil in
    /// production.
    let simulateCrashAfter: Int?
    init(simulateCrashAfter: Int?) { self.failPromotionAfter = nil; self.simulateCrashAfter = simulateCrashAfter; self.failAfterSwap = false }
    struct SimulatedCrash: Error {}
    /// Deep dive 2 (#2) — test hook: a complete restore fails after its files are swapped in and its completion steps ran
    /// (register merged, sources relinked, outbound work paused), before it is kept. false in production.
    let failAfterSwap: Bool
    init(failAfterSwap: Bool) { self.failPromotionAfter = nil; self.simulateCrashAfter = nil; self.failAfterSwap = failAfterSwap }

    /// Files a restore has swapped in, with what they replaced (kept aside until the restore is kept or rolled back).
    struct Promotion {
        let targetFolder: URL
        let aside: URL
        let managedPaths: [String]
        let displaced: [(target: URL, saved: URL)]
    }

    /// Keep a promotion: the replaced files go.
    static func keep(_ p: Promotion) {
        do { try FileManager.default.removeItem(at: p.aside) } catch {
            KalsmritikoshLog.storage.error("Restore aside not removed: \(error.localizedDescription, privacy: .private)")
        }
    }

    /// Undo a promotion: every managed path at the target is removed (promoted files, and sidecars an open made), every
    /// replaced file is put back. Returns false when something could not be put back (the aside folder and its journal are
    /// then kept, so the next launch finishes the undo).
    @discardableResult
    static func rollBack(_ p: Promotion) -> Bool {
        let fm = FileManager.default
        var ok = true
        for rel in p.managedPaths {
            let t = p.targetFolder.appendingPathComponent(rel)
            guard fm.fileExists(atPath: t.path) else { continue }
            do { try fm.removeItem(at: t) } catch {
                KalsmritikoshLog.storage.error("Restore roll-back: a restored file not removed: \(error.localizedDescription, privacy: .private)")
                ok = false
            }
        }
        for d in p.displaced.reversed() {
            do {
                try fm.createDirectory(at: d.target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: d.saved, to: d.target)
            } catch {
                KalsmritikoshLog.storage.error("Restore roll-back: a file not put back: \(error.localizedDescription, privacy: .private)")
                ok = false
            }
        }
        if ok { keep(p) }
        return ok
    }

    /// Restore into `targetFolder` ONLY when the backup verifies. F19 — failure-atomic:
    ///  1. the backup must pass content verification (sizes, checksums, safe unique paths) and
    ///     contain no symlinked entries;
    ///  2. every file is copied into a FRESH staging folder beside the target (same volume), the
    ///     staged copies are re-verified, and the staged database must pass `PRAGMA quick_check`;
    ///  3. only then are files promoted — each existing target file (and any stale `-wal`/`-shm`
    ///     of the outgoing database) is first MOVED aside, never deleted, so a failure at any point
    ///     moves everything back and the previous data survives intact.
    /// The caller must not restore over a database that is open (the app never does: restore is
    /// not exposed while a ledger is live).
    /// W2-7 — an encrypted backup is checked with `ledgerKey` (this Mac's key by default). One made
    /// with another Mac's key throws `encryptedWithAnotherKey`; restore again with that ledger's
    /// recovery key, which boot then keeps.
    @discardableResult
    public func restore(backupFolder: URL, into targetFolder: URL,
                        ledgerKey: LedgerKey? = LedgerKeychain.load()) throws -> BackupManifest {
        try restoreVerified(backupFolder: backupFolder, into: targetFolder, ledgerKey: ledgerKey).manifest
    }

    /// `restore`, also returning the signature state that applied (S11, RECOVERY-07): `.invalid` never comes back — with an
    /// encrypted ledger it refuses the restore, and a plaintext ledger cannot show whose key signed it (`.notChecked`).
    func restoreVerified(backupFolder: URL, into targetFolder: URL,
                         ledgerKey: LedgerKey?) throws -> (manifest: BackupManifest, signature: BackupSignatureState) {
        let staged = try restorePromoted(backupFolder: backupFolder, into: targetFolder, ledgerKey: ledgerKey)
        Self.keep(staged.promotion)
        return (staged.manifest, staged.signature)
    }

    /// `restoreVerified` up to the swap: the files are promoted and what they replaced is still aside (`Promotion`), so the
    /// caller can finish its own steps and then keep or roll back the restore.
    func restorePromoted(backupFolder: URL, into targetFolder: URL,
                         ledgerKey: LedgerKey?) throws -> (manifest: BackupManifest, signature: BackupSignatureState, promotion: Promotion) {
        let fm = FileManager.default
        // 2. Stage + verify. Speed PERF-25 (owner 2026-11-23) — not tested yet: the backup is read ONCE — each entry is
        // copied into the staging folder while it is hashed, and the verdict is taken over exactly those staged bytes
        // (before: hash the backup, copy it, hash the copy again).
        let parent = targetFolder.deletingLastPathComponent()
        let token = UUID().uuidString
        let staging = parent.appendingPathComponent(".\(targetFolder.lastPathComponent).restore-\(token)", isDirectory: true)
        let aside = parent.appendingPathComponent(".\(targetFolder.lastPathComponent).previous-\(token)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        let (manifest, verdict, symlinks) = try inspect(backupFolder: backupFolder, ledgerKey: ledgerKey, stagingInto: staging)
        guard let dbEntry = manifest.databaseEntry else { throw BackupError.notADatabaseBackup }
        // T2 — an older app never restores a newer ledger over the current one; update the app first.
        guard manifest.schemaVersion <= SchemaMigrations.latestVersion else {
            throw BackupError.newerSchema(backup: manifest.schemaVersion, supported: SchemaMigrations.latestVersion)
        }
        guard verdict.unsafe.isEmpty else { throw BackupError.unsafeEntry(verdict.unsafe.joined(separator: ", ")) }
        if let link = symlinks.sorted().first { throw BackupError.unsafeEntry(link) }
        guard verdict.corrupt.isEmpty else { throw BackupError.damaged(verdict.corrupt) }
        guard verdict.ok else { throw BackupError.restoreIncomplete(missing: verdict.missing) }
        try fm.createDirectory(at: targetFolder, withIntermediateDirectories: true)
        let stagedDB = staging.appendingPathComponent(dbEntry.relativePath)
        if LedgerFileState.of(stagedDB) == .encrypted {
            guard let ledgerKey else { throw BackupError.encryptedWithAnotherKey }
            var probe: OpaquePointer?
            defer { sqlite3_close(probe) }
            if sqlite3_open_v2(stagedDB.path, &probe, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let h = probe {
                do { try LedgerCipher.apply(ledgerKey, to: h) }
                catch LedgerEncryptionError.wrongKey { throw BackupError.encryptedWithAnotherKey }
            }
        }
        // A plaintext backup (made before ledger encryption) is checked without a key; the next
        // launch encrypts it once, like any plaintext ledger.
        if let problem = Database.quickCheck(fileAt: stagedDB, key: LedgerFileState.of(stagedDB) == .encrypted ? ledgerKey : nil) {
            throw BackupError.databaseUnusable(problem)
        }
        // S11 (RECOVERY-07) — a signature that does not match, with the key that DOES open the backup's encrypted ledger, means
        // the manifest was changed after the backup: refused. (A plaintext ledger cannot show whose key signed it: not checked.)
        var signature = verdict.signature
        if signature == .invalid {
            guard LedgerFileState.of(stagedDB) != .encrypted else { throw BackupError.manifestAltered }
            signature = .notChecked
        }

        // 3. Promote with rollback. Stale sidecars of the OUTGOING database are moved aside too:
        // SQLite would otherwise replay one database's `-wal` into another's pages.
        var displaced: [(target: URL, saved: URL)] = []
        var promoted: [URL] = []
        let managedPaths = manifest.entries.map(\.relativePath)
            + ["-wal", "-shm"].map { dbEntry.relativePath + $0 }.filter { s in !manifest.entries.contains { $0.relativePath == s } }
        do {
            try fm.createDirectory(at: aside, withIntermediateDirectories: true)
            // S11 (RECOVERY-09) — what is about to be promoted, so a crash part-way can be undone at the next launch.
            try JSONEncoder().encode(Journal(paths: managedPaths)).write(to: aside.appendingPathComponent(Self.journalName), options: .atomic)
            for rel in managedPaths {
                let target = targetFolder.appendingPathComponent(rel)
                guard fm.fileExists(atPath: target.path) else { continue }
                let saved = aside.appendingPathComponent(rel)
                try fm.createDirectory(at: saved.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: target, to: saved)
                displaced.append((target, saved))
            }
            for (i, e) in manifest.entries.enumerated() {
                if let limit = failPromotionAfter, i >= limit { throw BackupError.promotionFailed(e.relativePath) }
                if let limit = simulateCrashAfter, i >= limit { throw SimulatedCrash() }
                let target = targetFolder.appendingPathComponent(e.relativePath)
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: staging.appendingPathComponent(e.relativePath), to: target)
                promoted.append(target)
            }
        } catch {
            if error is SimulatedCrash { throw error }   // a dead process rolls nothing back
            // Roll back: remove what was promoted, put every displaced file back where it was.
            for url in promoted { try? fm.removeItem(at: url) }
            for d in displaced.reversed() { try? fm.moveItem(at: d.saved, to: d.target) }
            try? fm.removeItem(at: aside)
            throw error
        }
        return (manifest, signature, Promotion(targetFolder: targetFolder, aside: aside, managedPaths: managedPaths, displaced: displaced))
    }

    // MARK: - Complete backup (brief §11)

    public static let sourcesMapName = "backup-sources.json"

    /// What a complete backup carries besides the ledger: each original's backup path, keyed by the
    /// ledger's file id, and the sources that could not be read (kept as external dependencies).
    public struct SourcesMap: Codable, Sendable, Equatable {
        public var originals: [String: String]      // file id → relative path inside the backup
        public var notIncluded: [String]            // original locations that could not be read
        /// S11 (RECOVERY-02) — originals whose bytes no longer match the content hash the ledger recorded (backed up as they are
        /// now, which is not the version the ledger cites).
        public var changedSinceRecorded: [String]? = nil
        /// S11 (RECOVERY-07) — set at restore: ledger sources with no original in the backup and not listed as not included.
        public var unaccounted: [String]? = nil
        /// S11 — set at restore: the manifest signature state, and the automation / hand-overs paused for reconciliation.
        public var signature: String? = nil
        public var pausedOutbox: Int? = nil
        public var pausedEffects: Int? = nil
        public init(originals: [String: String], notIncluded: [String]) { self.originals = originals; self.notIncluded = notIncluded }
    }

    /// S11 (RECOVERY-01) — the stores kept beside the ledger that a complete backup carries: the evidence vault (managed copies,
    /// including earlier versions), output records waiting to be saved, and the erasure register (identifiers only; restored
    /// as a sidecar that is merged into the register beside the restored ledger, never replacing it).
    static let vaultFolder = "EvidenceVault", pendingFolder = "case-output-pending", sidecarFolder = "sidecars"

    /// Ledger snapshot + every readable original (under `originals/`) + the sources map + the stores beside the ledger, all in
    /// one manifest with sizes and SHA-256, an inventory of every store (and what is left out by design), signed when a key is
    /// given. `databaseSnapshot` must be a consistent snapshot (the caller takes it with the online backup API).
    @discardableResult
    public func createCompleteBackup(databaseSnapshot: URL, originals: [(fileID: UUID, url: URL)], notIncluded: [String],
                                     destination: URL, schemaVersion: Int, nowEpoch: Double, besideLedger: URL? = nil,
                                     expectedHashes: [UUID: String] = [:], signingKey: LedgerKey? = nil) throws -> BackupManifest {
        try Self.checkSpace(for: [databaseSnapshot] + originals.map(\.url), at: destination)
        return try Self.staged(destination) { staging in
            try writeCompleteBackup(databaseSnapshot: databaseSnapshot, originals: originals, notIncluded: notIncluded,
                                    destination: staging, schemaVersion: schemaVersion, nowEpoch: nowEpoch, besideLedger: besideLedger,
                                    expectedHashes: expectedHashes, signingKey: signingKey)
        }
    }

    private func writeCompleteBackup(databaseSnapshot: URL, originals: [(fileID: UUID, url: URL)], notIncluded: [String],
                                     destination: URL, schemaVersion: Int, nowEpoch: Double, besideLedger: URL?,
                                     expectedHashes: [UUID: String], signingKey: LedgerKey?) throws -> BackupManifest {
        let fm = FileManager.default
        try fm.createDirectory(at: destination.appendingPathComponent("originals", isDirectory: true), withIntermediateDirectories: true)
        var entries: [BackupEntry] = []
        var taken = Self.reservedNames
        let dbName = Self.uniqueName(for: databaseSnapshot.lastPathComponent, taken: &taken)
        // Speed PERF-25 (owner 2026-11-23) — not tested yet. Every file is copied and hashed in ONE pass (8 MB buffers), in
        // parallel with work stealing, and logged as it finishes so an interrupted backup resumes; the manifest keeps the
        // input order.
        let log = CopyResumeLog(folder: destination)
        let dbMeasured = try log.copy(databaseSnapshot, to: destination, relativePath: dbName)
        entries.append(BackupEntry(relativePath: dbName, byteSize: dbMeasured.byteSize, sha256: dbMeasured.sha256, kind: .database))
        var map = SourcesMap(originals: [:], notIncluded: notIncluded)
        var changed: [String] = []
        var takenOriginals = Set<String>()
        let originalPlan = originals.map { (o: $0, rel: "originals/" + Self.uniqueName(for: $0.url.lastPathComponent, taken: &takenOriginals)) }
        let originalResults = Self.copyEach(originalPlan.map { ($0.o.url, $0.rel) }, into: destination, log: log)
        for (i, p) in originalPlan.enumerated() {
            guard let measured = originalResults[i] else { map.notIncluded.append(p.o.url.path); continue }
            entries.append(BackupEntry(relativePath: p.rel, byteSize: measured.byteSize, sha256: measured.sha256, kind: .originalSource))
            map.originals[p.o.fileID.uuidString] = p.rel
            // RECOVERY-02 — reconciled against the version the ledger recorded, not trusted as it is now.
            if let expected = expectedHashes[p.o.fileID], expected.count == 64, expected.lowercased() != measured.sha256 { changed.append(p.o.url.path) }
        }
        if !changed.isEmpty { map.changedSinceRecorded = changed }
        // RECOVERY-01 — the stores beside the ledger.
        var sidecarProblems: [String] = []
        var vaultCount = 0, pendingCount = 0, registerIncluded = false
        var sidecarPlan: [(src: URL, rel: String, group: Int)] = []   // group: 0 vault, 1 pending, 2 register
        if let besideLedger {
            for (folder, isVault) in [(Self.vaultFolder, true), (Self.pendingFolder, false)] {
                let root = besideLedger.appendingPathComponent(folder, isDirectory: true)
                guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { continue }
                for case let file as URL in en {
                    guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                    let rel = folder + "/" + file.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1)
                    guard RestoreValidator.isSafeRelativePath(rel) else { continue }
                    sidecarPlan.append((file, rel, isVault ? 0 : 1))
                }
            }
            let register = ErasureRegister.url(besideLedgerAt: besideLedger.appendingPathComponent("ledger"))
            if fm.fileExists(atPath: register.path) {
                sidecarPlan.append((register, Self.sidecarFolder + "/" + ErasureRegister.fileName, 2))
            }
        }
        let sidecarResults = Self.copyEach(sidecarPlan.map { ($0.src, $0.rel) }, into: destination, log: log)
        for (i, p) in sidecarPlan.enumerated() {
            guard let m = sidecarResults[i] else { sidecarProblems.append(p.rel); continue }
            entries.append(BackupEntry(relativePath: p.rel, byteSize: m.byteSize, sha256: m.sha256, kind: .derivedExport))
            switch p.group {
            case 0: vaultCount += 1
            case 1: pendingCount += 1
            default: registerIncluded = true
            }
        }
        log.remove()
        let mapURL = destination.appendingPathComponent(Self.sourcesMapName)
        try JSONEncoder().encode(map).write(to: mapURL)
        let mapMeasured = try Self.measure(mapURL)
        entries.append(BackupEntry(relativePath: Self.sourcesMapName, byteSize: mapMeasured.byteSize, sha256: mapMeasured.sha256, kind: .derivedExport))
        var inventory: [BackupInventoryLine] = [
            BackupInventoryLine(store: "Ledger (every case and its map, history, revisions, work, outputs, approvals, money and policies)", included: true, count: 1,
                                note: "A consistent snapshot taken with SQLite's online backup; encrypted as the ledger is."),
            BackupInventoryLine(store: "Original files", included: map.notIncluded.isEmpty, count: map.originals.count,
                                note: map.notIncluded.isEmpty ? "Every original the ledger names." : "\(map.notIncluded.count) original(s) could not be read and are listed as not included."),
        ]
        if !changed.isEmpty {
            inventory.append(BackupInventoryLine(store: "Originals changed since they were recorded", included: false, count: changed.count,
                                                 note: "Backed up as they are now; that is not the version the ledger cites (its derived text is in the ledger)."))
        }
        if let besideLedger {
            inventory.append(BackupInventoryLine(store: "Evidence vault (managed copies, including earlier versions)", included: sidecarProblems.allSatisfy { !$0.hasPrefix(Self.vaultFolder) },
                                                 count: vaultCount, note: vaultCount == 0 ? "No managed copies on this Mac." : "Sealed copies; they open with the ledger's key."))
            inventory.append(BackupInventoryLine(store: "Output records waiting to be saved", included: sidecarProblems.allSatisfy { !$0.hasPrefix(Self.pendingFolder) },
                                                 count: pendingCount, note: "Recorded in the restored ledger at the next launch."))
            inventory.append(BackupInventoryLine(store: "Erasure register (identifiers only)", included: registerIncluded || !fm.fileExists(atPath: ErasureRegister.url(besideLedgerAt: besideLedger.appendingPathComponent("ledger")).path),
                                                 count: registerIncluded ? 1 : 0, note: "Merged into the register beside the restored ledger, so erased cases stay erased on a new Mac."))
        } else {
            inventory.append(BackupInventoryLine(store: "Evidence vault, pending output records, erasure register", included: false, count: nil,
                                                 note: "Not looked for: this backup was made without the ledger folder."))
        }
        inventory += [
            BackupInventoryLine(store: "AI permissions for cases", included: false, count: nil,
                                note: "Not included by design: the AI is asked again on the restored Mac before it reads a case.", byDesign: true),
            BackupInventoryLine(store: "Ledger key, sign-in tokens and AI keys", included: false, count: nil,
                                note: "Kept in this Mac's Keychain, never in a backup. Keep the recovery key separately; sign in again after a restore.", byDesign: true),
        ]
        // Complete only when nothing promised was left out (final brief §3.8; S11 RECOVERY-01/02).
        let complete = map.notIncluded.isEmpty && changed.isEmpty && sidecarProblems.isEmpty && besideLedger != nil
            && inventory.allSatisfy { $0.included || $0.byDesign }
        let coverage: BackupCoverage = complete ? .complete : .ledgerWithSomeOriginals
        let manifest = BackupPlanner.manifest(schemaVersion: schemaVersion, createdAtEpoch: nowEpoch, entries: entries, coverage: coverage, inventory: inventory)
        let json = try JSONEncoder().encode(manifest)
        try json.write(to: destination.appendingPathComponent(Self.manifestName))
        try Self.writeSignature(manifestData: json, key: signingKey, in: destination)
        return manifest
    }

    /// The sources map a complete (or partial-originals) backup carries.
    public static func sourcesMap(in backupFolder: URL) throws -> SourcesMap {
        try JSONDecoder().decode(SourcesMap.self, from: Data(contentsOf: backupFolder.appendingPathComponent(sourcesMapName)))
    }

    /// Restore a complete backup into `targetFolder` (verified, staged and failure-atomic, as
    /// `restore`), then relink the restored ledger's sources to the restored originals so every
    /// citation opens on this Mac without the old Mac's paths. Returns the sources not included.
    @discardableResult
    public func restoreComplete(backupFolder: URL, into targetFolder: URL,
                                ledgerKey: LedgerKey? = LedgerKeychain.load(), now: Date = Date()) async throws -> SourcesMap {
        // RECOVERY-06 — both erasure registers are read BEFORE anything is promoted: an unreadable one refuses the restore with
        // the ledger untouched (it is never treated as "nothing was erased", and a merge can then not fail half-way).
        if let data = FileManager.default.contents(atPath: backupFolder.appendingPathComponent(Self.manifestName).path),
           let dbRel = (try? JSONDecoder().decode(BackupManifest.self, from: data))?.databaseEntry?.relativePath {
            _ = try ErasureRegister.load(besideLedgerAt: targetFolder.appendingPathComponent(dbRel))
        }
        let carriedInBackup = backupFolder.appendingPathComponent(Self.sidecarFolder).appendingPathComponent(ErasureRegister.fileName)
        if FileManager.default.fileExists(atPath: carriedInBackup.path) { _ = try ErasureRegister.decodeCarried(carriedInBackup) }
        // Deep dive 2 (#2) — the completion steps (register merge, relinking the sources, pausing outbound work) run while the
        // replaced files are still aside: a failure in any of them rolls the whole restore back (the ledger, its files and
        // the register are as they were), so "your ledger was not changed" stays true. A crash meanwhile leaves the aside
        // folder and its journal: the next launch undoes the restore and runs the scheduled one again.
        let (manifest, signature, promotion) = try restorePromoted(backupFolder: backupFolder, into: targetFolder, ledgerKey: ledgerKey)
        guard manifest.coverage == .complete || manifest.coverage == .ledgerWithSomeOriginals,
              let dbEntry = manifest.databaseEntry else {
            Self.keep(promotion)
            return SourcesMap(originals: [:], notIncluded: [])
        }
        let restoredDB = targetFolder.appendingPathComponent(dbEntry.relativePath)
        let registerURL = ErasureRegister.url(besideLedgerAt: restoredDB)
        let registerBefore = FileManager.default.contents(atPath: registerURL.path)
        do {
            let map = try await completeRestore(manifest: manifest, signature: signature, backupFolder: backupFolder, targetFolder: targetFolder,
                                                restoredDB: restoredDB, ledgerKey: ledgerKey, now: now)
            if failAfterSwap { throw BackupError.promotionFailed("after the swap (test)") }
            Self.keep(promotion)
            return map
        } catch {
            KalsmritikoshLog.storage.error("Restore not completed, rolled back: \(error.localizedDescription, privacy: .private)")
            Self.restoreRegister(registerBefore, at: registerURL)
            if !Self.rollBack(promotion) {
                // One more try from the journal (as the next launch would); what is still not put back is said plainly.
                let notes = Self.recoverInterruptedRestores(ledgerFolder: targetFolder)
                if FileManager.default.fileExists(atPath: promotion.aside.path) {
                    throw RestoreNotUndone(aside: promotion.aside.lastPathComponent, notes: notes)
                }
            }
            throw error
        }
    }

    /// Deep dive 2 (#2) — a restore that failed after its swap and could not be fully undone: the replaced files are kept in
    /// `aside` (with their journal), and the next launch tries again to put them back.
    struct RestoreNotUndone: Error, LocalizedError {
        let aside: String
        let notes: [String]
        var errorDescription: String? {
            "the restore failed after its files were swapped in, and some could not be put back; the replaced files are kept in “\(aside)” and are put back when the app next opens"
        }
    }

    /// The register beside the target put back as it was before a rolled-back restore (removed when there was none).
    static func restoreRegister(_ before: Data?, at url: URL) {
        do {
            if let before { try before.write(to: url, options: .atomic) } else if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        } catch {
            KalsmritikoshLog.storage.error("Erasure register not put back after a rolled-back restore: \(error.localizedDescription, privacy: .private)")
        }
    }

    /// The steps of a complete restore after its files are swapped in. The restored ledger is closed again on every path.
    private func completeRestore(manifest: BackupManifest, signature: BackupSignatureState, backupFolder: URL, targetFolder: URL,
                                 restoredDB: URL, ledgerKey: LedgerKey?, now: Date) async throws -> SourcesMap {
        var map = try JSONDecoder().decode(SourcesMap.self, from: Data(contentsOf: targetFolder.appendingPathComponent(Self.sourcesMapName)))
        // RECOVERY-06 — the erasure register carried by the backup is merged into the one beside the restored ledger.
        let carried = targetFolder.appendingPathComponent(Self.sidecarFolder).appendingPathComponent(ErasureRegister.fileName)
        if FileManager.default.fileExists(atPath: carried.path) {
            try ErasureRegister.merge(from: carried, besideLedgerAt: restoredDB)
            do { try FileManager.default.removeItem(at: targetFolder.appendingPathComponent(Self.sidecarFolder)) } catch {
                KalsmritikoshLog.storage.error("Restored register sidecar not removed: \(error.localizedDescription, privacy: .private)")
            }
        }
        let db = try Database(url: restoredDB, key: LedgerFileState.of(restoredDB) == .encrypted ? ledgerKey : nil)
        do {
            // Speed PERF-25 (owner 2026-11-23) — not tested yet. Every relink in ONE savepoint (one commit, one actor hop)
            // instead of one autocommit per original; any failure rolls all of them back.
            let relinks: [(UUID, String)] = map.originals.compactMap { fileID, rel in
                guard let id = UUID(uuidString: fileID), RestoreValidator.isSafeRelativePath(rel) else { return nil }
                return (id, targetFolder.appendingPathComponent(rel).standardizedFileURL.absoluteString)
            }
            try await db.withSavepoint("restore_relink") { db in
                for (id, url) in relinks {
                    try db.exec("UPDATE files SET url = ?, availability = 'available' WHERE id = ?;", [.text(url), .uuid(id)])
                }
            }
            // RECOVERY-07 — every source the ledger names has its original in the backup or is listed as not included.
            let listed = Set(map.notIncluded)
            var unaccounted: [String] = []
            for r in try await db.query("SELECT id, url FROM files;", []) {
                guard let id = r.uuid(0), map.originals[id.uuidString] == nil else { continue }
                let path = r.string(1).flatMap(URL.init(string:))?.path ?? (r.string(1) ?? "")
                if !listed.contains(path) { unaccounted.append(path) }
            }
            map.unaccounted = unaccounted
            map.signature = signature.rawValue
            // RECOVERY-05 — work that was queued or about to be handed over when the backup was made may already have happened
            // on the old Mac: it is paused for a person to reconcile, never run or sent again blindly.
            let paused = try await Self.pauseOutboundWork(db, backupCreatedAt: manifest.createdAtEpoch, backupName: backupFolder.lastPathComponent,
                                                          signature: signature, now: now)
            map.pausedOutbox = paused.outbox
            map.pausedEffects = paused.effects
        } catch {
            await db.close()
            throw error
        }
        await db.close()
        return map
    }

    nonisolated static let restoredMarker = "restoredUnconfirmed:"

    static func pauseOutboundWork(_ db: Database, backupCreatedAt: Double, backupName: String, signature: BackupSignatureState,
                                  now: Date) async throws -> (outbox: Int, effects: Int) {
        func exists(_ t: String) async throws -> Bool { !(try await db.query("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?;", [.text(t)]).isEmpty) }
        var outbox = 0, effects = 0
        let when = ISO8601DateFormatter.string(from: Date(timeIntervalSince1970: backupCreatedAt), timeZone: .gmt, formatOptions: [.withInternetDateTime])
        if try await exists("case_automation_outbox") {
            outbox = Int(try await db.query("SELECT COUNT(*) FROM case_automation_outbox WHERE state IN ('queued','running','retrying');", []).first?.int(0) ?? 0)
            try await db.exec("""
                UPDATE case_automation_outbox SET state = 'held', lease_until = NULL, updated_at = ?,
                       state_reason = 'Paused after a restore from a backup made ' || ? || ': it may already have run on the Mac the backup came from. Check, then resume or cancel it.'
                WHERE state IN ('queued','running','retrying');
                """, [.date(now), .text(when)])
        }
        if try await exists("case_external_effects") {
            effects = Int(try await db.query("SELECT COUNT(*) FROM case_external_effects WHERE state = 'prepared';", []).first?.int(0) ?? 0)
            try await db.exec("""
                UPDATE case_external_effects SET updated_at = ?,
                       state_note = ? || ' restored from a backup made ' || ? || '; it may have been handed over after that. Confirm whether it was sent before handing it over.'
                WHERE state = 'prepared';
                """, [.date(now), .text(restoredMarker), .text(when)])
        }
        if try await exists("ledger_restores") {
            try await db.exec("""
                INSERT INTO ledger_restores (id, restored_at, backup_created_at, backup_name, signature_state, held_outbox, paused_effects, note)
                VALUES (?,?,?,?,?,?,?,?);
                """, [.uuid(UUID()), .date(now), .real(backupCreatedAt), .text(backupName),
                      .text(signature.rawValue),
                      .integer(Int64(outbox)), .integer(Int64(effects)), .null])
        }
        return (outbox, effects)
    }
}
