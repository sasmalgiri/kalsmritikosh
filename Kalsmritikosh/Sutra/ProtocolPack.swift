//
//  ProtocolPack.swift
//  Kalsmritikosh
//
//  Conformance roadmap 1.1 — signed OFFLINE protocol packs. Constitutions
//  update without any network connection: a pack is a single JSON file the
//  user moves by Files/AirDrop/USB/MDM and imports locally. A pack activates
//  only when ALL of these hold (fail-closed):
//
//   • the ECDSA P-256 signature over the canonical envelope verifies with the
//     embedded public key (an unsigned or edited pack cannot activate);
//   • the envelope's sutraSHA256 matches the actual snapshot bytes;
//   • the snapshot decodes to a Sutra whose compiled rules ALL evaluate
//     without evaluatorError (the schema compiles — no unparseable
//     applicability, no phase-less human rules).
//
//  Trust is recorded, not pretended: the signer key ID and the publisher's
//  assurance label ("developer" / "organization-approved" / "self-authored" /
//  "independently-reviewed") travel with the pack and are shown at import —
//  a signature proves origin consistency, never authority.
//

import Foundation
import CryptoKit

public nonisolated struct ProtocolPackEnvelope: Sendable, Codable, Equatable {
    public let formatVersion: Int          // 1
    public let sutraID: String
    public let sutraVersion: Int
    public let sutraSHA256: String
    public let publisher: String
    /// Assurance label per the roadmap's claim table — recorded, displayed,
    /// never upgraded silently.
    public let assurance: String
    public let publishedAt: Date
}

public nonisolated struct SignedProtocolPack: Sendable, Codable, Equatable {
    public let envelope: ProtocolPackEnvelope
    /// The exact canonical Sutra JSON (the same form the app freezes into runs).
    public let sutraSnapshotJSON: String
    public let signatureHex: String        // DER ECDSA over the canonical envelope
    public let publicKeyHex: String        // X9.63
}

public nonisolated enum ProtocolPackError: Error, Equatable {
    case unreadable
    case hashMismatch
    case signatureInvalid
    case schemaDoesNotCompile(String)
    case keyUnavailable
    case encodingFailed
}

public nonisolated enum ProtocolPacks {

    public static let formatVersion = 1
    public static let fileExtension = "kalprotocol"

    // MARK: - Export (sign)

    /// Sign a constitution into a distributable pack file's bytes.
    public static func export(sutra: Sutra, publisher: String, assurance: String,
                              key: P256.Signing.PrivateKey? = nil,
                              at now: Date) throws -> Data {
        guard let snapshotData = try? ConformanceCanonical.data(of: sutra),
              let snapshotJSON = String(data: snapshotData, encoding: .utf8) else {
            throw ProtocolPackError.encodingFailed
        }
        let backend: ConformanceSigningKey.Backend
        if let key { backend = .software(key) }
        else if let stored = ConformanceSigningKey.loadOrGenerateBackend() { backend = stored }
        else { throw ProtocolPackError.keyUnavailable }

        let envelope = ProtocolPackEnvelope(
            formatVersion: Self.formatVersion,
            sutraID: sutra.id,
            sutraVersion: sutra.version,
            sutraSHA256: SHA256.hash(data: snapshotData).map { String(format: "%02x", $0) }.joined(),
            publisher: publisher,
            assurance: assurance,
            publishedAt: now)
        guard let canonical = try? ConformanceCanonical.data(of: envelope) else {
            throw ProtocolPackError.encodingFailed
        }
        let signature = try backend.signature(for: canonical)
        let pack = SignedProtocolPack(
            envelope: envelope,
            sutraSnapshotJSON: snapshotJSON,
            signatureHex: signature.derRepresentation.map { String(format: "%02x", $0) }.joined(),
            publicKeyHex: backend.publicKey.x963Representation.map { String(format: "%02x", $0) }.joined())
        return try ConformanceCanonical.data(of: pack)
    }

    // MARK: - Verify (the activation gate)

    /// Verify pack bytes fail-closed. Returns the pack and its decoded Sutra
    /// only when signature, hash, and schema compilation ALL pass.
    public static func verify(_ data: Data) throws -> (pack: SignedProtocolPack, sutra: Sutra) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let pack = try? decoder.decode(SignedProtocolPack.self, from: data) else {
            throw ProtocolPackError.unreadable
        }
        // 1. The snapshot bytes must be the ones the envelope names.
        let snapshotData = Data(pack.sutraSnapshotJSON.utf8)
        let snapshotSHA = SHA256.hash(data: snapshotData).map { String(format: "%02x", $0) }.joined()
        guard snapshotSHA == pack.envelope.sutraSHA256 else { throw ProtocolPackError.hashMismatch }
        // 2. The signature over the canonical envelope must verify.
        guard let canonical = try? ConformanceCanonical.data(of: pack.envelope),
              let keyData = dataFromHex(pack.publicKeyHex),
              let publicKey = try? P256.Signing.PublicKey(x963Representation: keyData),
              let sigData = dataFromHex(pack.signatureHex),
              let signature = try? P256.Signing.ECDSASignature(derRepresentation: sigData),
              publicKey.isValidSignature(signature, for: canonical) else {
            throw ProtocolPackError.signatureInvalid
        }
        // 3. The schema must compile: decode + every rule evaluates without
        //    evaluatorError on empty facts (catches unparseable applicability
        //    and malformed rules before anything can activate).
        guard let sutra = try? decoder.decode(Sutra.self, from: snapshotData) else {
            throw ProtocolPackError.schemaDoesNotCompile("snapshot does not decode to a Sutra")
        }
        guard sutra.id == pack.envelope.sutraID, sutra.version == pack.envelope.sutraVersion else {
            throw ProtocolPackError.schemaDoesNotCompile("envelope identity does not match the snapshot")
        }
        let emptyFacts = ConformanceFacts(completedPhaseKinds: [])
        for rule in SutraRuleCompiler.rules(for: sutra) {
            if SutraConformance.evaluate(rule: rule, facts: emptyFacts).outcome == .evaluatorError {
                throw ProtocolPackError.schemaDoesNotCompile("rule \(rule.id) fails to evaluate")
            }
        }
        return (pack, sutra)
    }

    /// The signer key ID recorded in the registry ("who signed", not "who is trusted").
    public static func signerKeyID(of pack: SignedProtocolPack) -> String {
        guard let keyData = dataFromHex(pack.publicKeyHex),
              let publicKey = try? P256.Signing.PublicKey(x963Representation: keyData) else { return "?" }
        return ConformanceSigningKey.keyID(forPublicKey: publicKey)
    }

    private static func dataFromHex(_ hex: String) -> Data? {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var out = Data(capacity: hex.count / 2)
        var i = hex.startIndex
        while i < hex.endIndex {
            let next = hex.index(i, offsetBy: 2)
            guard let b = UInt8(hex[i..<next], radix: 16) else { return nil }
            out.append(b); i = next
        }
        return out
    }
}
