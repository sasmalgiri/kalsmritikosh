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
        ["caseNumber", "court", "plaintiff", "defendant", "hearingDate", "decisionDate", "disposition", "opinionAuthor"]

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
        if let v = DomainPackText.labeledValue(after: ["in the court of", "court of", "before the", "tribunal"], in: text)
            ?? captionCourtName(in: text) {
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
        #"\b((?:Civ\.|Crim\.|Cr\.|Misc\.|C\.\s?A\.|Patent Appeals?)(?:\s+A\.)?(?:\s+No\.)?\s*[A-Z]{0,5}\d[0-9A-Z\-]{0,12}[0-9A-Z])"# + courtAhead,
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
        let head = String(text.prefix(1200))
        // The court's name may carry initials ("District Court, E. D. Illinois."): a period after a
        // single capital does not end it.
        let pattern = #"(?:Court|Circuit|Division|Div\.[^.]{0,20})(?:[^.]|(?<=[\s,][A-Z])\.){0,100}?\.\]?\)?\s+[(\[]?((?:Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|June?|July?|Aug(?:ust)?|Sept?(?:ember)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?)\.?\s+\d{1,2},\s+\d{4})\.?[\])]?(?:\s|$)"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: head, range: NSRange(location: 0, length: (head as NSString).length)) else { return nil }
        return (head as NSString).substring(with: m.range(at: 1))
    }

    /// A US court as a caption names it: "United States Court of Appeals, District of Columbia
    /// Circuit", "District Court, D. Tennessee", "Supreme Court of Pennsylvania". Case bench
    /// 2026-10-18: the labeled rule above expects "In the Court of …", so US captions gave none.
    nonisolated static func captionCourtName(in text: String) -> String? {
        let head = String(text.prefix(1200))
        let pattern = #"(?:United States |U\.\s?S\. )?(?:Circuit Court of Appeals|Court of Appeals|District Court|Supreme Court|Court of Claims|Tax Court|Court of Criminal Appeals|Appellate Court|Superior Court|Bankruptcy Court)(?:,? (?:for the |of the |of )?[A-Z][A-Za-z.]*(?: (?:of )?[A-Z][A-Za-z.]*){0,5})"#
        guard let r = head.range(of: pattern, options: .regularExpression) else { return nil }
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
            #"(?m)^\s*((?:[A-Z][A-Z.'\-]+ ){0,3}[A-Z][A-Z'\-]{2,}),\s+(?:Chief |Senior |Associate |Circuit |District |Presiding )*(?:Circuit |District )?Judge\s*[:.]"#,
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
