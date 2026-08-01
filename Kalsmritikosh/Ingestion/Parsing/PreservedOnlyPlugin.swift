//
//  PreservedOnlyPlugin.swift
//  Kalsmritikosh
//
//  USF-M1 — a recognized SourceType that has no interpretation path (no loader, no structural
//  parser). Custody is already recorded by intake; this plugin honestly produces NO content: no
//  KnowledgeObjects, no ParsedDocument, notApplicable surfaces. It never fabricates text or blocks.
//

import Foundation

public struct PreservedOnlyPlugin: UniversalParserPlugin {
    public let pluginID: String
    public let pluginVersion: String
    public let supportedTypes: Set<SourceType>
    public let executionMode: UniversalParserExecutionMode
    public let primaryLane: ResourceLane = .cpu
    public let capabilities = UniversalParserCapabilities(producesStructure: false, requiresOCR: false, declaredSurfaces: [])

    public init(pluginID: String, pluginVersion: String = "1", supportedTypes: Set<SourceType>,
                executionMode: UniversalParserExecutionMode = .preservedOnly) {
        self.pluginID = pluginID
        self.pluginVersion = pluginVersion
        self.supportedTypes = supportedTypes
        self.executionMode = executionMode
    }

    public func execute(_ request: UniversalParserRequest) async throws -> UniversalParserResult {
        // Honest: recognized, preserved, not interpreted. Deferred media reports .deferred so the
        // pipeline keeps custody and postpones; anything else is .unsupported.
        let status: ExtractionStatus = executionMode == .deferred ? .deferred : .unsupported
        let surfaces = ContentSurfaceKind.allCases.map { ContentSurfaceReceipt(kind: $0, coverage: .notApplicable, unitCount: 0) }
        return UniversalParserResult(
            pluginID: pluginID, pluginVersion: pluginVersion, sourceType: request.sourceType,
            logicalSourceID: request.logicalSourceID, sourceVersionID: request.sourceVersionID,
            contentHash: request.contentHash, knowledgeObjects: [], parsedDocument: nil,
            contentSurfaces: surfaces, warnings: [], extractionStatus: status)
    }
}
