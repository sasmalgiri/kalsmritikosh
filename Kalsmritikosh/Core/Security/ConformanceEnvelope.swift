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
    /// Head of the PUBLIC (keyless SHA-256) audit chain at sealing time
    /// (Phase D). Bundles export the event payloads; outside verifiers fold
    /// SHA256(payload || prev) to this signed head. nil on pre-v114 seals.
    public let publicAuditChainHead: String?
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
    /// Head of the PUBLIC audit chain at sealing time (Phase D).
    public var publicAuditChainHead: String?

    public init(caseID: UUID? = nil, runRevision: Int? = nil, assessedRunRevision: Int? = nil,
                auditChainHead: String? = nil, auditEventCount: Int? = nil,
                unsealedAuditEvents: Int? = nil, receiptSeal: String? = nil,
                databaseSchemaVersion: Int? = nil, evidenceManifestSHA256: String? = nil,
                publicAuditChainHead: String? = nil) {
        self.caseID = caseID; self.runRevision = runRevision
        self.assessedRunRevision = assessedRunRevision
        self.auditChainHead = auditChainHead; self.auditEventCount = auditEventCount
        self.unsealedAuditEvents = unsealedAuditEvents; self.receiptSeal = receiptSeal
        self.databaseSchemaVersion = databaseSchemaVersion
        self.evidenceManifestSHA256 = evidenceManifestSHA256
        self.publicAuditChainHead = publicAuditChainHead
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

// MARK: - Public audit trail (Phase D)

/// One exportable entry of the PUBLIC audit chain: the canonical event
/// payload (metadata only — never document content) plus its keyless
/// SHA-256 links. An outside verifier folds
/// `SHA256(payload || publicPrev)` over the sequence and requires the last
/// hash to equal the head SIGNED in the conformance envelope.
public nonisolated struct AuditTrailEntry: Sendable, Codable, Equatable {
    public let seq: Int
    public let source: String
    public let eventID: UUID
    public let occurredAt: Date
    public let canonicalPayload: String
    public let publicPrev: String
    public let publicHash: String
    public init(seq: Int, source: String, eventID: UUID, occurredAt: Date,
                canonicalPayload: String, publicPrev: String, publicHash: String) {
        self.seq = seq; self.source = source; self.eventID = eventID
        self.occurredAt = occurredAt; self.canonicalPayload = canonicalPayload
        self.publicPrev = publicPrev; self.publicHash = publicHash
    }
}

// MARK: - Studio deliverable envelope + verifier (Phase D)

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
    public init(formatVersion: Int, studio: String, deliverableTitle: String,
                contentSHA256: String, stagesComplete: Int, stagesTotal: Int,
                allStagesComplete: Bool, sealedAt: Date, signerKeyID: String,
                signatureAlgorithm: String) {
        self.formatVersion = formatVersion; self.studio = studio
        self.deliverableTitle = deliverableTitle; self.contentSHA256 = contentSHA256
        self.stagesComplete = stagesComplete; self.stagesTotal = stagesTotal
        self.allStagesComplete = allStagesComplete; self.sealedAt = sealedAt
        self.signerKeyID = signerKeyID; self.signatureAlgorithm = signatureAlgorithm
    }
}

