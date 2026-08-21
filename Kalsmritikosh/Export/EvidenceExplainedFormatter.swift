//
//  EvidenceExplainedFormatter.swift
//  Kalsmritikosh
//
//  A citation builder following the Evidence Explained (Elizabeth Shown Mills)
//  layered model — the standard genealogists asked for. Every source produces
//  three layers:
//
//    • First (full) reference note — the complete footnote, first time cited
//    • Subsequent (short) note — the abbreviated footnote thereafter
//    • Source-list entry — the bibliography form (author inverted)
//
//  This is a deterministic template engine, not an auto-formatter guessing at
//  fields: the user picks the source type and fills the parts EE requires, and
//  the three layers are assembled exactly. It covers the most common source
//  types; the layered discipline is the point.
//

import Foundation

public struct EEField: Sendable, Identifiable, Hashable {
    public var id: String { key }
    public let key: String
    public let label: String
    public let placeholder: String
}

public enum EETemplate: String, Sendable, CaseIterable, Identifiable {
    case book
    case onlineDatabase
    case censusUS
    case vitalRecord
    case newspaper

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .book:           return "Book"
        case .onlineDatabase: return "Online database / image"
        case .censusUS:       return "U.S. census (population schedule)"
        case .vitalRecord:    return "Vital record (certificate)"
        case .newspaper:      return "Newspaper article"
        }
    }

    public var fields: [EEField] {
        switch self {
        case .book:
            return [
                .init(key: "author", label: "Author", placeholder: "Jane A. Smith"),
                .init(key: "title", label: "Title", placeholder: "The Smiths of Kent"),
                .init(key: "place", label: "Publication place", placeholder: "Baltimore"),
                .init(key: "publisher", label: "Publisher", placeholder: "Genealogical Publishing"),
                .init(key: "year", label: "Year", placeholder: "1998"),
                .init(key: "page", label: "Page(s) cited", placeholder: "142")
            ]
        case .onlineDatabase:
            return [
                .init(key: "dbtitle", label: "Database / item title", placeholder: "\"England Births and Christenings, 1538–1975\""),
                .init(key: "website", label: "Website title", placeholder: "FamilySearch"),
                .init(key: "url", label: "URL", placeholder: "https://familysearch.org/…"),
                .init(key: "accessed", label: "Date accessed", placeholder: "21 August 2026"),
                .init(key: "entry", label: "Entry for", placeholder: "John Smith, 1841"),
                .init(key: "citing", label: "Citing (original source)", placeholder: "citing parish register, St Mary's, Kent")
            ]
        case .censusUS:
            return [
                .init(key: "year", label: "Census year", placeholder: "1880"),
                .init(key: "county", label: "County", placeholder: "Cook County"),
                .init(key: "state", label: "State", placeholder: "Illinois"),
                .init(key: "locality", label: "Locality / ED", placeholder: "Chicago, enumeration district 12"),
                .init(key: "page", label: "Page / dwelling / family", placeholder: "p. 4B, dwelling 55, family 60"),
                .init(key: "person", label: "Person of interest", placeholder: "John Smith household"),
                .init(key: "provider", label: "Image provider", placeholder: "digital image, Ancestry.com"),
                .init(key: "citing", label: "Citing (NARA)", placeholder: "citing NARA microfilm T9, roll 190")
            ]
        case .vitalRecord:
            return [
                .init(key: "jurisdiction", label: "Jurisdiction", placeholder: "Ohio, Hamilton County"),
                .init(key: "rectype", label: "Record type", placeholder: "death certificate"),
                .init(key: "number", label: "File / certificate no.", placeholder: "no. 45123"),
                .init(key: "year", label: "Year", placeholder: "1921"),
                .init(key: "person", label: "For (name)", placeholder: "Mary Smith"),
                .init(key: "repository", label: "Repository", placeholder: "Ohio Department of Health"),
                .init(key: "place", label: "Repository place", placeholder: "Columbus")
            ]
        case .newspaper:
            return [
                .init(key: "headline", label: "Article headline", placeholder: "Local Family Reunites After 40 Years"),
                .init(key: "paper", label: "Newspaper name", placeholder: "The Kent Gazette"),
                .init(key: "city", label: "City", placeholder: "Kent"),
                .init(key: "date", label: "Date", placeholder: "14 July 1932"),
                .init(key: "page", label: "Page / column", placeholder: "p. 3, col. 2")
            ]
        }
    }
}

public struct EECitation: Sendable {
    public let first: String
    public let subsequent: String
    public let sourceList: String
}

public enum EvidenceExplainedFormatter {

