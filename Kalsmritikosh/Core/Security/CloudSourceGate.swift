//
//  CloudSourceGate.swift
//  Kalsmritikosh
//
//  Final completion instructions K1 — before any document-derived text becomes part of a prompt that
//  may leave the Mac, each source document is checked for that purpose: its own protection label
//  (sensitivity and privilege, through the lineage-aware resolver) and the legacy privileged flag.
//  Privileged material never goes; nothing above "confidential" goes (restricted material never leaves
//  the Mac, whatever the local scope permits); a document whose label cannot be resolved is denied.
//
//  The result is a `CloudSourceClearance`: the documents the caller may build its prompt from. The
//  Online provider refuses a document-bearing request that carries no clearance, so a route that does
//  not run this gate fails closed instead of sending.
//

import Foundation

/// B4 — where a document-bearing request is allowed to draw from: one case (or workspace) and the
/// exact source versions each document had when the request was built. `current` re-resolves the
/// scope NOW: the documents the case may use and the authorised versions of each. A document that left the case
/// (even if another case still holds it), a new version, or an erased case stops the send.
public nonisolated struct CloudScopeBinding: Sendable {
    public let scopeID: UUID
    public let current: @Sendable () async throws -> [UUID: Set<UUID>]
    public init(scopeID: UUID, current: @escaping @Sendable () async throws -> [UUID: Set<UUID>]) {
        self.scopeID = scopeID; self.current = current
    }
}

/// The documents a cloud prompt may be built from, as checked by `CloudSourceGate`.
public nonisolated struct CloudSourceClearance: Sendable, Hashable {
    public let clearedObjectIDs: Set<UUID>
    public let deniedCount: Int
    public let checkedAt: Date
    public let purpose: String
    /// B4 — the scope the request was built for and each cleared document's exact source version
    /// then (nil binding: an unscoped, whole-library question — label checks only).
    public var binding: CloudScopeBinding?
    public var versions: [UUID: Set<UUID>] = [:]
    /// A6 — the gate that issued this clearance, so the send boundary can re-clear exactly these
    /// sources after the consent dialog (a source made privileged, restricted or erased meanwhile
    /// stops the send). Not part of equality.
    public let gate: CloudSourceGate?

    public init(clearedObjectIDs: Set<UUID>, deniedCount: Int, checkedAt: Date, purpose: String, gate: CloudSourceGate? = nil) {
        self.clearedObjectIDs = clearedObjectIDs; self.deniedCount = deniedCount
        self.checkedAt = checkedAt; self.purpose = purpose; self.gate = gate
    }

    public static func == (a: CloudSourceClearance, b: CloudSourceClearance) -> Bool {
        a.clearedObjectIDs == b.clearedObjectIDs && a.deniedCount == b.deniedCount && a.checkedAt == b.checkedAt && a.purpose == b.purpose
    }
    public func hash(into h: inout Hasher) { h.combine(clearedObjectIDs); h.combine(deniedCount); h.combine(checkedAt); h.combine(purpose) }

    /// A6 — re-clear these sources now. Nil when they all still clear; otherwise why not. A clearance
    /// without its gate cannot be re-checked and is refused.
    public func stillCleared() async -> String? {
        guard let gate else { return "the sources could not be re-checked" }
        if let binding {
            // B4 — membership first: each document must still be in the asking case, at the same version.
            let now: [UUID: Set<UUID>]
            do { now = try await binding.current() } catch { return "the case's sources could not be re-checked (\(error.localizedDescription))" }
            let gone = clearedObjectIDs.filter { now[$0] == nil }
            if !gone.isEmpty { return "\(gone.count) source(s) are no longer part of this case" }
            let changed = clearedObjectIDs.filter { versions[$0] != nil && now[$0] != versions[$0] }
            if !changed.isEmpty { return "\(changed.count) source(s) have a new version" }
        }
        let again = await gate.clear(Array(clearedObjectIDs), purpose: purpose)
        if let reason = again.denied.values.sorted().first {
            return "\(again.denied.count) source(s) changed while you were reviewing (\(reason))"
        }
        return again.clearance.clearedObjectIDs == clearedObjectIDs ? nil : "the sources changed while you were reviewing"
    }
}

