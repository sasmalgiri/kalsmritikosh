//
//  ForumThreadMapper.swift
//  Kalsmritikosh
//
//  DISC-7 — saved forum threads (phpBB, vBulletin, XenForo, Discourse).
//
//  A saved forum page already ingests as an HTML document, so its words are
//  searchable. What is missing is the thing that makes a discussion evidence:
//  WHO said WHICH part, and WHEN. This mapper recovers per-post attribution.
//
//  HOW IT AVOIDS THE DEFECT THAT MATTERS. Splitting HTML by markers and then
//  hunting for the nearest author is exactly how a body ends up attributed to
//  the PREVIOUS person — the same defect found in chat exports in DISC-6, where
//  system notices were appended to the last speaker's message. So the rule here
//  is strict: the page is cut into slices at the post-container marker itself,
//  and a post's author, time and body may only come from INSIDE its own slice.
//  A slice with no author marker yields an UNATTRIBUTED record; it never
//  inherits the name above it. A test pins that.
//
//  WHAT IT WILL NOT DO: claim a page that carries no platform marker. Forum
//  themes vary without limit, and a generic "find the repeated blocks" heuristic
//  would attribute text to people on pages that are not forums at all. Without a
//  marker the file stays an HTML document, which is a working parse — not a gap.
//
//  Dates come from HTML5 `<time datetime="…">`, which every one of these
//  platforms emits and which is unambiguous ISO-8601. A post whose slice has no
//  `<time>` is recorded as undated rather than given the thread's date.
//

import Foundation

public struct ForumThreadMapper: DiscussionExportMapper {
    public nonisolated var platform: String { "Forum" }
    public nonisolated var mapperVersion: String { "1" }

    public nonisolated init() {}

    /// A forum engine, identified by a marker it emits regardless of theme.
    enum Engine: String, CaseIterable {
        case phpBB, vBulletin, xenForo, discourse

        /// Markers that identify the ENGINE. Deliberately specific: each is a
        /// class or attribute the software generates, not something a theme
        /// author would coin.
        var engineMarkers: [String] {
            switch self {
            case .phpBB: return ["class=\"postbody\"", "phpbb", "class=\"postprofile\""]
            case .vBulletin: return ["id=\"post_message_", "vbulletin"]
            case .xenForo: return ["data-author=", "js-post-", "xenforo"]
            case .discourse: return ["class=\"topic-post", "data-post-number=", "discourse"]
            }
        }

        /// The marker that begins ONE post. Slicing happens here, so it must be
        /// the OUTER container — the element that encloses both the author block
        /// and the body block. phpBB and vBulletin put the author in a SIBLING of
        /// the body (`postprofile` next to `postbody`), so slicing at the body
        /// would put the author outside its own post's slice and leave every
        /// record unattributed.
        ///
        /// Tried in order; the FIRST marker that matches anything is the one
        /// used, so a theme that omits the outer container still slices on the
        /// inner one rather than mixing the two and double-counting posts.
        var postMarkers: [String] {
            switch self {
            case .phpBB: return ["class=\"post\"", "class=\"post ", "class=\"postbody\""]
            case .vBulletin: return ["class=\"postcontainer\"", "id=\"post_message_"]
            case .xenForo: return ["data-author="]
            case .discourse: return ["data-post-number="]
            }
        }

        var display: String {
            switch self {
            case .phpBB: return "phpBB"
            case .vBulletin: return "vBulletin"
            case .xenForo: return "XenForo"
            case .discourse: return "Discourse"
            }
        }
    }

    public nonisolated func claims(filename: String, sample: Data) -> Bool {
        guard let text = String(data: sample, encoding: .utf8)
                ?? String(data: sample, encoding: .isoLatin1) else { return false }
        let lowered = text.lowercased()
        // Must look like HTML AND carry an engine marker. Either alone is not
        // enough: a plain page is a document, and the word "phpbb" in prose is
        // not a forum.
        guard lowered.contains("<html") || lowered.contains("<!doctype html")
                || lowered.contains("<div") else { return false }
        return Self.detectEngine(in: lowered) != nil
    }

    nonisolated static func detectEngine(in loweredHTML: String) -> Engine? {
        for engine in Engine.allCases {
            // BOTH are required: an ENGINE marker (something the software emits,
            // which `class="post"` alone is not — any blog uses that) and a POST
            // marker, because a page that merely mentions the software has
            // nothing to map.
            let engineSeen = engine.engineMarkers.contains {
                loweredHTML.contains($0.lowercased())
            }
            let postSeen = engine.postMarkers.contains {
                loweredHTML.contains($0.lowercased())
            }
            if engineSeen, postSeen { return engine }
        }
        return nil
    }

