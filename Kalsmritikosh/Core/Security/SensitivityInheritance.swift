//
//  SensitivityInheritance.swift
//  Kalsmritikosh
//
//  SEC-001 — sensitivity/privilege inheritance. Any derived artifact (a chunk, a fact, a
//  summary, a dataset cell, an answer) must be AT LEAST as protected as the most sensitive
//  source it was derived from. Otherwise a "public" summary could leak a "restricted"
//  source's content. The rule is monotone: derived sensitivity = max(source sensitivities),
//  and privilege is sticky — if any source is privileged, the derived artifact is too.
//
//  Pure, deterministic. This defines the lattice + inheritance; storage/repositories apply it.
//

import Foundation

/// Ordered sensitivity lattice. Higher rawValue = more protected.
public enum SensitivityLevel: Int, Codable, Sendable, Hashable, Comparable, CaseIterable {
    case publicLevel   = 0
    case internalLevel = 1
    case confidential  = 2
    case restricted    = 3

    public static func < (a: SensitivityLevel, b: SensitivityLevel) -> Bool { a.rawValue < b.rawValue }

    public var label: String {
        switch self {
        case .publicLevel:   return "Public"
        case .internalLevel: return "Internal"
        case .confidential:  return "Confidential"
        case .restricted:    return "Restricted"
        }
    }
}

/// The protection a source or derived artifact carries.
public struct ProtectionLabel: Codable, Sendable, Hashable {
    public let sensitivity: SensitivityLevel
    public let privileged: Bool

    public nonisolated init(sensitivity: SensitivityLevel = .internalLevel, privileged: Bool = false) {
        self.sensitivity = sensitivity
        self.privileged = privileged
    }

    public static let publicDefault = ProtectionLabel(sensitivity: .publicLevel, privileged: false)
}

public enum SensitivityInheritance {

    /// The protection a derived artifact must carry, given its sources' protections.
    /// Monotone: sensitivity = max; privileged = OR. With no sources, defaults to internal
    /// (never public — a derivation with unknown provenance is not assumed shareable).
    public nonisolated static func inherit(from sources: [ProtectionLabel]) -> ProtectionLabel {
        guard !sources.isEmpty else { return ProtectionLabel(sensitivity: .internalLevel, privileged: false) }
        let maxSensitivity = sources.map(\.sensitivity).max() ?? .internalLevel
        let anyPrivileged = sources.contains { $0.privileged }
        return ProtectionLabel(sensitivity: maxSensitivity, privileged: anyPrivileged)
    }

    /// Guard: is it safe to release `derived` at `targetSensitivity`? Only if the derived
    /// artifact's inherited sensitivity is <= the target AND it is not privileged.
    public nonisolated static func canRelease(_ derived: ProtectionLabel, at target: SensitivityLevel) -> Bool {
        !derived.privileged && derived.sensitivity <= target
    }
}
