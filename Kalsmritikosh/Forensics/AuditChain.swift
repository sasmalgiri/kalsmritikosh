//
//  AuditChain.swift
//  Kalsmritikosh
//
//  AUD-CHAIN (SAP-inspired change-document audit trail) — a tamper-EVIDENT hash
//  chain that SEALS the app's existing append-only audit ledgers
//  (custody_events + fact_reviews). It introduces NO second source of truth:
//  each seal is a hash over one already-recorded, immutable audit event.
//
//  Chain rule (identical shape to the forensic-industry / SAP change-document
//  pattern): events are ordered deterministically by (occurredAt, source,
//  eventID); each seal stores entry_hash = HMAC(payload_hash || prev_hash),
//  where prev_hash is the previous seal's entry_hash (a fixed genesis for the
//  first). Any insertion, edit, deletion or reordering of a sealed event
//  breaks the chain at that point, and `verify()` reports the first broken seq.
//
//  Sealing is append-only and idempotent (a seen event is never re-sealed);
//  it runs off the query path on a background schedule and can be triggered
//  after a recordable operation. Verification is a user-facing action
//  ("Verify integrity" in the Audit view).
//
//  Threat model (honest): the HMAC secret lives in the Keychain (see
//  AuditChainSecret), separate from the SQLite ledger, so an actor who edits
//  the database file cannot forge a valid chain without also extracting the
//  Keychain secret. When no Keychain is available (some test/headless
//  contexts) a per-database secret is used instead — that still detects
//  accidental corruption and non-malicious tampering, which is the claim the
//  UI makes.
//

import Foundation
import CryptoKit

/// One already-recorded audit event, reduced to the stable fields the chain
/// seals. Each source ledger produces these in deterministic order.
public struct AuditChainEvent: Sendable, Equatable {
    public enum Source: String, Sendable { case custody, review, governance }
    public let source: Source
    public let eventID: UUID
    public let occurredAt: Date
    /// Canonical, deterministic string of the event's immutable fields. Sorted
    /// `key=value;` pairs (never JSON — key order must be stable across runs).
    public let canonicalPayload: String

    public nonisolated init(source: Source, eventID: UUID, occurredAt: Date, canonicalPayload: String) {
        self.source = source
        self.eventID = eventID
        self.occurredAt = occurredAt
        self.canonicalPayload = canonicalPayload
    }
}

public struct AuditChainVerification: Sendable, Equatable {
    public let sealedCount: Int
    /// nil when the chain is intact end-to-end.
    public let firstBrokenSeq: Int?
    /// A sealed event that no longer exists in the source ledgers (a deletion —
    /// tamper). Reported as a break.
    public let missingEventSeq: Int?
    /// Recorded audit events not yet sealed (informational, NOT tamper — the
    /// next seal pass covers them).
    public let unsealedCount: Int
    public var isIntact: Bool { firstBrokenSeq == nil && missingEventSeq == nil }
}

