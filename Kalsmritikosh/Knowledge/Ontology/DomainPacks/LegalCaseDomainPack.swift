//
//  LegalCaseDomainPack.swift
//  Kalsmritikosh
//
//  Starter pack — the LITIGATION / legal-case domain (the lawyer /
//  forensic / compliance persona). Distinct from ContractDomainPack:
//  contracts are agreements between parties; this pack reads COURT
//  matters — case numbers, courts, plaintiff/defendant, hearing dates.
//  Optional, additive, marker-gated (silent on non-legal text).
//  Deterministic, offline.
//

import Foundation

public enum LegalCaseDomainPack {

    // Live-archive hardening: dropped the loose markers that fire on patent
    // and general correspondence ("hearing", "vs.", " v. ", "tribunal",
    // "adjourned", "court of") — patents have office hearings, and "vs."/
    // "v." appear everywhere. A real litigation document carries a numbered
    // case, named parties, or the court-of formula.
    nonisolated static let markers: [String] = [
        "plaintiff", "defendant", "petitioner", "respondent",
        "case no", "suit no", "in the court of", "hon'ble",
        // Case bench 2026-10-18 — US appellate captions ("Plaintiff-Appellant", "Appellee").
        "appellant", "appellee",
    ]

    nonisolated static func isLegalCase(_ lower: String) -> Bool {
        markers.contains { lower.contains($0) }
    }

    /// caseNumber is an identifier (display constant "Case No."); the rest
    /// are text/date and render their own atom.
    public nonisolated static let emittedFields: [String] =
        ["caseNumber", "court", "plaintiff", "defendant", "hearingDate", "decisionDate", "disposition", "opinionAuthor", "parties"]