    public nonisolated func map(data: Data, filename: String) -> DiscussionExport {
        var warnings: [ParserWarning] = []
        guard let html = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else {
            warnings.append(ParserWarning(severity: .error, code: "forum.unreadable",
                message: "This saved page could not be decoded as text."))
            return DiscussionExport(platform: platform, artifact: filename,
                                    records: [], warnings: warnings)
        }
        let lowered = html.lowercased()
        guard let engine = Self.detectEngine(in: lowered) else {
            warnings.append(ParserWarning(severity: .warning, code: "forum.no_engine",
                message: "No forum-engine marker was found, so no per-post attribution was "
                       + "attempted. The page's text is still ingested as an HTML document."))
            return DiscussionExport(platform: platform, artifact: filename,
                                    records: [], warnings: warnings)
        }

        let threadTitle = Self.title(in: html)
        let slices = Self.postSlices(in: html, lowered: lowered, engine: engine)
        var records: [DiscussionRecord] = []
        var unattributed = 0
        var undated = 0

        for (index, slice) in slices.enumerated() {
            let body = Self.plainText(slice)
            guard !body.isEmpty else { continue }
            // Author and time from THIS slice only. Nothing is inherited.
            let author = Self.author(in: slice, engine: engine)
            let timestamp = Self.time(in: slice)
            if author == nil { unattributed += 1 }
            if timestamp == nil { undated += 1 }

            records.append(DiscussionRecord(
                platform: "\(platform) (\(engine.display))",
                kind: index == 0 ? .post : .reply,
                // Position-based and zero-padded: the page carries no stable
                // platform id we can trust across saves, and ORDER is the
                // evidence a thread provides.
                recordID: String(format: "%@#%05d", filename, index + 1),
                threadID: filename, threadTitle: threadTitle,
                authorHandle: author, timestamp: timestamp, body: body))
        }

        if records.isEmpty {
            warnings.append(ParserWarning(severity: .warning, code: "forum.no_posts",
                message: "A \(engine.display) marker was found but no post produced readable "
                       + "text, so nothing was mapped."))
        }
        if unattributed > 0 {
            warnings.append(ParserWarning(severity: .warning, code: "forum.unattributed_posts",
                message: "\(unattributed) of \(records.count) post(s) carry no author name inside "
                       + "their own block and are recorded as unattributed. They are NOT "
                       + "attributed to the previous poster, which is what a nearest-name search "
                       + "would have done."))
        }
        if undated > 0 {
            warnings.append(ParserWarning(severity: .warning, code: "forum.undated_posts",
                message: "\(undated) of \(records.count) post(s) carry no machine-readable "
                       + "<time> element, so they keep their position in the thread but no date. "
                       + "A displayed date like \"2 hours ago\" is relative to when the page was "
                       + "saved and is not converted into a timestamp."))
        }
        return DiscussionExport(platform: "\(platform) (\(engine.display))",
                                artifact: filename, records: records, warnings: warnings)
    }

    // MARK: - Slicing

    /// Cut the page at each post-container marker. The slice is the marker's
    /// occurrence up to the next one (or the end), so a post's fields can only
    /// be read from its own region.
    nonisolated static func postSlices(in html: String, lowered: String,
                                       engine: Engine) -> [String] {
        var starts: [String.Index] = []
        for marker in engine.postMarkers {
            let needle = marker.lowercased()
            var search = lowered.startIndex
            while let found = lowered.range(of: needle, range: search..<lowered.endIndex) {
                starts.append(found.lowerBound)
                search = found.upperBound
            }
            // First marker that matches wins. Combining markers would split one
            // post at both its outer and inner container and report it twice.
            if !starts.isEmpty { break }
        }
        guard !starts.isEmpty else { return [] }
        starts.sort()

        var out: [String] = []
        for (index, start) in starts.enumerated() {
            let end = index + 1 < starts.count ? starts[index + 1] : html.endIndex
            guard start < end else { continue }
            // Back up to the start of the enclosing tag so the container's own
            // attributes (author, post number) are inside the slice.
            var from = start
            var steps = 0
            while from > html.startIndex, steps < 400 {
                let previous = html.index(before: from)
                if html[previous] == "<" { from = previous; break }
                from = previous
                steps += 1
            }
            out.append(String(html[from..<end]))
        }
        return out
    }

