//
//  SyncFormat.swift
//  SyncCore (shared by the Mac app and the iPhone/iPad app)
//
//  X-5/X-6 — the format of a sync store: a folder the person chooses (iCloud Drive, Dropbox,
//  a shared or USB disk). The apps only read and write files in it; the folder's own service
//  moves them between devices. Everything sensitive in it is encrypted with a key derived
//  from a passphrase the person sets, and every batch is signed by the device that wrote it.
//
//    <store>/store.json                  format, store id, KDF salt, passphrase check
//    <store>/devices/<deviceID>.json     device name + Ed25519 public key (plain: no content)
//    <store>/log/<deviceID>/<seq>.kchg   one encrypted, signed batch of changes per file
//    <store>/blobs/<sha256>.kblob        encrypted bytes of a file a change refers to
//
//  Each device writes only its own log and its own device file, so two devices never write
//  the same file; blobs are content-addressed (same bytes → same name), so a duplicate
//  write is harmless.
//

import Foundation

nonisolated enum SyncFormat {
    static let version = 1
    static let storeFile = "store.json"
    static let devicesFolder = "devices"
    static let logFolder = "log"
    static let blobsFolder = "blobs"
    static let batchExtension = "kchg"
    static let blobExtension = "kblob"

    /// File name of batch `seq` (zero-padded so names sort in order).
    static func batchName(_ seq: Int) -> String { String(format: "%010d.", seq) + batchExtension }

    static func seq(fromBatchName name: String) -> Int? {
        guard name.hasSuffix("." + batchExtension) else { return nil }
        return Int(name.dropLast(batchExtension.count + 1))
    }
}

/// A field value in a change. Mirrors the SQLite storage classes the synced tables use.
nonisolated enum SyncValue: Codable, Hashable, Sendable {
    case null
    case int(Int64)
    case real(Double)
    case text(String)

    var text: String? { if case .text(let s) = self { return s } else { return nil } }
}

/// One row's synced fields as one device last set them. `key` is the row's portable identity
/// (its primary key, with document references already made portable — see `SyncObjectRef`).
nonisolated struct SyncOp: Codable, Hashable, Sendable {
    var table: String
    var key: String
    var fields: [String: SyncValue]
    /// Lamport clock of the change: later changes carry larger values across all devices.
    var lamport: Int64
    var device: String
}

/// A file carried by the store: something added inside the app (a capture, a clip, a scan)
/// or one of the person's notes. Its bytes are in `blobs/<sha256>.kblob`.
nonisolated struct SyncFileOp: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable { case intake, note }
    var kind: Kind
    /// Intake: the original file name. Note: the note's file name (e.g. "Plan.md").
    var name: String
    var sha256: String
    var origin: String?
    /// A note moved to the trash on the writing device.
    var trashed: Bool = false
    /// For notes: the version this edit was made on top of (nil for a new note), so a
    /// concurrent edit on two devices can be detected and both texts kept.
    var baseSHA256: String?
    var lamport: Int64
    var device: String
}

/// One file in `log/<device>/`.
nonisolated struct SyncBatch: Codable, Hashable, Sendable {
    var format = SyncFormat.version
    var device: String
    var seq: Int
    var createdAt: Date
    var ops: [SyncOp]
    var files: [SyncFileOp]
    /// Display names of the documents the ops refer to (reference → file name), so a device
    /// without the document can still show what a mark or tag is on.
    var titles: [String: String]? = nil
}

/// `store.json` — readable without the passphrase, but carries nothing about content.
nonisolated struct SyncStoreInfo: Codable, Hashable, Sendable {
    var format: Int
    var storeID: String
    var createdAt: Date
    /// Salt for the passphrase key derivation (base64).
    var salt: String
    var kdfRounds: Int
    /// A known plaintext sealed with the store key: opening it proves the passphrase.
    var check: String
}

/// `devices/<id>.json`.
nonisolated struct SyncDeviceInfo: Codable, Hashable, Sendable {
    var id: String
    var name: String
    /// Raw Ed25519 public key, base64.
    var publicKey: String
    var platform: String
}

/// The on-disk form of a batch: the sealed batch and its signature.
nonisolated struct SyncEnvelope: Codable, Hashable, Sendable {
    var format = SyncFormat.version
    var device: String
    var seq: Int
    /// AES-GCM combined box (nonce + ciphertext + tag), base64.
    var sealed: String
    /// Ed25519 signature over the sealed bytes, base64.
    var signature: String
}

/// A portable reference to a document: the SHA-256 of its source file plus the SHA-256 of the
/// document's own text. The same file read on two devices gives the same reference even
/// though each ledger gave the document its own local id.
nonisolated struct SyncObjectRef: Hashable, Sendable {
    let fileHash: String
    let contentHash: String

    var encoded: String { "doc:\(fileHash):\(contentHash)" }

    init(fileHash: String, contentHash: String) {
        self.fileHash = fileHash
        self.contentHash = contentHash
    }

    init?(encoded: String) {
        let parts = encoded.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "doc", !parts[1].isEmpty else { return nil }
        fileHash = String(parts[1]); contentHash = String(parts[2])
    }
}

/// Lamport order with the device id as tie-break: a total order every device agrees on.
nonisolated struct SyncClock: Comparable, Hashable, Sendable {
    let lamport: Int64
    let device: String
    static func < (a: Self, b: Self) -> Bool { a.lamport == b.lamport ? a.device < b.device : a.lamport < b.lamport }
}
