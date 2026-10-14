//
//  NotesFormat.swift
//  Kalsmritikosh
//
//  N-9 — read the structure that notes apps put in their exported files:
//    Obsidian  [[Target]], [[Target|alias]], [[Target#Heading]], ![[embed]];
//              #tags in text and `tags:` in YAML front matter
//    Notion    exported page names end in a 32-hex id ("Plan 0f3a…e9.md");
//              links are Markdown links to those files, URL-encoded
//    Apple Notes  exported notes are plain files — no link structure to read
//  Pure functions; the notes' text is never changed.
//

import Foundation

public nonisolated enum NotesApp: String, Sendable, CaseIterable {
    case obsidian, notion, appleNotes
    public var label: String {
        switch self {
        case .obsidian: return "Obsidian vault"
        case .notion: return "Notion export"
        case .appleNotes: return "Apple Notes export"
        }
    }
}

public nonisolated enum NotesFormat {

    /// Obsidian wiki-link targets (page names, without alias or heading), in order of appearance.
    public static func wikiLinks(_ text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: #"!?\[\[([^\]\|#\n]+)(?:#[^\]\|\n]*)?(?:\|[^\]\n]*)?\]\]"#) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            let t = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? nil : t
        }
    }

    /// Inline #tags (not headings, not inside words, not pure numbers) plus YAML front-matter tags.
    public static func tags(_ text: String) -> [String] {
        var out: [String] = []
        if text.hasPrefix("---\n"), let end = text.range(of: "\n---", range: text.index(text.startIndex, offsetBy: 4)..<text.endIndex) {
            let yaml = text[text.index(text.startIndex, offsetBy: 4)..<end.lowerBound]
            var inTags = false
            for line in yaml.split(separator: "\n") {
                let l = line.trimmingCharacters(in: .whitespaces)
                if l.hasPrefix("tags:") {
                    let rest = l.dropFirst(5).trimmingCharacters(in: .whitespaces)
                    if rest.isEmpty { inTags = true; continue }
                    out += rest.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).split(separator: ",")
                        .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"'#")) }
                    inTags = false
                } else if inTags, l.hasPrefix("- ") {
                    out.append(l.dropFirst(2).trimmingCharacters(in: CharacterSet(charactersIn: " \"'#")))
                } else { inTags = false }
            }
        }
        if let re = try? NSRegularExpression(pattern: #"(?:^|[\s(])#([\p{L}\p{N}_/\-]*\p{L}[\p{L}\p{N}_/\-]*)"#) {
            let ns = text as NSString
            out += re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
        }
        var seen = Set<String>()
        return out.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    /// A Notion page title without its trailing 32-hex id ("Plan 0f3a…e9" → "Plan").
    public static func notionTitle(_ stem: String) -> String {
        guard let re = try? NSRegularExpression(pattern: #"\s+[0-9a-f]{32}$"#) else { return stem }
        let ns = stem as NSString
        return re.stringByReplacingMatches(in: stem, range: NSRange(location: 0, length: ns.length), withTemplate: "")
    }

    /// Targets of Markdown links to local .md files (decoded, file stem only).
    public static func markdownFileLinks(_ text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: #"\[[^\]]*\]\(([^)\s]+\.md)\)"#) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            let raw = ns.substring(with: m.range(at: 1))
            guard !raw.contains("://") else { return nil }
            let decoded = raw.removingPercentEncoding ?? raw
            return ((decoded as NSString).lastPathComponent as NSString).deletingPathExtension
        }
    }

    /// Best guess of which app produced a folder, from its file names and contents.
    public static func detect(fileNames: [String], hasObsidianFolder: Bool, sampleText: String) -> NotesApp {
        if hasObsidianFolder || !wikiLinks(sampleText).isEmpty { return .obsidian }
        let hex = fileNames.filter { notionTitle(($0 as NSString).deletingPathExtension) != ($0 as NSString).deletingPathExtension }
        if !fileNames.isEmpty, hex.count * 2 >= fileNames.count { return .notion }
        return .appleNotes
    }

    /// Normalised key for resolving a link to a note: lowercase stem, Notion id removed.
    public static func key(_ stem: String) -> String {
        notionTitle(stem).lowercased().trimmingCharacters(in: .whitespaces)
    }
}
