//
//  TeamSwarm.swift
//  Kalsmritikosh
//
//  Speed PERF-40 torrent (owner 2026-11-23, approved; per-case opt-in, shown to every member) — not tested yet.
//  "A swarm": a big import of files ALREADY SHARED in a team folder is split into pieces (IngestBatchPlanner batches);
//  each member's Mac claims pieces, reads them into its own partial ledger (ShardLedger) and publishes it to the folder
//  encrypted for the case's members and signed; every Mac verifies and merges each piece once (ShardMerger).
//  This file is the folder side only (what is written where, signed by whom). No server, no network of its own: the
//  folder is the only place anything goes, and nothing is ever written outside it.
//
//    <folder>/swarm/keys/<member>.json                       this member's X25519 public key, signed with its Ed25519 key
//    <folder>/swarm/<swarm>/manifest.json                    the pieces: each file's path INSIDE the folder, SHA-256, size
//    <folder>/swarm/<swarm>/claims/<piece>/<member>.json     a signed claim with an expiry (one file per member: no shared
//                                                            file is ever written by two Macs)
//    <folder>/swarm/<swarm>/shards/<piece>.<member>.kshard   the piece's partial ledger, SQLCipher-encrypted with a fresh
//                                                            piece key
//    <folder>/swarm/<swarm>/shards/<piece>.<member>.keys     the piece key wrapped for each member (X25519 + HKDF + AES-GCM,
//                                                            the shared-case vault's per-member envelopes)
//
//  Signed log entries (TeamLogEntry.action): "swarm.optin" (on/off for a case), "swarm.manifest" (a new swarm and its
//  manifest digest), "swarm.shard" (a published piece: file digest, key-file digest, seed marks), "swarm.erased".
//
//  Claims are conflict-safe without a lock: a Mac writes its own claim file, reads it back, then reads every claim of
//  the piece; the oldest unexpired, correctly signed claim wins (ties by member id), and a Mac whose claim did not win
//  leaves the piece. An expired claim is ignored, so the piece can be claimed again. Endgame: when every piece is
//  claimed or done and only a few remain, a free Mac may take a duplicate; the FIRST published shard of a piece (by
//  its signed time, then member id) is the one every Mac merges, so a duplicate never lands twice.
//
//  Honest scope: the folder's own access is the only access control; a member removed from the folder can still open
//  pieces published before (their envelopes were already written).
//

import Foundation
import CryptoKit
import Security
import os

/// One file of a swarm: where it is inside the team folder, its fingerprint and size.
nonisolated struct TeamSwarmFile: Codable, Sendable, Hashable {
    let path: String
    let sha256: String
    let bytes: Int64
}

nonisolated struct TeamSwarmPiece: Codable, Sendable, Hashable {
    let index: Int
    let files: [TeamSwarmFile]
    var bytes: Int64 { files.reduce(0) { $0 + $1.bytes } }
}

nonisolated struct TeamSwarmManifest: Codable, Sendable, Hashable {
    let id: String
    let title: String
    let author: String
    let created: String
    let pieces: [TeamSwarmPiece]
}

/// The signed announcement of a manifest.
nonisolated struct TeamSwarmAnnouncement: Codable, Sendable, Hashable {
    let id: String
    let title: String
    let manifestSHA256: String
    let pieces: Int
    let files: Int
}

/// The signed announcement of a published piece.
nonisolated struct TeamSwarmShardNote: Codable, Sendable, Hashable {
    let swarmID: String
    let piece: Int
    let file: String
    let sha256: String
    let bytes: Int64
    let keysFile: String
    let keysSHA256: String
    let seedMarks: [String: Int64]
    let files: Int
}

nonisolated struct TeamSwarmClaim: Codable, Sendable, Hashable {
    let swarmID: String
    let piece: Int
    let member: String
    let claimedAt: Double
    let expires: Double
    let duplicate: Bool
    var sig: String = ""
    var canonical: Data { Data("\(swarmID)|\(piece)|\(member)|\(claimedAt)|\(expires)|\(duplicate)".utf8) }
}