public nonisolated struct CloudSourceGate: Sendable {
    /// The strictest sensitivity any cloud send may carry.
    public static let cloudCeiling: SensitivityLevel = .confidential

    private let resolve: @Sendable (UUID) async throws -> ProtectionResolution
    private let legacyPrivileged: @Sendable () async throws -> Set<UUID>
    private let ceiling: SensitivityLevel
    /// B4 — the asking case's scope, when the request comes from one.
    public private(set) var binding: CloudScopeBinding?

    /// This gate, bound to one case's scope: documents outside it are denied, and the clearance
    /// carries the binding so the send boundary re-checks membership and versions.
    public func bound(to binding: CloudScopeBinding?) -> CloudSourceGate {
        var g = self; g.binding = binding; return g
    }

    public init(resolve: @escaping @Sendable (UUID) async throws -> ProtectionResolution,
                legacyPrivileged: @escaping @Sendable () async throws -> Set<UUID>,
                localCeiling: SensitivityLevel = .restricted) {
        self.resolve = resolve
        self.legacyPrivileged = legacyPrivileged
        self.ceiling = min(localCeiling, Self.cloudCeiling)
    }

    public init(sensitiveScope: SensitiveScopeRepository, objects: KnowledgeObjectRepository?, localCeiling: SensitivityLevel = .restricted) {
        self.init(resolve: { try await sensitiveScope.effectiveLabel(for: SensitiveScopeTarget(kind: .knowledgeObject, id: $0)) },
                  legacyPrivileged: { try await objects?.privilegedObjectIDs() ?? [] },
                  localCeiling: localCeiling)
    }

    /// Which of `objectIDs` may be sent for `purpose`, and why each other one may not.
    public func clear(_ objectIDs: [UUID], purpose: String) async -> (clearance: CloudSourceClearance, denied: [UUID: String]) {
        var cleared = Set<UUID>()
        var denied: [UUID: String] = [:]
        let legacy: Set<UUID>
        do { legacy = try await legacyPrivileged() } catch {
            // The privileged list cannot be read: nothing is cleared.
            for id in objectIDs { denied[id] = "the privileged-document list could not be read" }
            return (CloudSourceClearance(clearedObjectIDs: [], deniedCount: denied.count, checkedAt: Date(), purpose: purpose, gate: self), denied)
        }
        var inScope: [UUID: Set<UUID>]? = nil
        if let binding {
            do { inScope = try await binding.current() } catch {
                for id in objectIDs { denied[id] = "the case's sources could not be read" }
                return (CloudSourceClearance(clearedObjectIDs: [], deniedCount: denied.count, checkedAt: Date(), purpose: purpose, gate: self), denied)
            }
        }
        for id in Set(objectIDs) {
            if let inScope, inScope[id] == nil { denied[id] = "not part of this case"; continue }
            if legacy.contains(id) { denied[id] = "privileged"; continue }
            switch try? await resolve(id) {
            case .resolved(let label)?:
                if label.privileged { denied[id] = "privileged" }
                else if label.sensitivity > ceiling { denied[id] = "\(label.sensitivity.label) — above what may leave the Mac" }
                else { cleared.insert(id) }
            case .brokenLineage?:
                denied[id] = "the document's protection could not be traced"
            case nil:
                denied[id] = "the document's protection could not be read"
            }
        }
        var clearance = CloudSourceClearance(clearedObjectIDs: cleared, deniedCount: denied.count, checkedAt: Date(), purpose: purpose, gate: self)
        clearance.binding = binding
        clearance.versions = (inScope ?? [:]).filter { cleared.contains($0.key) }
        return (clearance, denied)
    }
}
