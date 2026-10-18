//
//  SyncStore.swift
//  SyncCore
//
//  X-5 — reading and writing a sync store folder (layout in SyncFormat.swift). Pure file
//  operations: no database, no network. Every read is verified before it is trusted:
//  a batch must carry a valid signature from its registered device AND open under the store
//  key; a blob must open AND hash to its own name.
//

import Foundation
import CryptoKit

nonisolated struct SyncStore {
    let root: URL
    let info: SyncStoreInfo
    let key: SymmetricKey

    enum Failure: Error, Equatable, LocalizedError {
        case notAStore, alreadyAStore, newerFormat(Int), unknownDevice(String), batchExists(Int), mismatched(String)
        var errorDescription: String? {
            switch self {
            case .notAStore: return "That folder is not an Investigation Docs Made Easy sync folder yet."
            case .alreadyAStore: return "That folder already holds a sync store; open it with its passphrase instead."
            case .newerFormat(let v): return "This sync folder was written by a newer version of Investigation Docs Made Easy (format \(v)). Update the app to use it."
            case .unknownDevice(let d): return "A change comes from a device this sync folder does not list (\(d))."
            case .batchExists(let s): return "Change \(s) from this device is already in the sync folder."
            case .mismatched(let what): return "A file in the sync folder does not match what it says it is (\(what))."
            }
        }
    }

    private static var fm: FileManager { .default }

    // MARK: - Opening

    static func exists(at root: URL) -> Bool {
        fm.fileExists(atPath: root.appendingPathComponent(SyncFormat.storeFile).path)
    }

    /// Start a new store in an empty (or unrelated) folder.
    static func create(at root: URL, passphrase: String, rounds: Int = SyncCrypto.defaultRounds) throws -> SyncStore {
        guard !exists(at: root) else { throw Failure.alreadyAStore }
        let salt = SyncCrypto.randomSalt()
        let key = try SyncCrypto.storeKey(passphrase: passphrase, salt: salt, rounds: rounds)
        let info = SyncStoreInfo(format: SyncFormat.version, storeID: UUID().uuidString, createdAt: Date(),
                                 salt: salt.base64EncodedString(), kdfRounds: rounds, check: try SyncCrypto.makeCheck(key: key))
        for folder in [SyncFormat.devicesFolder, SyncFormat.logFolder, SyncFormat.blobsFolder] {
            try fm.createDirectory(at: root.appendingPathComponent(folder, isDirectory: true), withIntermediateDirectories: true)
        }
        try encoder.encode(info).write(to: root.appendingPathComponent(SyncFormat.storeFile), options: .withoutOverwriting)
        return SyncStore(root: root, info: info, key: key)
    }

    /// Open an existing store; throws `.wrongPassphrase` (SyncCrypto) or `.newerFormat`.
    static func open(at root: URL, passphrase: String) throws -> SyncStore {
        guard let data = try? Data(contentsOf: root.appendingPathComponent(SyncFormat.storeFile)) else { throw Failure.notAStore }
        guard let info = try? decoder.decode(SyncStoreInfo.self, from: data) else { throw SyncCrypto.Failure.unreadable }
        guard info.format <= SyncFormat.version else { throw Failure.newerFormat(info.format) }
        guard let salt = Data(base64Encoded: info.salt) else { throw SyncCrypto.Failure.unreadable }
        let key = try SyncCrypto.storeKey(passphrase: passphrase, salt: salt, rounds: info.kdfRounds)
        try SyncCrypto.verify(check: info.check, key: key)
        return SyncStore(root: root, info: info, key: key)
    }

    /// Open with a key saved earlier (no passphrase): still verified against the store's check.
    static func open(at root: URL, key: SymmetricKey) throws -> SyncStore {
        guard let data = try? Data(contentsOf: root.appendingPathComponent(SyncFormat.storeFile)) else { throw Failure.notAStore }
        guard let info = try? decoder.decode(SyncStoreInfo.self, from: data) else { throw SyncCrypto.Failure.unreadable }
        guard info.format <= SyncFormat.version else { throw Failure.newerFormat(info.format) }
        try SyncCrypto.verify(check: info.check, key: key)
        return SyncStore(root: root, info: info, key: key)
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; e.dateEncodingStrategy = .iso8601; return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }()

    // MARK: - Devices

    func register(_ device: SyncDeviceInfo) throws {
        let url = root.appendingPathComponent(SyncFormat.devicesFolder, isDirectory: true)
        try Self.fm.createDirectory(at: url, withIntermediateDirectories: true)
        try Self.encoder.encode(device).write(to: url.appendingPathComponent("\(device.id).json"), options: .atomic)
    }

    func devices() -> [SyncDeviceInfo] {
        let dir = root.appendingPathComponent(SyncFormat.devicesFolder, isDirectory: true)
        let files = (try? Self.fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? Self.decoder.decode(SyncDeviceInfo.self, from: Data(contentsOf: $0)) }
            .filter { device in files.contains { $0.deletingPathExtension().lastPathComponent == device.id } }
            .sorted { $0.id < $1.id }
    }

    // MARK: - Batches

    private func logFolder(_ device: String) -> URL {
        root.appendingPathComponent(SyncFormat.logFolder, isDirectory: true).appendingPathComponent(device, isDirectory: true)
    }

    /// Seal, sign and write one batch. Never overwrites: a batch number is used once.
    @discardableResult
    func write(_ batch: SyncBatch, signingKey: Curve25519.Signing.PrivateKey) throws -> URL {
        let folder = logFolder(batch.device)
        try Self.fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(SyncFormat.batchName(batch.seq))
        guard !Self.fm.fileExists(atPath: url.path) else { throw Failure.batchExists(batch.seq) }
        let sealed = try SyncCrypto.seal(try Self.encoder.encode(batch), key: key)
        let envelope = SyncEnvelope(device: batch.device, seq: batch.seq, sealed: sealed.base64EncodedString(),
                                    signature: try SyncCrypto.sign(sealed, with: signingKey))
        // Written beside its final name and moved, so a reader never sees half a batch.
        let staging = folder.appendingPathComponent(".tmp-\(UUID().uuidString)")
        try Self.encoder.encode(envelope).write(to: staging)
        try Self.fm.moveItem(at: staging, to: url)
        return url
    }

    /// Batch numbers present for a device, ascending (half-written files are ignored).
    func batchNumbers(of device: String) -> [Int] {
        let files = (try? Self.fm.contentsOfDirectory(atPath: logFolder(device).path)) ?? []
        return files.compactMap(SyncFormat.seq(fromBatchName:)).sorted()
    }

    /// Device folders present in the log (including devices not yet registered).
    func loggedDevices() -> [String] {
        let dir = root.appendingPathComponent(SyncFormat.logFolder, isDirectory: true)
        return ((try? Self.fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
    }

    /// Read and verify one batch: signature by the registered device, then decryption, then
    /// the envelope and the batch agreeing on who and which.
    func readBatch(device: String, seq: Int) throws -> SyncBatch {
        guard let registered = devices().first(where: { $0.id == device }) else { throw Failure.unknownDevice(device) }
        let url = logFolder(device).appendingPathComponent(SyncFormat.batchName(seq))
        guard let data = try? Data(contentsOf: url),
              let envelope = try? Self.decoder.decode(SyncEnvelope.self, from: data),
              let sealed = Data(base64Encoded: envelope.sealed) else { throw SyncCrypto.Failure.unreadable }
        guard envelope.format <= SyncFormat.version else { throw Failure.newerFormat(envelope.format) }
        try SyncCrypto.verifySignature(envelope.signature, of: sealed, publicKey: registered.publicKey)
        let plain = try SyncCrypto.open(sealed, key: key)
        guard let batch = try? Self.decoder.decode(SyncBatch.self, from: plain) else { throw SyncCrypto.Failure.unreadable }
        guard batch.device == device, envelope.device == device, batch.seq == seq, envelope.seq == seq else {
            throw Failure.mismatched("change \(seq) of \(device)")
        }
        guard batch.format <= SyncFormat.version else { throw Failure.newerFormat(batch.format) }
        return batch
    }

    // MARK: - Blobs

    private func blobURL(_ sha: String) -> URL {
        root.appendingPathComponent(SyncFormat.blobsFolder, isDirectory: true)
            .appendingPathComponent("\(sha).\(SyncFormat.blobExtension)")
    }

    /// Store file bytes (once: the same bytes always land under the same name). Returns the SHA-256.
    @discardableResult
    func putBlob(_ data: Data) throws -> String {
        let sha = SyncCrypto.sha256Hex(data)
        let url = blobURL(sha)
        guard !Self.fm.fileExists(atPath: url.path) else { return sha }
        try Self.fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staging = url.deletingLastPathComponent().appendingPathComponent(".tmp-\(UUID().uuidString)")
        try SyncCrypto.seal(data, key: key).write(to: staging)
        if (try? Self.fm.moveItem(at: staging, to: url)) == nil { try? Self.fm.removeItem(at: staging) }
        return sha
    }

    func hasBlob(_ sha: String) -> Bool { Self.fm.fileExists(atPath: blobURL(sha).path) }

    /// The bytes behind `sha`, verified to hash to it.
    func blob(_ sha: String) throws -> Data {
        guard let sealed = try? Data(contentsOf: blobURL(sha)) else { throw Failure.mismatched("missing file \(sha.prefix(12))") }
        let data = try SyncCrypto.open(sealed, key: key)
        guard SyncCrypto.sha256Hex(data) == sha else { throw Failure.mismatched("file \(sha.prefix(12))") }
        return data
    }
}
