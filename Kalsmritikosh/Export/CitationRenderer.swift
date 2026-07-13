//
//  CitationRenderer.swift
//  Kalsmritikosh
//
//  Persona features Epic 2 (F3). Deterministic rendering of a CitationRecord
//  in every style the personas need (§8.2). Pure value-in / string-out — no
//  DB, no LLM — so it is fully unit-testable and reproducible: the same
//  record always renders the same text. Unresolved citations render an
//  explicit warning; generated summaries are labelled, never presented as
//  primary evidence (§8.5).
//

import Foundation

public enum CitationStyle: String, Sendable, CaseIterable, Codable {
    /// "Filename — exact location"
    case general
    /// Numbered footnote with source and locator.
    case footnote
    /// Legal / investigation: exhibit label · document · Bates-style · custody.
    case legalExhibit
    /// Research bibliography formats.
    case bibTeX
    case ris
    case cslJSON
    case plainBibliography

    public var displayName: String {
        switch self {
        case .general:           return "General"
        case .footnote:          return "Footnote"
        case .legalExhibit:      return "Exhibit / Bates-style"
        case .bibTeX:            return "BibTeX"
        case .ris:               return "RIS"
        case .cslJSON:           return "CSL-JSON"
        case .plainBibliography: return "Plain bibliography"
        }
    }
}

public enum CitationRenderer {

    private static let unresolvedPrefix = "⚠ UNRESOLVED SOURCE — cannot reopen: "

    /// Render one citation. `index` is the 1-based footnote/list number when
    /// the style needs it (ignored otherwise).
    public static func render(_ c: CitationRecord, style: CitationStyle, index: Int = 1) -> String {
        switch style {
        case .general:           return general(c)
        case .footnote:          return footnote(c, index: index)
        case .legalExhibit:      return legalExhibit(c)
        case .bibTeX:            return bibTeX(c, index: index)
        case .ris:               return ris(c)
        case .cslJSON:           return cslJSON(c, index: index)
        case .plainBibliography: return plain(c)
        }
    }

    /// Render a whole list, joined appropriately for the style (e.g. CSL-JSON
    /// yields a single JSON array).
    public static func renderList(_ cs: [CitationRecord], style: CitationStyle) -> String {
        switch style {
        case .cslJSON:
            let items = cs.enumerated().map { cslJSONObject($0.element, index: $0.offset + 1) }
            return "[\n" + items.joined(separator: ",\n") + "\n]"
        default:
            return cs.enumerated()
                .map { render($0.element, style: style, index: $0.offset + 1) }
                .joined(separator: "\n")
        }
    }

    // MARK: - Styles

    private static func general(_ c: CitationRecord) -> String {
        var s = c.isResolved ? "" : unresolvedPrefix
        s += c.sourceTitle
        let loc = c.effectiveLocator
        if !loc.isEmpty { s += " — \(loc)" }
        if c.isGeneratedSummary { s += " [generated summary — not primary evidence]" }
        return s
    }

    private static func footnote(_ c: CitationRecord, index: Int) -> String {
        var s = "\(index). "
        if !c.isResolved { s += unresolvedPrefix }
        if let a = c.authorOrSender, !a.isEmpty { s += "\(a), " }
        s += "\(c.sourceTitle)"
        if let d = c.date { s += " (\(humanDate(d)))" }
        let loc = c.effectiveLocator
        if !loc.isEmpty { s += ", \(loc)" }
        if c.isGeneratedSummary { s += " [generated summary]" }
        s += "."
        return s
    }

    private static func legalExhibit(_ c: CitationRecord) -> String {
        var parts: [String] = []
        if let ex = c.workspaceExhibitLabel, !ex.isEmpty { parts.append(ex) }
        if !c.isResolved { parts.append("UNRESOLVED SOURCE") }
        parts.append(c.sourceTitle)
        let loc = c.effectiveLocator
        if !loc.isEmpty { parts.append(loc) }
        if let h = c.sourceHash, !h.isEmpty { parts.append("hash \(h.prefix(12))") }
        if c.isGeneratedSummary { parts.append("[generated summary]") }
        return parts.joined(separator: " · ")
    }

    // MARK: - Bibliography formats

    private static func citeKey(_ c: CitationRecord, index: Int) -> String {
        let author = c.bibliographic?.authors.first ?? c.authorOrSender ?? "source"
        let last = author.split(separator: " ").last.map(String.init) ?? author
        let year = c.year.map(String.init) ?? "nd"
        let safe = last.lowercased().filter { $0.isLetter || $0.isNumber }
        return "\(safe.isEmpty ? "source" : safe)\(year)_\(index)"
    }

