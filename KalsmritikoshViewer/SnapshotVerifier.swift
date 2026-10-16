//
//  SnapshotVerifier.swift
//  KalsmritikoshViewer
//
//  W4-6 — checks a `.kalsnapshot` folder exported by the Mac app (App/CompanionSnapshot.swift,
//  App/BackupService.swift) before anything is shown: the signature (ECDSA P-256 over the
//  SHA-256 of manifest.json, made with the exporting Mac's key) and every listed file's size
//  and SHA-256. A snapshot that fails any check is not opened. Keep the format in step with
//  the Mac side: manifest.json { entries: [{ relativePath, byteSize, sha256, kind }] } and
//  signature.json { algorithm, publicKey (x9.63, base64), value (DER, base64) }.
//

import Foundation
import CryptoKit

nonisolated enum SnapshotVerdict: Equatable, Sendable {
    case verified(signer: String, files: Int)
    case unsigned
    case badSignature
    case damaged(String)

    var isVerified: Bool { if case .verified = self { return true }; return false }

    var message: String {
        switch self {
        case .verified(let signer, let files): return "Signature valid (Mac key \(signer)); all \(files) files match."
        case .unsigned: return "This snapshot is not signed, so it cannot be trusted and is not opened."
        case .badSignature: return "The signature does not match: the snapshot was changed after it was made. Not opened."
        case .damaged(let why): return "The snapshot is damaged: \(why). Not opened."
        }
    }
}

nonisolated enum SnapshotVerifier {
    static let manifestName = "manifest.json"
    static let signatureName = "signature.json"
    static let sourcesName = "kalsnapshot-sources.json"

    struct Entry: Decodable, Sendable {
        let relativePath: String
        let byteSize: Int64
        let sha256: String
        let kind: String
    }
    private struct Manifest: Decodable { let entries: [Entry] }

    static func verify(_ folder: URL) -> (SnapshotVerdict, [Entry]) {
        guard let manifest = try? Data(contentsOf: folder.appendingPathComponent(manifestName)) else {
            return (.damaged("manifest.json is missing"), [])
        }
        guard let sigData = try? Data(contentsOf: folder.appendingPathComponent(signatureName)) else { return (.unsigned, []) }
        guard let obj = try? JSONSerialization.jsonObject(with: sigData) as? [String: String],
              obj["algorithm"] == "ECDSA-P256-SHA256",
              let keyData = obj["publicKey"].flatMap({ Data(base64Encoded: $0) }),
              let valueData = obj["value"].flatMap({ Data(base64Encoded: $0) }),
              let key = try? P256.Signing.PublicKey(x963Representation: keyData),
              let sig = try? P256.Signing.ECDSASignature(derRepresentation: valueData) else {
            return (.badSignature, [])
        }
        guard key.isValidSignature(sig, for: Data(SHA256.hash(data: manifest))) else { return (.badSignature, []) }
        guard let m = try? JSONDecoder().decode(Manifest.self, from: manifest) else {
            return (.damaged("manifest.json is unreadable"), [])
        }
        var seen = Set<String>()
        for e in m.entries {
            let p = e.relativePath
            guard !p.isEmpty, !p.hasPrefix("/"), !p.split(separator: "/").contains(".."), seen.insert(p.lowercased()).inserted else {
                return (.damaged("unsafe path “\(p)”"), [])
            }
            guard let (size, digest) = measure(folder.appendingPathComponent(p)) else { return (.damaged("“\(p)” is missing"), []) }
            guard size == e.byteSize, digest == e.sha256 else { return (.damaged("“\(p)” does not match its record"), []) }
        }
        let fp = SHA256.hash(data: keyData).map { String(format: "%02x", $0) }.joined().prefix(16)
        return (.verified(signer: String(fp), files: m.entries.count), m.entries)
    }

    /// Streaming SHA-256, so a large original is never read into memory at once.
    static func measure(_ url: URL) -> (Int64, String)? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        var size: Int64 = 0
        while true {
            let chunk = autoreleasepool { (try? h.read(upToCount: 1 << 20)) ?? nil }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
            size += Int64(chunk.count)
        }
        return (size, hasher.finalize().map { String(format: "%02x", $0) }.joined())
    }
}
