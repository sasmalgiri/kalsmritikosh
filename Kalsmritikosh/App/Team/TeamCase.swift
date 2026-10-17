//
//  TeamCase.swift
//  Kalsmritikosh
//
//  W4-4 — team review over a shared folder (method as in mailin's ReviewPack /
//  TeamCase; native code). No server and no network: the folder is any folder
//  every reviewer can reach (SMB share, external disk, a synced folder).
//
//    <case>/case.json                    name, created
//    <case>/members/<memberID>.json      display name + Ed25519 public key
//    <case>/log/<memberID>.jsonl         that member's append-only log; each
//                                        entry is hash-chained to the previous
//                                        one and signed with the member's key
//    <case>/leases/<objectRef>.json      who is reviewing a document, until when
//
//  Each reviewer writes only their own log, so two Macs never write the same
//  file. Documents are matched across machines by the source file's content
//  hash (`objectRef`). Verify walks every log and reports tampering at the
//  exact member + entry: a changed byte fails the signature, a removed or
//  reordered entry breaks the chain.
//
//  Honest scope: a signature proves which installation's key wrote an entry,
//  not which person sat at it.
//

import Foundation
import CryptoKit
import Security

nonisolated struct TeamLogEntry: Codable, Sendable, Hashable {
    let seq: Int
    let prev: String          // SHA-256 hex of the previous entry's canonical bytes ("" for the first)
    let at: String            // ISO 8601
    let member: String
    let action: String        // "code" | "note"
    let objectRef: String     // source file content hash
    let objectName: String
    let value: String
    var sig: String = ""      // base64 Ed25519 signature over `canonical`

    /// The signed bytes: every field except the signature, in a fixed order.
    var canonical: Data {
        Data([String(seq), prev, at, member, action, objectRef, objectName, value].joined(separator: "\u{1F}").utf8)
    }
    var hash: String { SHA256.hash(data: canonical + Data(sig.utf8)).map { String(format: "%02x", $0) }.joined() }
}

nonisolated struct TeamMember: Codable, Sendable, Hashable {
    let id: String
    let name: String
    let publicKey: String     // base64 raw Ed25519
}

nonisolated enum TeamVerifyFinding: Sendable, Hashable {
    case ok(member: String, entries: Int)
    case badSignature(member: String, seq: Int)
    case brokenChain(member: String, seq: Int)
    case unknownMember(file: String)
    case unreadable(member: String, line: Int)

    var text: String {
        switch self {
        case .ok(let m, let n): return "\(m): \(n) entries, all signatures and links valid."
        case .badSignature(let m, let s): return "\(m): entry \(s) was changed after it was signed."
        case .brokenChain(let m, let s): return "\(m): entry \(s) does not follow the entry before it (an entry was removed, inserted or reordered)."
        case .unknownMember(let f): return "\(f): a log with no registered member key."
        case .unreadable(let m, let l): return "\(m): line \(l) is not a valid entry."
        }
    }
    var isProblem: Bool { if case .ok = self { return false }; return true }
}

