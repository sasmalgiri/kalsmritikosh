//
//  ConformanceSeal.swift
//  Kalsmritikosh
//
//  Conformance roadmap 1.0.x-B (Level 2 — authenticated sealing). An unkeyed
//  hash chain (VerifiableReceipt) proves only internal consistency: anyone can
//  edit content and recompute a valid chain. This seal closes that gap with an
//  asymmetric signature: the canonical envelope (Sutra hash, rule-evaluations
//  hash, status, build, date) is signed with a per-installation P-256 key whose
//  private half lives only in the Keychain. Editing anything and recomputing
//  the hashes still FAILS the signature check, and the public key lets anyone
//  verify the seal outside this app with any standard ECDSA P-256 verifier.
//
//  Honest scope: the seal proves this installation's key signed this exact
//  assessment. It does not prove which human ran it, and an indeterminate
//  assessment (unevaluated mandatory rules) REFUSES to seal — you cannot
//  attest what was never evaluated.
//

import Foundation
import Security
import CryptoKit

// MARK: - Envelope (what gets signed)

public nonisolated struct ConformanceSealEnvelope: Sendable, Codable, Equatable {
    public let formatVersion: Int              // 2
    public let sutraCitation: String
    public let sutraSHA256: String
    public let ruleEvaluationsSHA256: String
    public let overallStatus: String           // ConformanceStatus.rawValue
    public let ruleCount: Int
    public let assessedAt: Date
    public let applicationBuild: String
    public let signerKeyID: String             // SHA-256 of the public key, first 16 hex
    public let signatureAlgorithm: String      // "ECDSA-P256-SHA256"
    // v2 — linkage to the run and the app's other integrity primitives (all
    // optional so v1 envelopes still decode and verify).
    public let caseID: String?
    public let runRevision: Int?
    /// Head hash of the v104 HMAC audit chain at sealing time — ties this seal
    /// to the local tamper-evident custody/fact-review ledger.
    public let auditChainHead: String?
    public let auditEventCount: Int?
    /// The findings run's VerifiableReceipt seal, when one exists.
    public let receiptSeal: String?
    public let databaseSchemaVersion: Int?
}

/// What the seal binds to beyond the assessment itself. All optional — pass
/// what the caller has; refusal conditions apply only to supplied values.
public nonisolated struct ConformanceSealLinkage: Sendable, Equatable {
    public var caseID: UUID?
    public var runRevision: Int?
    /// The run revision the assessment was computed for. When both revisions
    /// are supplied and differ, sealing refuses (stale assessment).
    public var assessedRunRevision: Int?
    public var auditChainHead: String?
    public var auditEventCount: Int?
    /// Unsealed events still outstanding in the audit chain. > 0 refuses.
    public var unsealedAuditEvents: Int?
    public var receiptSeal: String?
    public var databaseSchemaVersion: Int?

    public init(caseID: UUID? = nil, runRevision: Int? = nil, assessedRunRevision: Int? = nil,
                auditChainHead: String? = nil, auditEventCount: Int? = nil,
                unsealedAuditEvents: Int? = nil, receiptSeal: String? = nil,
                databaseSchemaVersion: Int? = nil) {
        self.caseID = caseID; self.runRevision = runRevision
        self.assessedRunRevision = assessedRunRevision
        self.auditChainHead = auditChainHead; self.auditEventCount = auditEventCount
        self.unsealedAuditEvents = unsealedAuditEvents; self.receiptSeal = receiptSeal
        self.databaseSchemaVersion = databaseSchemaVersion
    }
}

public nonisolated struct SealedConformance: Sendable, Codable, Equatable {
    public let envelope: ConformanceSealEnvelope
    /// DER-encoded ECDSA signature over the canonical envelope JSON, hex.
    public let signatureHex: String
    /// X9.63 raw public key, hex — enough for any external P-256 verifier.
    public let publicKeyHex: String
}

public nonisolated enum ConformanceSealError: Error, Equatable {
    case indeterminateAssessment   // unevaluated mandatory rules — refuse to seal
    case keyUnavailable
    case encodingFailed
    case unsealedAuditEvents(Int)  // the local audit chain has outstanding unsealed events
    case runRevisionMismatch       // the assessment was computed for a different run revision
}

// MARK: - Per-installation signing key (Keychain; same idiom as AuditChainSecret)

public nonisolated enum ConformanceSigningKey {
    private static let service = "ecosanskritiinnovation.Kalsmritikosh.conformanceSeal"
    private static let account = "p256-signing-key-v1"

    /// Load the existing key, or generate + store a fresh one. Returns nil only
    /// when the Keychain is entirely unavailable (tests inject an ephemeral key).
    public static func loadOrGenerate() -> P256.Signing.PrivateKey? {
        if let data = load(), let key = try? P256.Signing.PrivateKey(rawRepresentation: data) {
            return key
        }
        let key = P256.Signing.PrivateKey()
        return store(key.rawRepresentation) ? key : nil
    }

    private static func load() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return data
    }

    private static func store(_ raw: Data) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: raw,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        SecItemDelete(query as CFDictionary)
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    /// "<first 16 hex of SHA-256(public key)>" — printed on certificates.
    public static func keyID(for key: P256.Signing.PrivateKey) -> String {
        let digest = SHA256.hash(data: key.publicKey.x963Representation)
        return digest.map { String(format: "%02x", $0) }.joined().prefix(16).lowercased()
    }
}

