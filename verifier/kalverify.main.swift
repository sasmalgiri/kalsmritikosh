// ============================================================================
// Verifier main — the CLI-only tail appended after the shared core by
// scripts/generate-kalverify.sh. Everything conformance-semantic above this
// line IS the app's own source: Sutra, SutraRuleCompiler, SutraConformance,
// ConformanceFacts, ConformanceStatus.rollup, ConformanceRunBinding,
// ConformanceCanonical, ConformanceSealEnvelope. This tail only does file IO,
// hashing, signature checks and printing.
//
// Three separated verdicts, each on its own line:
//   INTEGRITY     — every file matches manifest.json's SHA-256.
//   AUTHENTICITY  — the ECDSA P-256 signature over the canonical envelope
//                   verifies with the embedded key, and the envelope's hashes
//                   match the actual protocol/evaluations/facts bytes.
//   REPLAY        — the rules are RECOMPILED from the signed protocol with the
//                   app's own compiler, every evaluator is RERUN over the
//                   recorded facts with the app's own evaluator, the rollup is
//                   recomputed with the app's own rollup, and the run binding
//                   is recomputed from the signed facts.
//
// Exit code 0 = all three passed; 1 = any failed or unreadable.
// ============================================================================

func sha256Hex(_ data: Data) -> String {
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

func jsonDecoder() -> JSONDecoder {
    let d = JSONDecoder()
    d.dateDecodingStrategy = .iso8601
    return d
}

struct VerifierManifest: Codable {
    let formatVersion: Int
    let files: [String: String]
}

// MARK: - Main

// --studio <file.md>: verify a SEALED studio deliverable (Phase D) with the
// app's own StudioDeliverableVerifier — content hash + P-256 signature.
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--studio" {
    guard let markdown = try? String(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]), encoding: .utf8) else {
        print("STUDIO: FAILED — file unreadable"); exit(1)
    }
    let v = StudioDeliverableVerifier.verify(markdown: markdown)
    print("CONTENT: \(v.contentIntact ? "PASSED — matches the sealed content hash" : "FAILED")")
    print("SIGNATURE: \(v.signatureValid ? "PASSED — ECDSA P-256 over the canonical envelope" : "FAILED")")
    if let e = v.envelope {
        print("Deliverable: \(e.studio) · \(e.deliverableTitle) · stages \(e.stagesComplete)/\(e.stagesTotal)\(e.allStagesComplete ? "" : " — INCOMPLETE, stated honestly") · signer \(e.signerKeyID)")
    }
    print(v.verified ? "\nRESULT: VERIFIED" : "\nRESULT: FAILED")
    exit(v.verified ? 0 : 1)
}

guard CommandLine.arguments.count == 2 || CommandLine.arguments.count == 3 else {
    print("usage: swift kalverify.swift <bundle-folder> [trusted-signer-key-id]")
    print("       swift kalverify.swift --studio <sealed-deliverable.md>")
    print("Without a trusted key ID, AUTHENTICITY proves key-consistency only —")
    print("the signature matches the key EMBEDDED in the bundle. Supply the")
    print("signer's known key ID (16 hex chars) to bind the seal to an identity.")
    exit(1)
}
let bundleDir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let trustedKeyID: String? = CommandLine.arguments.count == 3
    ? CommandLine.arguments[2].lowercased() : nil
func read(_ name: String) -> Data? { try? Data(contentsOf: bundleDir.appendingPathComponent(name)) }

var anyFailed = false
func report(_ name: String, _ ok: Bool, _ detail: String = "") {
    print("\(name): \(ok ? "PASSED" : "FAILED")\(detail.isEmpty ? "" : " — \(detail)")")
    if !ok { anyFailed = true }
}

// 1 — INTEGRITY
guard let manifestData = read("manifest.json"),
      let manifest = try? jsonDecoder().decode(VerifierManifest.self, from: manifestData) else {
    report("INTEGRITY", false, "manifest.json missing or unreadable"); exit(1)
}
var integrityOK = true
var integrityDetail = ""
// EIGHTH AUDIT — hard failures, not gaps: an unknown format version is
// refused, and the manifest must cover the MANDATORY file set so a rewritten
// `{"files":{}}` manifest cannot pass integrity vacuously.
if manifest.formatVersion != 1 {
    integrityOK = false; integrityDetail = "unknown format version \(manifest.formatVersion) — refused"
}
for required in ["attestation.json", "protocol.json", "rule-evaluations.json",
                 "evaluation-facts.json", "public-key.hex"]