nonisolated enum TeamIdentity {
    static let service = "com.kalsmritikosh.team", account = "ed25519"

    /// This installation's signing key (Keychain, this device only), created on first use.
    static func key() -> Curve25519.Signing.PrivateKey? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: AnyObject?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data,
           let k = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) { return k }
        let k = Curve25519.Signing.PrivateKey()
        let add: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                  kSecAttrAccount as String: account, kSecValueData as String: k.rawRepresentation,
                                  kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        SecItemDelete(add as CFDictionary)
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess ? k : nil
    }

    /// Member id = first 16 hex digits of SHA-256(public key).
    static func memberID(_ k: Curve25519.Signing.PublicKey) -> String {
        SHA256.hash(data: k.rawRepresentation).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

nonisolated struct TeamCase {
    let root: URL
    var membersDir: URL { root.appendingPathComponent("members", isDirectory: true) }
    var logDir: URL { root.appendingPathComponent("log", isDirectory: true) }
    var leaseDir: URL { root.appendingPathComponent("leases", isDirectory: true) }
    var name: String {
        ((try? JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("case.json")))) as? [String: String])?["name"]
            ?? root.lastPathComponent
    }

    static func create(at root: URL, name: String) throws -> TeamCase {
        let c = TeamCase(root: root)
        for d in [c.membersDir, c.logDir, c.leaseDir] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        let meta = ["name": name, "created": ISO8601DateFormatter().string(from: Date())]
        try JSONSerialization.data(withJSONObject: meta, options: [.sortedKeys]).write(to: root.appendingPathComponent("case.json"), options: .withoutOverwriting)
        return c
    }

    static func open(_ root: URL) -> TeamCase? {
        FileManager.default.fileExists(atPath: root.appendingPathComponent("case.json").path) ? TeamCase(root: root) : nil
    }

    /// Register this installation as a member (idempotent).
    func join(displayName: String, key: Curve25519.Signing.PrivateKey) throws -> String {
        let id = TeamIdentity.memberID(key.publicKey)
        let url = membersDir.appendingPathComponent("\(id).json")
        if !FileManager.default.fileExists(atPath: url.path) {
            let m = TeamMember(id: id, name: displayName, publicKey: key.publicKey.rawRepresentation.base64EncodedString())
            try JSONEncoder().encode(m).write(to: url, options: .withoutOverwriting)
        }
        return id
    }

    func members() -> [TeamMember] {
        ((try? FileManager.default.contentsOfDirectory(at: membersDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(TeamMember.self, from: Data(contentsOf: $0)) }
    }

    func entries(of member: String) -> [TeamLogEntry] {
        guard let text = try? String(contentsOf: logDir.appendingPathComponent("\(member).jsonl"), encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { try? JSONDecoder().decode(TeamLogEntry.self, from: Data($0.utf8)) }
    }

    /// Append signed entries to this member's own log.
    func append(_ drafts: [(action: String, objectRef: String, objectName: String, value: String)],
                member: String, key: Curve25519.Signing.PrivateKey) throws -> Int {
        var existing = entries(of: member)
        let url = logDir.appendingPathComponent("\(member).jsonl")
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        let iso = ISO8601DateFormatter()
        for d in drafts {
            var e = TeamLogEntry(seq: (existing.last?.seq ?? 0) + 1, prev: existing.last?.hash ?? "", at: iso.string(from: Date()),
                                 member: member, action: d.action, objectRef: d.objectRef, objectName: d.objectName, value: d.value)
            e.sig = try key.signature(for: e.canonical).base64EncodedString()
            try handle.write(contentsOf: try JSONEncoder().encode(e) + Data("\n".utf8))
            existing.append(e)
        }
        return drafts.count
    }

    /// Check every log: signatures with the member's registered key, and the hash chain.
    func verify() -> [TeamVerifyFinding] {
        let members = Dictionary(members().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [TeamVerifyFinding] = []
        let logs = ((try? FileManager.default.contentsOfDirectory(at: logDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "jsonl" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        for log in logs {
            let id = log.deletingPathExtension().lastPathComponent
            guard let m = members[id], let raw = Data(base64Encoded: m.publicKey),
                  let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else { out.append(.unknownMember(file: log.lastPathComponent)); continue }
            let lines = ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n", omittingEmptySubsequences: true)
            var prev = "", expectedSeq = 1, problem = false
            for (i, line) in lines.enumerated() {
                guard let e = try? JSONDecoder().decode(TeamLogEntry.self, from: Data(line.utf8)) else {
                    out.append(.unreadable(member: m.name, line: i + 1)); problem = true; break
                }
                guard let sig = Data(base64Encoded: e.sig), e.member == id, pub.isValidSignature(sig, for: e.canonical) else {
                    out.append(.badSignature(member: m.name, seq: e.seq)); problem = true; break
                }
                guard e.prev == prev, e.seq == expectedSeq else {
                    out.append(.brokenChain(member: m.name, seq: e.seq)); problem = true; break
                }
                prev = e.hash; expectedSeq += 1
            }
            if !problem { out.append(.ok(member: m.name, entries: lines.count)) }
        }
        return out
    }

    /// Current shared state: the latest code per document across every member (by time, then member).
    func currentCodes() -> [String: (value: String, name: String, member: String, at: String)] {
        let names = Dictionary(members().map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        var all: [TeamLogEntry] = []
        for m in members() { all += entries(of: m.id).filter { $0.action == "code" } }
        all.sort { $0.at == $1.at ? $0.member < $1.member : $0.at < $1.at }
        var out: [String: (String, String, String, String)] = [:]
        for e in all { out[e.objectRef] = (e.value, e.objectName, names[e.member] ?? e.member, e.at) }
        return out
    }

    // MARK: Leases

    /// Take a lease on a document for `minutes`; refused while another member holds an unexpired one.
    func lease(_ objectRef: String, member: String, minutes: Int = 60) throws -> Bool {
        let url = leaseDir.appendingPathComponent("\(objectRef).json")
        if let data = try? Data(contentsOf: url),
           let l = try? JSONSerialization.jsonObject(with: data) as? [String: String],
           let holder = l["member"], holder != member,
           let until = l["until"].flatMap(ISO8601DateFormatter().date(from:)), until > Date() { return false }
        let until = ISO8601DateFormatter().string(from: Date().addingTimeInterval(TimeInterval(minutes * 60)))
        try JSONSerialization.data(withJSONObject: ["member": member, "until": until]).write(to: url, options: .atomic)
        return true
    }
}
