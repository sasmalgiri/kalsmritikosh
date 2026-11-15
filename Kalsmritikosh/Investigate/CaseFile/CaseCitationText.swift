//
//  CaseCitationText.swift
//  Kalsmritikosh
//
//  Ease fixes B (AI-off assessment 2026-11-15, friction point 4) — citations a court, an HR team or an insurer can
//  check without the app: "invoice-march.pdf, p. 4", "ledger.xlsx, sheet Sales, cell B5", "deck.pptx, slide 3",
//  "interview.m4a, at 12:34". The place comes from the locator the ledger already stores for the cited passage
//  (the evidence block's SRC-01 locator); a place that is not recorded is said so ("page not recorded") and never
//  guessed. The stable identifiers (source version, record, passage) stay in a machine-readable appendix at the end of
//  the document, so the manifest, the read-back and anyone checking against the ledger can still match every
//  citation; the visible text names documents, never identifiers.
//
//  Reads only. No AI, no network.
//

import Foundation
import os

/// What the ledger holds about the cited places of one document: each cited version's and record's document name, and
/// each cited passage's locator.
public nonisolated struct CaseCitationPlaces: Sendable, Equatable {
    /// Source version → the file name it was read from.
    public var versionNames: [UUID: String] = [:]
    /// Record (knowledge object) → the file name it was read from.
    public var objectNames: [UUID: String] = [:]
    /// Passage (evidence block) → its stored locator.
    public var locators: [UUID: SourceLocator] = [:]
    /// Passage (evidence block) → the source version it was read from (to name a passage cited without its version).
    public var blockVersions: [UUID: UUID] = [:]

    public init() {}

    public var isEmpty: Bool { versionNames.isEmpty && objectNames.isEmpty && locators.isEmpty }

    /// The document name for a citation, nil when the ledger names none.
    public func name(version: UUID?, object: UUID?, block: UUID?) -> String? {
        if let v = version, let n = versionNames[v] { return n }
        if let o = object, let n = objectNames[o] { return n }
        if let b = block, let v = blockVersions[b], let n = versionNames[v] { return n }
        return nil
    }
}

