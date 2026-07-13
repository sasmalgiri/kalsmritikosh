//
//  CitationRecord.swift
//  Kalsmritikosh
//
//  Persona features Epic 2 (F3). The single citation object every persona
//  and every export format shares. A CitationRecord always carries the
//  identifiers needed to REOPEN the exact source location (source version +
//  evidence blocks + a granular locator) plus enough surface metadata to
//  render a footnote or a bibliography entry. Generated summaries are never
//  represented here as original evidence — a summary citation must set
//  `isGeneratedSummary` so renderers can label it, never present it as a
//  primary source (§8.5).
//

import Foundation

/// A granular, format-agnostic pointer into a source. Exactly the locator
/// kinds the spec enumerates (§8.1). `rendered` builds the human string when
/// an explicit `locatorText` override isn't supplied.
public struct CitationLocator: Sendable, Hashable, Codable {
    public var page: Int?
    public var sheet: String?
    public var cell: String?
    public var slide: Int?
    public var message: Int?
    public var timecode: String?
    public var line: Int?
    public var row: Int?

    public nonisolated init(
        page: Int? = nil, sheet: String? = nil, cell: String? = nil,
        slide: Int? = nil, message: Int? = nil, timecode: String? = nil,
        line: Int? = nil, row: Int? = nil
    ) {
        self.page = page; self.sheet = sheet; self.cell = cell
        self.slide = slide; self.message = message; self.timecode = timecode
        self.line = line; self.row = row
    }

    /// Deterministic human rendering, most-specific first. Empty when no
    /// component is set (caller then omits the locator entirely).
    public var rendered: String {
        var parts: [String] = []
        if let page { parts.append("p. \(page)") }
        if let sheet {
            if let cell { parts.append("sheet \(sheet)!\(cell)") }
            else { parts.append("sheet \(sheet)") }
        } else if let cell {
            parts.append("cell \(cell)")
        }
        if let slide { parts.append("slide \(slide)") }
        if let message { parts.append("message \(message)") }
        if let timecode { parts.append("@ \(timecode)") }
        if let row { parts.append("row \(row)") }
        if let line { parts.append("line \(line + 1)") }
        return parts.joined(separator: ", ")
    }
}

/// Optional bibliographic surface for research-style renderers (BibTeX / RIS
/// / CSL-JSON). Absent for ordinary document citations.
public struct BibliographicMetadata: Sendable, Hashable, Codable {
    public var entryType: String   // article / book / report / misc …
    public var title: String?
    public var authors: [String]
    public var year: Int?
    public var container: String?  // journal / publisher / archive
    public var doi: String?
    public var url: String?

    public nonisolated init(
        entryType: String = "misc",
        title: String? = nil,
        authors: [String] = [],
        year: Int? = nil,
        container: String? = nil,
        doi: String? = nil,
        url: String? = nil
    ) {
        self.entryType = entryType
        self.title = title
        self.authors = authors
        self.year = year
        self.container = container
        self.doi = doi
        self.url = url
    }
}

public struct CitationRecord: Sendable, Identifiable, Hashable, Codable {
    public typealias ID = UUID

    public let id: ID
    /// The source version this citation reopens. `nil` marks an UNRESOLVED
    /// citation (the source could not be located) — renderers emit an
    /// explicit warning rather than a silent drop (§8.5).
    public let sourceVersionID: UUID?
    /// The exact evidence blocks that back the cited claim.
    public let evidenceBlockIDs: [UUID]
    /// Short label used inline ("[3]", "Ex. A", filename).
    public var displayLabel: String
    public var sourceTitle: String
    public var authorOrSender: String?
    public var date: Date?
    /// Explicit locator string; when nil, `locator.rendered` is used.
    public var locatorText: String?
    public var locator: CitationLocator
    /// SHA-256 (or content hash) of the source version, for the manifest.
    public var sourceHash: String?
    /// Exhibit/Bates label assigned within a workspace (legal/investigation).
    public var workspaceExhibitLabel: String?
    public var bibliographic: BibliographicMetadata?
    /// True when the cited text is a generated summary, not primary evidence.
    public var isGeneratedSummary: Bool

    public nonisolated init(
        id: ID = UUID(),
        sourceVersionID: UUID?,
        evidenceBlockIDs: [UUID] = [],
        displayLabel: String,
        sourceTitle: String,
        authorOrSender: String? = nil,
        date: Date? = nil,
        locatorText: String? = nil,
        locator: CitationLocator = CitationLocator(),
        sourceHash: String? = nil,
        workspaceExhibitLabel: String? = nil,
        bibliographic: BibliographicMetadata? = nil,
        isGeneratedSummary: Bool = false
    ) {
        self.id = id
        self.sourceVersionID = sourceVersionID
        self.evidenceBlockIDs = evidenceBlockIDs
        self.displayLabel = displayLabel
        self.sourceTitle = sourceTitle
        self.authorOrSender = authorOrSender
        self.date = date
        self.locatorText = locatorText
        self.locator = locator
        self.sourceHash = sourceHash
        self.workspaceExhibitLabel = workspaceExhibitLabel
        self.bibliographic = bibliographic
        self.isGeneratedSummary = isGeneratedSummary
    }

    /// Can this citation be reopened? False → renderers must warn (§8.5).
    public var isResolved: Bool { sourceVersionID != nil }

    /// The locator string to display (explicit override or rendered form).
    public var effectiveLocator: String {
        if let t = locatorText, !t.isEmpty { return t }
        return locator.rendered
    }
}