    private static func bibTeX(_ c: CitationRecord, index: Int) -> String {
        let bib = c.bibliographic
        let type = bib?.entryType ?? "misc"
        var fields: [String] = []
        fields.append("  title = {\(bib?.title ?? c.sourceTitle)}")
        let authors = bib?.authors.isEmpty == false ? bib!.authors : (c.authorOrSender.map { [$0] } ?? [])
        if !authors.isEmpty { fields.append("  author = {\(authors.joined(separator: " and "))}") }
        if let y = c.year { fields.append("  year = {\(y)}") }
        if let container = bib?.container { fields.append("  howpublished = {\(container)}") }
        if let doi = bib?.doi { fields.append("  doi = {\(doi)}") }
        if let url = bib?.url { fields.append("  url = {\(url)}") }
        return "@\(type){\(citeKey(c, index: index)),\n" + fields.joined(separator: ",\n") + "\n}"
    }

    private static func ris(_ c: CitationRecord) -> String {
        let bib = c.bibliographic
        var lines: [String] = ["TY  - \(risType(bib?.entryType))"]
        let authors = bib?.authors.isEmpty == false ? bib!.authors : (c.authorOrSender.map { [$0] } ?? [])
        for a in authors { lines.append("AU  - \(a)") }
        lines.append("TI  - \(bib?.title ?? c.sourceTitle)")
        if let y = c.year { lines.append("PY  - \(y)") }
        if let container = bib?.container { lines.append("PB  - \(container)") }
        if let doi = bib?.doi { lines.append("DO  - \(doi)") }
        if let url = bib?.url { lines.append("UR  - \(url)") }
        lines.append("ER  - ")
        return lines.joined(separator: "\n")
    }

    private static func risType(_ entryType: String?) -> String {
        switch entryType {
        case "article": return "JOUR"
        case "book":    return "BOOK"
        case "report":  return "RPRT"
        default:        return "GEN"
        }
    }

    private static func cslJSON(_ c: CitationRecord, index: Int) -> String {
        "[\n" + cslJSONObject(c, index: index) + "\n]"
    }

    private static func cslJSONObject(_ c: CitationRecord, index: Int) -> String {
        let bib = c.bibliographic
        var obj: [String] = []
        obj.append("    \"id\": \(jsonString(citeKey(c, index: index)))")
        obj.append("    \"type\": \(jsonString(cslType(bib?.entryType)))")
        obj.append("    \"title\": \(jsonString(bib?.title ?? c.sourceTitle))")
        let authors = bib?.authors.isEmpty == false ? bib!.authors : (c.authorOrSender.map { [$0] } ?? [])
        if !authors.isEmpty {
            let authorObjs = authors.map { "{ \"literal\": \(jsonString($0)) }" }.joined(separator: ", ")
            obj.append("    \"author\": [\(authorObjs)]")
        }
        if let y = c.year { obj.append("    \"issued\": { \"date-parts\": [[\(y)]] }") }
        if let container = bib?.container { obj.append("    \"container-title\": \(jsonString(container))") }
        if let doi = bib?.doi { obj.append("    \"DOI\": \(jsonString(doi))") }
        if let url = bib?.url { obj.append("    \"URL\": \(jsonString(url))") }
        return "  {\n" + obj.joined(separator: ",\n") + "\n  }"
    }

    private static func cslType(_ entryType: String?) -> String {
        switch entryType {
        case "article": return "article-journal"
        case "book":    return "book"
        case "report":  return "report"
        default:        return "document"
        }
    }

    private static func plain(_ c: CitationRecord) -> String {
        var s = ""
        let authors = c.bibliographic?.authors ?? c.authorOrSender.map { [$0] } ?? []
        if !authors.isEmpty { s += authors.joined(separator: ", ") + ". " }
        s += (c.bibliographic?.title ?? c.sourceTitle)
        if let y = c.year { s += " (\(y))" }
        if let container = c.bibliographic?.container { s += ". \(container)" }
        if let doi = c.bibliographic?.doi { s += ". doi:\(doi)" }
        if !c.isResolved { s = unresolvedPrefix + s }
        return s + "."
    }

    // MARK: - Helpers

    private static func humanDate(_ d: Date) -> String {
        d.formatted(date: .abbreviated, time: .omitted)
    }

    /// Minimal JSON string escaping (quotes + backslashes + control chars).
    static func jsonString(_ s: String) -> String {
        var out = "\""
        for ch in s.unicodeScalars {
            switch ch {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if ch.value < 0x20 {
                    out += String(format: "\\u%04x", ch.value)
                } else {
                    out.unicodeScalars.append(ch)
                }
            }
        }
        out += "\""
        return out
    }
}

private extension CitationRecord {
    var year: Int? {
        if let y = bibliographic?.year { return y }
        guard let d = date else { return nil }
        return Calendar(identifier: .gregorian).component(.year, from: d)
    }
}
