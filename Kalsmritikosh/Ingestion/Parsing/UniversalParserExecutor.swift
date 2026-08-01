//
//  UniversalParserExecutor.swift
//  Kalsmritikosh
//
//  USF-M1 (USF-003) — resolves the ONE plugin for a request's source type, executes it, and
//  fail-closes the result against the request identity. A plugin can never relabel a result to make
//  it pass: the result's logical source / version / hash / type must match the request, and when a
//  ParsedDocument is present its OWN identity fields are independently verified too.
//

import Foundation

public struct UniversalParserExecutor: Sendable {
    public let registry: UniversalParserRegistry

    public init(registry: UniversalParserRegistry) { self.registry = registry }

    public func execute(_ request: UniversalParserRequest) async throws -> UniversalParserResult {
        let plugin = try registry.resolve(request.sourceType)
        let result = try await plugin.execute(request)
        let id = plugin.pluginID

        // Result-level identity gates.
        guard result.logicalSourceID == request.logicalSourceID else { throw UniversalParserError.sourceIdentityMismatch(pluginID: id) }
        guard result.sourceVersionID == request.sourceVersionID else { throw UniversalParserError.sourceVersionMismatch(pluginID: id) }
        guard result.sourceType == request.sourceType else { throw UniversalParserError.sourceTypeMismatch(pluginID: id) }
        guard result.contentHash.lowercased() == request.contentHash.lowercased() else { throw UniversalParserError.contentHashMismatch(pluginID: id) }

        // A structure-less plugin must not smuggle a parsed document.
        if result.parsedDocument != nil, plugin.capabilities.producesStructure == false {
            throw UniversalParserError.unexpectedStructuralOutput(pluginID: id)
        }
        // The parsed document's OWN identity (set by the parser) must match the request — the real
        // exact-byte binding check (parser hash == source version hash).
        if let doc = result.parsedDocument {
            guard doc.logicalSourceID == request.logicalSourceID else { throw UniversalParserError.sourceIdentityMismatch(pluginID: id) }
            guard doc.sourceVersionID == request.sourceVersionID else { throw UniversalParserError.sourceVersionMismatch(pluginID: id) }
            guard doc.contentHash.lowercased() == request.contentHash.lowercased() else { throw UniversalParserError.contentHashMismatch(pluginID: id) }
            guard doc.detectedType == request.sourceType else { throw UniversalParserError.sourceTypeMismatch(pluginID: id) }
        }
        return result
    }
}