    // MARK: - Fields, each read only from its own slice

    nonisolated static func author(in slice: String, engine: Engine) -> String? {
        /// An empty result is NO author, never `Optional("")`: an empty handle
        /// would pass the nil check and quietly defeat both the unattributed
        /// count and its warning.
        func named(_ raw: String?) -> String? {
            guard let text = clean(raw), !text.isEmpty else { return nil }
            return text
        }
        // XenForo puts the author in the container attribute itself.
        if let value = named(attribute("data-author", in: slice)) { return value }
        // Discourse and schema.org markup.
        if let value = named(firstMatch(in: slice, opening: "itemprop=\"author\"")) { return value }
        // phpBB / vBulletin use a username class on a link.
        for token in ["class=\"username\"", "class=\"username-coloured\"",
                      "class=\"author\"", "class=\"post-author\"", "class=\"creator\""] {
            if let value = named(firstMatch(in: slice, opening: token)) { return value }
        }
        _ = engine
        return nil
    }

    /// The first `<time datetime="…">` in the slice. HTML5 and unambiguous; a
    /// human-readable "2 hours ago" is deliberately NOT parsed, because it is
    /// relative to when the page was saved and converting it would invent a date.
    nonisolated static func time(in slice: String) -> Date? {
        guard let raw = attribute("datetime", in: slice) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: trimmed) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: trimmed) { return date }
        // Some themes emit a bare date.
        let dayOnly = DateFormatter()
        dayOnly.dateFormat = "yyyy-MM-dd"
        dayOnly.timeZone = TimeZone(secondsFromGMT: 0)
        dayOnly.locale = Locale(identifier: "en_US_POSIX")
        return dayOnly.date(from: trimmed)
    }

    nonisolated static func title(in html: String) -> String? {
        guard let open = html.range(of: "<title", options: .caseInsensitive),
              let gt = html.range(of: ">", range: open.upperBound..<html.endIndex),
              let close = html.range(of: "</title>", options: .caseInsensitive,
                                     range: gt.upperBound..<html.endIndex) else { return nil }
        let text = clean(String(html[gt.upperBound..<close.lowerBound]))
        return text?.isEmpty == false ? text : nil
    }

    /// Value of `name="value"` or `name='value'`, first occurrence.
    nonisolated static func attribute(_ name: String, in slice: String) -> String? {
        for quote in ["\"", "'"] {
            let needle = "\(name)=\(quote)"
            guard let start = slice.range(of: needle, options: .caseInsensitive) else { continue }
            guard let end = slice.range(of: quote, range: start.upperBound..<slice.endIndex)
            else { continue }
            let value = String(slice[start.upperBound..<end.lowerBound])
            if !value.isEmpty { return value }
        }
        return nil
    }

    /// The text immediately following a marker, up to the closing tag — how a
    /// username sits inside `<a class="username">Name</a>`.
    nonisolated static func firstMatch(in slice: String, opening: String) -> String? {
        guard let marker = slice.range(of: opening, options: .caseInsensitive),
              let gt = slice.range(of: ">", range: marker.upperBound..<slice.endIndex),
              let lt = slice.range(of: "<", range: gt.upperBound..<slice.endIndex)
        else { return nil }
        return String(slice[gt.upperBound..<lt.lowerBound])
    }

    /// Tags removed, entities resolved, whitespace collapsed. Script and style
    /// contents are dropped rather than joining the post text as code.
    nonisolated static func plainText(_ html: String) -> String {
        var text = html
        for tag in ["script", "style"] {
            while let open = text.range(of: "<\(tag)", options: .caseInsensitive),
                  let close = text.range(of: "</\(tag)>", options: .caseInsensitive,
                                         range: open.upperBound..<text.endIndex) {
                text.removeSubrange(open.lowerBound..<close.upperBound)
            }
        }
        // Block boundaries become spaces so words do not run together.
        for tag in ["<br", "</p", "</div", "</li", "</blockquote"] {
            text = text.replacingOccurrences(of: tag, with: " \(tag)", options: .caseInsensitive)
        }
        var out = ""
        var insideTag = false
        for character in text {
            if character == "<" { insideTag = true; continue }
            if character == ">" { insideTag = false; out.append(" "); continue }
            if !insideTag { out.append(character) }
        }
        return clean(out) ?? ""
    }

    nonisolated static func clean(_ raw: String?) -> String? {
        guard var text = raw else { return nil }
        for (entity, replacement) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
                                      ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
                                      ("&nbsp;", " ")] {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