/// A member's key-agreement key, signed by its signing key.
nonisolated struct TeamSwarmMemberKey: Codable, Sendable, Hashable {
    let member: String
    let agreementKey: String
    let sig: String
}

nonisolated enum TeamSwarmIdentity {
    static let service = "com.kalsmritikosh.team", account = "x25519"

    /// This installation's key-agreement key (Keychain, this device only), created on first use.
    static func agreementKey() -> Curve25519.KeyAgreement.PrivateKey? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: AnyObject?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data {
            do { return try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data) } catch {
                KalsmritikoshLog.app.error("Team swarm: the stored agreement key is damaged; a new one is made: \(error.localizedDescription, privacy: .private)")
            }
        }
        let k = Curve25519.KeyAgreement.PrivateKey()
        let add: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                  kSecAttrAccount as String: account, kSecValueData as String: k.rawRepresentation,
                                  kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        SecItemDelete(add as CFDictionary)
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess ? k : nil
    }
}

nonisolated enum TeamSwarmError: Error, LocalizedError, Equatable {
    case notInFolder(String)
    case notShared(String)
    case changed(String)
    case noEnvelope
    case noMembersWithKeys

    var errorDescription: String? {
        switch self {
        case .notInFolder(let n): return "“\(n)” is not inside the team folder. Only files already shared in the team folder can be split among the team."
        case .notShared(let n): return "“\(n)” is not one of the files this shared import lists."
        case .changed(let n): return "“\(n)” is not the file the shared import listed (its fingerprint differs); it was not read."
        case .noEnvelope: return "This piece was not encrypted for this Mac (it joined after the piece was published, or its key was not in the folder yet)."
        case .noMembersWithKeys: return "No member of the folder has published a key yet."
        }
    }
}

