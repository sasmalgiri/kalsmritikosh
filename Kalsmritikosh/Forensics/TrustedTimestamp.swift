//
//  TrustedTimestamp.swift
//  Kalsmritikosh
//
//  ALCOA ALC-12 (owner 2026-11-24; DATA-22) — trusted time. Optional RFC 3161 timestamps of the audit-chain head and of
//  signed receipts, from a time-stamping authority (TSA) whose address the person sets in Settings ▸ Privacy (off by
//  default). Only a SHA-256 leaves this Mac: the request is a TimeStampReq (the digest, a nonce, "send your
//  certificate"), sent THROUGH the network helper (NetworkHelperClient, purpose "timestamp"; the helper accepts it only
//  as a small application/timestamp-query POST). The token the TSA returns is kept (trusted_timestamps, append-only)
//  and can be checked at any time: its message imprint must be the digest, its nonce ours, and its CMS signature valid.
//
//  Honest scope: the signature check confirms the token was signed by the certificate inside it; whether that TSA is
//  one you trust is your choice of TSA (its certificate chain is not evaluated against a trust store here).
//

import Foundation
import CryptoKit
import Security
import os

// MARK: - DER (just what RFC 3161 needs)

nonisolated enum DER {
    static func length(_ n: Int) -> [UInt8] {
        if n < 0x80 { return [UInt8(n)] }
        var bytes: [UInt8] = []
        var v = n
        while v > 0 { bytes.insert(UInt8(v & 0xFF), at: 0); v >>= 8 }
        return [0x80 | UInt8(bytes.count)] + bytes
    }
    static func tlv(_ tag: UInt8, _ body: [UInt8]) -> [UInt8] { [tag] + length(body.count) + body }
    static func sequence(_ parts: [[UInt8]]) -> [UInt8] { tlv(0x30, parts.flatMap { $0 }) }
    static func integer(_ bytes: [UInt8]) -> [UInt8] {
        var b = Array(bytes.drop { $0 == 0 })
        if b.isEmpty { b = [0] }
        if b[0] & 0x80 != 0 { b.insert(0, at: 0) }
        return tlv(0x02, b)
    }
    static func oid(_ arcs: [UInt]) -> [UInt8] {
        var body: [UInt8] = [UInt8(arcs[0] * 40 + arcs[1])]
        for arc in arcs.dropFirst(2) {
            var chunk: [UInt8] = [UInt8(arc & 0x7F)]
            var v = arc >> 7
            while v > 0 { chunk.insert(UInt8(v & 0x7F) | 0x80, at: 0); v >>= 7 }
            body += chunk
        }
        return tlv(0x06, body)
    }
    static let sha256OID: [UInt] = [2, 16, 840, 1, 101, 3, 4, 2, 1]
    static let tstInfoOID: [UInt] = [1, 2, 840, 113549, 1, 9, 16, 1, 4]
    static let signedDataOID: [UInt] = [1, 2, 840, 113549, 1, 7, 2]

    /// One element: tag, the element's content, the bytes after it.
    struct Node { let tag: UInt8; let content: ArraySlice<UInt8>; let rest: ArraySlice<UInt8> }

    static func read(_ data: ArraySlice<UInt8>) -> Node? {
        var i = data.startIndex
        guard i < data.endIndex else { return nil }
        let tag = data[i]; i += 1
        guard i < data.endIndex else { return nil }
        var len = Int(data[i]); i += 1
        if len & 0x80 != 0 {
            let n = len & 0x7F
            guard n > 0, n <= 4, i + n <= data.endIndex else { return nil }
            len = 0
            for _ in 0..<n { len = (len << 8) | Int(data[i]); i += 1 }
        }
        guard len >= 0, i + len <= data.endIndex else { return nil }
        return Node(tag: tag, content: data[i..<(i + len)], rest: data[(i + len)...])
    }

    /// The children of a constructed element.
    static func children(_ content: ArraySlice<UInt8>) -> [Node] {
        var out: [Node] = []
        var rest = content
        while !rest.isEmpty, let n = read(rest) { out.append(n); rest = n.rest }
        return out
    }
}

// MARK: - Request, token, check

