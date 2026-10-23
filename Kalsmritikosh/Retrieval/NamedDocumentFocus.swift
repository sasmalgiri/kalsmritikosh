//
//  NamedDocumentFocus.swift
//  Kalsmritikosh
//
//  Named-document focus. An archive holds many documents of the same kind (a dozen court
//  decisions, a year of press releases, a folder of claim files). When the question NAMES one
//  of them — by its caption ("Hughes v. Life Insurance Co."), a quoted title, a file name, or a
//  reference/citation number — the answer must come from that document, not from a sibling
//  that happens to carry the same kind of field (case bench round 4: "Opinion by: Barker" from
//  another decision, or a "conflict" averaged across four decisions' authors).
//
//  The rule is deliberately conservative ("never guess"):
//    * a naming is read from the question by shape only — no document type, no domain list;
//    * a candidate document matches only when the naming appears in its HEAD (title, subject,
//      file name, first line, or the opening window of its text) — a name cited in the body of
//      another document is never a match;
//    * focus applies only when exactly ONE document (an email and its attachment count as one)
//      matches at the strongest level found. Zero or several → the retrieval is unchanged.
//
//  PURE: question + RetrievalResult + per-object heads in, narrowed RetrievalResult out. No DB,
//  no model, no clock. The caller (MasterBrain) reads the heads from the ledger.
//

import Foundation

/// One candidate document's identifying head, as the focus step reads it.
public nonisolated struct NamedDocumentHead: Sendable, Hashable {
    public let objectID: UUID
    /// Objects sharing a family key are ONE document for focus purposes (an email and the file
    /// attached to it). Defaults to the object itself.
    public let familyKey: UUID
    /// A recorded title / subject, when the source carries one.
    public let title: String?
    /// The source file's name ("decision.pdf").
    public let fileName: String?
    /// The opening text of the document (its caption area).
    public let headText: String

    public nonisolated init(objectID: UUID, familyKey: UUID? = nil, title: String? = nil,
                            fileName: String? = nil, headText: String) {
        self.objectID = objectID
        self.familyKey = familyKey ?? objectID
        self.title = title
        self.fileName = fileName
        self.headText = headText
    }
}

/// The narrowed retrieval plus which document was chosen and why.
public nonisolated struct NamedDocumentFocusOutcome: Sendable {
    public let result: RetrievalResult
    /// The candidate objects kept (the named document and any attachment of it).
    public let focusedObjectIDs: [UUID]
    /// A reader-facing label for the document (its title, first line or file name).
    public let documentLabel: String
    public let naming: NamedDocumentFocus.Naming
    /// The naming as it appears in the question.
    public let namedAs: String

    /// The answer-path note: "Focused on <document> because the question names it …".
    public var note: String {
        "Focused on “\(documentLabel)” because the question names it (\(naming.phrase) “\(namedAs)”); "
            + "other documents were set aside for this answer."
    }
}

