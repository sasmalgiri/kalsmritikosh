//
//  ExportManifest.swift
//  Kalsmritikosh
//
//  Persona features Epic 2 (F3). Every export carries a manifest (§8.4) so a
//  work product is reproducible and auditable: what it was generated from,
//  which source versions + hashes back it, which citations it resolved (and
//  which it could NOT), what redactions were applied, and the known
//  limitations. Deterministic JSON so the same snapshot always produces the
//  same manifest bytes.
//

import Foundation

/// One entry in the manifest's citation map: does this citation reopen?
public struct CitationMapEntry: Sendable, Hashable, Codable {
    public var label: String
    public var resolved: Bool
    public nonisolated init(label: String, resolved: Bool) {
        self.label = label; self.resolved = resolved
    }
}

public struct ExportManifest: Sendable, Hashable {
    public var exportedAt: Date
    public var appVersion: String
    public var schemaVersion: Int
    public var workspaceTitle: String?
    public var workspaceTemplate: String?
    public var sourceVersionIDs: [String]
    public var sourceHashes: [String]
    public var selectedFindingCount: Int
    /// citation displayLabel → resolved(true/false).
    public var citationMap: [CitationMapEntry]
    public var appliedRedactions: [String]
    public var reviewStatusSummary: String?
    public var knownLimitations: [String]

    public nonisolated init(
        exportedAt: Date,
        appVersion: String,
        schemaVersion: Int,
        workspaceTitle: String? = nil,
        workspaceTemplate: String? = nil,
        sourceVersionIDs: [String] = [],
        sourceHashes: [String] = [],
        selectedFindingCount: Int = 0,
        citationMap: [CitationMapEntry] = [],
        appliedRedactions: [String] = [],
        reviewStatusSummary: String? = nil,
        knownLimitations: [String] = []
    ) {
        self.exportedAt = exportedAt
        self.appVersion = appVersion
        self.schemaVersion = schemaVersion
        self.workspaceTitle = workspaceTitle
        self.workspaceTemplate = workspaceTemplate
        self.sourceVersionIDs = sourceVersionIDs
        self.sourceHashes = sourceHashes
        self.selectedFindingCount = selectedFindingCount
        self.citationMap = citationMap
        self.appliedRedactions = appliedRedactions
        self.reviewStatusSummary = reviewStatusSummary
        self.knownLimitations = knownLimitations
    }

    public var unresolvedCitationCount: Int { citationMap.filter { !$0.resolved }.count }

    /// Deterministic JSON. Hand-built to control key order + formatting so a
    /// reproducible export yields identical manifest bytes.
    public func toJSON() -> String {
        func str(_ s: String) -> String { CitationRenderer.jsonString(s) }
        func arr(_ xs: [String]) -> String { "[" + xs.map(str).joined(separator: ", ") + "]" }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        var lines: [String] = []
        lines.append("  \"exported_at\": \(str(iso.string(from: exportedAt)))")
        lines.append("  \"app_version\": \(str(appVersion))")
        lines.append("  \"schema_version\": \(schemaVersion)")
        if let t = workspaceTitle { lines.append("  \"workspace\": \(str(t))") }
        if let t = workspaceTemplate { lines.append("  \"workspace_template\": \(str(t))") }
        lines.append("  \"source_version_ids\": \(arr(sourceVersionIDs))")
        lines.append("  \"source_hashes\": \(arr(sourceHashes))")
        lines.append("  \"selected_finding_count\": \(selectedFindingCount)")
        let citations = citationMap.map { "{ \"label\": \(str($0.label)), \"resolved\": \($0.resolved) }" }
        lines.append("  \"citation_map\": [" + citations.joined(separator: ", ") + "]")
        lines.append("  \"unresolved_citation_count\": \(unresolvedCitationCount)")
        lines.append("  \"applied_redactions\": \(arr(appliedRedactions))")
        if let r = reviewStatusSummary { lines.append("  \"review_status\": \(str(r))") }
        lines.append("  \"known_limitations\": \(arr(knownLimitations))")
        return "{\n" + lines.joined(separator: ",\n") + "\n}"
    }

    /// Human-readable manifest block appended to text exports.
    public func toMarkdown() -> String {
        var out = "## Export manifest\n\n"
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime]
        out += "- Exported: \(iso.string(from: exportedAt))\n"
        out += "- App version: \(appVersion) · schema v\(schemaVersion)\n"
        if let t = workspaceTitle { out += "- Workspace: \(t)\(workspaceTemplate.map { " (\($0))" } ?? "")\n" }
        out += "- Source versions: \(sourceVersionIDs.count) · hashes recorded: \(sourceHashes.count)\n"
        out += "- Selected findings: \(selectedFindingCount)\n"
        out += "- Citations: \(citationMap.count) (\(unresolvedCitationCount) unresolved)\n"
        if !appliedRedactions.isEmpty { out += "- Applied redactions: \(appliedRedactions.count)\n" }
        if let r = reviewStatusSummary { out += "- Review status: \(r)\n" }
        if !knownLimitations.isEmpty {
            out += "- Known limitations:\n"
            for l in knownLimitations { out += "  - \(l)\n" }
        }
        return out
    }
}
