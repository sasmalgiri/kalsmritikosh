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

/// The documents a cloud prompt may be built from, as checked by `CloudSourceGate`.
public nonisolated struct CloudSourceClearance: Sendable, Hashable {
    public let clearedObjectIDs: Set<UUID>
    public let deniedCount: Int
    public let checkedAt: Date
    public let purpose: String
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
        for id in Set(objectIDs) {
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
        return (CloudSourceClearance(clearedObjectIDs: cleared, deniedCount: denied.count, checkedAt: Date(), purpose: purpose, gate: self), denied)
    }
}
