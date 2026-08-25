//
//  ConformanceBundle.swift
//  Kalsmritikosh
//
//  Conformance roadmap 1.0.x-C — the verifiable bundle. A recorded, SEALED
//  assessment exports as a plain folder of canonical files that anyone can
//  verify OUTSIDE this app (spec: docs/verification/BUNDLE_FORMAT.md; a
//  standalone CLI lives at verifier/kalverify.swift). Three separated verdicts,
//  never blended:
//
//   • INTEGRITY     — every file matches the manifest's SHA-256 (detects edits
//                     and missing/renamed files; proves nothing about origin).
//   • AUTHENTICITY  — the ECDSA P-256 signature over the canonical envelope
//                     verifies with the embedded public key, and the envelope's
//                     hashes match the actual protocol + evaluations bytes
//                     (a recomputed-hash forgery fails here).
//   • REPLAY        — the fail-closed rollup recomputed from the evaluations
//                     equals the sealed status, and the evaluations correspond
//                     one-to-one with the rules compiled from the protocol.
//
//  Files are written as their EXACT canonical encodings (sorted keys, ISO-8601
//  dates), so a verifier hashes raw bytes — no re-encoding ambiguity.
//

import Foundation
import CryptoKit

public nonisolated enum ConformanceBundleError: Error, Equatable {
    case notSealed            // only sealed assessments export — nothing to verify otherwise
    case encodingFailed
}

/// The three separated verdicts. `notChecked` means an earlier layer failed so
/// this one never ran (integrity gates authenticity gates replay).
public nonisolated struct BundleVerdict: Sendable, Equatable {
    public enum State: String, Sendable { case passed, failed, notChecked }
    public var integrity: State = .notChecked
    public var authenticity: State = .notChecked
    public var conformanceReplay: State = .notChecked
    /// Human-readable findings, one line per check that failed (empty = clean).
    public var details: [String] = []
    public var allPassed: Bool {
        integrity == .passed && authenticity == .passed && conformanceReplay == .passed
    }
}

