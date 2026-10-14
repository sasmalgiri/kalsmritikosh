//
//  CaseSlice.swift
//  Kalsmritikosh
//
//  I-10 — share part of a case without a server. A slice is one signed,
//  redacted, read-only JSON file: for the documents carrying a chosen tag, their
//  (redacted) names and import fingerprints, their dated events and a few quoted
//  passages. Another Kalsmritikosh opens it read-only and verifies the
//  signature; any edited byte fails. Redaction runs through PIIRedactor (emails,
//  phone numbers and any terms the user lists) on the exported copy only.
//
//  Signed bytes: the slice encoded as JSON with sorted keys and `signature` nil.
//

import Foundation
import CryptoKit

public struct CaseSlice: Codable, Sendable {
    public struct Document: Codable, Sendable { public let ref: Int; public let name: String; public let sha256: String? }
    public struct Event: Codable, Sendable { public let ref: Int; public let date: String; public let title: String; public let summary: String? }
    public struct Passage: Codable, Sendable { public let ref: Int; public let text: String }
    public struct Redaction: Codable, Sendable { public let emails: Bool; public let phones: Bool; public let customTerms: Int; public let removed: Int }
    public struct Signature: Codable, Sendable { public let algorithm: String; public let publicKey: String; public let der: String; public let keyStore: String }

    public let format: String
    public let title: String
    public let createdAt: String
    public let redaction: Redaction
    public let documents: [Document]
    public let events: [Event]
    public let passages: [Passage]
    public var signature: Signature?

    public enum Check: Equatable { case valid(fingerprint: String), invalid, unsigned }

    func canonicalBytes() throws -> Data {
        var copy = self
        copy.signature = nil
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return try enc.encode(copy)
    }

    public func signed() -> CaseSlice? {
        guard let key = ConformanceSigningKey.loadOrGenerateBackend(),
              let bytes = try? canonicalBytes(),
              let sig = try? key.signature(for: bytes) else { return nil }
        var copy = self
        copy.signature = Signature(algorithm: "ECDSA-P256-SHA256",
                                   publicKey: key.publicKey.x963Representation.base64EncodedString(),
                                   der: sig.derRepresentation.base64EncodedString(),
                                   keyStore: key.assurance)
        return copy
    }

    public func verify() -> Check {
        guard let s = signature else { return .unsigned }
        guard let keyData = Data(base64Encoded: s.publicKey), let sigData = Data(base64Encoded: s.der),
              let key = try? P256.Signing.PublicKey(x963Representation: keyData),
              let sig = try? P256.Signing.ECDSASignature(derRepresentation: sigData),
              let bytes = try? canonicalBytes(),
              key.isValidSignature(sig, for: bytes) else { return .invalid }
        let fp = SHA256.hash(data: keyData).map { String(format: "%02x", $0) }.joined().prefix(16)
        return .valid(fingerprint: String(fp))
    }
}

extension AppState {

    /// Build a signed slice of the documents carrying tag `tagName`.
    public func caseSlice(tagName: String, customTerms: [String]) async -> CaseSlice? {
        guard ProductModuleFlags.isEnabled(.caseSlices), let database, let tags = tagsRepository else { return nil }
        let ids = (try? await tags.subjects(taggedWith: tagName, kind: .object)) ?? []
        guard !ids.isEmpty else { return nil }
        let policy = RedactionPolicy(redactEmails: true, redactPhones: true, customTerms: customTerms)
        let redactor = PIIRedactor()
        var removed = 0
        func clean(_ s: String) -> String {
            let r = redactor.redact(s, policy: policy)
            removed += r.redactionCount
            return r.redactedText
        }
        var documents: [CaseSlice.Document] = []
        var events: [CaseSlice.Event] = []
        var passages: [CaseSlice.Passage] = []
        let iso = ISO8601DateFormatter()
        for (i, id) in ids.enumerated() {
            let ref = i + 1
            let doc = try? await database.query("""
                SELECT f.url, f.content_hash FROM knowledge_objects ko JOIN files f ON f.id = ko.file_id WHERE ko.id = ?;
                """, [.uuid(id)]).first
            let name = doc?.string(0).map { URL(string: $0)?.lastPathComponent ?? $0 } ?? "Document \(ref)"
            documents.append(.init(ref: ref, name: clean(name), sha256: doc?.string(1)))
            for r in (try? await database.query(
                "SELECT date, title, summary FROM events WHERE source_object_id = ? ORDER BY date LIMIT 50;",
                [.uuid(id)])) ?? [] {
                let date = r.double(0).map { iso.string(from: Date(timeIntervalSince1970: $0)) } ?? ""
                events.append(.init(ref: ref, date: date, title: clean(r.string(1) ?? ""), summary: r.string(2).map(clean)))
            }
            for r in (try? await database.query("""
                SELECT text FROM chunks WHERE object_id = ? AND review_status IS NULL AND superseded_by_run IS NULL
                ORDER BY ordinal LIMIT 3;
                """, [.uuid(id)])) ?? [] {
                if let t = r.string(0) { passages.append(.init(ref: ref, text: clean(String(t.prefix(800))))) }
            }
        }
        let slice = CaseSlice(format: "kalsmritikosh.slice.v1", title: "Case slice: \(tagName)",
                              createdAt: iso.string(from: Date()),
                              redaction: .init(emails: true, phones: true, customTerms: customTerms.count, removed: removed),
                              documents: documents, events: events, passages: passages, signature: nil)
        return slice.signed()
    }
}
