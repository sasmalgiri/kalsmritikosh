//
//  UniversalParserRegistry.swift
//  Kalsmritikosh
//
//  USF-M1 (USF-003) — the ONE immutable production routing authority: exactly one plugin owns each
//  SourceType. Replaces the two independent maps (LoaderRegistry + StructuralParserRegistry) as the
//  runtime dispatch. Immutable after construction; duplicate registration FAILS (never last-wins).
//

import Foundation

public struct UniversalParserRegistry: Sendable {
    private let pluginsByType: [SourceType: any UniversalParserPlugin]
    public let plugins: [any UniversalParserPlugin]
    public let unknownFallbackID: String

    /// Build + validate the registry. `unknownFallback` MUST own `.unknown` (explicit fallback —
    /// no silent substitution). Throws on any inconsistency; the result is immutable.
    public init(plugins: [any UniversalParserPlugin], unknownFallback: any UniversalParserPlugin) throws {
        let all = plugins + [unknownFallback]
        var ids = Set<String>()
        var byType: [SourceType: any UniversalParserPlugin] = [:]
        for p in all {
            guard !p.pluginID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw UniversalParserError.blankPluginID }
            guard !p.pluginVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw UniversalParserError.blankPluginVersion }
            guard !p.supportedTypes.isEmpty else { throw UniversalParserError.emptySupportedTypes(pluginID: p.pluginID) }
            guard ids.insert(p.pluginID).inserted else { throw UniversalParserError.duplicatePluginID(p.pluginID) }
            // Adapter plugins prove their loader / structural parser actually support their types.
            try (p as? ExistingParserPluginAdapter)?.validateInternalConsistency()
            for t in p.supportedTypes {
                guard byType[t] == nil else { throw UniversalParserError.duplicateSourceTypeOwner(t) }
                byType[t] = p
            }
        }
        guard unknownFallback.supportedTypes.contains(.unknown) else {
            throw UniversalParserError.invalidExecutionMode(pluginID: unknownFallback.pluginID)
        }
        self.pluginsByType = byType
        self.plugins = all
        self.unknownFallbackID = unknownFallback.pluginID
    }

    /// The one plugin that owns a source type. Throws when unregistered (never a silent fallback).
    public func resolve(_ type: SourceType) throws -> any UniversalParserPlugin {
        guard let p = pluginsByType[type] else { throw UniversalParserError.pluginNotFound(type) }
        return p
    }

    /// Whether a source type has an owning plugin.
    public func owns(_ type: SourceType) -> Bool { pluginsByType[type] != nil }

    /// The plugin owning a type, or nil — for the capability manifest.
    public func plugin(for type: SourceType) -> (any UniversalParserPlugin)? { pluginsByType[type] }
}
