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
    /// SHA-256 over the canonical evidence manifest (source version IDs +
    /// content hashes) the run was assessed over.
    public let evidenceManifestSHA256: String?
    /// Where the signing key lives: "secure-enclave", "keychain-software", or
    /// "external-software" (injected key, e.g. tests).
    public let signerAssurance: String?
    /// The REAL immutable run this seal binds to (audit item 2) — the findings
    /// run's ID and a hash over its identifying state at assessment time.
    public let runID: String?
    public let runStateSHA256: String?
    /// Deviations are visible on the wire: a conformant-with-deviations seal
    /// says so, distinctly from a clean conformant.
    public let approvedDeviationCount: Int?
    /// SHA-256 over the canonical consulted facts. SIGNED, so deleting
    /// evaluation-facts.json from a bundle cannot silently downgrade the
    /// verifier to outcome-consistency (audit item 4).
    public let factsSHA256: String?
}

/// One evidence-manifest line: a source version and the content hash that
/// custody recorded for it. Hashed canonically into the envelope.
public nonisolated struct EvidenceManifestEntry: Sendable, Codable, Equatable {
    public let sourceVersionID: String
    public let contentHash: String?
    public init(sourceVersionID: String, contentHash: String?) {
        self.sourceVersionID = sourceVersionID; self.contentHash = contentHash
    }
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
    public var evidenceManifestSHA256: String?

    public init(caseID: UUID? = nil, runRevision: Int? = nil, assessedRunRevision: Int? = nil,
                auditChainHead: String? = nil, auditEventCount: Int? = nil,
                unsealedAuditEvents: Int? = nil, receiptSeal: String? = nil,
                databaseSchemaVersion: Int? = nil, evidenceManifestSHA256: String? = nil) {
        self.caseID = caseID; self.runRevision = runRevision
        self.assessedRunRevision = assessedRunRevision
        self.auditChainHead = auditChainHead; self.auditEventCount = auditEventCount
        self.unsealedAuditEvents = unsealedAuditEvents; self.receiptSeal = receiptSeal
        self.databaseSchemaVersion = databaseSchemaVersion
        self.evidenceManifestSHA256 = evidenceManifestSHA256
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
    private static let enclaveAccount = "p256-se-signing-key-v1"

    /// Where the private key lives. Secure Enclave when the hardware offers it
    /// (the key never leaves the chip); Keychain software key otherwise.
    public enum Backend {
        case software(P256.Signing.PrivateKey)
        case enclave(SecureEnclave.P256.Signing.PrivateKey)

        public var assurance: String {
            switch self {
            case .software: return "keychain-software"
            case .enclave:  return "secure-enclave"
            }
        }
        public var publicKey: P256.Signing.PublicKey {
            switch self {
            case .software(let k): return k.publicKey
            case .enclave(let k):  return k.publicKey
            }
        }
        public func signature(for data: Data) throws -> P256.Signing.ECDSASignature {
            switch self {
            case .software(let k): return try k.signature(for: data)
            case .enclave(let k):  return try k.signature(for: data)
            }
        }
    }

    /// Load the existing key, or generate + store a fresh one — Secure Enclave
    /// preferred, Keychain software key as the fallback. Returns nil only when
    /// neither store is available (tests inject an ephemeral key instead).
    public static func loadOrGenerateBackend() -> Backend? {
        if SecureEnclave.isAvailable {
            if let data = load(account: enclaveAccount),
               let key = try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: data) {
                return .enclave(key)
            }
            if let key = try? SecureEnclave.P256.Signing.PrivateKey(),
               store(key.dataRepresentation, account: enclaveAccount) {
                return .enclave(key)
            }
        }
        if let data = load(account: account), let key = try? P256.Signing.PrivateKey(rawRepresentation: data) {
            return .software(key)
        }
        let key = P256.Signing.PrivateKey()
        return store(key.rawRepresentation, account: account) ? .software(key) : nil
    }

    /// Compatibility: the software key path (used before Secure Enclave support).
    public static func loadOrGenerate() -> P256.Signing.PrivateKey? {
        if let data = load(account: account), let key = try? P256.Signing.PrivateKey(rawRepresentation: data) {
            return key
        }
        let key = P256.Signing.PrivateKey()
        return store(key.rawRepresentation, account: account) ? key : nil
    }

    private static func load(account: String) -> Data? {
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

    private static func store(_ raw: Data, account: String) -> Bool {
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
        keyID(forPublicKey: key.publicKey)
    }

    public static func keyID(forPublicKey publicKey: P256.Signing.PublicKey) -> String {
        let digest = SHA256.hash(data: publicKey.x963Representation)
        return digest.map { String(format: "%02x", $0) }.joined().prefix(16).lowercased()
    }
}

// MARK: - Trusted signers (audit item 4 — the owner's allowlist)

/// The Mac-local allowlist of signer key fingerprints the OWNER has explicitly
/// trusted (Compliance Board › Trust signer). Verification consults it when no
/// explicit trusted key is supplied: a listed signer binds identity, an
/// unlisted one stays "key-consistent only". UserDefaults-backed — trust is a
/// local, revocable decision, never shipped as someone else's assumption.
/// The developer's release signing fingerprint, pinned at BUILD time — the
/// remaining owner/release act from the roadmap. Before a release build the
/// owner exports their signer fingerprint (Compliance Board › Copy my signer
/// fingerprint) and sets it here; packs and bundles signed by that key then
/// bind identity on every install without a local trust decision. nil = not
/// yet pinned (verification stays TOFU/allowlist-based, labelled honestly).
public nonisolated enum PinnedDeveloperKey {
    public static let keyID: String? = nil   // [owner: set before release build]
}

public nonisolated enum TrustedSigners {
    private static let key = "kalsmritikosh.trustedSigners.keyIDs"

    public static func all() -> Set<String> {
        Set((UserDefaults.standard.stringArray(forKey: key) ?? []).map { $0.lowercased() })
    }
    public static func isTrusted(_ keyID: String) -> Bool {
        if let pinned = PinnedDeveloperKey.keyID, pinned.lowercased() == keyID.lowercased() {
            return true
        }
        return all().contains(keyID.lowercased())
    }
    public static func trust(_ keyID: String) {
        UserDefaults.standard.set(Array(all().union([keyID.lowercased()])).sorted(), forKey: key)
    }
    /// (Named untrust — the bare verb `revoke` is reserved by the
    /// sensitive-scope mutation guard for SensitiveScopeRepository.)
    public static func untrust(_ keyID: String) {
        UserDefaults.standard.set(Array(all().subtracting([keyID.lowercased()])).sorted(), forKey: key)
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
        // The facts and evidence-manifest hashes come from the assessment itself
        // so the SIGNED envelope commits to them (downgrade-proof).
        let factsSHA = try assessment.facts.map { try ConformanceCanonical.sha256(of: $0) }
        let manifestSHA = try assessment.evidenceManifest.map { try ConformanceCanonical.sha256(of: $0) }
            ?? linkage.evidenceManifestSHA256
        // An injected key is an external signer (tests); otherwise Secure Enclave
        // when the hardware offers it, Keychain software key as fallback.
        let backend: ConformanceSigningKey.Backend
        if let key { backend = .software(key) }
        else if let stored = ConformanceSigningKey.loadOrGenerateBackend() { backend = stored }
        else { throw ConformanceSealError.keyUnavailable }
        let assurance = key != nil ? "external-software" : backend.assurance

        let envelope = ConformanceSealEnvelope(
            formatVersion: 2,
            sutraCitation: assessment.sutraCitation,
            sutraSHA256: assessment.sutraSHA256,
            ruleEvaluationsSHA256: assessment.ruleEvaluationsSHA256,
            overallStatus: assessment.status.rawValue,
            ruleCount: assessment.evaluations.count,
            assessedAt: assessment.assessedAt,
            applicationBuild: build,
            signerKeyID: ConformanceSigningKey.keyID(forPublicKey: backend.publicKey),
            signatureAlgorithm: "ECDSA-P256-SHA256",
            caseID: linkage.caseID?.uuidString,
            runRevision: linkage.runRevision,
            auditChainHead: linkage.auditChainHead,
            auditEventCount: linkage.auditEventCount,
            receiptSeal: linkage.receiptSeal,
            databaseSchemaVersion: linkage.databaseSchemaVersion,
            evidenceManifestSHA256: manifestSHA,
            signerAssurance: assurance,
            runID: assessment.runID?.uuidString,
            runStateSHA256: assessment.runStateSHA256,
            approvedDeviationCount: assessment.approvedDeviationCount > 0
                ? assessment.approvedDeviationCount : nil,
            factsSHA256: factsSHA)
        guard let canonical = try? ConformanceCanonical.data(of: envelope) else {
            throw ConformanceSealError.encodingFailed
        }
        let signature = try backend.signature(for: canonical)
        return SealedConformance(
            envelope: envelope,
            signatureHex: signature.derRepresentation.map { String(format: "%02x", $0) }.joined(),
            publicKeyHex: backend.publicKey.x963Representation.map { String(format: "%02x", $0) }.joined())
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
        if let manifest = e.evidenceManifestSHA256 { out += "| Evidence manifest SHA-256 | `\(manifest)` |\n" }
        if let runID = e.runID { out += "| Findings run | `\(runID)` |\n" }
        if let runState = e.runStateSHA256 { out += "| Run state SHA-256 | `\(runState)` |\n" }
        if let deviations = e.approvedDeviationCount { out += "| Approved deviations | \(deviations) — each with its justification in the per-rule certificate |\n" }
        if let schema = e.databaseSchemaVersion { out += "| DB schema | v\(schema) |\n" }
        if let assurance = e.signerAssurance { out += "| Key assurance | \(assurance) |\n" }
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

// MARK: - Studio deliverable seal (audit item 10 — every studio, one shell)
//
// Persona-studio deliverables are completeness-gated documents, not case runs;
// their conformance surface is the deliverable itself. Whenever a report
// leaves the app (copy / export / print) the SHELL appends this signed seal:
// content hash, stage completion honestly stated, installation key signature.
// The same three-verdict logic applies — hash the text above the seal line,
// re-encode the envelope canonically, check the P-256 signature.

public nonisolated struct StudioDeliverableEnvelope: Sendable, Codable, Equatable {
    public let formatVersion: Int          // 1
    public let studio: String
    public let deliverableTitle: String
    /// SHA-256 over the rendered report text ABOVE the seal block (UTF-8).
    public let contentSHA256: String
    public let stagesComplete: Int
    public let stagesTotal: Int
    public let allStagesComplete: Bool
    public let sealedAt: Date
    public let signerKeyID: String
    public let signatureAlgorithm: String
}

public nonisolated enum StudioDeliverableSeal {
    /// The line separating report content from the seal — verifiers hash
    /// everything strictly above it.
    public static let separator = "\n---\n## Deliverable seal (ECDSA P-256)\n"

    /// Append a signed seal to a rendered report. When no signing key is
    /// available the report gains an honest UNSEALED note instead — the
    /// deliverable never silently pretends.
    public static func sealedReport(studio: String, title: String, report: String,
                                    stagesComplete: Int, stagesTotal: Int,
                                    at now: Date,
                                    key: P256.Signing.PrivateKey? = nil) -> String {
        let contentSHA = SHA256.hash(data: Data(report.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let backend: ConformanceSigningKey.Backend
        if let key { backend = .software(key) }
        else if let stored = ConformanceSigningKey.loadOrGenerateBackend() { backend = stored }
        else {
            return report + separator + "_UNSEALED — no signing key available on this Mac._\n"
        }
        let envelope = StudioDeliverableEnvelope(
            formatVersion: 1, studio: studio, deliverableTitle: title,
            contentSHA256: contentSHA,
            stagesComplete: stagesComplete, stagesTotal: stagesTotal,
            allStagesComplete: stagesComplete == stagesTotal,
            sealedAt: now,
            signerKeyID: ConformanceSigningKey.keyID(forPublicKey: backend.publicKey),
            signatureAlgorithm: "ECDSA-P256-SHA256")
        guard let canonical = try? ConformanceCanonical.data(of: envelope),
              let signature = try? backend.signature(for: canonical) else {
            return report + separator + "_UNSEALED — signing failed._\n"
        }
        var out = report + separator
        out += "| Field | Value |\n|---|---|\n"
        out += "| Studio | \(studio) |\n"
        out += "| Content SHA-256 | `\(contentSHA)` |\n"
        out += "| Stages complete | \(stagesComplete)/\(stagesTotal)\(stagesComplete == stagesTotal ? "" : " — INCOMPLETE, stated honestly") |\n"
        out += "| Signer key ID | `\(envelope.signerKeyID)` |\n"
        out += "| Envelope (canonical JSON) | `\(String(data: canonical, encoding: .utf8) ?? "")` |\n"
        out += "| Signature (DER, hex) | `\(signature.derRepresentation.map { String(format: "%02x", $0) }.joined())` |\n"
        out += "| Public key (X9.63, hex) | `\(backend.publicKey.x963Representation.map { String(format: "%02x", $0) }.joined())` |\n\n"
        out += "_Verify: SHA-256 the report text above the seal line; check it equals contentSHA256 in the envelope; verify the ECDSA P-256 signature over the canonical envelope with the public key._\n"
        return out
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
