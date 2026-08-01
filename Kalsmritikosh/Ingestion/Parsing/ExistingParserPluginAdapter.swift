//
//  ExistingParserPluginAdapter.swift
//  Kalsmritikosh
//
//  USF-M1 (USF-004) — wraps an EXISTING Ingestor (+ optional StructuralParser) as a
//  UniversalParserPlugin without rewriting the parser algorithms. It reads ONLY the immutable
//  processing snapshot (USF-001.2 exact-byte binding), runs the loader ONCE via `ingestMany`
//  (never both ingest + ingestMany), runs the structural parser over the SAME snapshot bytes, and
//  projects the result into common content surfaces. Identity is validated by the executor, not here.
//

import Foundation

public struct ExistingParserPluginAdapter: UniversalParserPlugin {
    public let pluginID: String
    public let pluginVersion: String
    public let supportedTypes: Set<SourceType>
    public let capabilities: UniversalParserCapabilities
    public let executionMode: UniversalParserExecutionMode
    public let primaryLane: ResourceLane

    private let loader: any Ingestor
    private let structural: (any StructuralParser)?
    /// When true, the loader must advertise every declared type. Set false ONLY for the intentional
    /// text-fallback plugins (html/json/xml/log/sqlite read via TextLoader while their STRUCTURE
    /// comes from a structural parser) and the generic-text fallback for `.unknown`.
    private let enforceLoaderTypeSupport: Bool

    public init(pluginID: String, pluginVersion: String, supportedTypes: Set<SourceType>,
                executionMode: UniversalParserExecutionMode, loader: any Ingestor,
                structural: (any StructuralParser)? = nil, requiresOCR: Bool = false,
                enforceLoaderTypeSupport: Bool = true, declaredSurfaces: Set<ContentSurfaceKind>) {
        self.pluginID = pluginID
        self.pluginVersion = pluginVersion
        self.supportedTypes = supportedTypes
        self.executionMode = executionMode
        self.loader = loader
        self.structural = structural
        self.enforceLoaderTypeSupport = enforceLoaderTypeSupport
        self.primaryLane = loader.primaryLane
        self.capabilities = UniversalParserCapabilities(
            producesStructure: structural != nil, requiresOCR: requiresOCR, declaredSurfaces: declaredSurfaces)
    }

    /// USF-M1 §11 — a real-loader plugin's loader must advertise its declared types, and its
    /// structural parser (when present) must support them too. Validated at registry construction.
    public func validateInternalConsistency() throws {
        if enforceLoaderTypeSupport {
            guard supportedTypes.isSubset(of: loader.supportedTypes) else {
                throw UniversalParserError.loaderTypeMismatch(pluginID: pluginID, type: supportedTypes.subtracting(loader.supportedTypes).first ?? .unknown)
            }
        }
        if let structural {
            guard supportedTypes.isSubset(of: structural.supportedTypes) else {
                throw UniversalParserError.structuralParserTypeMismatch(pluginID: pluginID, type: supportedTypes.subtracting(structural.supportedTypes).first ?? .unknown)
            }
        }
    }

    public func execute(_ request: UniversalParserRequest) async throws -> UniversalParserResult {
        // Read ONLY the immutable snapshot — never the mutable original.
        guard let snapshotData = try? Data(contentsOf: request.processingSnapshotURL) else {
            throw UniversalParserError.snapshotUnreadable(pluginID: pluginID)
        }
        // Loader runs ONCE via ingestMany (single-KO formats return one; mbox/pst return many).
        let objects: [KnowledgeObject]
        do { objects = try await loader.ingestMany(fileAt: request.processingSnapshotURL, type: request.sourceType) }
        catch { throw UniversalParserError.loaderFailure(pluginID: pluginID, detail: String(describing: error).prefix(200).description) }

        // Structural parse over the SAME snapshot bytes, when this plugin has one. USF-M3 §21 — a
        // `searchCore` request may SKIP structure when the loader already produced usable searchable
        // text; evidence upgrade re-runs with `evidenceStructure`/`fullAvailable`. Same registry, one
        // flag — never an alternate parser path.
        let loaderProducedText = objects.contains { !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let skipStructureForSearchCore = request.intent == .searchCore && loaderProducedText
        var parsedDocument: ParsedDocument? = nil
        if let structural, !skipStructureForSearchCore {
            do {
                parsedDocument = try await structural.parse(
                    data: snapshotData, filename: request.originalURL.lastPathComponent, type: request.sourceType,
                    logicalSourceID: request.logicalSourceID, sourceVersionID: request.sourceVersionID)
            } catch {
                throw UniversalParserError.structuralParserFailure(pluginID: pluginID, detail: String(describing: error).prefix(200).description)
            }
        }

        let surfaces: [ContentSurfaceReceipt]
        let status: ExtractionStatus
        if let doc = parsedDocument {
            surfaces = ContentSurfaceProjector.project(blocks: doc.blocks, metadata: doc.metadata, extractionStatus: doc.extractionStatus)
            status = doc.extractionStatus
        } else {
            let hasText = objects.contains { !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            status = hasText ? .complete : .empty
            surfaces = ContentSurfaceProjector.projectFromObjects(objects, extractionStatus: status)
        }

        return UniversalParserResult(
            pluginID: pluginID, pluginVersion: pluginVersion, sourceType: request.sourceType,
            logicalSourceID: request.logicalSourceID, sourceVersionID: request.sourceVersionID,
            contentHash: request.contentHash, knowledgeObjects: objects, parsedDocument: parsedDocument,
            contentSurfaces: surfaces, warnings: parsedDocument?.warnings ?? [], extractionStatus: status)
    }
}