public nonisolated enum ConformanceBundle {

    public static let formatVersion = 1
    static let attestationFile = "attestation.json"
    static let protocolFile = "protocol.json"
    static let evaluationsFile = "rule-evaluations.json"
    static let publicKeyFile = "public-key.hex"
    static let manifestFile = "manifest.json"
    static let readmeFile = "README.txt"

    /// The manifest: format version + SHA-256 of every other file in the bundle.
    struct Manifest: Codable, Equatable {
        let formatVersion: Int
        let files: [String: String]
    }

    // MARK: - Write

    /// Export a sealed assessment as a verification bundle folder. Refuses an
    /// unsealed record — there is nothing for an outsider to verify.
    public static func write(stored: StoredConformanceAssessment, to directory: URL) throws {
        guard let seal = stored.seal else { throw ConformanceBundleError.notSealed }
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        let protocolData = Data(stored.assessment.sutraSnapshotJSON.utf8)
        let evaluationsData = try ConformanceCanonical.data(of: stored.assessment.evaluations)
        let attestationData = try ConformanceCanonical.data(of: seal)
        let publicKeyData = Data(seal.publicKeyHex.utf8)

        let payload: [(String, Data)] = [
            (protocolFile, protocolData),
            (evaluationsFile, evaluationsData),
            (attestationFile, attestationData),
            (publicKeyFile, publicKeyData),
        ]
        for (name, data) in payload {
            try data.write(to: directory.appendingPathComponent(name), options: .atomic)
        }
        let manifest = Manifest(formatVersion: Self.formatVersion,
                                files: Dictionary(uniqueKeysWithValues: payload.map { ($0.0, sha256($0.1)) }))
        try ConformanceCanonical.data(of: manifest)
            .write(to: directory.appendingPathComponent(manifestFile), options: .atomic)
        let readme = """
        Kalsmritikosh conformance verification bundle (format v\(Self.formatVersion))

        Constitution: \(stored.assessment.sutraCitation)
        Status: \(stored.assessment.status.rawValue) · revision \(stored.runRevision)

        Verify independently — spec: docs/verification/BUNDLE_FORMAT.md in the
        kalsmritikosh repository; CLI: `swift verifier/kalverify.swift <this folder>`.
        Three separated verdicts: integrity (manifest hashes), authenticity
        (ECDSA P-256 signature over the canonical attestation envelope), and
        conformance replay (fail-closed rollup of the rule evaluations).
        This bundle contains no source documents — only rule outcomes and hashes.
        """
        try Data(readme.utf8).write(to: directory.appendingPathComponent(readmeFile), options: .atomic)
    }

    // MARK: - Verify (the same checks the standalone CLI performs, plus the
    // in-app-only protocol recompile check)

    public static func verify(at directory: URL) -> BundleVerdict {
        var verdict = BundleVerdict()
        let fm = FileManager.default
        func read(_ name: String) -> Data? {
            try? Data(contentsOf: directory.appendingPathComponent(name))
        }

        // 1 — INTEGRITY: every manifest entry present with a matching hash.
        guard let manifestData = read(manifestFile),
              let manifest = try? decoder().decode(Manifest.self, from: manifestData) else {
            verdict.integrity = .failed
            verdict.details.append("integrity: manifest.json missing or unreadable")
            return verdict
        }
        if manifest.formatVersion != Self.formatVersion {
            verdict.details.append("integrity: unknown format version \(manifest.formatVersion)")
        }
        var integrityOK = true
        for (name, expected) in manifest.files {
            guard let data = read(name) else {
                integrityOK = false; verdict.details.append("integrity: \(name) missing"); continue
            }
            if sha256(data) != expected {
                integrityOK = false; verdict.details.append("integrity: \(name) does not match its manifest hash")
            }
        }
        verdict.integrity = integrityOK ? .passed : .failed
        guard integrityOK else { return verdict }

        // 2 — AUTHENTICITY: signature over the canonical envelope + hash linkage.
        guard let attestationData = read(attestationFile),
              let sealed = try? decoder().decode(SealedConformance.self, from: attestationData),
              let protocolData = read(protocolFile),
              let evaluationsData = read(evaluationsFile) else {
            verdict.authenticity = .failed
            verdict.details.append("authenticity: attestation/protocol/evaluations unreadable")
            return verdict
        }
        var authenticityOK = true
        if !ConformanceSeal.verify(sealed) {
            authenticityOK = false
            verdict.details.append("authenticity: signature does not verify against the embedded public key")
        }
        if sealed.envelope.sutraSHA256 != sha256(protocolData) {
            authenticityOK = false
            verdict.details.append("authenticity: protocol.json does not match the signed constitution hash")
        }
        if sealed.envelope.ruleEvaluationsSHA256 != sha256(evaluationsData) {
            authenticityOK = false
            verdict.details.append("authenticity: rule-evaluations.json does not match the signed evaluations hash")
        }
        verdict.authenticity = authenticityOK ? .passed : .failed
        guard authenticityOK else { return verdict }

        // 3 — CONFORMANCE REPLAY: recompute the fail-closed rollup and the
        // rule correspondence against the protocol.
        guard let evaluations = try? decoder().decode([RuleEvaluation].self, from: evaluationsData),
              let sutra = try? decoder().decode(Sutra.self, from: protocolData) else {
            verdict.conformanceReplay = .failed
            verdict.details.append("replay: evaluations or protocol failed to decode")
            return verdict
        }
        var replayOK = true
        let mandatory = evaluations.filter { $0.rule.severity == .mandatory }
        let recomputed: ConformanceStatus =
            mandatory.contains { $0.outcome == .failed } ? .notConformant
            : mandatory.contains { $0.outcome == .notEvaluated || $0.outcome == .evaluatorError } ? .indeterminate
            : .conformant
        if recomputed.rawValue != sealed.envelope.overallStatus {
            replayOK = false
            verdict.details.append("replay: recomputed status '\(recomputed.rawValue)' ≠ sealed status '\(sealed.envelope.overallStatus)'")
        }
        if evaluations.count != sealed.envelope.ruleCount {
            replayOK = false
            verdict.details.append("replay: \(evaluations.count) evaluation(s) ≠ sealed ruleCount \(sealed.envelope.ruleCount)")
        }
        // Exactly one evaluation per rule the protocol compiles to — no silently
        // dropped or invented rules.
        let compiledIDs = Set(SutraRuleCompiler.rules(for: sutra).map(\.id))
        let evaluatedIDs = evaluations.map(\.id)
        if Set(evaluatedIDs).count != evaluatedIDs.count {
            replayOK = false; verdict.details.append("replay: duplicate rule evaluations")
        }
        if compiledIDs != Set(evaluatedIDs) {
            replayOK = false
            verdict.details.append("replay: evaluations do not correspond one-to-one with the protocol's compiled rules")
        }
        verdict.conformanceReplay = replayOK ? .passed : .failed
        return verdict
    }

    // MARK: - Helpers

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