public nonisolated enum CaseCitationText {
    /// Said when the cited place has no recorded page (or other position). Never replaced by a guess.
    public static let pageNotRecorded = "page not recorded"
    /// Said when the ledger does not name the cited document.
    public static let unnamedDocument = "a document the ledger does not name"
    /// The appendix that carries the stable identifiers. Everything above it is the human text.
    public static let appendixHeading = "## Appendix — machine-readable references"

    /// The place a locator points at, in words: "p. 4", "sheet Sales, cell B5", "slide 3", "at 12:34", "line 10" —
    /// or `pageNotRecorded`. Only what the locator records; nothing is inferred.
    public static func place(_ l: SourceLocator?) -> String {
        guard let l else { return pageNotRecorded }
        var parts: [String] = []
        if let page = l.page, page >= 1 { parts.append("p. \(page)") }
        if let sheet = l.sheet, !sheet.isEmpty { parts.append("sheet \(sheet)") }
        if let cells = l.cellRange, !cells.isEmpty {
            parts.append(cells.contains(":") ? "cells \(cells)" : "cell \(cells)")
        } else if let column = l.column, !column.isEmpty, let row = l.row, row >= 0 {
            parts.append("cell \(column)\(row + 1)")
        } else if let row = l.row, row >= 0, l.sheet != nil || l.tableID != nil {
            parts.append("row \(row + 1)")
        }
        if let slide = l.slide, slide >= 1 { parts.append("slide \(slide)") }
        if let start = l.transcriptStart, start.isFinite, start >= 0 {
            var t = "at \(CitedSourceResolver.timecode(start))"
            if let end = l.transcriptEnd, end.isFinite, end > start { t += "–\(CitedSourceResolver.timecode(end))" }
            parts.append(t)
        }
        if let line = l.line, line >= 1 { parts.append("line \(line)") }
        if let field = l.emailHeaderField, !field.isEmpty {
            parts.append("the “\(field)” line of the email")
        } else if l.messageID != nil, parts.isEmpty {
            parts.append("the email message")
        }
        if let member = l.archiveMemberPath, !member.isEmpty { parts.append("inside the archive at \(member)") }
        if let key = l.databaseRowKey, !key.isEmpty { parts.append("database row \(key)") }
        return parts.isEmpty ? pageNotRecorded : parts.joined(separator: ", ")
    }

    /// "document name, p. 4" — the human citation of one cited place.
    public static func cite(name: String?, locator: SourceLocator?) -> String {
        let n = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\((n?.isEmpty ?? true) ? unnamedDocument : (n ?? unnamedDocument)), \(place(locator))"
    }

    /// The human citation of a cited version / record / passage with what `places` holds.
    public static func cite(_ places: CaseCitationPlaces, version: UUID?, object: UUID?, block: UUID?) -> String {
        cite(name: places.name(version: version, object: object, block: block), locator: block.flatMap { places.locators[$0] })
    }

    /// The text before the appendix — what a reader sees as the report.
    public static func visibleBody(_ text: String) -> String {
        guard let r = text.range(of: appendixHeading) else { return text }
        return String(text[text.startIndex..<r.lowerBound])
    }

    /// `section` placed just before the appendix (or at the end when there is none).
    public static func insertBeforeAppendix(_ section: String, into text: String) -> String {
        guard !section.isEmpty else { return text }
        guard let r = text.range(of: appendixHeading) else { return text + section }
        return String(text[text.startIndex..<r.lowerBound]) + section + "\n" + String(text[r.lowerBound...])
    }

    /// Lines to add to the appendix (each "- …"), merged into an existing appendix or starting one.
    public static func appendToAppendix(_ lines: [String], into text: String) -> String {
        guard !lines.isEmpty else { return text }
        let block = lines.joined(separator: "\n") + "\n"
        if text.contains(appendixHeading) { return text + block }
        return text + "\n" + appendixHeading + "\n" + appendixLegend + block
    }

    static let appendixLegend = "_For checking against the ledger: each reference's stable identifiers (source version, record, passage). The report above names documents and places only._\n"

    // MARK: Reading the places

    /// Read every cited place's document name and locator from the ledger, in batches. Unknown ids are simply absent
    /// (the text then says the document is not named or the page is not recorded).
    public static func read(_ db: Database, versions: Set<UUID>, objects: Set<UUID>, blocks: Set<UUID>) async throws -> CaseCitationPlaces {
        var out = CaseCitationPlaces()
        func batches(_ ids: Set<UUID>) -> [[UUID]] {
            let all = ids.sorted { $0.uuidString < $1.uuidString }
            return stride(from: 0, to: all.count, by: 400).map { Array(all[$0..<min($0 + 400, all.count)]) }
        }
        func marks(_ n: Int) -> String { Array(repeating: "?", count: n).joined(separator: ",") }
        for chunk in batches(blocks) {
            let rows = try await db.query("SELECT id, locator, source_version_id FROM evidence_blocks WHERE id IN (\(marks(chunk.count)));", chunk.map { .uuid($0) })
            for r in rows {
                guard let id = r.uuid(0) else { continue }
                if let v = r.uuid(2) { out.blockVersions[id] = v }
                guard let json = r.string(1), let data = json.data(using: .utf8) else { continue }
                do { out.locators[id] = try JSONDecoder().decode(SourceLocator.self, from: data) } catch {
                    KalsmritikoshLog.app.error("Citation place: locator unreadable: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        let allVersions = versions.union(out.blockVersions.values)
        for chunk in batches(allVersions) {
            let rows = try await db.query("SELECT id, filename, original_url FROM source_versions WHERE id IN (\(marks(chunk.count)));", chunk.map { .uuid($0) })
            for r in rows {
                guard let id = r.uuid(0) else { continue }
                if let n = documentName(filename: r.string(1), url: r.string(2)) { out.versionNames[id] = n }
            }
        }
        for chunk in batches(objects) {
            let rows = try await db.query("""
                SELECT k.id, f.url FROM knowledge_objects k JOIN files f ON f.id = k.file_id WHERE k.id IN (\(marks(chunk.count)));
                """, chunk.map { .uuid($0) })
            for r in rows {
                guard let id = r.uuid(0) else { continue }
                if let n = documentName(filename: nil, url: r.string(1)) { out.objectNames[id] = n }
            }
        }
        return out
    }

    /// A readable file name: the recorded file name, else the last part of the original location.
    static func documentName(filename: String?, url: String?) -> String? {
        if let f = filename?.trimmingCharacters(in: .whitespacesAndNewlines), !f.isEmpty { return f }
        guard let s = url, !s.isEmpty else { return nil }
        let u = URL(string: s) ?? URL(fileURLWithPath: s)
        let last = u.lastPathComponent.removingPercentEncoding ?? u.lastPathComponent
        return last.isEmpty || last == "/" ? nil : last
    }
}

/// The numbered references of one document: each cited place gets a short label (R1, R2, …) shown with the document
/// name and place; the appendix lists each label with its stable identifiers. The same place cited twice keeps one label.
public nonisolated struct CaseReportReferences: Sendable {
    public let places: CaseCitationPlaces
    private var lines: [String] = []
    private var index: [String: String] = [:]
    private var origins: [String: String] = [:]
    /// The label prefix ("R" for the report's own citations; another letter for a section rendered apart, so labels never collide).
    public let prefix: String

    public init(places: CaseCitationPlaces, prefix: String = "R") { self.places = places; self.prefix = prefix }

    /// "R1: invoice.pdf, p. 4" for a cited version / record / passage.
    public mutating func cite(version: UUID?, object: UUID?, block: UUID?) -> String {
        let key = "\(version?.uuidString ?? "-")|\(object?.uuidString ?? "-")|\(block?.uuidString ?? "-")"
        let human = CaseCitationText.cite(places, version: version, object: object, block: block)
        if let label = index[key] { return "\(label): \(human)" }
        let label = "\(prefix)\(index.count + 1)"
        index[key] = label
        var ids: [String] = []
        if let version { ids.append("source version \(version.uuidString)") }
        if let object { ids.append("record \(object.uuidString)") }
        if let block { ids.append("passage \(block.uuidString)") }
        lines.append("- \(label): " + (ids.isEmpty ? "no identifier recorded" : ids.joined(separator: " · ")))
        return "\(label): \(human)"
    }

    public mutating func cite(_ r: StudioEvidenceRef) -> String { cite(version: r.sourceVersionID, object: r.objectID, block: r.blockID) }

    /// A free-text case reference ("exhibit:EX-001", "note:…", a source version id), in words.
    public mutating func cite(evidenceRef raw: String, block: UUID? = nil, object: UUID? = nil) -> String {
        switch CaseEvidenceReference.parse(raw) {
        case .sourceVersion(let v): return cite(version: v, object: object, block: block)
        case .exhibit(let n): return "exhibit \(n)"
        case .investigatorNote: return "investigator's note"
        case .unresolved(let s):
            // An old free-text reference is kept as written, unless it is an identifier: then it goes to the appendix.
            if UUID(uuidString: s) != nil || s.range(of: #"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-"#, options: .regularExpression) != nil {
                return reference(raw: s, prefix: "U", wording: "an unresolved reference")
            }
            return "reference as written: \(s)"
        }
    }

    /// Where a carried item came from, in words; the stamp itself goes to the appendix.
    public mutating func origin(_ raw: String) -> String {
        let parts = raw.split(separator: ":").map(String.init)
        let wording: String
        if parts.first == "job", parts.count >= 5, let row = parts.last {
            let job = PersonaJobCatalogComposer.allJobs.first { $0.id == parts[1] }?.title
            wording = "the result of “\(job ?? "a job")”, row \(row)"
        } else if parts.first == "passage" {
            wording = "a passage of the case's documents"
        } else {
            wording = "another record of the case"
        }
        return reference(raw: raw, prefix: "O", wording: wording)
    }

    private mutating func reference(raw: String, prefix: String, wording: String) -> String {
        if let label = origins[raw] { return "\(wording) (\(label))" }
        let label = "\(prefix)\(origins.filter { $0.value.hasPrefix(prefix) }.count + 1)"
        origins[raw] = label
        lines.append("- \(label): \(raw)")
        return "\(wording) (\(label))"
    }

    /// The appendix lines ("- R1: source version … · passage …").
    public var appendixLines: [String] { lines }

    /// The appendix section (empty when nothing was cited).
    public var appendix: String {
        guard !lines.isEmpty else { return "" }
        return "\n" + CaseCitationText.appendixHeading + "\n" + CaseCitationText.appendixLegend + lines.joined(separator: "\n") + "\n"
    }
}
