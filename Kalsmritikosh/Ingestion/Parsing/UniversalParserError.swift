//
//  UniversalParserError.swift
//  Kalsmritikosh
//
//  USF-M1 — typed failures for the universal parser platform. Never flattened to strings.
//

import Foundation

public nonisolated enum UniversalParserError: Error, Equatable, Sendable {
    // Registry construction
    case blankPluginID
    case blankPluginVersion
    case emptySupportedTypes(pluginID: String)
    case duplicatePluginID(String)
    case duplicateSourceTypeOwner(SourceType)
    case loaderTypeMismatch(pluginID: String, type: SourceType)
    case structuralParserTypeMismatch(pluginID: String, type: SourceType)
    case invalidExecutionMode(pluginID: String)
    // Resolution
    case pluginNotFound(SourceType)
    // Result identity gates (fail closed — never relabel to pass)
    case sourceIdentityMismatch(pluginID: String)
    case sourceVersionMismatch(pluginID: String)
    case sourceTypeMismatch(pluginID: String)
    case contentHashMismatch(pluginID: String)
    // Output contracts
    case surfaceContractViolation(pluginID: String, detail: String)
    case unexpectedStructuralOutput(pluginID: String)
    case loaderFailure(pluginID: String, detail: String)
    case structuralParserFailure(pluginID: String, detail: String)
    case snapshotUnreadable(pluginID: String)
}
