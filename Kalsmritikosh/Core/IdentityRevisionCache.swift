//
//  IdentityRevisionCache.swift
//  Kalsmritikosh
//
//  Unified path R2-E (PERF-04, owner 2026-11-22 round 2) — not tested yet. A derived-state cache keyed by WHAT was read
//  (case, scope fingerprint, revision) and WHO read it under which permissions (principal, permission epoch), plus the
//  connection epoch of a shared service. A read answers from the cache only when every part of the key still matches;
//  an edit (revision), a revocation (permission epoch), an erasure (`dropCase`) or a reconnection (`noteReconnected`)
//  invalidates only the entries it affects. Used by the simulated team service (SimulatedTeamJourneys); the case map's
//  own branch cache follows the same rule (CaseMapService, keyed by fence + principal; `noteReconnected`).
//

import Foundation

public nonisolated struct IdentityRevisionKey: Hashable, Sendable {
    public let caseID: UUID
    public let derivedKind: String
    public let scopeFingerprint: String
    public let revision: Int
    public let principal: String
    public let permissionEpoch: Int
    public let connectionEpoch: Int
    public init(caseID: UUID, derivedKind: String, scopeFingerprint: String, revision: Int, principal: String,
                permissionEpoch: Int, connectionEpoch: Int) {
        self.caseID = caseID; self.derivedKind = derivedKind; self.scopeFingerprint = scopeFingerprint; self.revision = revision
        self.principal = principal; self.permissionEpoch = permissionEpoch; self.connectionEpoch = connectionEpoch
    }
}

public actor IdentityRevisionCache<Value: Sendable> {
    private var entries: [IdentityRevisionKey: Value] = [:]
    public private(set) var hits = 0
    public private(set) var misses = 0
    /// Bumped by `noteReconnected()`; callers put it into their keys.
    public private(set) var connectionEpoch = 0

    public nonisolated init() {}

    /// The cached value for exactly this key, or a fresh one from `compute` (stored for the key).
    public func value(for key: IdentityRevisionKey, compute: @Sendable () async throws -> Value) async rethrows -> Value {
        if key.connectionEpoch == connectionEpoch, let v = entries[key] { hits += 1; return v }
        misses += 1
        let v = try await compute()
        if key.connectionEpoch == connectionEpoch { entries[key] = v }
        return v
    }

    /// An edit: entries of this case at an older revision go (other cases and derived kinds of a newer revision stay).
    public func noteRevision(_ revision: Int, caseID: UUID, derivedKinds: Set<String>? = nil) {
        entries = entries.filter { k, _ in
            !(k.caseID == caseID && k.revision < revision && (derivedKinds?.contains(k.derivedKind) ?? true))
        }
    }

    /// A revocation or role change: that principal's entries for the case go.
    public func notePermissionChange(caseID: UUID, principal: String) {
        entries = entries.filter { k, _ in !(k.caseID == caseID && k.principal == principal) }
    }

    /// An erasure: everything derived from the case goes.
    public func dropCase(_ caseID: UUID) { entries = entries.filter { $0.key.caseID != caseID } }

    /// A reconnection to the shared service: nothing read before it is trusted (remote state may have moved).
    public func noteReconnected() { connectionEpoch += 1; entries.removeAll() }

    public var count: Int { entries.count }
}
