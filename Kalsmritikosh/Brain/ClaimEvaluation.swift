//
//  ClaimEvaluation.swift
//  Kalsmritikosh
//
//  S0.5 item 2, Commit C2 (decision wiring). ONE immutable envelope for a ledger claim's
//  assertability decision, produced ONCE at retrieval and carried unchanged through the
//  expert/brain layer to the export validator. Because every stage reads (or re-derives
//  and compares) this same envelope, retrieval / MasterBrain / validator can never
//  disagree about whether — and how — a claim may be surfaced.
//
//  `claimID` is the ORIGINAL ledger identity (a GenericFact's id), never a fresh UUID, so
//  the same claim is traceable across stages. Deterministic; LLM-free.
//

import Foundation
import CryptoKit

/// The kind of ledger claim an evaluation describes (extensible as more canonical
/// assessment paths appear; today only GenericFact flows through this envelope).
public enum ClaimKind: String, Codable, Sendable, Hashable {
    case genericFact
}

/// How a surfaced claim MUST be framed — one-to-one from the policy decision. `refuse`
/// has no presentation (the claim must not surface at all), so this is a failable mapping.
public enum ClaimPresentation: String, Codable, Sendable, Hashable {
    case fact
    case attributed
    case corroborated
    case derivation
    case userAttributed
    case inference
    case conflict

    /// The REQUIRED presentation for a decision. Nil for `refuse` (do not surface).
    /// A caller may never choose a stronger presentation than this mapping permits.
    public nonisolated init?(decision: AssertabilityDecision) {
        switch decision {
        case .assertAsFact:            self = .fact
        case .assertWithAttribution:   self = .attributed
        case .assertAsCorroborated:    self = .corroborated
        case .assertAsDerivation:      self = .derivation
        case .assertWithUserAttribution: self = .userAttributed
        case .presentAsInference:      self = .inference
        case .presentAsConflict:       self = .conflict
        case .refuse:                  return nil
        }
    }
}

public struct ClaimEvaluation: Codable, Sendable, Hashable, Identifiable {
    /// The ORIGINAL ledger claim id (e.g. GenericFact.id) — never regenerated.
    public let id: UUID
    public let claimKind: ClaimKind
    public let assessment: EvidenceAssessment
    public let evidence: [AssertabilityEvidence]
    public let context: AssertabilityContext
    public let decision: AssertabilityDecision
    /// Required presentation; nil iff the decision is `refuse`.
    public let presentation: ClaimPresentation?
    /// Stable fingerprint of the normalized evidence — lets a later stage detect tampering
    /// without re-deriving the whole context. Deterministic (sorted), process-independent.
    public let evidenceFingerprint: String

    public nonisolated init(
        id: UUID, claimKind: ClaimKind, assessment: EvidenceAssessment,
        evidence: [AssertabilityEvidence], context: AssertabilityContext, decision: AssertabilityDecision
    ) {
        self.id = id
        self.claimKind = claimKind
        self.assessment = assessment
        self.evidence = evidence
        self.context = context
        self.decision = decision
        self.presentation = ClaimPresentation(decision: decision)
        self.evidenceFingerprint = Self.fingerprint(evidence)
    }

    /// May this claim surface at all? (Everything except a `refuse` decision.)
    public var maySurface: Bool { decision.maySurface }

    /// Deterministic, order-independent fingerprint of normalized evidence — a SHA-256 over
    /// a canonical, length-prefixed encoding. Length prefixes + an explicit nil marker make
    /// it unambiguous: nil ≠ literal "-", keys containing `|`/`;` can't collide, reordering
    /// is normalized by sorting, and duplicates are preserved as distinct items.
    private static let fingerprintVersion: UInt8 = 1

    public nonisolated static func fingerprint(_ evidence: [AssertabilityEvidence]) -> String {
        // Encode each field length-prefixed with an explicit nil marker (nil ≠ any string,
        // delimiter-safe).
        func field(_ s: String?) -> Data {
            var d = Data()
            guard let s else { d.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF]); return d }   // nil marker
            let b = Data(s.utf8)
            withUnsafeBytes(of: UInt32(b.count).bigEndian) { d.append(contentsOf: $0) }
            d.append(b)
            return d
        }
        // Encode each item to canonical bytes, then sort the BYTE SEQUENCES lexicographically
        // — no sentinel-string ordering, so a real key can never compare equal to a nil marker.
        // Duplicates are preserved (kept as separate items).
        let encodedItems: [[UInt8]] = evidence.map { e in
            var d = Data()
            d.append(field(e.objectID.uuidString))
            d.append(field(e.blockID?.uuidString))
            d.append(field(e.independenceKey))
            return Array(d)
        }.sorted { lhs, rhs in
            for i in 0..<min(lhs.count, rhs.count) where lhs[i] != rhs[i] { return lhs[i] < rhs[i] }
            return lhs.count < rhs.count
        }
        var data = Data([fingerprintVersion])
        withUnsafeBytes(of: UInt32(encodedItems.count).bigEndian) { data.append(contentsOf: $0) }
        for item in encodedItems {
            withUnsafeBytes(of: UInt32(item.count).bigEndian) { data.append(contentsOf: $0) }   // item length
            data.append(contentsOf: item)
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