public nonisolated enum RFC3161 {

    /// A TimeStampReq for a SHA-256 digest (hex): version 1, the imprint, the nonce, certReq TRUE.
    public static func request(digestHex: String, nonce: [UInt8]) -> Data? {
        guard let digest = hexBytes(digestHex), digest.count == 32 else { return nil }
        let algorithm = DER.sequence([DER.oid(DER.sha256OID), [0x05, 0x00]])
        let imprint = DER.sequence([algorithm, DER.tlv(0x04, digest)])
        return Data(DER.sequence([DER.integer([1]), imprint, DER.integer(nonce), DER.tlv(0x01, [0xFF])]))
    }

    /// What a token says (read from its TSTInfo).
    public struct TokenInfo: Sendable, Equatable {
        public let digestHex: String
        public let nonce: [UInt8]?
        public let genTime: Date?
    }

    public enum Failure: Error, Equatable, LocalizedError {
        case notGranted(Int), noToken, unreadable
        public var errorDescription: String? {
            switch self {
            case .notGranted(let s): return "The time-stamping authority did not grant the timestamp (status \(s))."
            case .noToken: return "The time-stamping authority's reply carried no token."
            case .unreadable: return "The timestamp token could not be read."
            }
        }
    }

    /// The token (a CMS ContentInfo) from a TimeStampResp; refuses a status other than granted (0) / with mods (1).
    public static func token(fromResponse data: Data) throws -> Data {
        let bytes = Array(data)
        guard let top = DER.read(bytes[...]), top.tag == 0x30 else { throw Failure.unreadable }
        let parts = DER.children(top.content)
        guard let statusInfo = parts.first, statusInfo.tag == 0x30, let status = DER.children(statusInfo.content).first, status.tag == 0x02 else {
            throw Failure.unreadable
        }
        let code = status.content.reduce(0) { ($0 << 8) | Int($1) }
        guard code == 0 || code == 1 else { throw Failure.notGranted(code) }
        guard parts.count > 1 else { throw Failure.noToken }
        let t = parts[1]
        return Data([t.tag] + DER.length(t.content.count) + Array(t.content))
    }

    /// Read the TSTInfo inside a token (ContentInfo → SignedData → encapContentInfo → eContent).
    public static func info(token: Data) throws -> TokenInfo {
        let bytes = Array(token)
        guard let ci = DER.read(bytes[...]), ci.tag == 0x30 else { throw Failure.unreadable }
        let ciParts = DER.children(ci.content)
        guard ciParts.count >= 2, ciParts[0].tag == 0x06, Array(ciParts[0].content) == Array(DER.oid(DER.signedDataOID).dropFirst(2)),
              ciParts[1].tag == 0xA0, let sd = DER.children(ciParts[1].content).first, sd.tag == 0x30 else { throw Failure.unreadable }
        let sdParts = DER.children(sd.content)
        guard sdParts.count >= 3, sdParts[2].tag == 0x30 else { throw Failure.unreadable }
        let encap = DER.children(sdParts[2].content)
        guard encap.count >= 2, encap[0].tag == 0x06, Array(encap[0].content) == Array(DER.oid(DER.tstInfoOID).dropFirst(2)),
              encap[1].tag == 0xA0, let octets = DER.children(encap[1].content).first, octets.tag == 0x04,
              let tst = DER.read(octets.content), tst.tag == 0x30 else { throw Failure.unreadable }
        return try tstInfo(tst.content)
    }

    static func tstInfo(_ content: ArraySlice<UInt8>) throws -> TokenInfo {
        let f = DER.children(content)
        // version, policy, messageImprint, serialNumber, genTime, [accuracy], [ordering], [nonce], …
        guard f.count >= 5, f[2].tag == 0x30 else { throw Failure.unreadable }
        let imprint = DER.children(f[2].content)
        guard imprint.count == 2, imprint[1].tag == 0x04 else { throw Failure.unreadable }
        let digest = imprint[1].content.map { String(format: "%02x", $0) }.joined()
        let genTime = f[4].tag == 0x18 ? generalizedTime(String(decoding: f[4].content, as: UTF8.self)) : nil
        let nonce = f.dropFirst(5).first { $0.tag == 0x02 }.map { Array($0.content.drop { $0 == 0 }) }
        return TokenInfo(digestHex: digest, nonce: nonce, genTime: genTime)
    }

    static func generalizedTime(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        let core = s.replacingOccurrences(of: "Z", with: "")
        let whole = core.split(separator: ".").first.map(String.init) ?? core
        f.dateFormat = "yyyyMMddHHmmss"
        guard var d = f.date(from: whole) else { return nil }
        if let frac = core.split(separator: ".").dropFirst().first, let v = Double("0." + frac) { d.addTimeInterval(v) }
        return d
    }

    /// The result of checking a kept token against the digest it was asked for.
    public struct Check: Sendable, Equatable {
        public let imprintMatches: Bool
        public let nonceMatches: Bool
        public let signatureValid: Bool
        public let genTime: Date?
        public var ok: Bool { imprintMatches && nonceMatches && signatureValid }
        public var line: String {
            var parts: [String] = []
            parts.append(imprintMatches ? "the token is for this digest" : "the token is NOT for this digest")
            parts.append(nonceMatches ? "our nonce" : "a different nonce")
            parts.append(signatureValid ? "its signature is valid (the TSA's own certificate; trust in the TSA is yours to judge)" : "its signature does NOT verify")
            return (ok ? "Verified: " : "NOT verified: ") + parts.joined(separator: ", ") + "."
        }
    }

    public static func check(token: Data, digestHex: String, nonce: [UInt8]) -> Check {
        guard let info = try? info(token: token) else {
            return Check(imprintMatches: false, nonceMatches: false, signatureValid: false, genTime: nil)
        }
        let n = Array(nonce.drop { $0 == 0 })
        return Check(imprintMatches: info.digestHex == digestHex.lowercased(), nonceMatches: info.nonce == n,
                     signatureValid: cmsSignatureValid(token), genTime: info.genTime)
    }

    /// The CMS signature of the token, checked by macOS's CMS decoder (signature only; the chain is not evaluated).
    static func cmsSignatureValid(_ token: Data) -> Bool {
        var decoder: CMSDecoder?
        guard CMSDecoderCreate(&decoder) == errSecSuccess, let decoder else { return false }
        let fed = token.withUnsafeBytes { CMSDecoderUpdateMessage(decoder, $0.baseAddress!, token.count) }
        guard fed == errSecSuccess, CMSDecoderFinalizeMessage(decoder) == errSecSuccess else { return false }
        var signers = 0
        guard CMSDecoderGetNumSigners(decoder, &signers) == errSecSuccess, signers > 0 else { return false }
        var status = CMSSignerStatus.unsigned
        let policy = SecPolicyCreateBasicX509()
        guard CMSDecoderCopySignerStatus(decoder, 0, policy, false, &status, nil, nil) == errSecSuccess else { return false }
        return status == .valid
    }

    static func hexBytes(_ hex: String) -> [UInt8]? {
        let chars = Array(hex.lowercased())
        guard chars.count % 2 == 0 else { return nil }
        var out: [UInt8] = []
        var i = 0
        while i < chars.count {
            guard let b = UInt8(String(chars[i...i + 1]), radix: 16) else { return nil }
            out.append(b); i += 2
        }
        return out
    }
}