where integrityOK && manifest.files[required] == nil {
    integrityOK = false; integrityDetail = "manifest does not cover mandatory file \(required)"
}
if integrityOK {
    for (name, expected) in manifest.files {
        guard let data = read(name) else { integrityOK = false; integrityDetail = "\(name) missing"; break }
        if sha256Hex(data) != expected { integrityOK = false; integrityDetail = "\(name) hash mismatch"; break }
    }
}
report("INTEGRITY", integrityOK, integrityDetail)
guard integrityOK else { exit(1) }

// 2 — AUTHENTICITY
guard let attestationData = read("attestation.json"),
      let attestation = try? jsonDecoder().decode(SealedConformance.self, from: attestationData),
      let protocolData = read("protocol.json"),
      let evaluationsData = read("rule-evaluations.json") else {
    report("AUTHENTICITY", false, "attestation/protocol/evaluations unreadable"); exit(1)
}
var authOK = true
var authDetail = ""
if attestation.envelope.sutraSHA256 != sha256Hex(protocolData) {
    authOK = false; authDetail = "protocol.json ≠ signed constitution hash"
}
if authOK, attestation.envelope.ruleEvaluationsSHA256 != sha256Hex(evaluationsData) {
    authOK = false; authDetail = "rule-evaluations.json ≠ signed evaluations hash"
}
if authOK {
    // Canonical bytes come from the SHARED ConformanceCanonical + the SHARED
    // envelope struct — byte-identical to what the app signed, by construction.
    if let canonicalEnvelope = try? ConformanceCanonical.data(of: attestation.envelope),
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

// 3 — CONFORMANCE REPLAY (the app's own compiler + evaluator + rollup)
guard let recorded = try? jsonDecoder().decode([RuleEvaluation].self, from: evaluationsData) else {
    report("REPLAY", false, "rule-evaluations.json failed to decode"); exit(1)
}
var replayOK = true
var replayDetail = ""
// Rollup recomputed with the ONE shared computation.
let recomputedStatus = ConformanceStatus.rollup(of: recorded)
if recomputedStatus.rawValue != attestation.envelope.overallStatus {
    replayOK = false
    replayDetail = "recomputed '\(recomputedStatus.rawValue)' ≠ sealed '\(attestation.envelope.overallStatus)'"
}
if replayOK, recorded.count != attestation.envelope.ruleCount {
    replayOK = false; replayDetail = "\(recorded.count) evaluation(s) ≠ sealed ruleCount \(attestation.envelope.ruleCount)"
}
if replayOK, Set(recorded.map(\.rule.id)).count != recorded.count {
    replayOK = false; replayDetail = "duplicate rule evaluations"
}

func rerunEvaluators() -> String? {
    // The protocol snapshot IS the canonical Sutra JSON — decode it with the
    // app's own type and recompile with the app's own compiler. Every rule
    // field (severity, waivability, applicability, evidence requirements,
    // human role, authority references, evaluator version) participates in
    // the comparison because it is the SAME Equatable type.
    guard let sutra = try? jsonDecoder().decode(Sutra.self, from: protocolData) else {
        return "protocol.json does not decode as a constitution"
    }
    let compiled = SutraRuleCompiler.rules(for: sutra)
    guard !compiled.isEmpty else {
        return "the protocol compiles to zero rules — vacuous conformance is refused"
    }
    if Set(compiled) != Set(recorded.map(\.rule)) {
        return "recorded rule definitions do not match the signed protocol's compiled rules (every field compared)"
    }
    guard let factsData = read("evaluation-facts.json") else {
        // Downgrade-proof: when the SIGNED envelope commits to a facts hash,
        // the facts file is REQUIRED — deleting it fails replay.
        if attestation.envelope.factsSHA256 != nil {
            return "signed envelope commits to facts but evaluation-facts.json is missing — downgrade refused"
        }
        print("REPLAY note: legacy bundle without signed facts — outcome-consistency only")
        return nil
    }
    if let signedSHA = attestation.envelope.factsSHA256, sha256Hex(factsData) != signedSHA {
        return "evaluation-facts.json does not match the SIGNED facts hash"
    }
    if let signedManifestSHA = attestation.envelope.evidenceManifestSHA256 {
        guard let manifestData = read("evidence-manifest.json") else {
            return "signed envelope commits to an evidence manifest but evidence-manifest.json is missing"
        }
        if sha256Hex(manifestData) != signedManifestSHA {
            return "evidence-manifest.json does not match the SIGNED manifest hash"
        }
    }
    guard let facts = try? jsonDecoder().decode(ConformanceFacts.self, from: factsData) else {
        return "evaluation-facts.json failed to decode"
    }
    // RUN BINDING RECOMPUTED: the signed facts carry the binding components;
    // with the envelope's runID they must hash to the SIGNED runStateSHA256 —
    // same struct, same canonicalization as the app.
    if let signedBinding = attestation.envelope.runStateSHA256 {
        if let runIDString = attestation.envelope.runID, let runID = UUID(uuidString: runIDString),
           let seal = facts.runReceiptSeal, let revision = facts.runCaseRevision {
            let recomputedBinding = try? ConformanceCanonical.sha256(
                of: ConformanceRunBinding(runID: runID, receiptSeal: seal, caseRevision: revision))
            if recomputedBinding != signedBinding {
                return "recomputed run binding does not match the SIGNED runStateSHA256"
            }
            print("REPLAY note: run binding RECOMPUTED from signed facts — matches the sealed runStateSHA256")
        } else {
            // EIGHTH AUDIT — a signed run binding whose components are absent
            // from the facts FAILS: current-format bundles always carry them.
            return "the envelope signs runStateSHA256 but the facts carry no binding components — unverifiable binding refused"
        }
    }
    // PUBLIC AUDIT CHAIN (Phase D): when the signed envelope commits to a
    // non-genesis public head, the exported trail is REQUIRED and must fold —
    // with the app's own PublicAuditChain rule-v2 computation (each link binds
    // seq/source/eventID/occurredAt/payload) — exactly to that head. A signed
    // GENESIS head (fresh ledger) is valid with no trail.
    if let signedHead = attestation.envelope.publicAuditChainHead {
        if signedHead == PublicAuditChain.genesis {
            if let trailData = read("audit-events.json"),
               let trail = try? jsonDecoder().decode([AuditTrailEntry].self, from: trailData),
               !trail.isEmpty {
                return "the signed public head is genesis but the bundle ships a non-empty trail"
            }
            print("REPLAY note: public head is the chain genesis (fresh ledger) — no trail required")
        } else {
            guard let trailData = read("audit-events.json"),
                  let trail = try? jsonDecoder().decode([AuditTrailEntry].self, from: trailData) else {
                return "signed envelope commits to a public audit-chain head but audit-events.json is missing or unreadable — downgrade refused"
            }
            if let failure = PublicAuditChain.replay(trail, expectedHead: signedHead) {
                return failure
            }
            print("REPLAY note: public audit chain REPLAYED over \(trail.count) exported event(s) — matches the SIGNED head")
        }
    }
    // RERUN with the app's own assess(): every evaluator, every gate, the
    // same code — outcome, evaluator ID and detail must all reproduce.
    let reproduced = SutraConformance.assess(
        facts: facts, against: sutra, at: attestation.envelope.assessedAt).evaluations
    if reproduced != recorded {
        let recordedByID = Dictionary(uniqueKeysWithValues: recorded.map { ($0.rule.id, $0) })
        let diffs = reproduced.filter { recordedByID[$0.rule.id] != $0 }
            .map { $0.rule.id }.sorted().prefix(3)
        return "rerunning the app's evaluators does not reproduce the recorded evaluations (e.g. \(diffs.joined(separator: ", ")))"
    }
    return nil
}
if replayOK, let rerunFailure = rerunEvaluators() {
    replayOK = false; replayDetail = rerunFailure
}
report("REPLAY", replayOK, replayDetail)

print(anyFailed ? "\nRESULT: FAILED" : "\nRESULT: VERIFIED — \(attestation.envelope.sutraCitation) · status \(attestation.envelope.overallStatus) · signer \(attestation.envelope.signerKeyID)")
exit(anyFailed ? 1 : 0)