// MARK: - Seal + verify

public nonisolated enum ConformanceSeal {

    /// Sign an assessment. Refuses `.indeterminate` — unevaluated mandatory
    /// rules cannot be attested. `.notConformant` seals fine: a truthful
    /// negative attestation is still an attestation.
    public static func seal(assessment: ConformanceAssessment,
                            build: String = appBuild(),
                            key: P256.Signing.PrivateKey? = nil,
                            linkage: ConformanceSealLinkage = ConformanceSealLinkage()) throws -> SealedConformance {
        guard assessment.status != .indeterminate else {
            throw ConformanceSealError.indeterminateAssessment
        }
        // Refuse when the local audit chain has events not yet sealed — the seal
        // would attest over a ledger that can still silently change.
        if let unsealed = linkage.unsealedAuditEvents, unsealed > 0 {
            throw ConformanceSealError.unsealedAuditEvents(unsealed)
        }
        // Refuse a stale assessment: computed for a different run revision.
        if let runRev = linkage.runRevision, let assessedRev = linkage.assessedRunRevision,
           runRev != assessedRev {
            throw ConformanceSealError.runRevisionMismatch
        }
        guard let signingKey = key ?? ConformanceSigningKey.loadOrGenerate() else {
            throw ConformanceSealError.keyUnavailable
        }
        let envelope = ConformanceSealEnvelope(
            formatVersion: 2,
            sutraCitation: assessment.sutraCitation,
            sutraSHA256: assessment.sutraSHA256,
            ruleEvaluationsSHA256: assessment.ruleEvaluationsSHA256,
            overallStatus: assessment.status.rawValue,
            ruleCount: assessment.evaluations.count,
            assessedAt: assessment.assessedAt,
            applicationBuild: build,
            signerKeyID: ConformanceSigningKey.keyID(for: signingKey),
            signatureAlgorithm: "ECDSA-P256-SHA256",
            caseID: linkage.caseID?.uuidString,
            runRevision: linkage.runRevision,
            auditChainHead: linkage.auditChainHead,
            auditEventCount: linkage.auditEventCount,
            receiptSeal: linkage.receiptSeal,
            databaseSchemaVersion: linkage.databaseSchemaVersion)
        guard let canonical = try? ConformanceCanonical.data(of: envelope) else {
            throw ConformanceSealError.encodingFailed
        }
        let signature = try signingKey.signature(for: canonical)
        return SealedConformance(
            envelope: envelope,
            signatureHex: signature.derRepresentation.map { String(format: "%02x", $0) }.joined(),
            publicKeyHex: signingKey.publicKey.x963Representation.map { String(format: "%02x", $0) }.joined())
    }

    /// Recompute the canonical envelope and check the signature against the
    /// embedded public key. A recomputed-hash forgery fails here.
    public static func verify(_ sealed: SealedConformance) -> Bool {
        guard let canonical = try? ConformanceCanonical.data(of: sealed.envelope),
              let keyData = Data(hex: sealed.publicKeyHex),
              let publicKey = try? P256.Signing.PublicKey(x963Representation: keyData),
              let sigData = Data(hex: sealed.signatureHex),
              let signature = try? P256.Signing.ECDSASignature(derRepresentation: sigData)
        else { return false }
        return publicKey.isValidSignature(signature, for: canonical)
    }

    /// Certificate block: everything an outside party needs to re-verify.
    public static func markdown(for sealed: SealedConformance) -> String {
        let e = sealed.envelope
        var out = "## Conformance seal (ECDSA P-256)\n\n"
        out += "| Field | Value |\n|---|---|\n"
        out += "| Constitution | \(e.sutraCitation) |\n"
        out += "| Constitution SHA-256 | `\(e.sutraSHA256)` |\n"
        out += "| Rule evaluations SHA-256 | `\(e.ruleEvaluationsSHA256)` |\n"
        out += "| Status | \(e.overallStatus) (\(e.ruleCount) rules) |\n"
        out += "| App build | \(e.applicationBuild) |\n"
        if let c = e.caseID { out += "| Case | `\(c)` |\n" }
        if let rev = e.runRevision { out += "| Run revision | \(rev) |\n" }
        if let head = e.auditChainHead { out += "| Audit chain head | `\(head)` (\(e.auditEventCount ?? 0) sealed event(s)) |\n" }
        if let receipt = e.receiptSeal { out += "| Findings receipt seal | `\(receipt)` |\n" }
        if let schema = e.databaseSchemaVersion { out += "| DB schema | v\(schema) |\n" }
        out += "| Signer key ID | `\(e.signerKeyID)` |\n"
        out += "| Algorithm | \(e.signatureAlgorithm) |\n"
        out += "| Signature (DER, hex) | `\(sealed.signatureHex)` |\n"
        out += "| Public key (X9.63, hex) | `\(sealed.publicKeyHex)` |\n\n"
        out += "_Verify independently: canonical JSON of the envelope (sorted keys, ISO-8601 dates) "
        out += "signed with ECDSA P-256/SHA-256. The seal proves this installation's key signed this "
        out += "exact assessment; it is not third-party certification._\n"
        return out
    }

    public static func appBuild() -> String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(v) (\(b))"
    }
}

// MARK: - Hex decoding helper (file-private on purpose — tiny, no dependency)

extension Data {
    fileprivate nonisolated init?(hex: String) {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        self = data
    }
}
