//
//  Contradiction.swift
//  Kalsmritikosh
//
//  System 3 — a persisted CONFLICT between two claims that the ledger
//  supports simultaneously (schema v31 `contradictions`). Per the
//  evidence-gate contract, conflicting evidence is NEVER averaged away —
//  it is surfaced to the user as a conflict with BOTH sources shown. This
//  model is the ledger's memory of such a conflict so it accumulates
//  instead of being recomputed per query.
//
//  A contradiction is not a factual claim about the world; it is a claim
//  about the ARCHIVE ("two ingested sources disagree"). It always carries
//  both claims and, where known, the evidence object behind each.
//

import Foundation
import CryptoKit

public nonisolated struct Contradiction: Identifiable, Sendable, Hashable, Codable {
    public typealias ID = UUID

    /// How much the conflict matters. Derived from the size of the
    /// disagreement + how confident each side is.
    public enum Severity: String, Sendable, CaseIterable, Codable {
        case low
        case medium
        case high

        public var displayName: String {
            switch self {
            case .low:    return "Low"
            case .medium: return "Medium"
            case .high:   return "High"
            }
        }
    }

    /// Lifecycle of a surfaced conflict.
    public enum Status: String, Sendable, CaseIterable, Codable {
        /// Unresolved — still shown to the user.
        case open
        /// The user (or a later ingest) settled which side is right.
        case resolved
        /// The user judged it a non-issue.
        case dismissed
    }

    /// P5.5 — the KIND of disagreement, so the UI and evidence-ranking can
    /// treat a payment conflict differently from a date conflict. Detection
    /// for the non-date kinds lands incrementally; the vocabulary + persistence
    /// exist now so detectors can tag as they come online.
    public enum Kind: String, Sendable, CaseIterable, Codable {
        case date
        case amount
        case identity
        case location
        case status
        case eventOccurrence
        case sequence
        case documentVersion
        case testimony
        case sentReceived
        case payment
        case signature
        case causation
        case other

        public var displayName: String {
            switch self {
            case .date: return "Date"
            case .amount: return "Amount"
            case .identity: return "Identity"
            case .location: return "Location"
            case .status: return "Status"
            case .eventOccurrence: return "Event occurrence"
            case .sequence: return "Sequence"
            case .documentVersion: return "Document version"
            case .testimony: return "Testimony"
            case .sentReceived: return "Sent/received"
            case .payment: return "Payment"
            case .signature: return "Signature"
            case .causation: return "Causation"
            case .other: return "Other"
            }
        }
    }

    public let id: ID
    /// The kind of disagreement (P5.5). Defaults to `.other` for rows/payloads
    /// written before the taxonomy existed.
    public let kind: Kind
    /// One-line human summary ("Conflicting dates for \"Kickoff call\"").
    public let description: String
    /// The two mutually-incompatible claims, verbatim.
    public let claimA: String
    public let claimB: String
    /// The KnowledgeObject each claim came from, when known.
    public let evidenceA: KnowledgeObject.ID?
    public let evidenceB: KnowledgeObject.ID?
    public let severity: Severity
    public let status: Status
    public let detectedAt: Date

    public nonisolated init(
        id: ID = UUID(),
        kind: Kind = .other,
        description: String,
        claimA: String,
        claimB: String,
        evidenceA: KnowledgeObject.ID? = nil,
        evidenceB: KnowledgeObject.ID? = nil,
        severity: Severity = .medium,
        status: Status = .open,
        detectedAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.description = description
        self.claimA = claimA
        self.claimB = claimB
        self.evidenceA = evidenceA
        self.evidenceB = evidenceB
        self.severity = severity
        self.status = status
        self.detectedAt = detectedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, description, claimA, claimB, evidenceA, evidenceB, severity, status, detectedAt
    }

    public nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(ID.self, forKey: .id)
        self.kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .other
        self.description = try c.decode(String.self, forKey: .description)
        self.claimA = try c.decode(String.self, forKey: .claimA)
        self.claimB = try c.decode(String.self, forKey: .claimB)
        self.evidenceA = try c.decodeIfPresent(KnowledgeObject.ID.self, forKey: .evidenceA)
        self.evidenceB = try c.decodeIfPresent(KnowledgeObject.ID.self, forKey: .evidenceB)
        self.severity = try c.decode(Severity.self, forKey: .severity)
        self.status = try c.decode(Status.self, forKey: .status)
        self.detectedAt = try c.decode(Date.self, forKey: .detectedAt)
    }
}

extension Contradiction {
    /// The same contradiction keeps the same id across archive rescans. A rescan clears its own rows and inserts
    /// what it finds again; with a random id every decision recorded against an item (confirm, dismiss, defer),
    /// its map item and its change-feed identity were orphaned on the next scan (UI walk 2026-11-07: decisions
    /// recorded, items shown as "Not reviewed yet" after relaunch). The identity is the kind, the description and
    /// the two documents — not the claim text, so a revised document reopens the decision through its source
    /// version instead of silently becoming a new item. Same-identity findings get a deterministic ordinal.
    nonisolated static func stableIdentities(_ found: [Contradiction]) -> [Contradiction] {
        func key(_ c: Contradiction) -> String {
            let docs = [c.evidenceA?.uuidString ?? "-", c.evidenceB?.uuidString ?? "-"].sorted().joined(separator: "|")
            return "archive-scan|\(c.kind.rawValue)|\(c.description)|\(docs)"
        }
        var groups: [String: [Contradiction]] = [:]
        for c in found { groups[key(c), default: []].append(c) }
        var out: [Contradiction] = []
        out.reserveCapacity(found.count)
        for (k, members) in groups.sorted(by: { $0.key < $1.key }) {
            let ordered = members.sorted { ($0.claimA, $0.claimB) < ($1.claimA, $1.claimB) }
            for (n, c) in ordered.enumerated() {
                let digest = Array(SHA256.hash(data: Data("\(k)|\(n)".utf8)))
                var b = Array(digest.prefix(16))
                b[6] = (b[6] & 0x0F) | 0x50   // RFC 4122 name-based layout (version 5 style)
                b[8] = (b[8] & 0x3F) | 0x80
                let id = UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
                out.append(Contradiction(id: id, kind: c.kind, description: c.description, claimA: c.claimA, claimB: c.claimB,
                                         evidenceA: c.evidenceA, evidenceB: c.evidenceB, severity: c.severity,
                                         status: c.status, detectedAt: c.detectedAt))
            }
        }
        return out
    }
}