public actor AuditChainService {
    public struct Row: Sendable {
        public let seq: Int
        public let source: String
        public let eventID: UUID
        public let payloadHash: String
        public let prevHash: String
        public let entryHash: String
    }

    static let genesis = "GENESIS-audit-chain-v1"
    /// Genesis of the PUBLIC (keyless SHA-256) chain — Phase D. The public
    /// chain lets an OUTSIDE verifier replay the ledger from exported event
    /// payloads to the head SIGNED in the conformance envelope; the HMAC
    /// chain remains the local tamper-evidence (its key never leaves the
    /// Keychain). Rows sealed before v114 carry no public hash — the public
    /// chain starts at the first post-v114 seal, stated on the wire.
    public static let publicGenesis = PublicAuditChain.genesis

    private static func publicSHA(_ payload: String, prev: String) -> String {
        PublicAuditChain.link(payload: payload, prev: prev)
    }

    private let database: Database
    private let secret: SymmetricKey
    /// Ordered-event providers for each source ledger (injected so the service
    /// stays free of repository-specific decode logic and is trivially testable).
    private let eventProvider: @Sendable () async -> [AuditChainEvent]

    public init(database: Database,
                secret: Data,
                eventProvider: @escaping @Sendable () async -> [AuditChainEvent]) {
        self.database = database
        self.secret = SymmetricKey(data: secret)
        self.eventProvider = eventProvider
    }

    // MARK: - HMAC

    private func hmac(_ message: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: secret)
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    private static func order(_ a: AuditChainEvent, _ b: AuditChainEvent) -> Bool {
        if a.occurredAt != b.occurredAt { return a.occurredAt < b.occurredAt }
        if a.source != b.source { return a.source.rawValue < b.source.rawValue }
        return a.eventID.uuidString < b.eventID.uuidString
    }

    // MARK: - Seal (append-only, idempotent)

    /// Append seals for every recorded audit event not yet sealed, in canonical
    /// order, continuing the existing chain. Returns the number newly sealed.
    @discardableResult
    public func seal(now: Date = Date()) async throws -> Int {
        let events = await eventProvider().sorted(by: Self.order)
        let sealedIDs = try await sealedEventKeys()
        var (lastSeq, prevHash) = try await tail()
        var publicPrev = try await publicTailHash()

        var appended = 0
        for e in events {
            let key = e.source.rawValue + ":" + e.eventID.uuidString
            if sealedIDs.contains(key) { continue }
            let payloadHash = hmac(e.canonicalPayload)
            let entryHash = hmac(payloadHash + prevHash)
            // Phase D — the parallel PUBLIC chain over the same payloads.
            let publicHash = Self.publicSHA(e.canonicalPayload, prev: publicPrev)
            let seq = lastSeq + 1
            try await database.exec("""
            INSERT INTO audit_chain (seq, source, event_id, occurred_at, payload_hash, prev_hash, entry_hash, sealed_at, public_prev, public_hash)
            VALUES (?,?,?,?,?,?,?,?,?,?);
            """, [.integer(Int64(seq)), .text(e.source.rawValue), .uuid(e.eventID),
                  .date(e.occurredAt), .text(payloadHash), .text(prevHash), .text(entryHash), .date(now),
                  .text(publicPrev), .text(publicHash)])
            lastSeq = seq
            prevHash = entryHash
            publicPrev = publicHash
            appended += 1
        }
        return appended
    }

    /// Head of the PUBLIC chain (last non-null public hash; genesis before
    /// the first post-v114 seal). This is what the conformance envelope signs.
    public func publicHead() async throws -> String {
        try await publicTailHash()
    }

    private func publicTailHash() async throws -> String {
        let rows = try await database.query(
            "SELECT public_hash FROM audit_chain WHERE public_hash IS NOT NULL ORDER BY seq DESC LIMIT 1;", [])
        return rows.first?.string(0) ?? Self.publicGenesis
    }

    /// The exportable public trail (Phase D): every sealed event that carries
    /// a public hash, with its canonical payload — METADATA ONLY, never
    /// document content. An outside verifier folds SHA-256 over these to the
    /// signed head. Rows sealed pre-v114 are not exportable (no public link).
    public func publicTrail() async throws -> [AuditTrailEntry] {
        let rows = try await database.query("""
        SELECT seq, source, event_id, occurred_at, public_prev, public_hash
        FROM audit_chain WHERE public_hash IS NOT NULL ORDER BY seq ASC;
        """, [])
        var payloadByKey: [String: String] = [:]
        for e in await eventProvider() {
            payloadByKey[e.source.rawValue + ":" + e.eventID.uuidString] = e.canonicalPayload
        }
        return rows.compactMap { r in
            guard let seq = r.int(0), let source = r.string(1), let id = r.uuid(2),
                  let at = r.date(3), let prev = r.string(4), let hash = r.string(5),
                  let payload = payloadByKey[source + ":" + id.uuidString] else { return nil }
            return AuditTrailEntry(seq: Int(seq), source: source, eventID: id, occurredAt: at,
                                   canonicalPayload: payload, publicPrev: prev, publicHash: hash)
        }
    }

    // MARK: - Verify

    /// Recompute the chain over the sealed events (re-deriving each payload hash
    /// from the CURRENT source ledgers) and confirm every link. Reports the
    /// first broken seq, any deleted sealed event, and the count of recorded
    /// events not yet sealed.
    public func verify() async throws -> AuditChainVerification {
        let rows = try await allSeals()
        // Current source events, keyed for re-derivation.
        var payloadByKey: [String: String] = [:]
        for e in await eventProvider() {
            payloadByKey[e.source.rawValue + ":" + e.eventID.uuidString] = e.canonicalPayload
        }

        var prev = Self.genesis
        for row in rows {
            let key = row.source + ":" + row.eventID.uuidString
            guard let payload = payloadByKey[key] else {
                return AuditChainVerification(sealedCount: rows.count, firstBrokenSeq: nil,
                                              missingEventSeq: row.seq, unsealedCount: 0)
            }
            let expectedPayloadHash = hmac(payload)
            let expectedEntryHash = hmac(row.payloadHash + prev)
            if row.payloadHash != expectedPayloadHash || row.prevHash != prev || row.entryHash != expectedEntryHash {
                return AuditChainVerification(sealedCount: rows.count, firstBrokenSeq: row.seq,
                                              missingEventSeq: nil, unsealedCount: 0)
            }
            prev = row.entryHash
        }

        let sealedKeys = Set(rows.map { $0.source + ":" + $0.eventID.uuidString })
        let unsealed = payloadByKey.keys.filter { !sealedKeys.contains($0) }.count
        return AuditChainVerification(sealedCount: rows.count, firstBrokenSeq: nil,
                                      missingEventSeq: nil, unsealedCount: unsealed)
    }

    public func sealedCount() async throws -> Int {
        let rows = try await database.query("SELECT COUNT(*) FROM audit_chain;", [])
        return Int(rows.first?.int(0) ?? 0)
    }

    /// The chain's current head — the last sealed entry hash and its sequence.
    /// This is what a conformance seal binds to (roadmap 1.0.x-B): the signed
    /// certificate then attests over a specific, tamper-evident ledger state.
    /// Returns (0, genesis) before anything is sealed.
    public func head() async throws -> (sealedSeq: Int, hash: String) {
        let t = try await tail()
        return (t.seq, t.hash)
    }

    // MARK: - Reads

    private func tail() async throws -> (seq: Int, hash: String) {
        let rows = try await database.query(
            "SELECT seq, entry_hash FROM audit_chain ORDER BY seq DESC LIMIT 1;", [])
        guard let r = rows.first, let seq = r.int(0), let hash = r.string(1) else {
            return (0, Self.genesis)
        }
        return (Int(seq), hash)
    }

    private func sealedEventKeys() async throws -> Set<String> {
        let rows = try await database.query("SELECT source, event_id FROM audit_chain;", [])
        var out = Set<String>()
        for r in rows {
            if let s = r.string(0), let id = r.uuid(1) { out.insert(s + ":" + id.uuidString) }
        }
        return out
    }

    private func allSeals() async throws -> [Row] {
        let rows = try await database.query("""
        SELECT seq, source, event_id, payload_hash, prev_hash, entry_hash
        FROM audit_chain ORDER BY seq;
        """, [])
        return rows.compactMap { r in
            guard let seq = r.int(0), let source = r.string(1), let id = r.uuid(2),
                  let ph = r.string(3), let prev = r.string(4), let eh = r.string(5) else { return nil }
            return Row(seq: Int(seq), source: source, eventID: id,
                       payloadHash: ph, prevHash: prev, entryHash: eh)
        }
    }
}