/// Pure verification of a SEALED studio deliverable (Foundation + CryptoKit
/// only) — used by BOTH the app and kalverify's --studio mode, from this
/// same file. Parses the seal block appended by StudioDeliverableSeal:
/// hashes the content above the separator, checks it against the envelope,
/// and verifies the ECDSA P-256 signature over the canonical envelope.
public nonisolated enum StudioDeliverableVerifier {
    /// Must match StudioDeliverableSeal.separator exactly.
    public static let separator = "\n---\n## Deliverable seal (ECDSA P-256)\n"

    public struct Verdict: Sendable, Equatable {
        public let contentIntact: Bool
        public let signatureValid: Bool
        public let envelope: StudioDeliverableEnvelope?
        public var verified: Bool { contentIntact && signatureValid }
    }

    public static func verify(markdown: String) -> Verdict {
        guard let sepRange = markdown.range(of: separator) else {
            return Verdict(contentIntact: false, signatureValid: false, envelope: nil)
        }
        let content = String(markdown[..<sepRange.lowerBound])
        let sealBlock = String(markdown[sepRange.upperBound...])
        func field(_ label: String) -> String? {
            guard let r = sealBlock.range(of: "| \(label) | `") else { return nil }
            let rest = sealBlock[r.upperBound...]
            guard let end = rest.range(of: "` |") else { return nil }
            return String(rest[..<end.lowerBound])
        }
        guard let envelopeJSON = field("Envelope (canonical JSON)"),
              let signatureHex = field("Signature (DER, hex)"),
              let publicKeyHex = field("Public key (X9.63, hex)") else {
            return Verdict(contentIntact: false, signatureValid: false, envelope: nil)
        }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        guard let envelope = try? decoder.decode(StudioDeliverableEnvelope.self,
                                                 from: Data(envelopeJSON.utf8)) else {
            return Verdict(contentIntact: false, signatureValid: false, envelope: nil)
        }
        let contentSHA = SHA256.hash(data: Data(content.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let contentIntact = contentSHA == envelope.contentSHA256
        var signatureValid = false
        if let keyData = hexBytes(publicKeyHex),
           let key = try? P256.Signing.PublicKey(x963Representation: keyData),
           let sigData = hexBytes(signatureHex),
           let signature = try? P256.Signing.ECDSASignature(derRepresentation: sigData),
           let canonical = try? ConformanceCanonical.data(of: envelope) {
            signatureValid = key.isValidSignature(signature, for: canonical)
        }
        return Verdict(contentIntact: contentIntact, signatureValid: signatureValid, envelope: envelope)
    }

    private static func hexBytes(_ hex: String) -> Data? {
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

/// THE public-chain computation (Phase D) — one definition used by the
/// sealing service, the in-app bundle verifier, and the generated CLI.
///
/// Rule v2 (eighth audit): every link binds the FULL entry — sequence,
/// source, event ID and occurrence time, not just the payload — so no
/// wrapper metadata in an exported trail can be edited without breaking
/// the fold to the SIGNED head. occurredAt is bound as its canonical
/// ISO-8601 string (whole seconds, UTC), the exact form the bundle
/// serializes, so the computation is identical before and after the
/// JSON round-trip.
public nonisolated enum PublicAuditChain {
    public static let genesis = "GENESIS-public-audit-chain-v2"

    /// The canonical string a link hashes: seq|source|eventID|occurredAt|payload.
    public static func canonicalEntry(seq: Int, source: String, eventID: UUID,
                                      occurredAt: Date, payload: String) -> String {
        "\(seq)|\(source)|\(eventID.uuidString)|\(iso8601(occurredAt))|\(payload)"
    }

    public static func link(entry: String, prev: String) -> String {
        SHA256.hash(data: Data((entry + "|" + prev).utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    /// Fold the exported trail and require it to reach the SIGNED head.
    /// Each hash is recomputed from the entry's OWN seq/source/eventID/
    /// occurredAt/payload fields, so editing any of them breaks the chain.
    /// Returns a human-readable failure, or nil when the chain replays.
    public static func replay(_ trail: [AuditTrailEntry], expectedHead: String) -> String? {
        var prev = genesis
        for entry in trail.sorted(by: { $0.seq < $1.seq }) {
            guard entry.publicPrev == prev else {
                return "public chain broken at seq \(entry.seq): prev link does not match"
            }
            let canonical = canonicalEntry(seq: entry.seq, source: entry.source,
                                           eventID: entry.eventID, occurredAt: entry.occurredAt,
                                           payload: entry.canonicalPayload)
            let computed = link(entry: canonical, prev: prev)
            guard computed == entry.publicHash else {
                return "public chain broken at seq \(entry.seq): recomputed hash does not match (payload or metadata edited)"
            }
            prev = computed
        }
        guard prev == expectedHead else {
            return "recomputed public chain head does not match the SIGNED head"
        }
        return nil
    }

    private static func iso8601(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f.string(from: date)
    }
}