    public nonisolated static func extractFacts(
        fromText text: String,
        subjectLabel: String,
        blockID: UUID
    ) -> [GenericFact] {
        let lower = text.lowercased()
        // The decision's closing words ("Affirmed.", "Reversed and remanded.") sit in the last
        // block, which rarely carries the caption markers; the end-of-text pattern is strict
        // enough to run without them.
        var facts: [GenericFact] = []
        if let d = disposition(in: text) {
            facts.append(fact(subjectLabel, "disposition", d, blockID, 0.75))
        }
        // Who wrote the opinion: "SELYA, Circuit Judge:" / "Mr. JUSTICE MORAN delivered the opinion of
        // the court" / "PER CURIAM". Case bench 2026-10-20: "Who wrote the majority opinion in …?" had
        // no fact to answer from, so the answer was a list of passages.
        if let author = opinionAuthor(in: text) {
            facts.append(fact(subjectLabel, "opinionAuthor", author, blockID, 0.75))
        }
        // A case number printed beside the court's name ("No. 4781. Special Supreme Court of
        // Texas.") or the court's name followed by a bare date ("District Court, E. D. Illinois.
        // March 13, 1935.") is a caption by itself, even when no party is labeled by role.
        guard isLegalCase(lower) || numberedBesideCourt(text) || courtLineDate(in: text) != nil else { return facts }

        if let v = DomainPackText.labeledIdentifier(after: ["case no", "suit no", "case number", "c.a. no", "w.p. no",
                                                            "docket no", "docket number"], in: text)
            ?? captionDocketNumber(in: text) ?? flowingDocketNumber(in: text) {
            facts.append(fact(subjectLabel, "caseNumber", v, blockID, 0.8))
        }
        // The caption names the deciding court beside its number or date, or in a short caption
        // block; a long body paragraph naming a court is citing another decision (case bench
        // 2026-10-22: "the Supreme Court of Tennessee held …" became a federal case's court).
        let captionLike = text.count < 400 || numberedBesideCourt(text) || courtLineDate(in: text) != nil
        // A short block that only TELLS of a court ("This suit was filed in the District Court of
        // Grayson County") is narrative; the caption names the court as a heading line.
        let narratesCourt = text.range(of: #"(?i)\b(?:filed|brought|tried|heard|pending|instituted)\s+in\s+the\s+[A-Za-z ]{0,30}Court\b"#,
                                       options: .regularExpression) != nil
        // "In the Court of …" names the deciding court wherever it stands; a bare "court of" in a
        // long paragraph is usually the court below ("This suit was filed in the District Court of
        // Grayson County" — case bench 2026-10-24 answered that for a Court of Civil Appeals case).
        if let v = DomainPackText.labeledValue(after: ["in the court of"], in: text)
            ?? (captionLike && !narratesCourt ? DomainPackText.labeledValue(after: ["court of", "before the", "tribunal"], in: text) : nil)
            ?? (captionLike && !narratesCourt ? captionCourtName(in: text) : nil) {
            facts.append(fact(subjectLabel, "court", v, blockID, 0.7))
        }
        if let v = DomainPackText.labeledValue(after: ["plaintiff", "petitioner", "appellant", "complainant"], in: text),
           PatentDomainPack.isPlausibleRoleValue(v) {
            facts.append(fact(subjectLabel, "plaintiff", v, blockID, 0.7))
        }
        if let v = DomainPackText.labeledValue(after: ["defendant", "respondent", "accused"], in: text),
           PatentDomainPack.isPlausibleRoleValue(v) {
            facts.append(fact(subjectLabel, "defendant", v, blockID, 0.7))
        }
        if let raw = DomainPackText.labeledDate(after: ["hearing on", "date of hearing", "listed on", "next hearing", "adjourned to"], in: text),
           let iso = PatentDomainPack.normalizeDate(raw) {
            facts.append(GenericFact(subjectLabel: subjectLabel, field: "hearingDate", value: iso,
                                     status: .sourceAsserted, confidence: 0.65, sourceBlockIDs: [blockID],
                                     producerVersion: DerivedProducerVersions.facts, rawMatch: raw, sourceCount: 1))
        }
        // The decision date: "Decided July 23, 1993", "Opinion filed August 3, 1971", or the
        // caption's own date line ("August 8, 1924.)"). Case bench 2026-10-18: US decisions
        // carried no decision-date fact at all, so "When was X decided?" had nothing to read.
        if let raw = DomainPackText.labeledDate(after: ["decided", "opinion filed", "date of decision",
                                                        "date of judgment", "judgment dated"], in: text)
            ?? captionDateLine(in: text) ?? courtLineDate(in: text),
           let iso = PatentDomainPack.normalizeDate(raw), iso.count == 10 {
            facts.append(GenericFact(subjectLabel: subjectLabel, field: "decisionDate", value: iso,
                                     status: .sourceAsserted, confidence: 0.7, sourceBlockIDs: [blockID],
                                     producerVersion: DerivedProducerVersions.facts, rawMatch: raw, sourceCount: 1))
        }
        return facts
    }