public nonisolated enum NamedDocumentFocus {

    public nonisolated enum Naming: String, Sendable, Hashable {
        case caption, quotedTitle, fileName, citation
        public nonisolated var phrase: String {
            switch self {
            case .caption:     return "by its caption"
            case .quotedTitle: return "by its title"
            case .fileName:    return "by its file name"
            case .citation:    return "by its reference"
            }
        }
    }

    /// Characters of document text that count as the head (caption area).
    public nonisolated static let headWindow = 800

    /// Match strength: a naming found in a title line beats one found in the opening window.
    private nonisolated static let titleStrength = 3
    private nonisolated static let headStrength = 2

    // MARK: - Candidates and families

    /// The distinct documents a retrieval surfaced, in first-seen order.
    public nonisolated static func candidateObjectIDs(in result: RetrievalResult) -> [UUID] {
        var seen = Set<UUID>()
        var out: [UUID] = []
        func add(_ id: UUID) { if seen.insert(id).inserted { out.append(id) } }
        result.chunks.forEach { add($0.chunk.objectID) }
        result.events.forEach { add($0.sourceObjectID) }
        result.authorityObjectIDs.forEach(add)
        result.claimEvaluations.forEach { $0.evidence.forEach { add($0.objectID) } }
        for s in result.summaries { if case .document(let id) = s.scope { add(id) } }
        return out
    }

    /// The family key for one object: an attachment belongs to the document that carries it, when
    /// that parent file holds exactly one object (an email); objects of a multi-object file (the
    /// messages of a mailbox) stay separate documents.
    public nonisolated static func familyKey(objectID: UUID, fileID: UUID?, fileObjectCount: Int,
                                             parentFileID: UUID?, parentFileObjectCount: Int) -> UUID {
        if let parentFileID, parentFileObjectCount == 1 { return parentFileID }
        if let fileID, fileObjectCount == 1 { return fileID }
        return objectID
    }

    // MARK: - Focus

    /// Narrow `result` to the one document the question names, or nil (unchanged) when the question
    /// names none, nothing matches, several documents match equally, or the narrowed result would
    /// hold no passage to answer from.
    public nonisolated static func focus(question: String, result: RetrievalResult,
                                         heads: [NamedDocumentHead]) -> NamedDocumentFocusOutcome? {
        guard !asksAcrossDocuments(question) else { return nil }
        let mentions = namings(in: question)
        guard !mentions.isEmpty, !heads.isEmpty else { return nil }
        let docs = heads.map(Prepared.init)

        // Best strength per family, and the naming that produced it.
        var familyScore: [UUID: (score: Int, mention: Mention, doc: Prepared)] = [:]
        for doc in docs {
            for m in mentions {
                let s = m.strength(in: doc)
                guard s > 0 else { continue }
                if let cur = familyScore[doc.head.familyKey], cur.score >= s { continue }
                familyScore[doc.head.familyKey] = (s, m, doc)
            }
        }
        guard let top = familyScore.values.map(\.score).max() else { return nil }
        let winners = familyScore.filter { $0.value.score == top }
        guard winners.count == 1, let (family, win) = winners.first else { return nil }

        let members = Set(heads.filter { $0.familyKey == family }.map(\.objectID))
        let narrowed = narrow(result, to: members)
        guard !narrowed.chunks.isEmpty else { return nil }               // nothing left to answer from
        let removedSomething = narrowed.chunks.count != result.chunks.count
            || narrowed.genericFacts.count != result.genericFacts.count
            || narrowed.claimEvaluations.count != result.claimEvaluations.count
            || narrowed.events.count != result.events.count
        guard removedSomething else { return nil }                       // already only that document

        let kept = candidateObjectIDs(in: narrowed).filter(members.contains)
        return NamedDocumentFocusOutcome(result: narrowed, focusedObjectIDs: kept,
                                         documentLabel: win.doc.label, naming: win.mention.naming,
                                         namedAs: win.mention.display)
    }

    /// Keep only what is anchored to `objects`. Facts and claim evaluations survive when any of their
    /// evidence lies in the kept documents (a merged fact also stated there is still stated there);
    /// summaries survive only when document-scoped to a kept document.
    public nonisolated static func narrow(_ result: RetrievalResult, to objects: Set<UUID>) -> RetrievalResult {
        let chunks = result.chunks.filter { objects.contains($0.chunk.objectID) }
        var blockObject: [UUID: UUID] = [:]
        for c in result.chunks { for b in blocks(of: c.chunk) where blockObject[b] == nil { blockObject[b] = c.chunk.objectID } }
        let facts = result.genericFacts.filter { f in f.sourceBlockIDs.contains { blockObject[$0].map(objects.contains) ?? false } }
        let factIDs = Set(facts.map(\.id))
        let allFactIDs = Set(result.genericFacts.map(\.id))
        let evaluations = result.claimEvaluations.filter { e in
            if factIDs.contains(e.id) { return true }
            if allFactIDs.contains(e.id) { return false }
            return e.evidence.contains { objects.contains($0.objectID) }
        }
        let summaries = result.summaries.filter { s in
            if case .document(let id) = s.scope { return objects.contains(id) }
            return false
        }
        return RetrievalResult(
            chunks: chunks,
            events: result.events.filter { objects.contains($0.sourceObjectID) },
            entities: result.entities.filter { objects.contains($0.sourceObjectID) },
            relationships: result.relationships.filter { objects.contains($0.sourceObjectID) },
            summaries: summaries,
            layersUsed: result.layersUsed, shortCircuitedAt: result.shortCircuitedAt,
            walkSteps: result.walkSteps.filter { $0.evidenceObjectIDs.contains(where: objects.contains) },
            genericFacts: facts, claimEvaluations: evaluations,
            authorityObjectIDs: result.authorityObjectIDs.filter(objects.contains))
    }

    /// A question that asks ACROSS documents ("which documents cite …", "list all files …") is not
    /// about one named document, even when it carries a name or a number.
    nonisolated static func asksAcrossDocuments(_ question: String) -> Bool {
        let q = question.lowercased()
        let nouns = ["documents", "files", "emails", "records", "sources", "cases", "decisions", "messages"]
        let openers = ["which", "all", "every", "how many", "list", "other", "across"]
        for n in nouns {
            for o in openers where q.contains("\(o) \(n)") || q.contains("\(o) the \(n)") || q.contains("\(o) of the \(n)") {
                return true
            }
        }
        return q.contains("every document") || q.contains("each document")
    }

    /// Every block a chunk was assembled from (its recorded lineage, else its primary block).
    private nonisolated static func blocks(of c: Chunk) -> [UUID] {
        c.evidenceBlockIDs.isEmpty ? (c.evidenceBlockID.map { [$0] } ?? []) : c.evidenceBlockIDs
    }

    // MARK: - Namings read from the question

    nonisolated struct Mention: Sendable {
        let naming: Naming
        let display: String
        /// caption sides / in-re subject (significant tokens)
        let sideA: [String]
        let sideB: [String]
        /// quoted title / citation / file name tokens
        let tokens: [String]

        nonisolated func strength(in doc: Prepared) -> Int {
            switch naming {
            case .caption:
                if sideB.isEmpty {   // "In re A" / "Matter of A"
                    if doc.titleLines.contains(where: { NamedDocumentFocus.inReMatch($0, sideA) }) { return titleStrength }
                    return NamedDocumentFocus.inReMatch(doc.headTokens, sideA) ? headStrength : 0
                }
                if doc.titleLines.contains(where: { NamedDocumentFocus.captionMatch($0, sideA, sideB) }) { return titleStrength }
                return NamedDocumentFocus.captionMatch(doc.headTokens, sideA, sideB) ? headStrength : 0
            case .quotedTitle:
                if doc.titleLines.contains(where: { line in
                    NamedDocumentFocus.containsRun(line, tokens) && tokens.count * 2 >= line.count }) { return titleStrength }
                return tokens.count >= 3 && NamedDocumentFocus.containsRun(doc.headTokens, tokens) ? headStrength : 0
            case .fileName:
                return doc.fileTokens == tokens ? titleStrength : 0
            case .citation:
                if doc.titleLines.contains(where: { NamedDocumentFocus.containsRun($0, tokens) }) { return titleStrength }
                return NamedDocumentFocus.containsRun(doc.headTokens, tokens) ? headStrength : 0
            }
        }
    }

    nonisolated static func namings(in question: String) -> [Mention] {
        var out: [Mention] = []
        out += captionMentions(in: question)
        let quoted = quotedSpans(in: question)
        for q in quoted {
            let t = tokens(q)
            if fileNameShape(q) { out.append(Mention(naming: .fileName, display: q, sideA: [], sideB: [], tokens: t)) }
            else if t.count >= 2 { out.append(Mention(naming: .quotedTitle, display: q, sideA: [], sideB: [], tokens: t)) }
        }
        for f in fileNames(in: question) where !quoted.contains(where: { $0.localizedCaseInsensitiveContains(f) }) {
            out.append(Mention(naming: .fileName, display: f, sideA: [], sideB: [], tokens: tokens(f)))
        }
        for c in citations(in: question) {
            out.append(Mention(naming: .citation, display: c, sideA: [], sideB: [], tokens: tokens(c)))
        }
        return out
    }

    // Caption: "A v. B", "A vs. B", "A versus B", "In re A", "Matter of A".
    private nonisolated static let connectors: Set<String> = ["of", "the", "and", "&", "de", "la", "le", "von", "van",
                                                              "du", "del", "der", "ex", "rel", "rel.", "for", "on", "in"]
    private nonisolated static let questionWords: Set<String> = [
        "when", "who", "what", "which", "where", "why", "how", "did", "does", "do", "was", "were", "is", "are",
        "in", "summarize", "summarise", "tell", "describe", "explain", "list", "show", "give", "find", "according"]
    /// Generic party words that carry no identity ("Co.", "Inc.", "et al.").
    private nonisolated static let genericPartyTokens: Set<String> = [
        "of", "the", "and", "a", "an", "et", "al", "inc", "incorporated", "co", "company", "corp", "corporation",
        "llc", "ltd", "limited", "plc", "lp", "llp", "for", "in", "on", "at", "to", "de", "la", "rel", "ex"]

    nonisolated static func captionMentions(in question: String) -> [Mention] {
        let lower = question.lowercased()
        if lower.contains("compare") || lower.contains("comparison") || lower.contains("difference between") { return [] }
        let words = question.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).map(String.init)
        var out: [Mention] = []
        for (i, w) in words.enumerated() {
            let bare = w.lowercased().trimmingCharacters(in: .punctuationCharacters)
            if ["v", "vs", "versus"].contains(bare), i > 0, i < words.count - 1 {
                let left = partyRun(words, from: i - 1, step: -1)
                let right = partyRun(words, from: i + 1, step: 1)
                let a = significant(left.joined(separator: " ")), b = significant(right.joined(separator: " "))
                guard !a.isEmpty, !b.isEmpty else { continue }
                let display = (left + [w] + right).joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: ",?.;:"))
                out.append(Mention(naming: .caption, display: display, sideA: a, sideB: b, tokens: []))
            }
            // "In re A" / "Matter of A" — capitalized forms only ("a matter of time" is not a caption).
            let isInRe = (w == "In" || w == "in") && i + 1 < words.count && words[i + 1].lowercased() == "re"
            let isMatter = w == "Matter" && i + 1 < words.count && words[i + 1].lowercased() == "of"
            if isInRe || isMatter {
                let name = partyRun(words, from: i + 2, step: 1)
                let a = significant(name.joined(separator: " "))
                guard !a.isEmpty else { continue }
                let display = ([w, words[i + 1]] + name).joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: ",?.;:"))
                out.append(Mention(naming: .caption, display: display, sideA: a, sideB: [], tokens: []))
            }
        }
        return out
    }

    /// The party name next to a "v." — a run of capitalized words (and name connectors), read away
    /// from the "v.". Falls back to one adjacent content word for an all-lowercase question.
    private nonisolated static func partyRun(_ words: [String], from start: Int, step: Int) -> [String] {
        var run: [String] = []
        var i = start
        let corporateSuffix: Set<String> = ["inc", "inc.", "llc", "ltd", "ltd.", "co", "co.", "corp", "corp.", "l.l.c."]
        while i >= 0, i < words.count, run.count < 9 {
            let w = words[i]
            let bare = w.trimmingCharacters(in: .punctuationCharacters)
            guard !bare.isEmpty else { break }
            if step < 0, i == 0, questionWords.contains(bare.lowercased()) { break }
            let capitalized = bare.first.map { $0.isUppercase } ?? false
            let connector = connectors.contains(bare.lowercased())
            guard capitalized || connector else { break }
            if step < 0 { run.insert(w, at: 0) } else { run.append(w) }
            // A comma or question mark ends the right-hand party ("…of North America, 112 F. Supp…"),
            // unless a corporate suffix follows ("Smith, Inc.").
            if step > 0, w.hasSuffix(",") || w.hasSuffix("?") || w.hasSuffix(";") || w.hasSuffix(":") {
                if w.hasSuffix(","), i + 1 < words.count, corporateSuffix.contains(words[i + 1].lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ",?"))) {
                    i += step; continue
                }
                break
            }
            if step < 0, i - 1 >= 0, words[i - 1].hasSuffix("?") { break }
            i += step
        }
        // Trim name connectors at the outer edge ("in Pinching" → "Pinching").
        while let first = run.first, connectors.contains(first.lowercased().trimmingCharacters(in: .punctuationCharacters)) { run.removeFirst() }
        while let last = run.last, connectors.contains(last.lowercased().trimmingCharacters(in: .punctuationCharacters)) { run.removeLast() }
        if run.isEmpty, start >= 0, start < words.count {
            let bare = words[start].trimmingCharacters(in: .punctuationCharacters)
            if bare.count >= 3, bare.allSatisfy(\.isLetter), !questionWords.contains(bare.lowercased()),
               !genericPartyTokens.contains(bare.lowercased()), !connectors.contains(bare.lowercased()) {
                run = [words[start]]
            }
        }
        return run
    }

    private nonisolated static func significant(_ text: String) -> [String] {
        tokens(text).filter { !genericPartyTokens.contains($0) && !$0.allSatisfy(\.isNumber) }
    }

    // Quoted spans: "…", “…”, «…».
    nonisolated static func quotedSpans(in question: String) -> [String] {
        var out: [String] = []
        let pairs: [(Character, Character)] = [("\"", "\""), ("“", "”"), ("«", "»")]
        for (open, close) in pairs {
            var rest = Substring(question)
            while let o = rest.firstIndex(of: open) {
                let after = rest[rest.index(after: o)...]
                guard let c = after.firstIndex(of: close) else { break }
                let span = after[..<c].trimmingCharacters(in: .whitespacesAndNewlines)
                if span.count >= 4 { out.append(span) }
                rest = after[after.index(after: c)...]
            }
        }
        return out
    }

    private nonisolated static let fileExtensions: Set<String> = [
        "pdf", "doc", "docx", "rtf", "txt", "md", "markdown", "pages", "odt", "eml", "emlx", "msg", "mbox", "pst",
        "html", "htm", "xml", "json", "csv", "tsv", "xls", "xlsx", "numbers", "ppt", "pptx", "key", "epub",
        "jpg", "jpeg", "png", "heic", "tif", "tiff", "gif", "zip", "vcf", "ics", "log", "sqlite", "db"]

    nonisolated static func fileNameShape(_ s: String) -> Bool {
        guard let dot = s.lastIndex(of: "."), dot != s.startIndex else { return false }
        let ext = s[s.index(after: dot)...].lowercased()
        return fileExtensions.contains(ext)
    }

    nonisolated static func fileNames(in question: String) -> [String] {
        question.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).compactMap { raw in
            let w = String(raw).trimmingCharacters(in: CharacterSet(charactersIn: ",;:?!()[]{}'\"“”‘’"))
            let trimmed = w.hasSuffix(".") ? String(w.dropLast()) : w
            return fileNameShape(trimmed) && trimmed.count > 4 ? trimmed : nil
        }
    }

    /// Reference-like strings: a reporter citation ("112 F. Supp. 2d 780"), or an identifier token
    /// carrying at least three digits plus a letter or separator ("99-1143", "CLM-2024-0091"), or a
    /// bare number of five or more digits. Dates and years are not references.
    nonisolated static func citations(in question: String) -> [String] {
        let words = question.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).map(String.init)
        var out: [String] = []
        let strip = CharacterSet(charactersIn: ",;:?!()[]{}'\"“”‘’")
        func bare(_ w: String) -> String {
            var s = w.trimmingCharacters(in: strip)
            if s.hasSuffix("."), s.dropLast().allSatisfy(\.isNumber) { s.removeLast() }
            return s
        }
        func isNumber(_ w: String, max: Int) -> Bool { !w.isEmpty && w.count <= max && w.allSatisfy(\.isNumber) }
        func isReporterPiece(_ w: String) -> Bool {
            guard let f = w.first else { return false }
            if f.isUppercase { return w.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "&" || $0 == "'" } }
            // ordinal series marker: 2d, 3d, 4th
            let digits = w.prefix(while: \.isNumber)
            let suffix = w.dropFirst(digits.count).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return !digits.isEmpty && ["d", "st", "nd", "rd", "th"].contains(suffix)
        }
        var i = 0
        while i < words.count {
            let first = bare(words[i])
            if isNumber(first, max: 4) {
                var j = i + 1
                var middle: [String] = []
                while j < words.count, middle.count < 5 {
                    let w = bare(words[j])
                    if isNumber(w, max: 5), !middle.isEmpty { break }
                    guard isReporterPiece(w) else { middle = []; break }
                    middle.append(w); j += 1
                }
                if !middle.isEmpty, j < words.count, isNumber(bare(words[j]), max: 5),
                   middle.contains(where: { $0.contains(".") || ($0.count >= 2 && $0.allSatisfy { $0.isUppercase }) }) {
                    out.append(([first] + middle + [bare(words[j])]).joined(separator: " "))
                    i = j + 1
                    continue
                }
            }
            i += 1
        }
        for raw in words {
            let w = bare(raw).trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let digits = w.filter(\.isNumber).count
            guard digits >= 3, !w.contains(where: { "()[]%$€£".contains($0) }) else { continue }
            if isDateShaped(w) || fileNameShape(w) { continue }
            if out.contains(where: { $0.split(separator: " ").contains(Substring(w)) }) { continue }
            let hasLetterOrSeparator = w.contains { $0.isLetter || $0 == "-" || $0 == "/" || $0 == "_" }
            let allDigits = w.allSatisfy(\.isNumber)
            if allDigits ? w.count >= 5 : hasLetterOrSeparator && w.count >= 4 && !w.hasPrefix("$") {
                // "1950s", "2024th" — decades and ordinals are not references.
                let letters = w.filter(\.isLetter).lowercased()
                if !allDigits, w.first?.isNumber == true, ["s", "th", "st", "nd", "rd", "d"].contains(letters) { continue }
                out.append(w)
            }
        }
        return out
    }

    private nonisolated static func isDateShaped(_ w: String) -> Bool {
        let parts = w.split(whereSeparator: { $0 == "-" || $0 == "/" || $0 == "." })
        guard parts.count == 3, parts.allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return false }
        let lens = parts.map(\.count)
        return lens == [4, 2, 2] || lens == [4, 1, 1] || lens == [4, 1, 2] || lens == [4, 2, 1]
            || (lens[0] <= 2 && lens[1] <= 2 && (lens[2] == 2 || lens[2] == 4))
    }

    // MARK: - Matching

    /// Lowercased, diacritic-folded alphanumeric tokens.
    nonisolated static func tokens(_ s: String) -> [String] {
        let folded = s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        var out: [String] = []
        var cur = ""
        for ch in folded {
            if ch.isLetter || ch.isNumber { cur.append(ch) }
            else if !cur.isEmpty { out.append(cur); cur = "" }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    private nonisolated static func tokenMatches(_ want: String, _ have: String) -> Bool {
        if want == have { return true }
        // Abbreviations: "Ins." ↔ "Insurance".
        return (have.count >= 3 && want.hasPrefix(have)) || (want.count >= 3 && have.hasPrefix(want))
    }

    /// Every significant token of a party (one may be missing in a long name) appears in `window`.
    private nonisolated static func covers(_ window: ArraySlice<String>, _ side: [String]) -> Bool {
        guard !side.isEmpty else { return false }
        let hit = side.filter { t in window.contains { tokenMatches(t, $0) } }.count
        let required = side.count >= 4 ? side.count - 1 : side.count
        return hit >= required
    }

    /// Side A just before a "v"/"vs"/"versus" token and side B just after it.
    nonisolated static func captionMatch(_ t: [String], _ a: [String], _ b: [String]) -> Bool {
        for p in t.indices where t[p] == "v" || t[p] == "vs" || t[p] == "versus" {
            let before = t[max(0, p - 10)..<p]
            let after = t[(p + 1)..<min(t.count, p + 15)]
            if covers(before, a) && covers(after, b) { return true }
        }
        return false
    }

    /// The subject just after "in re" / "matter of" / "estate of".
    nonisolated static func inReMatch(_ t: [String], _ a: [String]) -> Bool {
        for p in t.indices {
            let opens = (t[p] == "re" && p > 0 && t[p - 1] == "in")
                || ((t[p] == "matter" || t[p] == "estate") && p + 1 < t.count && t[p + 1] == "of")
            guard opens else { continue }
            let start = t[p] == "re" ? p + 1 : p + 2
            guard start < t.count else { continue }
            if covers(t[start..<min(t.count, start + 12)], a) { return true }
        }
        return false
    }

    /// `run` occurs contiguously in `t`.
    nonisolated static func containsRun(_ t: [String], _ run: [String]) -> Bool {
        guard !run.isEmpty, run.count <= t.count else { return false }
        for s in 0...(t.count - run.count) where t[s] == run[0] {
            if Array(t[s..<(s + run.count)]) == run { return true }
        }
        return false
    }

    /// A candidate document, tokenized once.
    nonisolated struct Prepared: Sendable {
        let head: NamedDocumentHead
        let titleLines: [[String]]
        let headTokens: [String]
        let fileTokens: [String]
        let label: String

        nonisolated init(_ head: NamedDocumentHead) {
            self.head = head
            let window = String(head.headText.prefix(NamedDocumentFocus.headWindow))
            var lines: [String] = []
            if let t = head.title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { lines.append(t) }
            // The first line of text that is not a "Key: value" header; a "Subject:" header is a title.
            var firstLine: String?
            for raw in window.split(whereSeparator: \.isNewline).prefix(12) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty else { continue }
                if let colon = line.firstIndex(of: ":"), line.distance(from: line.startIndex, to: colon) <= 20,
                   line[..<colon].allSatisfy({ $0.isLetter || $0 == "-" }) {
                    if line[..<colon].lowercased() == "subject" || line[..<colon].lowercased() == "title" {
                        lines.append(String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
                    }
                    continue
                }
                if firstLine == nil { firstLine = line; lines.append(line) }
            }
            var stem: String?
            if let f = head.fileName, !f.isEmpty {
                stem = (f as NSString).deletingPathExtension
                lines.append(stem ?? f)
            }
            self.titleLines = lines.map(NamedDocumentFocus.tokens).filter { !$0.isEmpty }
            self.headTokens = NamedDocumentFocus.tokens(window)
            self.fileTokens = NamedDocumentFocus.tokens(head.fileName ?? "")
            let best = head.title.flatMap { $0.isEmpty ? nil : $0 } ?? firstLine ?? head.fileName ?? "the named document"
            self.label = best.count > 120 ? String(best.prefix(117)) + "…" : best
        }
    }
}