    public static func format(_ template: EETemplate, values: [String: String]) -> EECitation {
        let raw = formatRaw(template, values: values)
        func tidy(_ s: String) -> String {
            var x = s
            while x.contains("..") { x = x.replacingOccurrences(of: "..", with: ".") }
            x = x.replacingOccurrences(of: " .", with: ".")
                 .replacingOccurrences(of: " ,", with: ",")
                 .replacingOccurrences(of: ",,", with: ",")
            return x.trimmingCharacters(in: .whitespaces)
        }
        return EECitation(first: tidy(raw.first), subsequent: tidy(raw.subsequent), sourceList: tidy(raw.sourceList))
    }

    private static func formatRaw(_ template: EETemplate, values: [String: String]) -> EECitation {
        func v(_ key: String) -> String {
            (values[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Join parts, dropping empties, with a given separator.
        func join(_ parts: [String], _ sep: String) -> String {
            parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                 .filter { !$0.isEmpty }
                 .joined(separator: sep)
        }
        func invertName(_ name: String) -> String {
            let parts = name.split(separator: " ").map(String.init)
            guard parts.count >= 2, let last = parts.last else { return name }
            return "\(last), " + parts.dropLast().joined(separator: " ")
        }
        func shortTitle(_ title: String) -> String {
            let words = title.split(separator: " ")
            return words.prefix(4).joined(separator: " ")
        }

        switch template {
        case .book:
            let pub = join(["\(v("place"))", v("publisher")], ": ")
            let imprint = join([pub, v("year")], ", ")
            let first = join([
                v("author"),
                join([v("title"), imprint.isEmpty ? "" : "(\(imprint))"], " "),
                v("page").isEmpty ? "" : "p. \(v("page"))"
            ], ", ") + "."
            let subsequent = join([
                v("author").split(separator: " ").last.map(String.init) ?? v("author"),
                shortTitle(v("title")),
                v("page").isEmpty ? "" : "p. \(v("page"))"
            ], ", ") + "."
            let sourceList = join([
                invertName(v("author")),
                v("title"),
                imprint
            ], ". ") + "."
            return EECitation(first: first, subsequent: subsequent, sourceList: sourceList)

        case .onlineDatabase:
            let accessInfo = join([v("url"), v("accessed").isEmpty ? "" : "accessed \(v("accessed"))"], " : ")
            let first = join([
                v("dbtitle"),
                join([v("website"), accessInfo.isEmpty ? "" : "(\(accessInfo))"], " "),
                v("entry").isEmpty ? "" : "entry for \(v("entry"))",
                v("citing")
            ], ", ") + "."
            let subsequent = join([
                v("website"),
                v("entry").isEmpty ? "" : "entry for \(v("entry"))"
            ], ", ") + "."
            let sourceList = join([
                v("dbtitle"),
                v("website"),
                accessInfo.isEmpty ? "" : "(\(accessInfo))"
            ], ". ") + "."
            return EECitation(first: first, subsequent: subsequent, sourceList: sourceList)

        case .censusUS:
            let head = join(["\(v("year")) U.S. census", v("county"), v("state"), "population schedule"], ", ")
            let first = join([
                head,
                v("locality"),
                v("page"),
                v("person"),
                v("provider"),
                v("citing")
            ], ", ") + "."
            let subsequent = join([
                "\(v("year")) U.S. census",
                v("county"),
                v("person"),
                v("page")
            ], ", ") + "."
            let sourceList = join([
                head,
                v("provider")
            ], ". ") + "."
            return EECitation(first: first, subsequent: subsequent, sourceList: sourceList)

        case .vitalRecord:
            let first = join([
                v("jurisdiction"),
                join([v("rectype"), v("number")], " "),
                v("year").isEmpty ? "" : "(\(v("year")))",
                v("person"),
                join([v("repository"), v("place")], ", ")
            ], ", ") + "."
            let subsequent = join([
                v("jurisdiction"),
                join([v("rectype"), v("number")], " "),
                v("person")
            ], ", ") + "."
            let sourceList = join([
                v("jurisdiction"),
                "\(v("rectype"))s",
                v("repository").isEmpty ? "" : "\(v("repository")), \(v("place"))"
            ], ". ") + "."
            return EECitation(first: first, subsequent: subsequent, sourceList: sourceList)

        case .newspaper:
            let first = join([
                v("headline").isEmpty ? "" : "\"\(v("headline")),\"",
                join([v("paper"), v("city").isEmpty ? "" : "(\(v("city")))"], " "),
                v("date"),
                v("page")
            ], " ") + "."
            let subsequent = join([
                v("paper"),
                v("date")
            ], ", ") + "."
            let sourceList = join([
                v("paper"),
                v("city"),
                v("date").isEmpty ? "" : "issue of \(v("date"))"
            ], ". ") + "."
            return EECitation(first: first, subsequent: subsequent, sourceList: sourceList)
        }
    }
}
