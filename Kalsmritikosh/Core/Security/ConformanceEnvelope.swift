//
//  ConformanceEnvelope.swift
//  Kalsmritikosh
//
//  PHASE A (seventh audit) — the PURE wire types of the conformance seal,
//  split from ConformanceSeal.swift so the standalone verifier compiles from
//  THIS EXACT FILE (scripts/generate-kalverify.sh concatenates it). One
//  definition of the signed envelope; parity drift between app and CLI is
//  impossible by construction. Foundation-only: no Keychain, no Security.
//

import Foundation

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
    public init(envelope: ConformanceSealEnvelope, signatureHex: String, publicKeyHex: String) {
        self.envelope = envelope; self.signatureHex = signatureHex; self.publicKeyHex = publicKeyHex
    }
}

public nonisolated enum ConformanceSealError: Error, Equatable {
    case indeterminateAssessment   // unevaluated mandatory rules — refuse to seal
    case keyUnavailable
    case encodingFailed
    case unsealedAuditEvents(Int)  // the local audit chain has outstanding unsealed events
    case runRevisionMismatch       // the assessment was computed for a different run revision
}
