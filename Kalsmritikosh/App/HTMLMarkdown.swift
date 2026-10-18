//
//  HTMLMarkdown.swift
//  Kalsmritikosh
//
//  X-4 — a Markdown rendering of a clipped web page ("Clip page as Markdown"). The page's
//  readable part is taken (navigation, scripts, styles, forms and footers dropped), read
//  with the system's HTML reader, and written as Markdown: headings by size, bold, italic,
//  links, list bullets, paragraphs. The clipped HTML itself is always kept as well; this is
//  an extra, easier-to-read copy. No library, no network (remote images are not loaded).
//

import AppKit
import Foundation

@MainActor
enum HTMLMarkdown {
    /// Elements that are never the readable part of a page.
    static let droppedElements = ["script", "style", "noscript", "nav", "header", "footer", "aside", "form",
                                  "iframe", "svg", "button", "template"]

    /// The page's main content: <article> or <main> when present, else <body>, with the
    /// dropped elements removed and images reduced to their alt text (so nothing is loaded).
    static func readablePart(of html: String) -> String {
        var s = html
        for tag in droppedElements {
            s = s.replacingOccurrences(of: "<\(tag)\\b[^>]*>[\\s\\S]*?</\(tag)>", with: " ",
                                       options: [.regularExpression, .caseInsensitive])
        }
        s = s.replacingOccurrences(of: "<img\\b[^>]*\\balt\\s*=\\s*\"([^\"]*)\"[^>]*>", with: "$1",
                                   options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<(img|link|video|audio|source|picture)\\b[^>]*>", with: " ",
                                   options: [.regularExpression, .caseInsensitive])
        for container in ["article", "main", "body"] {
            if let r = s.range(of: "<\(container)\\b[^>]*>([\\s\\S]*)</\(container)>", options: [.regularExpression, .caseInsensitive]) {
                return String(s[r])
            }
        }
        return s
    }

    /// Markdown for `html`, headed by the title and the source address.
    static func markdown(fromHTML html: String, title: String, sourceURL: String) -> String {
        let readable = readablePart(of: html)
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]
        let body: String
        if let attributed = try? NSAttributedString(data: Data(readable.utf8), options: options, documentAttributes: nil) {
            body = markdown(from: attributed)
        } else {
            body = readable.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        }
        var head = "# \(title.isEmpty ? "Web page" : title)\n\n"
        if !sourceURL.isEmpty { head += "Source: <\(sourceURL)>\n\n" }
        return head + body.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    /// Walk the attributed string paragraph by paragraph.
    static func markdown(from text: NSAttributedString) -> String {
        let ns = text.string as NSString
        var out: [String] = []
        var location = 0
        while location < ns.length {
            let para = ns.paragraphRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(para)
            let raw = ns.substring(with: para).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { continue }
            let size = (text.attribute(.font, at: para.location, effectiveRange: nil) as? NSFont)?.pointSize ?? 12
            var line = inline(text.attributedSubstring(from: para)).trimmingCharacters(in: .whitespacesAndNewlines)
            let isList = raw.hasPrefix("•") || raw.hasPrefix("◦") || raw.hasPrefix("▪") || raw.range(of: "^\\d+[.)]\\s", options: .regularExpression) != nil
            if isList {
                line = line.replacingOccurrences(of: "^[•◦▪]\\s*", with: "", options: .regularExpression)
                out.append(raw.first?.isNumber == true ? line : "- " + line)
            } else if size >= 22 {
                out.append("# " + raw)
            } else if size >= 17 {
                out.append("## " + raw)
            } else if size >= 14.5 {
                out.append("### " + raw)
            } else {
                out.append(line)
            }
        }
        return out.joined(separator: "\n\n").replacingOccurrences(of: "\n\n- ", with: "\n- ")
    }

    /// Bold, italic and links within one paragraph.
    static func inline(_ para: NSAttributedString) -> String {
        var result = ""
        para.enumerateAttributes(in: NSRange(location: 0, length: para.length)) { attrs, range, _ in
            var piece = (para.string as NSString).substring(with: range).replacingOccurrences(of: "\n", with: " ")
            guard !piece.trimmingCharacters(in: .whitespaces).isEmpty else { result += piece; return }
            let traits = (attrs[.font] as? NSFont).map { NSFontManager.shared.traits(of: $0) } ?? []
            let lead = String(piece.prefix { $0 == " " }), trail = String(piece.reversed().prefix { $0 == " " })
            piece = piece.trimmingCharacters(in: .whitespaces)
            if traits.contains(.boldFontMask) { piece = "**\(piece)**" }
            if traits.contains(.italicFontMask) { piece = "*\(piece)*" }
            if let link = attrs[.link] {
                let target = (link as? URL)?.absoluteString ?? (link as? String) ?? ""
                if !target.isEmpty, !target.hasPrefix("javascript:") { piece = "[\(piece)](\(target))" }
            }
            result += lead + piece + trail
        }
        return result
    }
}