nonisolated extension TeamCase {
    var swarmDir: URL { root.appendingPathComponent("swarm", isDirectory: true) }
    var swarmKeysDir: URL { swarmDir.appendingPathComponent("keys", isDirectory: true) }
    func swarmFolder(_ id: String) -> URL { swarmDir.appendingPathComponent(id, isDirectory: true) }
    func swarmManifestURL(_ id: String) -> URL { swarmFolder(id).appendingPathComponent("manifest.json") }
    func swarmClaimsDir(_ id: String, piece: Int) -> URL {
        swarmFolder(id).appendingPathComponent("claims", isDirectory: true).appendingPathComponent(String(piece), isDirectory: true)
    }
    func swarmShardsDir(_ id: String) -> URL { swarmFolder(id).appendingPathComponent("shards", isDirectory: true) }

    static let claimMinutes: Double = 30

    // MARK: Paths inside the folder

    /// The path of `url` relative to the folder, or nil when it is not inside it.
    func relativePath(of url: URL) -> String? {
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path
        let p = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard p.hasPrefix(base + "/") else { return nil }
        let rel = String(p.dropFirst(base.count + 1))
        return rel.split(separator: "/").contains("..") ? nil : rel
    }

    /// The file a relative path names, only when it stays inside the folder (never the swarm's own files).
    func sharedFile(_ rel: String) -> URL? {
        let parts = rel.split(separator: "/")
        guard !parts.isEmpty, !parts.contains(".."), parts.first != "swarm", parts.first != "log", parts.first != "members" else { return nil }
        return root.appendingPathComponent(rel)
    }

    // MARK: Member keys

    func publishAgreementKey(member: String, signing: Curve25519.Signing.PrivateKey, agreement: Curve25519.KeyAgreement.PrivateKey) throws {
        try FileManager.default.createDirectory(at: swarmKeysDir, withIntermediateDirectories: true)
        let url = swarmKeysDir.appendingPathComponent("\(member).json")
        let pub = agreement.publicKey.rawRepresentation
        if let data = try? Data(contentsOf: url), let k = try? JSONDecoder().decode(TeamSwarmMemberKey.self, from: data),
           k.agreementKey == pub.base64EncodedString() { return }
        let sig = try signing.signature(for: Data("swarm-key|\(member)|".utf8) + pub).base64EncodedString()
        try JSONEncoder().encode(TeamSwarmMemberKey(member: member, agreementKey: pub.base64EncodedString(), sig: sig)).write(to: url, options: .atomic)
    }

    /// Every member's key-agreement key whose signature verifies with that member's registered signing key.
    func verifiedAgreementKeys() -> [String: Curve25519.KeyAgreement.PublicKey] {
        var out: [String: Curve25519.KeyAgreement.PublicKey] = [:]
        for m in members() {
            let url = swarmKeysDir.appendingPathComponent("\(m.id).json")
            guard let data = try? Data(contentsOf: url), let k = try? JSONDecoder().decode(TeamSwarmMemberKey.self, from: data),
                  k.member == m.id, let raw = Data(base64Encoded: k.agreementKey), let sig = Data(base64Encoded: k.sig),
                  let signRaw = Data(base64Encoded: m.publicKey),
                  let signPub = try? Curve25519.Signing.PublicKey(rawRepresentation: signRaw),
                  signPub.isValidSignature(sig, for: Data("swarm-key|\(m.id)|".utf8) + raw),
                  let pub = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw) else { continue }
            out[m.id] = pub
        }
        return out
    }

    // MARK: Announcements

    func announceOptIn(caseLabel: String, on: Bool, member: String, key: Curve25519.Signing.PrivateKey) throws {
        guard reachable() else { throw TeamFolderError.unreachable("its log folder is missing") }
        _ = try append([("swarm.optin", member, caseLabel, on ? "on" : "off")], member: member, key: key)
    }

    /// The latest opt-in of every member (verified entries only): member name → on/off.
    func optIns(in entries: [(entry: TeamLogEntry, name: String)]) -> [(member: String, name: String, on: Bool, at: String)] {
        var latest: [String: (String, Bool, String)] = [:]
        for e in entries where e.entry.action == "swarm.optin" { latest[e.entry.member] = (e.name, e.entry.value == "on", e.entry.at) }
        return latest.map { (member: $0.key, name: $0.value.0, on: $0.value.1, at: $0.value.2) }.sorted { $0.name < $1.name }
    }

    /// Write a manifest and announce it (signed). Every file must be inside the folder; its fingerprint is taken now.
    func publishSwarm(id: String, title: String, pieces: [[URL]], member: String, key: Curve25519.Signing.PrivateKey) throws -> TeamSwarmAnnouncement {
        var out: [TeamSwarmPiece] = []
        for (i, urls) in pieces.enumerated() {
            var files: [TeamSwarmFile] = []
            for u in urls {
                guard let rel = relativePath(of: u), sharedFile(rel) != nil else { throw TeamSwarmError.notInFolder(u.lastPathComponent) }
                let m = try VolumeReadLanes.withReadBlocking(u) { try StreamingFileCopy.hash(u) }
                files.append(TeamSwarmFile(path: rel, sha256: m.sha256, bytes: m.byteSize))
            }
            if !files.isEmpty { out.append(TeamSwarmPiece(index: i, files: files)) }
        }
        let manifest = TeamSwarmManifest(id: id, title: title, author: member, created: ISO8601DateFormatter().string(from: Date()),
                                         pieces: out.enumerated().map { TeamSwarmPiece(index: $0.offset, files: $0.element.files) })
        try FileManager.default.createDirectory(at: swarmFolder(id), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: swarmManifestURL(id), options: .atomic)
        let note = TeamSwarmAnnouncement(id: id, title: title, manifestSHA256: TeamLogVerifyCache.digest(data), pieces: manifest.pieces.count,
                                         files: manifest.pieces.reduce(0) { $0 + $1.files.count })
        if !hasEntry(member: member, action: "swarm.manifest", objectRef: id) {
            let json = String(decoding: try JSONEncoder().encode(note), as: UTF8.self)
            _ = try append([("swarm.manifest", id, title, json)], member: member, key: key)
        }
        return note
    }

    /// Every announced swarm whose manifest file is there and matches its signed digest.
    func swarms(in entries: [(entry: TeamLogEntry, name: String)]) -> [(note: TeamSwarmAnnouncement, manifest: TeamSwarmManifest, author: String, authorName: String)] {
        var out: [(TeamSwarmAnnouncement, TeamSwarmManifest, String, String)] = []
        for e in entries where e.entry.action == "swarm.manifest" {
            guard let note = try? JSONDecoder().decode(TeamSwarmAnnouncement.self, from: Data(e.entry.value.utf8)),
                  let data = try? Data(contentsOf: swarmManifestURL(note.id)), TeamLogVerifyCache.digest(data) == note.manifestSHA256,
                  let m = try? JSONDecoder().decode(TeamSwarmManifest.self, from: data), m.id == note.id, m.author == e.entry.member else {
                continue
            }
            out.append((note, m, e.entry.member, e.name))
        }
        return out.map { (note: $0.0, manifest: $0.1, author: $0.2, authorName: $0.3) }
    }

    /// The published shards of a swarm per piece, FIRST published first (signed time, then member id).
    func shardNotes(swarmID: String, in entries: [(entry: TeamLogEntry, name: String)]) -> [Int: [TeamSigned<TeamSwarmShardNote>]] {
        var out: [Int: [TeamSigned<TeamSwarmShardNote>]] = [:]
        for e in entries where e.entry.action == "swarm.shard" && e.entry.objectRef.hasPrefix(swarmID + ":") {
            guard let n = try? JSONDecoder().decode(TeamSwarmShardNote.self, from: Data(e.entry.value.utf8)), n.swarmID == swarmID else { continue }
            out[n.piece, default: []].append(TeamSigned(value: n, member: e.entry.member, memberName: e.name, at: e.entry.at))
        }
        for k in out.keys { out[k]?.sort { $0.at == $1.at ? $0.member < $1.member : $0.at < $1.at } }
        return out
    }

    // MARK: Claims

    private func signedClaim(_ c: TeamSwarmClaim, pub: Curve25519.Signing.PublicKey?) -> Bool {
        guard let pub, let sig = Data(base64Encoded: c.sig) else { return false }
        return pub.isValidSignature(sig, for: c.canonical)
    }

    /// The valid (signed, unexpired) claims of a piece, oldest first.
    func validClaims(swarmID: String, piece: Int, now: Date = Date()) -> [TeamSwarmClaim] {
        let keys: [String: Curve25519.Signing.PublicKey] = Dictionary(members().compactMap { m in
            guard let raw = Data(base64Encoded: m.publicKey), let k = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else { return nil }
            return (m.id, k)
        }, uniquingKeysWith: { a, _ in a })
        let dir = swarmClaimsDir(swarmID, piece: piece)
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "json" }
        let t = now.timeIntervalSince1970
        return files.compactMap { u -> TeamSwarmClaim? in
            guard let data = try? Data(contentsOf: u), let c = try? JSONDecoder().decode(TeamSwarmClaim.self, from: data),
                  c.swarmID == swarmID, c.piece == piece, u.deletingPathExtension().lastPathComponent == c.member,
                  c.expires > t, signedClaim(c, pub: keys[c.member]) else { return nil }
            return c
        }.sorted { $0.claimedAt == $1.claimedAt ? $0.member < $1.member : $0.claimedAt < $1.claimedAt }
    }

    /// Claim a piece: write this member's claim, read it back, then read every claim; true when this member's claim is
    /// the oldest valid one (or, for an endgame duplicate, when it was written and read back).
    func claim(swarmID: String, piece: Int, member: String, key: Curve25519.Signing.PrivateKey, duplicate: Bool = false,
               now: Date = Date()) -> Bool {
        let dir = swarmClaimsDir(swarmID, piece: piece)
        let url = dir.appendingPathComponent("\(member).json")
        let t = now.timeIntervalSince1970
        var c = TeamSwarmClaim(swarmID: swarmID, piece: piece, member: member, claimedAt: t, expires: t + Self.claimMinutes * 60, duplicate: duplicate)
        do {
            c.sig = try key.signature(for: c.canonical).base64EncodedString()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(c)
            try data.write(to: url, options: .atomic)
            guard (try Data(contentsOf: url)) == data else { return false }
        } catch {
            KalsmritikoshLog.app.error("Team swarm: claim not written: \(error.localizedDescription, privacy: .private)")
            return false
        }
        if duplicate { return true }
        let valid = validClaims(swarmID: swarmID, piece: piece, now: now).filter { !$0.duplicate }
        guard let first = valid.first else { return false }
        if first.member != member {
            // Lost the race: give the piece back at once so nobody waits for this claim to expire.
            do { try FileManager.default.removeItem(at: url) } catch {
                KalsmritikoshLog.app.debug("Team swarm: lost claim not removed (it expires): \(error.localizedDescription, privacy: .private)")
            }
            return false
        }
        return true
    }

    /// Renew this member's claim while the piece is still being read (a long piece outlives one claim period).
    func renewClaim(swarmID: String, piece: Int, member: String, key: Curve25519.Signing.PrivateKey) {
        let url = swarmClaimsDir(swarmID, piece: piece).appendingPathComponent("\(member).json")
        guard let data = try? Data(contentsOf: url), var c = try? JSONDecoder().decode(TeamSwarmClaim.self, from: data) else { return }
        c = TeamSwarmClaim(swarmID: c.swarmID, piece: c.piece, member: c.member, claimedAt: c.claimedAt,
                           expires: Date().timeIntervalSince1970 + Self.claimMinutes * 60, duplicate: c.duplicate)
        do {
            c.sig = try key.signature(for: c.canonical).base64EncodedString()
            try JSONEncoder().encode(c).write(to: url, options: .atomic)
        } catch {
            KalsmritikoshLog.app.error("Team swarm: claim not renewed: \(error.localizedDescription, privacy: .private)")
        }
    }

    // MARK: Publishing a piece

    /// Copy a closed shard (keyed with `pieceKey`) into the folder, write the key wrapped for every member with a
    /// published key, then announce it (signed). Idempotent per piece and member.
    func publishShard(swarmID: String, piece: Int, shardURL: URL, pieceKey: LedgerKey, seedMarks: [String: Int64], files: Int,
                      teamCaseID: String, member: String, key: Curve25519.Signing.PrivateKey) throws -> TeamSwarmShardNote {
        let ref = "\(swarmID):\(piece)"
        let recipients = verifiedAgreementKeys()
        guard !recipients.isEmpty else { throw TeamSwarmError.noMembersWithKeys }
        let dir = swarmShardsDir(swarmID)
        let name = "\(piece).\(member).kshard"
        let copied = try Self.copyChecked(shardURL, into: dir, name: name)
        let caseUUID = UUID(uuidString: teamCaseID) ?? TeamSwarmIDs.uuid(from: teamCaseID)
        var envelopes: [String: SimulatedSharedCaseVault.WrappedKey] = [:]
        for (m, pub) in recipients {
            envelopes[m] = try SimulatedSharedCaseVault.wrap(SymmetricKey(data: pieceKey.raw), for: pub, caseID: caseUUID, epoch: piece + 1)
        }
        let keysName = "\(piece).\(member).keys"
        let keysData = try JSONEncoder().encode(envelopes)
        try keysData.write(to: dir.appendingPathComponent(keysName), options: .atomic)
        let note = TeamSwarmShardNote(swarmID: swarmID, piece: piece, file: name, sha256: copied.sha256, bytes: Int64(copied.bytes),
                                      keysFile: keysName, keysSHA256: TeamLogVerifyCache.digest(keysData), seedMarks: seedMarks, files: files)
        if !hasEntry(member: member, action: "swarm.shard", objectRef: ref) {
            let json = String(decoding: try JSONEncoder().encode(note), as: UTF8.self)
            _ = try append([("swarm.shard", ref, "piece \(piece + 1)", json)], member: member, key: key)
        }
        return note
    }

    /// Fetch a published piece for this Mac: the shard copied to `localURL` and checked against its signed digest, and the
    /// piece key opened with this Mac's agreement key.
    func fetchShard(_ note: TeamSwarmShardNote, teamCaseID: String, member: String, agreement: Curve25519.KeyAgreement.PrivateKey,
                    into localDir: URL) throws -> (url: URL, key: LedgerKey) {
        let dir = swarmShardsDir(note.swarmID)
        let keysURL = dir.appendingPathComponent(note.keysFile)
        let keysData = try Data(contentsOf: keysURL)
        guard TeamLogVerifyCache.digest(keysData) == note.keysSHA256 else { throw TeamSwarmError.changed(note.keysFile) }
        let envelopes = try JSONDecoder().decode([String: SimulatedSharedCaseVault.WrappedKey].self, from: keysData)
        guard let mine = envelopes[member] else { throw TeamSwarmError.noEnvelope }
        let caseUUID = UUID(uuidString: teamCaseID) ?? TeamSwarmIDs.uuid(from: teamCaseID)
        let sym = try SimulatedSharedCaseVault.unwrap(mine, with: agreement, caseID: caseUUID)
        guard let key = LedgerKey(raw: sym.withUnsafeBytes { Data($0) }) else { throw TeamSwarmError.noEnvelope }
        let fetched = try Self.copyChecked(dir.appendingPathComponent(note.file), into: localDir, name: note.file)
        guard fetched.sha256 == note.sha256 else { throw TeamSwarmError.changed(note.file) }
        return (localDir.appendingPathComponent(note.file), key)
    }

    // MARK: Erasure

    /// Remove every swarm file `member` wrote for `swarmIDs` (its claims and published pieces; the manifest when it
    /// started the swarm) and announce it. Returns what could not be removed (shown as residue).
    func eraseSwarmFiles(swarmIDs: [String], authored: Set<String>, member: String, key: Curve25519.Signing.PrivateKey?) -> [String] {
        let fm = FileManager.default
        var residue: [String] = []
        func remove(_ u: URL) {
            guard fm.fileExists(atPath: u.path) else { return }
            do { try fm.removeItem(at: u) } catch {
                KalsmritikoshLog.app.error("Team swarm: a file not removed by the erasure: \(error.localizedDescription, privacy: .private)")
                residue.append("team folder: \(u.lastPathComponent)")
            }
        }
        for id in swarmIDs {
            let claims = swarmFolder(id).appendingPathComponent("claims", isDirectory: true)
            for d in (try? fm.contentsOfDirectory(at: claims, includingPropertiesForKeys: nil)) ?? [] {
                remove(d.appendingPathComponent("\(member).json"))
            }
            for f in (try? fm.contentsOfDirectory(at: swarmShardsDir(id), includingPropertiesForKeys: nil)) ?? []
            where f.lastPathComponent.contains(".\(member).") {
                remove(f)
            }
            if authored.contains(id) { remove(swarmManifestURL(id)) }
            if let key, !hasEntry(member: member, action: "swarm.erased", objectRef: id) {
                do { _ = try append([("swarm.erased", id, "erased", "")], member: member, key: key) } catch {
                    KalsmritikoshLog.app.error("Team swarm: erasure not announced: \(error.localizedDescription, privacy: .private)")
                }
            }
        }
        return residue
    }
}

nonisolated enum TeamSwarmIDs {
    /// A stable UUID from any text (the first 16 bytes of its SHA-256, version bits set).
    static func uuid(from text: String) -> UUID {
        var b = Array(SHA256.hash(data: Data(text.utf8)).prefix(16))
        b[6] = (b[6] & 0x0F) | 0x50
        b[8] = (b[8] & 0x3F) | 0x80
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }
}
