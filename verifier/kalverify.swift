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
    let runID: String?
    let runStateSHA256: String?
    let approvedDeviationCount: Int?
    let factsSHA256: String?
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
        let phaseKind: String?
        let kind: String
        let severity: String
        let text: String
        let applicability: String?
        let requiredEvidence: [String]?
    }
    let rule: Rule
    let outcome: String
    let evaluatorID: String
}

/// Mirror of the protocol snapshot (spec v1) — enough to recompile the rules.
struct ProtocolSnapshot: Codable {
    struct Phase: Codable {
        let kind: String
        let obligations: [String]
        let humanDecisions: [String]
        let prohibitedConclusions: [String]
    }
    let phases: [Phase]
    let globalRequirements: [String]?
}

/// Mirror of evaluation-facts.json (spec v1). requiredPhaseKinds is embedded
/// by the app at assessment time, so the CLI never re-derives defaults.
struct Facts: Codable {
    struct Attestation: Codable { let actor: String }
    /// Typed deviation authorization; legacy facts stored a plain string.
    struct Deviation: Codable {
        let authorizedBy: String
        init(from decoder: Decoder) throws {
            if let single = try? decoder.singleValueContainer(), let _ = try? single.decode(String.self) {
                self.authorizedBy = "unattributed"; return
            }
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.authorizedBy = try c.decode(String.self, forKey: .authorizedBy)
        }
        enum CodingKeys: String, CodingKey { case authorizedBy }
    }
    let completedPhaseKinds: [String]
    let standardOfProofDeclared: Bool
    let openItemsAcknowledged: Bool
    let humanDecisionsMade: [String]
    let assertedProhibited: [String]
    let attestedRuleIDs: [String]
    let approvedDeviations: [String: Deviation]
    let presentEvidenceKinds: [String]
    let attestations: [String: Attestation]
    let requiredPhaseKinds: [String]
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

guard CommandLine.arguments.count == 2 || CommandLine.arguments.count == 3 else {
    print("usage: swift kalverify.swift <bundle-folder> [trusted-signer-key-id]")
    print("Without a trusted key ID, AUTHENTICITY proves key-consistency only —")
    print("the signature matches the key EMBEDDED in the bundle. Supply the")
    print("signer's known key ID (16 hex chars) to bind the seal to an identity.")
    exit(1)
}
let dir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let trustedKeyID: String? = CommandLine.arguments.count == 3
    ? CommandLine.arguments[2].lowercased() : nil
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
        // Signature verifies against the EMBEDDED key. Identity binding requires
        // a trusted key ID supplied by the recipient (a forger can always embed
        // a fresh self-consistent key).
        if let trustedKeyID {
            let keyID = String(SHA256.hash(data: keyData)
                .map { String(format: "%02x", $0) }.joined().prefix(16))
            if keyID != trustedKeyID {
                authOK = false
                authDetail = "signer key ID \(keyID) does NOT match the trusted key ID \(trustedKeyID)"
            }
        } else {
            authDetail = "key-consistent only — supply the signer's known key ID to bind identity"
        }
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
    : mandatory.contains { $0.outcome == "approvedDeviation" } ? "conformantWithDeviations"
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

// TRUE replay (spec v1): when the bundle carries the facts, RERUN the
// deterministic evaluators — recompile the rules from the protocol, evaluate
// each over the facts, and require (rule id, outcome) to reproduce exactly.
// Detail strings are informational and not compared.
func rerunEvaluators() -> String? {
    guard let factsData = read("evaluation-facts.json") else {
        // Downgrade-proof (spec v1): when the SIGNED envelope commits to a
        // facts hash, the facts file is REQUIRED — deleting it fails replay.
        if attestation.envelope.factsSHA256 != nil {
            return "signed envelope commits to facts but evaluation-facts.json is missing — downgrade refused"
        }
        print("REPLAY note: legacy bundle without signed facts — outcome-consistency only")
        return nil
    }
    if let signedSHA = attestation.envelope.factsSHA256, sha256(factsData) != signedSHA {
        return "evaluation-facts.json does not match the SIGNED facts hash"
    }
    if let signedManifestSHA = attestation.envelope.evidenceManifestSHA256 {
        guard let manifestData = read("evidence-manifest.json") else {
            return "signed envelope commits to an evidence manifest but evidence-manifest.json is missing"
        }
        if sha256(manifestData) != signedManifestSHA {
            return "evidence-manifest.json does not match the SIGNED manifest hash"
        }
    }
    guard let facts = try? decoder().decode(Facts.self, from: factsData),
          let proto = try? decoder().decode(ProtocolSnapshot.self, from: protocolData) else {
        return "facts or protocol failed to decode for evaluator rerun"
    }
    // Recompile the rules exactly as the app's SutraRuleCompiler does.
    struct R { let id: String; let phase: String?; let kind: String; let text: String; let applicability: String? }
    var rules: [R] = []
    for (i, text) in (proto.globalRequirements ?? []).enumerated() {
        rules.append(R(id: "global.requirement.\(i)", phase: nil, kind: "obligation", text: text, applicability: "always"))
    }
    for phase in proto.phases {
        for (i, t) in phase.obligations.enumerated() {
            rules.append(R(id: "\(phase.kind).obligation.\(i)", phase: phase.kind, kind: "obligation", text: t, applicability: nil))
        }
        for (i, t) in phase.humanDecisions.enumerated() {
            rules.append(R(id: "\(phase.kind).humanDecision.\(i)", phase: phase.kind, kind: "humanDecision", text: t, applicability: nil))
        }
        for (i, t) in phase.prohibitedConclusions.enumerated() {
            rules.append(R(id: "\(phase.kind).prohibition.\(i)", phase: phase.kind, kind: "prohibition", text: t, applicability: nil))
        }
    }
    let reached = Set(facts.completedPhaseKinds)
    let required = Set(facts.requiredPhaseKinds)
    // Deterministic evaluator — mirrors SutraConformance.evaluate (spec v1).
    func evaluate(_ rule: R) -> String {
        let applicable: Bool?
        switch rule.applicability {
        case nil:      applicable = rule.phase.map(reached.contains) ?? true
        case "always": applicable = true
        case let e? where e.hasPrefix("phase_reached(") && e.hasSuffix(")"):
            applicable = reached.contains(String(e.dropFirst("phase_reached(".count).dropLast()))
        default:       applicable = nil
        }
        guard let applicable else { return "evaluatorError" }
        guard applicable else {
            if let phase = rule.phase, required.contains(phase) { return "failed" }
            return "notApplicable"
        }
        if facts.approvedDeviations[rule.id] != nil {
            // Prohibitions are NON-waivable (spec v1): a deviation on one fails.
            return rule.kind == "prohibition" ? "failed" : "approvedDeviation"
        }
        switch rule.kind {
        case "humanDecision":
            guard let phase = rule.phase else { return "evaluatorError" }
            return facts.humanDecisionsMade.contains(phase) ? "passed" : "failed"
        case "prohibition":
            if facts.assertedProhibited.contains(rule.text) { return "failed" }
            if facts.attestations[rule.id] != nil || facts.attestedRuleIDs.contains(rule.id) { return "passed" }
            return "notEvaluated"
        default: // obligation
            if rule.phase == "findings" && rule.text == "Declare a standard of proof" {
                return facts.standardOfProofDeclared ? "passed" : "failed"
            }
            if rule.phase == "findings" && rule.text == "Surface every open contradiction and gap" {
                return facts.openItemsAcknowledged ? "passed" : "failed"
            }
            if facts.attestations[rule.id] != nil || facts.attestedRuleIDs.contains(rule.id) { return "passed" }
            return "notEvaluated"
        }
    }
    let reproduced = Dictionary(uniqueKeysWithValues: rules.map { ($0.id, evaluate($0)) })
    let recorded = Dictionary(uniqueKeysWithValues: evaluations.map { ($0.rule.id, $0.outcome) })
    if reproduced != recorded {
        let diffs = Set(reproduced.keys).union(recorded.keys)
            .filter { reproduced[$0] != recorded[$0] }.sorted().prefix(3)
        return "rerunning the evaluators does not reproduce the recorded outcomes (e.g. \(diffs.joined(separator: ", ")))"
    }
    return nil
}
if replayOK, let rerunFailure = rerunEvaluators() {
    replayOK = false; replayDetail = rerunFailure
}
report("REPLAY", replayOK, replayDetail)

print(failed ? "\nRESULT: FAILED" : "\nRESULT: VERIFIED — \(attestation.envelope.sutraCitation) · status \(attestation.envelope.overallStatus) · signer \(attestation.envelope.signerKeyID)")
exit(failed ? 1 : 0)