// MARK: - Settings (off by default)

public nonisolated enum TrustedTimestampSettings {
    static let enabledKey = "alcoa.trustedTimestamp.enabled"
    static let urlKey = "alcoa.trustedTimestamp.tsaURL"

    public static func isEnabled(_ defaults: UserDefaults = AppDefaults.store) -> Bool { defaults.bool(forKey: enabledKey) }
    public static func url(_ defaults: UserDefaults = AppDefaults.store) -> String? {
        let s = (defaults.string(forKey: urlKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }
    public static func set(enabled: Bool, url: String, _ defaults: UserDefaults = AppDefaults.store) {
        defaults.set(enabled, forKey: enabledKey)
        defaults.set(url.trimmingCharacters(in: .whitespacesAndNewlines), forKey: urlKey)
    }
    /// The one host the network door lets a timestamp request reach: the person's TSA, while timestamping is on.
    public static func allowedHost(_ defaults: UserDefaults = AppDefaults.store) -> String? {
        guard isEnabled(defaults), let u = url(defaults), u.hasPrefix("https://"), let host = URL(string: u)?.host, !host.isEmpty else { return nil }
        return host
    }
}

// MARK: - Service

public nonisolated enum TrustedTimestamps {

    public struct Kept: Sendable, Equatable, Identifiable {
        public let id: UUID
        public let subjectKind: String
        public let subjectRef: String
        public let digestHex: String
        public let tsaURL: String
        public let nonceHex: String
        public let token: Data
        public let genTime: Date?
        public let requestedAt: Date
    }

    public enum Failure: Error, LocalizedError {
        case off, badDigest
        public var errorDescription: String? {
            switch self {
            case .off: return "Trusted timestamps are off. Turn them on and give the address of a time-stamping authority in Settings ▸ Privacy."
            case .badDigest: return "Only a SHA-256 digest can be timestamped."
            }
        }
    }

    /// Ask the person's TSA for a token over `digestHex` and keep it. `send` is the network door (tests pass a stand-in).
    @discardableResult
    public static func request(_ database: Database, kind: String, subjectRef: String, digestHex: String,
                               defaults: UserDefaults = AppDefaults.store,
                               send: @Sendable (OutboundHTTPRequest) async throws -> OutboundHTTPResponse = { try await TimestampAuthorityClient.send($0) }) async throws -> Kept {
        guard TrustedTimestampSettings.allowedHost(defaults) != nil, let url = TrustedTimestampSettings.url(defaults) else { throw Failure.off }
        var nonce = [UInt8](repeating: 0, count: 8)
        guard SecRandomCopyBytes(kSecRandomDefault, nonce.count, &nonce) == errSecSuccess else { throw RFC3161.Failure.unreadable }
        nonce[0] &= 0x7F
        if nonce[0] == 0 { nonce[0] = 1 }
        guard let body = RFC3161.request(digestHex: digestHex, nonce: nonce) else { throw Failure.badDigest }
        let reply = try await send(OutboundHTTPRequest(url: url, headers: ["Content-Type": "application/timestamp-query", "Accept": "application/timestamp-reply"],
                                                       body: body, method: nil, purpose: "timestamp"))
        guard (200..<300).contains(reply.status) else { throw NetworkHelperError.failed("The time-stamping authority answered HTTP \(reply.status).") }
        let token = try RFC3161.token(fromResponse: reply.body)
        let info = try RFC3161.info(token: token)
        guard info.digestHex == digestHex.lowercased(), info.nonce == nonce else { throw RFC3161.Failure.unreadable }
        let kept = Kept(id: UUID(), subjectKind: kind, subjectRef: subjectRef, digestHex: digestHex.lowercased(), tsaURL: url,
                        nonceHex: nonce.map { String(format: "%02x", $0) }.joined(), token: token, genTime: info.genTime, requestedAt: Date())
        try await database.exec("""
            INSERT INTO trusted_timestamps (id, subject_kind, subject_ref, digest_sha256, tsa_url, nonce, token, gen_time, requested_at)
            VALUES (?,?,?,?,?,?,?,?,?);
            """, [.uuid(kept.id), .text(kind), .text(subjectRef), .text(kept.digestHex), .text(url), .text(kept.nonceHex), .blob(token),
                  kept.genTime.map { .date($0) } ?? .null, .date(kept.requestedAt)])
        return kept
    }

    /// Timestamp the audit chain's current head (its entry hash is already a SHA-256 hex digest).
    @discardableResult
    public static func stampChainHead(_ database: Database, chain: AuditChainService, defaults: UserDefaults = AppDefaults.store,
                                      send: @Sendable (OutboundHTTPRequest) async throws -> OutboundHTTPResponse = { try await TimestampAuthorityClient.send($0) }) async throws -> Kept {
        _ = try await chain.seal()
        let head = try await chain.head()
        let digest = head.hash.count == 64 ? head.hash : CaseFileHash.sha256(head.hash)
        return try await request(database, kind: "chainHead", subjectRef: "seq \(head.sealedSeq)", digestHex: digest, defaults: defaults, send: send)
    }

    /// When timestamping is on, timestamp a signed receipt's seal in the background; logs, never throws.
    public static func stampReceiptIfEnabled(_ database: Database?, seal: String) {
        guard let database, TrustedTimestampSettings.allowedHost() != nil else { return }
        let digest = seal.count == 64 && seal.allSatisfy(\.isHexDigit) ? seal.lowercased() : CaseFileHash.sha256(seal)
        Task.detached(priority: .utility) {
            do { try await request(database, kind: "receipt", subjectRef: String(seal.prefix(64)), digestHex: digest) } catch {
                KalsmritikoshLog.app.error("Receipt timestamp not obtained: \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    public static func kept(_ database: Database) async throws -> [Kept] {
        guard !(try await database.query("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'trusted_timestamps';", []).isEmpty) else { return [] }
        return try await database.query("""
            SELECT id, subject_kind, subject_ref, digest_sha256, tsa_url, nonce, token, gen_time, requested_at FROM trusted_timestamps ORDER BY requested_at DESC;
            """, []).compactMap { r in
            guard let id = r.uuid(0), let k = r.string(1), let s = r.string(2), let d = r.string(3), let u = r.string(4), let n = r.string(5),
                  let t = r.blob(6), let at = r.date(8) else { return nil }
            return Kept(id: id, subjectKind: k, subjectRef: s, digestHex: d, tsaURL: u, nonceHex: n, token: t, genTime: r.date(7), requestedAt: at)
        }
    }

    /// Check a kept token now.
    public static func verify(_ k: Kept) -> RFC3161.Check {
        RFC3161.check(token: k.token, digestHex: k.digestHex, nonce: RFC3161.hexBytes(k.nonceHex) ?? [])
    }
}