    /// A caption line that is ONLY a docket number: "No. 92-5255." / "Nos. 87-1234, 87-1235".
    /// The whole-line requirement is what keeps "No. 5 of the agreement" out.
    nonisolated static func captionDocketNumber(in text: String) -> String? {
        for raw in text.components(separatedBy: .newlines).prefix(40) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            // Northern District of Illinois style: "No. 50 C 684." — year, letter, number.
            if let r = line.range(of: #"^Nos?\.\s*\d{1,2} [A-Z]{1,3} \d{1,6}\.?$"#, options: .regularExpression) {
                return line[r].replacingOccurrences(of: #"^Nos?\.\s*|\.$"#, with: "", options: .regularExpression)
            }
            guard let r = line.range(of: #"^(?:Nos?\.|Docket)\s*([A-Za-z0-9][A-Za-z0-9/\-]*[0-9][A-Za-z0-9/\-]*)[.,]?(?:\s*(?:,|and)\s*[A-Za-z0-9/\-]+)*\.?$"#,
                                     options: .regularExpression) else { continue }
            let body = line[r].replacingOccurrences(of: #"^(?:Nos?\.|Docket)\s*"#, with: "", options: .regularExpression)
            let first = body.prefix { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "/" }
            if first.count >= 3, first.contains(where: \.isNumber) { return String(first) }
        }
        return nil
    }

    /// The docket number when the block's line breaks were normalized away: "No. 92-5255"
    /// near the start of a legal block. A hyphenated court number ("92-5255", "3:06-cv-00862")
    /// is what separates it from "No. 5 of the agreement".
    nonisolated static func flowingDocketNumber(in text: String) -> String? {
        let head = String(text.prefix(800))
        let pattern = #"\bNos?\.\s+((?:\d{1,2}:)?\d{1,4}[-–](?:[A-Za-z]{2}[-–])?\d{2,6}(?:[-–][0-9A-Za-z]+)*)"#
        if let r = head.range(of: pattern, options: .regularExpression) {
            return head[r].replacingOccurrences(of: #"^Nos?\.\s+"#, with: "", options: .regularExpression)
        }
        // Second Circuit style: "No. 1497, Docket 93-1070" / "Dockets 92-9236, 92-9238".
        let docket = #"\bDockets?\s+(?:No\.\s*)?((?:\d{1,2}:)?\d{1,4}[-–](?:[A-Za-z]{2}[-–])?\d{2,6})"#
        if let r = head.range(of: docket, options: .regularExpression) {
            return head[r].replacingOccurrences(of: #"^Dockets?\s+(?:No\.\s*)?"#, with: "", options: .regularExpression)
        }
        // Case bench 2026-10-20: most state and older federal reporters number a case plainly —
        // "No. 7861. Supreme Court of North Dakota.", "(No. 4781.) Special Supreme Court of
        // Texas.", "[Civ. No. 33558. Second Dist., Div. Five." — and older F.2d volumes put it
        // after the court-and-date parenthesis: "(Circuit Court of Appeals, Eighth Circuit.
        // August 28, 1924.) No. 6602." An unhyphenated number counts only next to the court.
        for pattern in Self.plainDocketPatterns {
            guard let re = try? NSRegularExpression(pattern: pattern),
                  let m = re.firstMatch(in: head, range: NSRange(location: 0, length: (head as NSString).length)) else { continue }
            return (head as NSString).substring(with: m.range(at: 1))
        }
        return nil
    }

    nonisolated static func numberedBesideCourt(_ text: String) -> Bool {
        let head = String(text.prefix(800))
        return plainDocketPatterns.contains { head.range(of: $0, options: .regularExpression) != nil }
    }

    /// The court's name within the next few words.
    nonisolated static let courtAhead = #"\.?[\])]?\s+(?=(?:[A-Z][A-Za-z.,'’]*\s+){0,8}?(?:Court|Circuit|Dist\.))"#

    nonisolated static let plainDocketPatterns = [
        // A designated number keeps its designation — "Civ. A. No. 9870", "Civ. No. 3730",
        // "Patent Appeals No. 4043": a civil and a criminal number 3730 are different cases.
        // "Crim. Nos. 13662 and 13665." — one decision, two numbers (case bench 2026-10-24).
        #"\b((?:Civ\.|Crim\.|Cr\.|Misc\.|C\.\s?A\.|Patent Appeals?)(?:\s+A\.)?(?:\s+Nos?\.)?\s*[A-Z]{0,5}\d[0-9A-Z\-]{0,12}[0-9A-Z](?:(?:,|\s+and)\s+\d[0-9A-Z\-]{0,12})*)"# + courtAhead,
        // The number, or the whole list ("Nos. 1658, 1662-1664." — one decision, four cases),
        // then the court.
        #"\bNos?\.\s*([A-Z]{0,5}\d[0-9A-Z\-]{0,12}[0-9A-Z](?:,\s*(?:and\s+)?[0-9A-Z\-]+)*)"# + courtAhead,
        // The court-and-date parenthesis, then the number.
        #"(?:Court|Circuit)[^()]{0,80}?\d{4}\.?\)\s*Nos?\.\s*(\d{2,6})\b"#,
    ]

    /// The bare date sentence right after the court's name, when line breaks are gone: "Supreme
    /// Court of Indiana. Jan. 5, 1979.", "(Circuit Court of Appeals, Eighth Circuit. August 28,
    /// 1924.)", "Second Dist., Div. Five. Nov. 18, 1969.]". A labeled date ("Decided …") is read
    /// first; this is the caption's own date for reporters that print no label.
    nonisolated static func courtLineDate(in text: String) -> String? {
        // A long caption (many parties) can push the court line past 1,400 characters.
        let head = String(text.prefix(2500))
        // The court's name may carry initials ("District Court, E. D. Illinois.", "E.D. New
        // York."): a period after a single capital does not end it.
        // "Fifth Dist. Mar. 20, 1981." (California) names the district, not the court; "Court of
        // Civil Appeals of Texas. Waco. March 16, 1939." puts the seat's name before the date.
        let pattern = #"(?:Court|Circuit|Division|Div\.[^.]{0,20}|\bDist(?=\.))(?:[^.]|(?<=[\s,.][A-Z])\.){0,100}?\.-?\]?\)?\s+(?:[A-Z][a-z]+(?: [A-Z][a-z]+)?\.\s+)?[(\[]?((?:Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|June?|July?|Aug(?:ust)?|Sept?(?:ember)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?)\.?\s+\d{1,2},\s+\d{4})\.?[\])]?(?:\s|$)"#
        let ns = head as NSString
        if let re = try? NSRegularExpression(pattern: pattern),
           let m = re.firstMatch(in: head, range: NSRange(location: 0, length: ns.length)) {
            return ns.substring(with: m.range(at: 1))
        }
        // "Circuit Court of Appeals, Fifth Circuit June 24, 1940." — a numbered circuit runs straight
        // into the date with no period (case bench 2026-10-24).
        let circuit = #"\b(?:First|Second|Third|Fourth|Fifth|Sixth|Seventh|Eighth|Ninth|Tenth|Eleventh|Federal|District of Columbia)\s+Circuit,?\s+((?:Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|June?|July?|Aug(?:ust)?|Sept?(?:ember)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?)\.?\s+\d{1,2},\s+\d{4})"#
        guard let re = try? NSRegularExpression(pattern: circuit),
              let m = re.firstMatch(in: head, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    /// The decision date when the caption is split across blocks — HTML and PDF captions put
    /// "Supreme Court of Oklahoma." and "March 27, 1956." in blocks of their own, and a block
    /// holding only a date passes no legal-case gate. Read over the document's first blocks
    /// joined; cites the blocks that carry the court line and the date. Nil when any block
    /// already filed a decision date.
    nonisolated static func documentLevelDecisionDate(blocks: [(id: UUID, text: String)], subjectLabel: String) -> GenericFact? {
        let head = Array(blocks.prefix(20))
        let joined = head.map(\.text).joined(separator: " ")
        // A caption line that is only the date ("March 16, 1939.") when the court line does not
        // run straight into it.
        // "Decided April 5, 1926." among the caption's lines (wide case bench 2026-10-25: a caption
        // whose court line is in parentheses filed no decision date).
        let labeled = DomainPackText.labeledDate(after: ["decided", "opinion filed", "date of decision"], in: head.map(\.text).joined(separator: "\n"))
        guard let raw = courtLineDate(in: joined) ?? labeled ?? captionDateLine(in: head.map(\.text).joined(separator: "\n")),
              let iso = PatentDomainPack.normalizeDate(raw), iso.count == 10,
              let at = head.firstIndex(where: { $0.text.contains(raw) }) else { return nil }
        var cited = [head[at].id]
        // The court line is the nearest earlier block naming a court (none when both share one).
        if let court = head[..<at].last(where: { $0.text.range(of: #"\b(?:Court|Circuit)\b"#, options: .regularExpression) != nil }),
           head[at].text.range(of: #"\b(?:Court|Circuit)\b"#, options: .regularExpression) == nil {
            cited.insert(court.id, at: 0)
        }
        return GenericFact(subjectLabel: subjectLabel, field: "decisionDate", value: iso,
                           status: .sourceAsserted, confidence: 0.7, sourceBlockIDs: cited,
                           producerVersion: DerivedProducerVersions.facts, rawMatch: raw, sourceCount: cited.count)
    }

    /// The caption's docket and court when the caption is split across blocks (HTML and PDF
    /// put "No. 9941." and "Circuit Court of Appeals, Fifth Circuit." in blocks of their own,
    /// and neither passes the per-block legal gate alone). Read over the first blocks joined
    /// line by line, only when the joined head is a caption (a number beside the court, or the
    /// court's line followed by a date). Fields any block already filed are left alone.
    nonisolated static func documentLevelCaption(blocks: [(id: UUID, text: String)], subjectLabel: String,
                                                 have: Set<String>) -> [GenericFact] {
        let head = Array(blocks.prefix(20))
        let joined = head.map(\.text).joined(separator: "\n")
        guard numberedBesideCourt(joined) || courtLineDate(in: joined) != nil || opensWithReportedCaption(joined) else { return [] }
        func block(containing value: String) -> UUID? { head.first(where: { $0.text.contains(value) })?.id }
        // Field names are compared normalized ("decisionDate" is stored as "decisiondate").
        let filed = Set(have.map(FactSchemaRegistry.normalizeField))
        func missing(_ field: String) -> Bool { !filed.contains(FactSchemaRegistry.normalizeField(field)) }
        var out: [GenericFact] = []
        if missing("caseNumber"), let v = captionDocketNumber(in: joined) ?? flowingDocketNumber(in: joined),
           let b = block(containing: v) {
            out.append(fact(subjectLabel, "caseNumber", v, b, 0.8))
        }
        if missing("court"), let v = captionCourtName(in: joined), let b = block(containing: v) {
            out.append(fact(subjectLabel, "court", v, b, 0.7))
        }
        if missing("decisionDate"), let d = documentLevelDecisionDate(blocks: blocks, subjectLabel: subjectLabel) {
            out.append(d)
        }
        if missing("parties"), let v = captionParties(in: joined), let b = block(containing: v) {
            out.append(fact(subjectLabel, "parties", v, b, 0.75))
        }
        return out
    }

    /// A decision that opens with its case name and its reporter citation ("Pinching v. Wurdeman" /
    /// "12 F.2d 164") is a caption even when its court line is printed in a form the other tests do
    /// not read ("(Court of Appeals of District of Columbia. Submitted March. 5, 1926. …"). Wide
    /// case bench 2026-10-25.
    nonisolated static func opensWithReportedCaption(_ text: String) -> Bool {
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.prefix(3)
        guard lines.contains(where: { $0.range(of: #"^[A-Z].{0,120}\s(?:v\.|vs\.)\s[A-Z]|^In re\s[A-Z]"#, options: .regularExpression) != nil }) else { return false }
        return lines.contains { $0.range(of: #"^\d{1,4}\s+(?:[A-Z][A-Za-z.]*\s?(?:\d[a-z]{1,2}\s?)?){1,4}\d{1,5}$"#, options: .regularExpression) != nil }
    }

    /// The parties as the caption's case name gives them: "Sims v. Dallas Ry. & Terminal Co.",
    /// "In re Kindred", "Ex parte Smith". Case bench 2026-10-24: "Who were the parties in X v. Y?"
    /// had no fact to answer from, so the answer was a page of passages. Read only from the first
    /// lines of a document already known to be a caption (the caller's gate); a reporter citation
    /// running on after the name ("In re Kindred 117 Cal. App. 3d 165 [Crim. No. …") is cut off.
    nonisolated static func captionParties(in text: String) -> String? {
        let citation = #"\s+\d{1,4}\s+(?:[A-Z][A-Za-z]*\.?\s?(?:\d[a-z]{1,2}\s)?){1,4}\d{1,5}\b.*$"#
        for raw in text.components(separatedBy: .newlines).prefix(12) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            guard let first = line.first, first.isUppercase else { continue }
            line = line.replacingOccurrences(of: citation, with: "", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: " ,;"))
            guard line.count >= 6, line.count <= 200 else { continue }
            // A sentence citing another decision ("See Smith v. Jones …") is not this case's name.
            if line.range(of: #"^(?:See|Cf\.|But|Accord|Compare|The|This|As|Under|Following)\s"#, options: .regularExpression) != nil { continue }
            if line.range(of: #"^(?:In re|In the Matter of|Ex parte|Matter of)\s+[A-Z]"#, options: .regularExpression) != nil
                || line.range(of: #"^[A-Z].{0,120}?\S\s+(?:v\.|vs\.|versus)\s+[A-Z(]"#, options: .regularExpression) != nil {
                // The caption's closing period goes; an abbreviation's ("Co.", "Ry.", "Inc.") stays.
                let lastWord = line.split(separator: " ").last.map { $0.dropLast() } ?? ""
                return line.hasSuffix(".") && lastWord.count >= 4 ? String(line.dropLast()) : line
            }
        }
        return nil
    }

    /// A US court as a caption names it: "United States Court of Appeals, District of Columbia
    /// Circuit", "District Court, D. Tennessee", "Supreme Court of Pennsylvania". Case bench
    /// 2026-10-18: the labeled rule above expects "In the Court of …", so US captions gave none.
    nonisolated static func captionCourtName(in text: String) -> String? {
        let head = String(text.prefix(1200))
        let pattern = #"(?:United States |U\.\s?S\. )?(?:Circuit Court of Appeals|Court of Civil Appeals|Court of Appeals|District Court|Supreme Court|Court of Claims|Tax Court|Court of Criminal Appeals|Appellate Court|Superior Court|Bankruptcy Court)(?:,? (?:for the |of the |of )?[A-Z][A-Za-z.]*(?: (?:of )?[A-Z][A-Za-z.]*){0,5})?"#
        guard let r = head.range(of: pattern, options: .regularExpression) else { return nil }
        // A bare court type names a court only when it is a national one ("United States Court of
        // Claims", "Tax Court") — "Supreme Court" alone could be anyone's (case bench 2026-10-24).
        let bare = String(head[r])
        let typeOnly = bare.range(of: #"^(?:Circuit Court of Appeals|Court of Civil Appeals|Court of Appeals|District Court|Supreme Court|Court of Claims|Tax Court|Court of Criminal Appeals|Appellate Court|Superior Court|Bankruptcy Court)$"#,
                                  options: .regularExpression) != nil
        if typeOnly, !bare.hasSuffix("Claims"), !bare.hasSuffix("Tax Court") { return nil }
        // A period after a full word ends the name ("… Circuit. Argued"); initials keep it
        // ("District Court, D. Tennessee").
        let v = String(head[r])
            .replacingOccurrences(of: #"([A-Za-z]{3,})\..*$"#, with: "$1", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " ,."))
        return v.count >= 10 ? v : nil
    }

    /// The disposition in a decision's closing words: "Affirmed.", "Reversed and remanded.",
    /// "The judgment of the district court is AFFIRMED." → "affirmed", "reversed and remanded".
    /// Only the LAST sentence is read, and only a sentence made of disposition words (optionally
    /// "The judgment … is"), so prose that merely mentions "affirmed" never matches.
    nonisolated static func disposition(in text: String) -> String? {
        // The LAST standalone disposition sentence in the block: a dissent or concurrence often
        // follows the majority's "Affirmed.", so the text's final sentence is not enough.
        var sentences: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: [.bySentences, .localized]) { s, _, _, _ in
            if let s { sentences.append(s.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        let verbs = "affirmed|reversed|vacated|remanded|dismissed|modified"
        // "Judgment affirmed." carries no verb; "The order and judgment … are affirmed." does.
        let pattern = "^(?:(?:the )?(?:judgments?|orders?|decisions?|convictions?|sentences?)(?:[^.]{0,120}? (?:is|are|be))? )?((?:\(verbs))(?:(?: in part)?(?:,? and|,)(?: in part)? (?:\(verbs)))*(?: in part)?)\\.?$"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        for raw in sentences.reversed() where raw.count <= 200 {
            // Normalization joins a heading to the sentence after it ("CONCLUSION The order …
            // is affirmed."), and decisions often open the line with "For the foregoing
            // reasons, …" — neither is part of the disposition.
            let sentence = raw
                .replacingOccurrences(of: #"^(?:(?!(?:AFFIRMED|REVERSED|VACATED|REMANDED|DISMISSED|MODIFIED)\b)[A-Z]{3,}[.:]?\s+)+"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"^(?i:for (?:the|these|all the) [^,]{0,60}, )"#, with: "", options: .regularExpression)
            guard sentence.count <= 160 else { continue }
            let ns = sentence as NSString
            if let m = re.firstMatch(in: sentence, range: NSRange(location: 0, length: ns.length)) {
                return ns.substring(with: m.range(at: 1)).lowercased()
            }
        }
        return ruling(inClosing: sentences)
    }

    /// Case bench 2026-10-20: most decisions close with the ruling in a full sentence, not a
    /// bare "Affirmed." — "The decree is reversed, and the bill dismissed.", "Defendants' motion
    /// must be, and is hereby, sustained.", "The petition is denied and the judgment of the Board
    /// is affirmed.", "Appeal dismissed." (63% of outcomes were missed). Read only the closing
    /// sentences (boilerplate such as "An order will be entered accordingly." or "X, J., concur."
    /// skipped), and only a present-tense ruling on the decision's own subject — "the motion was
    /// denied" is the case's history, not its outcome.
    nonisolated static let rulingVerbs = "affirmed|reversed|vacated|remanded|dismissed|modified|denied|granted|sustained|overruled|set aside"

    nonisolated static func ruling(inClosing sentences: [String]) -> String? {
        let subject = "judgments?|decrees?|orders?|decisions?|petitions?|motions?|writs?|appeals?|applications?|cases?|convictions?|sentences?|demurrers?|bill|complaint|libel|cause"
        let clause = "^.{0,70}?\\b(?:the|these|this|its|his|her|their|[a-z]+['’]s?)\\s+(?:[a-z]+\\s+){0,3}?(?:\(subject))\\b[^.;]{0,160}?\\b(?:is|are|be)\\b(?:,? and (?:it )?(?:is )?hereby,?)?(?:,? (?:therefore|hereby|severally|accordingly|in all respects))*,? (\(rulingVerbs))\\b"
        let short = "^(?:the )?(?:\(subject)) (\(rulingVerbs))\\.?$"
        let boilerplate = ["concur", "entered accordingly", "so ordered", "order accordingly", "costs", "mandate"]
        guard let clauseRE = try? NSRegularExpression(pattern: clause, options: [.caseInsensitive]),
              let shortRE = try? NSRegularExpression(pattern: short, options: [.caseInsensitive]) else { return nil }
        let closing = sentences.reversed().filter { s in
            !boilerplate.contains { s.lowercased().contains($0) } || s.count > 80
        }.prefix(3)
        for sentence in closing where sentence.count <= 400 {
            let ns = sentence as NSString
            let range = NSRange(location: 0, length: ns.length)
            if let m = shortRE.firstMatch(in: sentence, range: range) ?? clauseRE.firstMatch(in: sentence, range: range) {
                var verbs = [ns.substring(with: m.range(at: 1)).lowercased()]
                // A second ruling in the same sentence: "… is reversed, and the bill dismissed".
                let rest = ns.substring(from: m.range.location + m.range.length)
                if let r = rest.range(of: "^[^.;]{0,80}?\\band\\b[^.;]{0,60}?\\b(\(rulingVerbs))\\b", options: [.regularExpression, .caseInsensitive]),
                   let v = rest[r].range(of: "(\(rulingVerbs))$", options: [.regularExpression, .caseInsensitive]) {
                    verbs.append(rest[v].lowercased())
                }
                return verbs.joined(separator: " and ")
            }
        }
        return nil
    }

    /// The judge who delivered the opinion, as the opinion's own header line names them.
    nonisolated static func opinionAuthor(in text: String) -> String? {
        let head = String(text.prefix(20_000))
        let patterns = [
            // "SELYA, Circuit Judge." / "KEARSE, Circuit Judge:" / "RUTH BADER GINSBURG, Circuit Judge:"
            // — at a line start, or after a sentence end: packs read the block's normalized
            // text, whose line breaks are gone (case bench 2026-10-21: "… for defendants-
            // appellants. CALABRIA, Judge. CALABRIA, Judge. Assurance …" filed no author).
            // Also "VAN ORSDEL, Associate Justice." / "ALEXANDER, Justice." / "YOUNG, 'Justice." (stray
            // mark from the source) / "BROWN, J." — never "SMITH, J., concurring" and never a list
            // ("Before MARTIN, Chief Justice, VAN ORSDEL, …": no terminator after the title).
            #"(?m)(?:^\s*|(?<=[.:;]\s))((?:[A-Z][A-Z.'\-]+ ){0,3}[A-Z][A-Z'\-]{2,}),\s+['‘’]?(?:Chief |Senior |Associate |Circuit |District |Presiding )*(?:Circuit |District )?(?:(?:Judge|Justice)\s*[:.]|(?:C\.\s?|P\.\s?)?J\.(?!,)(?=\s|$))"#,
            // California: "BROWN (G. A.), P. J." — the surname, the initials in parentheses, the title
            // (case bench 2026-10-24).
            #"(?m)(?:^\s*|(?<=[.:;]\s))([A-Z][A-Z'\-]{2,})\s+\([A-Z][A-Z.\s]{0,10}\),\s+(?:(?:C\.\s?|P\.\s?)?J\.|Acting P\.\s?J\.)(?=\s|$)"#,
            // "Mr. JUSTICE MORAN delivered the opinion of the court" / "Justice Moran delivered …"
            #"(?:Mr\.\s+|Mrs\.\s+|Ms\.\s+)?(?:Chief\s+)?(?:JUSTICE|Justice)\s+([A-Z][A-Za-z'\-]+(?:\s+[A-Z][A-Za-z'\-]+)?)\s+delivered the opinion"#,
        ]
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p) else { continue }
            let ns = head as NSString
            if let m = re.firstMatch(in: head, range: NSRange(location: 0, length: ns.length)) {
                let name = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
                return name.capitalized
            }
        }
        if head.range(of: #"(?m)^\s*PER CURIAM[.:]?\s*$"#, options: .regularExpression) != nil { return "Per curiam" }
        return nil
    }

    /// A caption line that is ONLY a date ("August 8, 1924.)"), among the first lines.
    nonisolated static func captionDateLine(in text: String) -> String? {
        for raw in text.components(separatedBy: .newlines).prefix(25) {
            let line = raw.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".()[]")))
            guard line.count <= 22, let d = DomainPackText.firstDate(in: line), d.count >= line.count - 1 else { continue }
            return d
        }
        return nil
    }

    nonisolated static func fact(_ subject: String, _ field: String, _ value: String,
                                 _ block: UUID, _ conf: Double) -> GenericFact {
        GenericFact(subjectLabel: subject, field: field, value: value,
                    status: .sourceAsserted, confidence: conf, sourceBlockIDs: [block],
                    producerVersion: DerivedProducerVersions.facts, rawMatch: value, sourceCount: 1)
    }
}
