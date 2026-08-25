//
//  kalverify.swift — standalone Kalsmritikosh conformance-bundle verifier.
//
//  Runs OUTSIDE the app, with no dependency on it: only Foundation + CryptoKit.
//  Usage:  swift verifier/kalverify.swift <bundle-folder>
//  Spec:   docs/verification/BUNDLE_FORMAT.md (format v1)
//
//  Three separated verdicts, each printed on its own line:
//   INTEGRITY     — every file matches manifest.json's SHA-256.
//   AUTHENTICITY  — the ECDSA P-256 signature over the canonical attestation
//                   envelope verifies with the embedded public key, and the
//                   envelope's hashes match the actual protocol + evaluations
//                   bytes (recomputed-hash forgeries fail here).
//   REPLAY        — the fail-closed rollup recomputed from the rule outcomes
//                   equals the sealed status and the count matches.
//                   (The in-app verifier additionally recompiles the rules from
//                   the protocol; this CLI checks outcome data + counts.)
//
//  Exit code 0 = all three passed; 1 = any failed or unreadable.
//

import Foundation
import CryptoKit

// MARK: - Mirrored wire types (spec v1 — field names are the contract)

struct Envelope: Codable {
    let formatVersion: Int
    let sutraCitation: String
    let sutraSHA256: String
    let ruleEvaluationsSHA256: String
    let overallStatus: String
    let ruleCount: Int
    let assessedAt: Date
    let applicationBuild: String
    let signerKeyID: String
    let signatureAlgorithm: String
    let caseID: String?
    let runRevision: Int?
    let auditChainHead: String?
    let auditEventCount: Int?
    let receiptSeal: String?
    let databaseSchemaVersion: Int?
    let evidenceManifestSHA256: String?
    let signerAssurance: String?
}

struct Attestation: Codable {
    let envelope: Envelope
    let signatureHex: String
    let publicKeyHex: String
}

struct Manifest: Codable {
    let formatVersion: Int
    let files: [String: String]
}

struct Evaluation: Codable {
    struct Rule: Codable {
        let id: String
        let severity: String
    }
    let rule: Rule
    let outcome: String
}

// MARK: - Helpers

func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func hexData(_ hex: String) -> Data? {
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

/// Canonical envelope bytes (spec: JSON, sorted keys, ISO-8601 dates, no
/// pretty-printing) — must byte-match what the app signed.
func canonical<T: Encodable>(_ value: T) throws -> Data {
    let enc = JSONEncoder()
    enc.outputFormatting = [.sortedKeys]
    enc.dateEncodingStrategy = .iso8601
    return try enc.encode(value)
}

func decoder() -> JSONDecoder {
    let d = JSONDecoder()
    d.dateDecodingStrategy = .iso8601
    return d
}

// MARK: - Main

guard CommandLine.arguments.count == 2 else {
    print("usage: swift kalverify.swift <bundle-folder>")
    exit(1)
}
let dir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
func read(_ name: String) -> Data? { try? Data(contentsOf: dir.appendingPathComponent(name)) }

var failed = false
func report(_ name: String, _ ok: Bool, _ detail: String = "") {
    print("\(name): \(ok ? "PASSED" : "FAILED")\(detail.isEmpty ? "" : " — \(detail)")")
    if !ok { failed = true }
}

// 1 — INTEGRITY
guard let manifestData = read("manifest.json"),
      let manifest = try? decoder().decode(Manifest.self, from: manifestData) else {
    report("INTEGRITY", false, "manifest.json missing or unreadable"); exit(1)
}
var integrityOK = true
var integrityDetail = ""
for (name, expected) in manifest.files {
    guard let data = read(name) else { integrityOK = false; integrityDetail = "\(name) missing"; break }
    if sha256(data) != expected { integrityOK = false; integrityDetail = "\(name) hash mismatch"; break }
}
report("INTEGRITY", integrityOK, integrityDetail)
guard integrityOK else { exit(1) }

// 2 — AUTHENTICITY
guard let attestationData = read("attestation.json"),
      let attestation = try? decoder().decode(Attestation.self, from: attestationData),
      let protocolData = read("protocol.json"),
      let evaluationsData = read("rule-evaluations.json") else {
    report("AUTHENTICITY", false, "attestation/protocol/evaluations unreadable"); exit(1)
}
var authOK = true
var authDetail = ""
if attestation.envelope.sutraSHA256 != sha256(protocolData) {
    authOK = false; authDetail = "protocol.json ≠ signed constitution hash"
}
if authOK, attestation.envelope.ruleEvaluationsSHA256 != sha256(evaluationsData) {
    authOK = false; authDetail = "rule-evaluations.json ≠ signed evaluations hash"
}
if authOK {
    if let canonicalEnvelope = try? canonical(attestation.envelope),
       let keyData = hexData(attestation.publicKeyHex),
       let publicKey = try? P256.Signing.PublicKey(x963Representation: keyData),
       let sigData = hexData(attestation.signatureHex),
       let signature = try? P256.Signing.ECDSASignature(derRepresentation: sigData),
       publicKey.isValidSignature(signature, for: canonicalEnvelope) {
        // signature verifies
    } else {
        authOK = false; authDetail = "signature does not verify against the embedded public key"
    }
}
report("AUTHENTICITY", authOK, authDetail)
guard authOK else { exit(1) }

// 3 — CONFORMANCE REPLAY
guard let evaluations = try? decoder().decode([Evaluation].self, from: evaluationsData) else {
    report("REPLAY", false, "rule-evaluations.json failed to decode"); exit(1)
}
let mandatory = evaluations.filter { $0.rule.severity == "mandatory" }
let recomputed: String =
    mandatory.contains { $0.outcome == "failed" } ? "notConformant"
    : mandatory.contains { $0.outcome == "notEvaluated" || $0.outcome == "evaluatorError" } ? "indeterminate"
    : "conformant"
var replayOK = true
var replayDetail = ""
if recomputed != attestation.envelope.overallStatus {
    replayOK = false; replayDetail = "recomputed '\(recomputed)' ≠ sealed '\(attestation.envelope.overallStatus)'"
}
if replayOK, evaluations.count != attestation.envelope.ruleCount {
    replayOK = false; replayDetail = "\(evaluations.count) evaluation(s) ≠ sealed ruleCount \(attestation.envelope.ruleCount)"
}
if replayOK, Set(evaluations.map(\.rule.id)).count != evaluations.count {
    replayOK = false; replayDetail = "duplicate rule evaluations"
}
report("REPLAY", replayOK, replayDetail)

print(failed ? "\nRESULT: FAILED" : "\nRESULT: VERIFIED — \(attestation.envelope.sutraCitation) · status \(attestation.envelope.overallStatus) · signer \(attestation.envelope.signerKeyID)")
exit(failed ? 1 : 0)
